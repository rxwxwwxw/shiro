// The village's defenses between battles: the towers standing on the battlefield (with their
// crews and wear), the treasury, and how many battles have been fought. A tower defense Game is
// built from it for each visit (midweek planning or Saturday's battle) and saved back afterwards,
// so the battlefield persists for the whole campaign. Headless Model: no SDL, @nogc nothrow.
module campaign.fort;

import td.catalog;
import td.defs;
import td.game;

enum int maxFortTowers = 256;

struct FortTower {
    int col, row;
    TowerKind kind;
    Stage stage;
    Targeting targeting;
    int invested;
    /// Hit points left (0: wrecked, rebuilt by repairing it).
    int hp;
    /// Villager manning it (story speaker index), or noCrew.
    ubyte crew = noCrew;
}

struct Fort {
    FortTower[maxFortTowers] towers;
    int numTowers;
    /// Gold carried between battles (the battlefield's purse).
    int gold;
    /// Battles fought so far (Saturday waves continue from them).
    int battles;

    /// A fresh campaign: no towers, the rules' starting gold.
    void begin(ref const Catalog cat) @nogc nothrow pure @safe {
        numTowers = 0;
        gold = cat.econ.startGold;
        battles = 0;
    }

    /// Keeps the game's towers and gold (after a visit or a battle).
    void save(ref const Game g) @nogc nothrow @safe {
        numTowers = 0;
        foreach (ref t; g.towers) {
            if (!t.alive || numTowers == maxFortTowers)
                continue;
            towers[numTowers++] = FortTower(t.col, t.row, t.kind, t.stage, t.targeting, t.invested, t.hp, t.crew);
        }
        gold = g.gold;
    }

    /// Puts the towers into `g` (just begun on the battlefield) and sets its gold.
    void restore(ref Game g) const @nogc nothrow @safe {
        foreach (ref t; towers[0 .. numTowers])
            g.restoreTower(t.kind, t.stage, t.col, t.row, t.targeting, t.invested, t.hp, t.crew);
        g.gold = gold;
    }

    /// Tower on (col, row), or null.
    inout(FortTower)* at(int col, int row) inout return @nogc nothrow pure @trusted {
        foreach (i; 0 .. numTowers)
            if (towers[i].col == col && towers[i].row == row)
                return &towers[i];
        return null;
    }

    ulong hash() const @nogc nothrow pure @safe {
        ulong h = 0xCBF29CE484222325UL;
        void put(long v) {
            h = (h ^ cast(ulong)v) * 0x100000001B3UL;
        }

        put(numTowers);
        put(gold);
        put(battles);
        foreach (ref t; towers[0 .. numTowers]) {
            put(t.col * 65_536 + t.row);
            put(t.kind * 64 + t.stage);
            put(t.targeting);
            put(t.invested);
            put(t.hp);
            put(t.crew);
        }
        return h;
    }
}

version (unittest) {
    import td.board : CellFlag;
    import wfc.grid_connector : MapRect;

    /// A 12 x 5 board with a road on row 2.
    private void fieldBoard(ref Game g) @nogc nothrow @trusted {
        auto b = &g.boardForSetup();
        b.allocate(MapRect(12, 5));
        foreach (row; 0 .. 5)
            foreach (col; 0 .. 12)
                b.setCell(col, row, row == 2 ? cast(ubyte)(CellFlag.walk | CellFlag.road | (col == 0
                        ? CellFlag.source : 0) | (col == 11 ? CellFlag.sink : 0)) : CellFlag.buildable);
        b.finish(1, false);
        g.begin(1);
    }
}

@nogc nothrow @trusted unittest {
    // A visit's towers, crews and gold survive into the next game on the same battlefield.
    static Fort f;
    f.begin(defaultCatalog);
    assert(f.gold == startGold && f.numTowers == 0);
    Game a;
    fieldBoard(a);
    f.restore(a);
    a.startPlanning();
    assert(a.apply(GameCommand(CommandType.place, TowerKind.frost, 0, 3, 1)) == CommandError.none);
    assert(a.apply(GameCommand(CommandType.upgrade, TowerKind.frost, 0, 3, 1)) == CommandError.none);
    assert(a.apply(GameCommand(CommandType.assignCrew, TowerKind.frost, 7, 3, 1)) == CommandError.none);
    f.save(a);
    assert(f.numTowers == 1 && f.gold == a.gold && f.at(3, 1).crew == 7 && f.at(4, 1) is null);
    immutable h = f.hash();
    Game b;
    fieldBoard(b);
    f.restore(b);
    const t = b.towerAt(3, 1);
    assert(t !is null && t.stage == Stage.lv2 && t.crew == 7 && b.gold == a.gold);
    assert(t.invested == defaultCatalog.investedIn(TowerKind.frost, Stage.lv2));
    f.save(b);
    assert(f.hash() == h);
}
