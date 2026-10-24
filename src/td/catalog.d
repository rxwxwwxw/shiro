// The rules of a tower defense run as data: tower kinds (a behavior plus eleven upgrade stages),
// creep kinds, wave composition and the economy. The shipped game reads them from the story's
// `data` tables (`assets/story/rules/*.story`, see story.catalog_load) so mods change the game by
// editing script; `defaultCatalog` holds the same numbers built from the D tables in td.defs, for
// headless tests, benchmarks and as the fallback. Headless Model; integer data only.
module td.catalog;

import td.defs;

/// Most tower and creep kinds one catalog holds (kind ids are indices; lock masks are 16 bits).
enum int maxTowerKinds = 16, maxCreepKinds = 16;

/// How a tower attacks. Mods compose new towers from these mechanics and the stage stats.
enum Behavior : ubyte {
    /// Homing arrows at up to `targets` creeps (pierce).
    projectile,
    /// A shell that lands where the target stood: splash, bomblets, shred.
    shell,
    /// A homing shard that splashes: slow and chill.
    shard,
    /// Instant chain lightning (chains, chainRange, chainKeep, stun).
    chain,
    /// A burning cone (coneCos, burn, napalm patches).
    cone,
    /// Fights nothing; pays `income` when a wave is cleared.
    income
}

struct TowerDef {
    /// Script name (`:arrow`); story and save data refer to kinds by it.
    string id;
    Behavior behavior;
    /// Built-in kind whose model and effects the View borrows.
    TowerKind look;
    /// Builds only on gold veins (and gold veins take only these).
    bool vein;
    /// Splits into specializations A and B after Lv3; otherwise it climbs path A.
    bool branches = true;
    /// Hit points against siege creeps (0: it cannot be damaged).
    int hp;
    /// Stats by Stage (lv1 .. lv3, a1 .. a4, b1 .. b4).
    TowerStats[numStages] stages;
}

struct CreepDef {
    string id;
    /// Built-in kind whose looks the View borrows.
    CreepKind look;
    CreepStats stats;
    /// First wave it may appear in, and its share of the picks from then on.
    int unlockWave = 1;
    int pickWeight;
    /// Spawned in runs of exactly this many (0: runs of 1 to 3).
    int pack;
    /// Comes alone every `Economy.bossEvery` waves instead of being picked.
    bool boss;
}

/// Run-wide numbers (the D constants in td.defs are the defaults).
struct Economy {
    int startGold = .startGold;
    int startLives = .startLives;
    int totalWaves = .totalWaves;
    int firstWaveDelay = .firstWaveDelay;
    int waveBreak = .waveBreak;
    int sellPercent = .sellPercent;
    /// Wave clear bonus: base + perWave * wave.
    int clearBase = 30, clearPerWave = 3;
    int leyDamagePct = .leyDamagePct;
    int highGroundPctPerLevel = .highGroundPctPerLevel, highGroundCapPct = .highGroundCapPct;
    /// Creep hit points compound by this percent per wave.
    int hpGrowthPct = 111;
    /// Wave budget: base + linear * wave + quad * wave².
    int budgetBase = 60, budgetLinear = 25, budgetQuad = 2;
    int bossEvery = 10;
    /// Chance (percent) that a tower's crew is hurt when it falls below half its hit points, and
    /// when it is wrecked.
    int injuryAtHalfPct = 20, injuryAtWreckPct = 60;
    /// Repairs cost this percent of what the tower is worth, in proportion to the damage.
    int repairPct = 50;
}

struct Catalog {
    TowerDef[maxTowerKinds] towers;
    int numTowers;
    CreepDef[maxCreepKinds] creeps;
    int numCreeps;
    Economy econ;
    /// Storage for the names of a catalog loaded from script (the defaults point at literals).
    char[16 * 1024] text;
    uint textLen;

    // Names point into `text`, so a catalog is never copied; build it in place.
    @disable this(this);

    ref const(TowerStats) tower(TowerKind k, Stage s) const return @nogc nothrow pure @safe {
        assert(k < numTowers);
        return towers[k].stages[s];
    }

    ref const(CreepStats) creep(CreepKind k) const return @nogc nothrow pure @safe {
        assert(k < numCreeps);
        return creeps[k].stats;
    }

    Behavior behavior(TowerKind k) const @nogc nothrow pure @safe {
        return towers[k].behavior;
    }

    /// True for towers that attack (everything but income buildings).
    bool fights(TowerKind k) const @nogc nothrow pure @safe {
        return towers[k].behavior != Behavior.income;
    }

    /// True where an upgrade picks a specialization (Lv3 of a branching tower).
    bool isBranchPoint(TowerKind k, Stage s) const @nogc nothrow pure @safe {
        return s == Stage.lv3 && towers[k].branches;
    }

    /// Stage an upgrade from `s` leads to (`branch` 0 = A, 1 = B, only read at the branch point),
    /// or false at the top (or where the next stage was never defined: cost 0).
    bool nextStage(TowerKind k, Stage s, int branch, out Stage next) const @nogc nothrow pure @safe {
        immutable tier = tierOf(s);
        if (tier >= maxTier)
            return false;
        immutable br = branchOf(s) >= 0 ? branchOf(s) : (towers[k].branches ? branch != 0 : 0);
        next = stageAt(br, tier + 1);
        return towers[k].stages[next].cost > 0;
    }

    /// Gold spent to bring a tower to stage `s` (its build cost plus the upgrades on the way).
    int investedIn(TowerKind k, Stage s) const @nogc nothrow pure @safe {
        immutable br = branchOf(s) < 0 ? 0 : branchOf(s);
        int g = 0;
        foreach (t; 1 .. tierOf(s) + 1)
            g += towers[k].stages[stageAt(br, t)].cost;
        return g;
    }

    /// Hit points of a tower of `k` at stage `s`: each level adds a quarter of the base.
    int towerHp(TowerKind k, Stage s) const @nogc nothrow pure @safe {
        return towers[k].hp * (100 + 25 * (tierOf(s) - 1)) / 100;
    }

    /// Hit points of a creep in wave `wave` (1-based), compounding per wave.
    int scaledHp(CreepKind k, int wave) const @nogc nothrow pure @safe {
        long hp = creeps[k].stats.hp * 1000L;
        foreach (w; 1 .. wave)
            hp = hp * econ.hpGrowthPct / 100;
        return cast(int)(hp / 1000);
    }

    int waveBudget(int wave) const @nogc nothrow pure @safe {
        return econ.budgetBase + econ.budgetLinear * wave + econ.budgetQuad * wave * wave;
    }

    int waveClearBonus(int wave) const @nogc nothrow pure @safe {
        return econ.clearBase + econ.clearPerWave * wave;
    }

    /// Kind with script id `id`, or -1.
    int findTower(const(char)[] id) const @nogc nothrow pure @safe {
        foreach (i; 0 .. numTowers)
            if (towers[i].id == id)
                return i;
        return -1;
    }

    int findCreep(const(char)[] id) const @nogc nothrow pure @safe {
        foreach (i; 0 .. numCreeps)
            if (creeps[i].id == id)
                return i;
        return -1;
    }

    /// FNV-1a over every number and name (a replay check: two runs on different rules differ).
    ulong hash() const @nogc nothrow pure @trusted {
        ulong h = 0xCBF29CE484222325UL;
        void put(long v) {
            foreach (k; 0 .. 8) {
                h ^= (v >> (8 * k)) & 0xFF;
                h *= 0x100000001B3UL;
            }
        }

        void str(const(char)[] s) {
            put(s.length);
            foreach (c; s)
                put(c);
        }

        void fields(T)(ref const T v) {
            foreach (ref f; v.tupleof) {
                static if (is(typeof(f) : const(char)[]))
                    str(f);
                else static if (is(typeof(f) == struct))
                    fields(f);
                else static if (is(typeof(f) : const(TowerStats)[]))
                    foreach (ref e; f)
                        fields(e);
                else
                    put(cast(long)f);
            }
        }

        put(numTowers);
        foreach (i; 0 .. numTowers)
            fields(towers[i]);
        put(numCreeps);
        foreach (i; 0 .. numCreeps)
            fields(creeps[i]);
        fields(econ);
        return h;
    }

    /// Becomes a copy of the shipped defaults.
    void setDefault() @nogc nothrow @trusted {
        import core.stdc.string : memcpy;

        // The defaults' names are literals, so a byte copy is sound.
        memcpy(&this, &defaultCatalog, Catalog.sizeof);
    }

    /// A copy of `s` in the name storage, or null when it is full.
    string keepText(const(char)[] s) @nogc nothrow @trusted {
        if (textLen + s.length > text.length)
            return null;
        text[textLen .. textLen + s.length] = s[];
        auto r = cast(string)text[textLen .. textLen + s.length];
        textLen += cast(uint)s.length;
        return r;
    }
}

/// The shipped rules, built at compile time from the tables in td.defs.
immutable Catalog defaultCatalog = makeDefault();

private Catalog makeDefault() @nogc nothrow pure @safe {
    static immutable string[numTowerKinds] towerIds = [
        "arrow", "cannon", "frost", "tesla", "flame", "mine"
    ];
    static immutable Behavior[numTowerKinds] behaviors = [
        Behavior.projectile, Behavior.shell, Behavior.shard, Behavior.chain, Behavior.cone,
        Behavior.income
    ];
    static immutable string[numCreepKinds] creepIds = ["grunt", "runner", "brute", "swarm", "boss"];
    static immutable int[numCreepKinds] unlock = [1, 3, 6, 4, 1];
    static immutable int[numCreepKinds] weight = [5, 3, 2, 2, 0];
    static immutable int[numTowerKinds] towerHp = [220, 300, 220, 240, 260, 160];
    Catalog c;
    c.numTowers = numTowerKinds;
    foreach (k; 0 .. numTowerKinds) {
        c.towers[k].id = towerIds[k];
        c.towers[k].behavior = behaviors[k];
        c.towers[k].look = cast(TowerKind)k;
        c.towers[k].vein = k == TowerKind.mine;
        c.towers[k].branches = k != TowerKind.mine;
        c.towers[k].hp = towerHp[k];
        c.towers[k].stages = towerTable[k];
    }
    c.numCreeps = numCreepKinds;
    foreach (k; 0 .. numCreepKinds) {
        c.creeps[k].id = creepIds[k];
        c.creeps[k].look = cast(CreepKind)k;
        c.creeps[k].stats = creepTable[k];
        c.creeps[k].unlockWave = unlock[k];
        c.creeps[k].pickWeight = weight[k];
        c.creeps[k].pack = k == CreepKind.swarm ? 5 : 0;
        c.creeps[k].boss = k == CreepKind.boss;
    }
    // Siege creeps: they wear towers down (and the people in them) as they pass.
    c.creeps[c.numCreeps++] = CreepDef("sapper", CreepKind.runner, CreepStats("Sapper", 45, 40, 10,
            8, 1, 15, 20, 0, 6, 1300, 60), 7, 1, 0, false);
    c.creeps[c.numCreeps++] = CreepDef("ram", CreepKind.brute, CreepStats("Battering ram", 320, 18,
            55, 20, 2, 45, 40, 60, 20, 1100, 120), 11, 1, 0, false);
    return c;
}

@nogc nothrow @safe unittest {
    // The default catalog answers like the D tables it was built from.
    alias c = defaultCatalog;
    assert(c.numTowers == numTowerKinds && c.numCreeps == numCreepKinds + 2);
    foreach (k; 0 .. numTowerKinds)
        foreach (s; 0 .. numStages) {
            immutable kind = cast(TowerKind)k, st = cast(Stage)s;
            assert(c.tower(kind, st) == towerStats(kind, st));
            assert(c.investedIn(kind, st) == investedIn(kind, st));
            Stage a, b;
            immutable ra = c.nextStage(kind, st, 1, a), rb = .nextStage(kind, st, 1, b);
            // The mine's B path is undefined (cost 0), so it is never reached.
            assert(c.tower(kind, st).cost == 0 || (ra == rb && (!ra || a == b)));
            assert(c.isBranchPoint(kind, st) == .isBranchPoint(kind, st));
        }
    foreach (k; 0 .. numCreepKinds)
        foreach (w; 1 .. 31)
            assert(c.scaledHp(cast(CreepKind)k, w) == .scaledHp(cast(CreepKind)k, w));
    assert(c.waveClearBonus(7) == .waveClearBonus(7) && c.waveBudget(4) == 60 + 100 + 32);
    assert(c.fights(TowerKind.flame) && !c.fights(TowerKind.mine));
    assert(c.findTower("tesla") == TowerKind.tesla && c.findCreep("boss") == CreepKind.boss);
    assert(c.findTower("ballista") == -1);
}

@nogc nothrow @trusted unittest {
    // Copies and hashes: a copy hashes like the original; any number changes the hash.
    static Catalog a, b;
    a.setDefault();
    b.setDefault();
    assert(a.hash() == b.hash() && a.hash() == defaultCatalog.hash());
    b.towers[TowerKind.cannon].stages[Stage.b2].damage++;
    assert(a.hash() != b.hash());
    b.setDefault();
    b.econ.sellPercent = 50;
    assert(a.hash() != b.hash());
    assert(a.keepText("Ballista") == "Ballista" && a.textLen == 8);
}
