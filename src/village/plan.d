// The village map: a seeded layout of landmarks (west gate, plaza, đình hall, market, temple,
// smithy, homes) turned into WFC anchors, generated through MapSession, then checked for
// walkability. The terrain around the anchors is ordinary seeded WFC, so every playthrough seed
// gives a different village with the same story landmarks. Model layer: no SDL, @nogc nothrow.
module village.plan;

import core.random : Random;
import core.result;
import wfc.decorations;
import wfc.grid_connector : MapRect;
import wfc.hex;
import wfc.map_session;
import wfc.passability : unreachable;
import village.walk;

enum int villageCols = 40;
enum int villageRows = 28;
/// Village layouts tried (each with a derived seed) before generation gives up.
enum int maxVillageAttempts = 8;
private enum int maxAnchors = 192;
private enum int numHomes = 5;
private enum int numTrees = 8;

/// Named places: where NPCs live and the zones story triggers react to.
enum Landmark : ubyte {
    /// Just inside the west gate (the guard's post).
    gate,
    plaza,
    hall,
    market,
    temple,
    smithy,
    /// In front of the first home.
    home
}

enum int numLandmarks = Landmark.max + 1;

/// Story names of the landmarks (zone and NPC home ids in the story data).
immutable string[numLandmarks] landmarkNames = [
    "gate", "plaza", "hall", "market", "temple", "smithy", "home"
];

/// Landmark by story name, or -1.
int landmarkByName(const(char)[] n) @nogc nothrow pure @safe {
    foreach (i, ln; landmarkNames)
        if (ln == n)
            return cast(int)i;
    return -1;
}

@nogc nothrow pure @safe unittest {
    assert(landmarkByName("temple") == Landmark.temple && landmarkByName("nowhere") == -1);
}

/// Direction of the neighbor of `a` closest to `b` (ties go to the lower HexDir).
HexDir dirToward(const CubeCoord a, const CubeCoord b) @nogc nothrow pure @safe {
    HexDir best = HexDir.E;
    int bd = int.max;
    foreach (d; 0 .. numHexDirs) {
        immutable dist = cubeDistance(a.neighbor(cast(HexDir)d), b);
        if (dist < bd) {
            bd = dist;
            best = cast(HexDir)d;
        }
    }
    return best;
}

@nogc nothrow pure @safe unittest {
    immutable o = offsetToCube(5, 5);
    assert(dirToward(o, offsetToCube(9, 5)) == HexDir.E && dirToward(o, offsetToCube(1, 5)) == HexDir.W);
    assert(o.neighbor(dirToward(o, o.neighbor(HexDir.SW))) == o.neighbor(HexDir.SW));
}

struct VillagePlan {
    MapRect rect = MapRect(villageCols, villageRows);
    uint seed;
    int gateRow;
    /// Where each landmark's NPC stands; the zone around it is the landmark's trigger area.
    CubeCoord[numLandmarks] spot;
    /// The road's ends: just inside the gate, and the plaza center.
    CubeCoord roadStart, roadEnd;
    Anchor[maxAnchors] anchors;
    int numAnchors;
    /// Anchors that carry a building the layout cannot do without (checked after generation).
    ubyte[maxAnchors] required;

    const(Anchor)[] anchorList() const return @nogc nothrow pure @safe {
        return anchors[0 .. numAnchors];
    }

    /// Cells on the west edge the player leaves through.
    bool isExit(const CubeCoord c) const @nogc nothrow pure @safe {
        immutable o = cubeToOffset(c);
        return o.col == 0 && o.row >= gateRow - 1 && o.row <= gateRow + 1;
    }

    /// Session parameters for this layout (the anchors are borrowed from the plan).
    GenParams params() const return @nogc nothrow pure @safe {
        GenParams p;
        p.layout = Layout.rect;
        p.cols = rect.cols;
        p.rows = rect.rows;
        p.radius = 6;
        p.seed = seed;
        // The terrain noise already sinks the border; fixed perimeter ocean would fight the gate.
        p.gen.oceanSpacing = 0;
        p.terrain.seaLevel = 0.22f;
        p.terrain.edgeFalloff = 3;
        // Low, green land: the atlas turns the top levels to snow.
        p.terrain.landLevels = 2;
        p.terrain.peakHeight = 0.97f;
        p.terrain.riverWidth = 0.035f;
        p.deco.treeThreshold = 0.62f;
        p.routes.wallDepth = 0;
        p.routes.flankTerrain = false;
        p.routes.walled = false;
        // Buildings count as off-map to the road planner, so roads may pass right beside them.
        p.routes.roadMargin = 0;
        p.routes.bendiness = 120;
        p.routes.waypoints = 0;
        p.reveal.enabled = false;
        p.pinned.numSources = 1;
        p.pinned.sources[0] = roadStart;
        // Every landmark is a road end, so paths link them all to the gate road.
        p.pinned.numSinks = 0;
        p.pinned.sinks[p.pinned.numSinks++] = roadEnd;
        foreach (l; [
            Landmark.hall, Landmark.market, Landmark.temple, Landmark.smithy, Landmark.home
        ])
            if (spot[l] != roadEnd)
                p.pinned.sinks[p.pinned.numSinks++] = spot[l];
        p.anchors = anchorList;
        return p;
    }

    private bool anchoredAt(const CubeCoord c) const @nogc nothrow pure @safe {
        foreach (ref a; anchors[0 .. numAnchors])
            if (a.cell == c)
                return true;
        return false;
    }

    /// Adds an anchor (a later anchor on the same cell is ignored, so earlier ones win).
    private void add(const CubeCoord c, Decoration d = Decoration.init, bool req = false) @nogc nothrow pure @safe {
        if (numAnchors == maxAnchors || !rect.contains(c) || anchoredAt(c))
            return;
        anchors[numAnchors] = Anchor(c, d);
        required[numAnchors] = req;
        numAnchors++;
    }

    private void clearDisk(const CubeCoord c, int radius) @nogc nothrow pure @safe {
        CubeCoord[37] near = void;
        immutable n = cubeCoordsInRadius(c, radius, near[]);
        foreach (i; 0 .. n)
            add(near[i]);
    }

    /// A building facing `toward`, with the cell in front of it kept open; returns that cell.
    private CubeCoord building(const CubeCoord c, VillageProp p, const CubeCoord toward) @nogc nothrow pure @safe {
        immutable face = dirToward(c, toward);
        immutable front = c.neighbor(face);
        add(c, Decoration(DecoKind.village, p, face, 0), true);
        add(front);
        return front;
    }

    /// True if `c` keeps `gap` cells from every anchor and stays off the map border.
    private bool clearOf(const CubeCoord c, int gap) const @nogc nothrow pure @safe {
        immutable o = cubeToOffset(c);
        if (o.col < 3 || o.row < 2 || o.col >= rect.cols - 2 || o.row >= rect.rows - 2)
            return false;
        foreach (ref a; anchors[0 .. numAnchors])
            if (cubeDistance(a.cell, c) <= gap)
                return false;
        return true;
    }
}

private CubeCoord walk(CubeCoord c, HexDir d, int steps) @nogc nothrow pure @safe {
    foreach (_; 0 .. steps)
        c = c.neighbor(d);
    return c;
}

/// Lays out the landmarks for `seed` (pure: same seed, same plan).
void planVillage(uint seed, out VillagePlan plan) @nogc nothrow @safe {
    auto rng = Random(seed ^ 0x7111A6Eu);
    plan.seed = seed;
    with (plan) {
        immutable mid = rect.rows / 2;
        gateRow = mid - 2 + cast(int)rng.below(5);
        immutable plazaCol = rect.cols * 11 / 20 - 2 + cast(int)rng.below(5);
        immutable plaza = offsetToCube(plazaCol, mid - 2 + cast(int)rng.below(5));
        roadStart = offsetToCube(4, gateRow);
        roadEnd = plaza;

        // The gate arch on the open path out of the west edge, lanterns either side.
        add(offsetToCube(1, gateRow), Decoration(DecoKind.village, VillageProp.gate, HexDir.W, 0), true);
        foreach (col; 0 .. 5)
            add(offsetToCube(col, gateRow));
        add(offsetToCube(0, gateRow - 1));
        add(offsetToCube(0, gateRow + 1));
        add(offsetToCube(2, gateRow - 1), Decoration(DecoKind.village, VillageProp.lantern, HexDir.W, 0));
        add(offsetToCube(2, gateRow + 1), Decoration(DecoKind.village, VillageProp.lantern, HexDir.W, 0));
        spot[Landmark.gate] = offsetToCube(3, gateRow - 1);
        add(spot[Landmark.gate]);

        // The plaza: an open disk around the road's end, a well on its rim.
        add(walk(plaza, HexDir.NW, 2), Decoration(DecoKind.village, VillageProp.well, HexDir.SE, 0), true);
        clearDisk(plaza, 2);
        spot[Landmark.plaza] = plaza.neighbor(HexDir.E);

        // The đình hall north-east of the plaza, the market south-east, both facing it.
        spot[Landmark.hall] = building(walk(plaza, HexDir.NE, 4), VillageProp.dinhHall, plaza);
        spot[Landmark.market] = building(walk(plaza, HexDir.SE, 4), VillageProp.marketStall, plaza);
        building(walk(plaza, HexDir.SE, 4).neighbor(HexDir.E), VillageProp.marketStall, plaza);
        add(walk(plaza, HexDir.SE, 3).neighbor(HexDir.E), Decoration(DecoKind.village,
                VillageProp.lantern, HexDir.W, 0));

        // The temple on its own pad east of the plaza.
        immutable temple = walk(plaza, HexDir.E, 7);
        spot[Landmark.temple] = building(temple, VillageProp.temple, plaza);
        clearDisk(spot[Landmark.temple], 1);

        // The smithy halfway along the road, set back to the north.
        immutable half = offsetToCube((4 + plazaCol) / 2, gateRow - 3);
        spot[Landmark.smithy] = building(half, VillageProp.stiltHouse, half.neighbor(HexDir.SE).neighbor(HexDir.SE));

        // Homes and trees scattered around the plaza, clear of everything else.
        int homes = 0, trees = 0;
        foreach (tries; 0 .. 400) {
            if (homes == numHomes && trees == numTrees)
                break;
            immutable c = offsetToCube(3 + cast(int)rng.below(rect.cols - 5), 2 + cast(int)rng.below(rect.rows - 4));
            immutable d = cubeDistance(c, plaza);
            if (homes < numHomes && d >= 4 && d <= 10 && plan.clearOf(c, 2)) {
                immutable front = building(c, VillageProp.stiltHouse, plaza);
                if (homes++ == 0)
                    spot[Landmark.home] = front;
            } else if (trees < numTrees && d >= 3 && plan.clearOf(c, 1)) {
                add(c, Decoration(DecoKind.village, rng.below(2) ? VillageProp.palm
                        : VillageProp.banana, cast(HexDir)rng.below(6), 0));
                trees++;
            }
        }
        if (homes == 0)
            spot[Landmark.home] = spot[Landmark.plaza];
    }
}

@nogc nothrow @safe unittest {
    VillagePlan a, b, c;
    planVillage(5, a);
    planVillage(5, b);
    planVillage(6, c);
    assert(a.numAnchors == b.numAnchors && a.anchors == b.anchors && a.spot == b.spot);
    assert(a.anchors != c.anchors);
    assert(a.numAnchors > 40 && a.numAnchors <= maxAnchors);
    assert(cubeToOffset(a.roadStart).col == 4 && a.isExit(offsetToCube(0, a.gateRow)));
    assert(!a.isExit(offsetToCube(1, a.gateRow)) && !a.isExit(offsetToCube(0, a.gateRow + 2)));
    foreach (ref s; a.spot)
        assert(a.rect.contains(s));
    // Required buildings: the gate, the well, hall, two stalls, temple, smithy and some homes.
    int req = 0;
    foreach (i; 0 .. a.numAnchors)
        req += a.required[i];
    assert(req >= 8);
    const p = a.params();
    assert(p.anchors.length == a.numAnchors && p.pinned.sinks[0] == a.roadEnd && !p.routes.walled);
}

enum VillageError : ubyte {
    none,
    /// A required building was overwritten by the road.
    buildingLost,
    /// The gate, the plaza or a landmark cannot be walked to from the west edge.
    unreachable,
    /// The session rejected the parameters or no road could be planned.
    generation
}

/// Checks a generated village: every required building stands, and the plaza and every landmark
/// can be walked to from the west exit. `dist` needs rect.cellCount entries.
VillageError checkVillage(ref const VillagePlan plan, ref const MapSession s, ref const WalkGrid walk, ushort[] dist) @nogc nothrow @trusted {
    foreach (i; 0 .. plan.numAnchors)
        if (plan.required[i] && s.decorations.get(plan.anchors[i].cell) != plan.anchors[i].deco)
            return VillageError.buildingLost;
    walk.distances(offsetToCube(0, plan.gateRow), dist);
    if (dist[plan.rect.index(plan.roadEnd)] == unreachable)
        return VillageError.unreachable;
    foreach (ref c; plan.spot)
        if (dist[plan.rect.index(c)] == unreachable)
            return VillageError.unreachable;
    return VillageError.none;
}

/// Generates the village for `seed` into `s` and `walk`, trying derived layouts until one checks
/// out; returns the number of attempts used.
Result!(int, VillageError) buildVillage(MapSession* s, uint seed, ref VillagePlan plan, ref WalkGrid walk) @nogc nothrow @trusted {
    import core.stdc.stdlib : free, malloc;

    alias R = Result!(int, VillageError);
    auto dist = cast(ushort*)malloc(villageCols * villageRows * ushort.sizeof);
    assert(dist !is null, "village distance allocation failed");
    scope (exit)
        free(dist);
    VillageError last = VillageError.generation;
    foreach (attempt; 0 .. maxVillageAttempts) {
        planVillage(seed + cast(uint)attempt * 0x51ED27u, plan);
        if (s.regenerate(plan.params()).isErr || !s.routeReport.okOpen) {
            last = VillageError.generation;
            continue;
        }
        walk.build(s.tiles, s.nav, s.rules);
        last = checkVillage(plan, *s, walk, dist[0 .. villageCols * villageRows]);
        if (last == VillageError.none)
            return R.ok(attempt + 1);
    }
    return R.err(last);
}

@nogc nothrow unittest {
    // Most seeds give a valid village within a few attempts; the result is deterministic.
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    VillagePlan plan, again;
    WalkGrid walk;
    int ok = 0;
    foreach (seed; 1 .. 7) {
        auto r = buildVillage(s, seed, plan, walk);
        if (r.isErr)
            continue;
        ok++;
        assert(walk.standable(offsetToCube(0, plan.gateRow)));
        immutable tiles0 = s.tiles.get(plan.roadEnd);
        WalkGrid w2;
        assert(buildVillage(s, seed, again, w2).isOk && again.anchors == plan.anchors);
        assert(s.tiles.get(plan.roadEnd) == tiles0);
    }
    assert(ok >= 5);
}
