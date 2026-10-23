// A scripted player that stands in for the human Controller (AGENTS.md §1.2): it builds a mix of
// towers on the cells that cover the most road, spread over every source's lane, upgrades them, and puts mines on gold veins. Used
// by the headless integration test and the viewer's --bot flag. It only issues GameCommands, so
// its games replay like any other. Headless Model.
module td.bot;

import core.stdc.stdlib : calloc, malloc, free;
import td.board;
import td.defs;
import td.game;
import wfc.hex;

struct Bot {
    private struct Spot {
        int col, row;
        int score;
        /// Sources whose walk to a sink passes within reach.
        ushort lanes;
    }

    private Spot* spots;
    // Per cell: the sources whose walk passes through it.
    private ushort* laneAt;
    private int numLanes;
    private int numSpots;
    private int[numTowerKinds] built;
    private int decisions;
    private int rankedStage;
    /// Ticks between decisions.
    int every = 20;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(spots);
        free(laneAt);
    }

    enum int maxSpots = 512;

    /// Starts on `g`'s board.
    void setup(ref const Game g) @nogc nothrow @trusted {
        free(spots);
        spots = cast(Spot*)malloc(maxSpots * Spot.sizeof);
        assert(spots !is null);
        built[] = 0;
        decisions = 0;
        rank(g);
    }

    /// Ranks the board's buildable cells by how much road lies within a typical tower range (again
    /// whenever a reveal changes the board).
    private void rank(ref const Game g) @nogc nothrow @trusted {
        numSpots = 0;
        rankedStage = g.board.stage;
        const b = &g.board();
        // Traffic: how many sources' walks to a sink pass each cell (steepest descent, first
        // candidate), so towers go where every creep passes, not on a branch one source uses.
        auto traffic = cast(ubyte*)calloc(b.rect.cellCount, 1);
        free(laneAt);
        laneAt = cast(ushort*)calloc(b.rect.cellCount, ushort.sizeof);
        assert(traffic !is null && laneAt !is null);
        numLanes = b.numSources;
        scope (exit)
            free(traffic);
        foreach (k; 0 .. b.numSources) {
            CubeCoord c = b.sources[k];
            foreach (step; 0 .. b.rect.cellCount) {
                immutable i = b.rect.index(c);
                if (traffic[i] < 255)
                    traffic[i]++;
                laneAt[i] |= cast(ushort)(1 << k);
                immutable d = b.distAt(i);
                if (d == 0)
                    break;
                bool moved = false;
                foreach (dir; 0 .. numHexDirs) {
                    immutable nc = c.neighbor(cast(HexDir)dir);
                    if (b.rect.contains(nc) && b.distAt(b.rect.index(nc)) == d - 1) {
                        c = nc;
                        moved = true;
                        break;
                    }
                }
                if (!moved)
                    break;
            }
        }
        CubeCoord[19] near = void;
        foreach (i; 0 .. b.rect.cellCount) {
            if (!(b.flagsAt(i) & CellFlag.buildable))
                continue;
            immutable c = b.rect.cellAt(i);
            immutable lanes = lanesNear(*b, c);
            immutable n = cubeCoordsInRadius(c, reach, near[]);
            int score = 0;
            foreach (k; 0 .. n)
                if (b.rect.contains(near[k]))
                    score += traffic[b.rect.index(near[k])] * (3 - cubeDistance(c, near[k]));
            if (b.specialAt(i) == SpecialKind.goldVein)
                score = 1000; // mines first, whatever the road
            else if (score == 0)
                continue;
            if (b.specialAt(i) == SpecialKind.leyStone)
                score += 4;
            score = score * 64 + cast(int)(mix(cast(uint)i, 0xB07u) & 63);
            // Keep the best maxSpots, sorted descending (insertion).
            if (numSpots == maxSpots && score <= spots[numSpots - 1].score)
                continue;
            int j = numSpots < maxSpots ? numSpots++ : numSpots - 1;
            while (j > 0 && spots[j - 1].score < score) {
                spots[j] = spots[j - 1];
                j--;
            }
            immutable o = cubeToOffset(c);
            spots[j] = Spot(o.col, o.row, score, lanes);
        }
    }

    /// Takes one turn every `every` ticks: spend gold on a tower, a mine or an upgrade.
    void act(ref Game g) @nogc nothrow @trusted {
        if (spots is null || g.tick % every != 0)
            return;
        if (g.status != GameStatus.waiting && g.status != GameStatus.wave)
            return;
        if (g.board.stage != rankedStage)
            rank(g);
        decisions++;
        // Mines on free veins pay for themselves within a few waves.
        foreach (k; 0 .. numSpots) {
            const s = &spots[k];
            if (g.board.special(s.col, s.row) != SpecialKind.goldVein || g.towerAt(s.col, s.row) !is null)
                continue;
            if (g.gold >= towerStats(TowerKind.mine, Stage.lv1).cost + 60 && g.waveNo >= 2)
                if (g.apply(GameCommand(CommandType.place, TowerKind.mine, 0, s.col, s.row)) == CommandError.none)
                    return;
            break;
        }
        // Alternate between building and upgrading once a few towers stand.
        immutable towers = built[0] + built[1] + built[2] + built[3] + built[4];
        if (towers >= 4 && decisions % 3 == 0 && upgrade(g))
            return;
        static immutable TowerKind[8] order = [
            TowerKind.arrow, TowerKind.cannon, TowerKind.frost, TowerKind.arrow, TowerKind.tesla,
            TowerKind.flame, TowerKind.cannon, TowerKind.tesla
        ];
        immutable kind = order[towers % order.length];
        if (g.gold < towerStats(kind, Stage.lv1).cost)
            return;
        // The least defended lane first, then anywhere.
        immutable lane = weakestLane(g);
        foreach (pass; 0 .. 2)
            foreach (k; 0 .. numSpots) {
                const s = &spots[k];
                if (pass == 0 && !(s.lanes & (1 << lane)))
                    continue;
                if (g.canPlace(kind, s.col, s.row) != CommandError.none)
                    continue;
                if (g.apply(GameCommand(CommandType.place, kind, 0, s.col, s.row)) == CommandError.none) {
                    built[kind]++;
                    return;
                }
            }
        upgrade(g);
    }

    private enum int reach = 2;

    /// Sources whose walk passes within reach of `c`.
    private ushort lanesNear(ref const Board b, const CubeCoord c) const @nogc nothrow @trusted {
        CubeCoord[19] near = void;
        immutable n = cubeCoordsInRadius(c, reach, near[]);
        ushort m = 0;
        foreach (k; 0 .. n)
            if (b.rect.contains(near[k]))
                m |= laneAt[b.rect.index(near[k])];
        return m;
    }

    /// The source lane with the fewest towers covering it.
    private int weakestLane(ref const Game g) const @nogc nothrow @trusted {
        int[16] cover;
        foreach (ref t; g.towers) {
            if (!t.alive || t.kind == TowerKind.mine)
                continue;
            immutable m = lanesNear(g.board, g.board.rect.cellAt(t.cell));
            foreach (l; 0 .. numLanes)
                cover[l] += (m >> l) & 1;
        }
        int best = 0;
        foreach (l; 1 .. numLanes)
            if (cover[l] < cover[best])
                best = l;
        return best;
    }

    /// Upgrades the affordable tower furthest behind; true if it did.
    private bool upgrade(ref Game g) @nogc nothrow @trusted {
        int best = -1, bestStage = int.max;
        foreach (i, ref t; g.towers) {
            if (!t.alive)
                continue;
            Stage next;
            immutable branch = cast(int)(mix(t.cell, 0x8A4u) & 1);
            if (!nextStage(t.kind, t.stage, branch, next) || g.gold < towerStats(t.kind, next).cost)
                continue;
            if (tierOf(t.stage) < bestStage) {
                bestStage = tierOf(t.stage);
                best = cast(int)i;
            }
        }
        if (best < 0)
            return false;
        const t = &g.towers[best];
        return g.apply(GameCommand(CommandType.upgrade, t.kind, cast(ubyte)(mix(t.cell, 0x8A4u) & 1), t.col, t.row)) == CommandError
            .none;
    }
}

@nogc nothrow unittest {
    import wfc.map_session : GenParams, MapSession;

    // On a generated map the bot builds a mix of towers near the road and survives the first waves.
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    GenParams p;
    p.cols = 72;
    p.rows = 40;
    p.radius = 6;
    p.seed = 3;
    assert(s.regenerate(p).isOk);
    Game g;
    g.start(*s, 93);
    Bot bot;
    bot.setup(g);
    foreach (t; 0 .. 6000) {
        bot.act(g);
        g.advance();
    }
    int alive = 0;
    bool[numTowerKinds] kinds;
    foreach (ref t; g.towers)
        if (t.alive) {
            alive++;
            kinds[t.kind] = true;
        }
    assert(alive >= 4 && kinds[TowerKind.arrow] && kinds[TowerKind.cannon]);
    assert(g.waveNo >= 3 && g.status != GameStatus.lost);
}
