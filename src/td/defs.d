// Tower defense rules as data: tower, creep and economy tables, world units and small integer
// helpers. Headless Model; everything is integer so a game replays bit-for-bit on any platform.
module td.defs;

import wfc.hex : CubeCoord, cubeToOffset;

/// Simulation rate. All durations below are in ticks.
enum int ticksPerSecond = 30;

/// World units: a cell center (col, row) sits at x = (2 col + (row & 1)) * 512, y = row * 887,
/// the viewer's iso layout scaled by 512 (adjacent centers are ~1024 apart).
enum int halfHex = 512;
enum int rowUnits = 887;
enum int cellUnits = 1024;
/// Progress along one step between adjacent cells.
enum int stepUnits = 1024;

void cellWorld(int col, int row, out int x, out int y) @nogc nothrow pure @safe {
    x = (2 * col + (row & 1)) * halfHex;
    y = row * rowUnits;
}

void cellWorld(const CubeCoord c, out int x, out int y) @nogc nothrow pure @safe {
    immutable o = cubeToOffset(c);
    cellWorld(o.col, o.row, x, y);
}

long dist2(int ax, int ay, int bx, int by) @nogc nothrow pure @safe {
    immutable long dx = ax - bx, dy = ay - by;
    return dx * dx + dy * dy;
}

/// Integer hash of up to three values (deterministic choices without a shared RNG stream).
uint mix(uint a, uint b = 0, uint c = 0) @nogc nothrow pure @safe {
    uint h = a * 0x9E3779B1u ^ b * 0x85EBCA77u ^ c * 0xC2B2AE3Du;
    h ^= h >> 15;
    h *= 0x2C1B3C6Du;
    h ^= h >> 12;
    h *= 0x297A2D39u;
    h ^= h >> 15;
    return h;
}

@nogc nothrow pure @safe unittest {
    int x, y;
    cellWorld(0, 0, x, y);
    assert(x == 0 && y == 0);
    cellWorld(1, 0, x, y);
    assert(x == 1024 && y == 0);
    cellWorld(0, 1, x, y);
    assert(x == 512 && y == 887);
    // Diagonal neighbors are about one cell apart, like horizontal ones.
    immutable d = dist2(0, 0, 512, 887);
    assert(d > 1000L * 1000 && d < 1050L * 1050);
    assert(mix(1, 2, 3) == mix(1, 2, 3) && mix(1, 2, 3) != mix(1, 2, 4));
}

enum TowerKind : ubyte {
    arrow,
    cannon,
    frost,
    tesla,
    flame,
    /// Economy building, only on gold veins.
    mine
}

enum int numTowerKinds = 6;
/// Towers that fight (all but the mine).
enum int numCombatKinds = 5;

enum DamageType : ubyte {
    /// Reduced by armor.
    physical,
    /// Ignores armor.
    magic,
    /// Ignores armor.
    fire
}

/// Upgrade stage: Lv1 to Lv3 in a line, then one of two specializations with four levels each,
/// so a tower takes six upgrades to max out. The mine never branches and climbs path A.
enum Stage : ubyte {
    lv1,
    lv2,
    lv3,
    a1,
    a2,
    a3,
    a4,
    b1,
    b2,
    b3,
    b4
}

enum int numStages = 11;
/// Levels before the branch, levels on a branch, and the highest level.
enum int linearLevels = 3, branchLevels = 4, maxTier = linearLevels + branchLevels;

/// Level of a stage, 1 .. maxTier.
int tierOf(Stage s) @nogc nothrow pure @safe {
    return s < Stage.a1 ? s + 1 : linearLevels + 1 + (s - Stage.a1) % branchLevels;
}

/// Specialization of a stage: -1 before the branch, else 0 (A) or 1 (B).
int branchOf(Stage s) @nogc nothrow pure @safe {
    return s < Stage.a1 ? -1 : (s - Stage.a1) / branchLevels;
}

/// Stage at level `tier` (1 .. maxTier) on `branch` (ignored below the branch).
Stage stageAt(int branch, int tier) @nogc nothrow pure @safe {
    assert(tier >= 1 && tier <= maxTier);
    if (tier <= linearLevels)
        return cast(Stage)(tier - 1);
    return cast(Stage)(Stage.a1 + (branch ? branchLevels : 0) + tier - linearLevels - 1);
}

@nogc nothrow pure @safe unittest {
    assert(tierOf(Stage.lv1) == 1 && tierOf(Stage.lv3) == 3 && tierOf(Stage.a1) == 4);
    assert(tierOf(Stage.b4) == maxTier && tierOf(Stage.a4) == maxTier);
    assert(branchOf(Stage.lv3) == -1 && branchOf(Stage.a3) == 0 && branchOf(Stage.b1) == 1);
    foreach (s; 0 .. numStages) {
        immutable st = cast(Stage)s;
        assert(stageAt(branchOf(st) < 0 ? 0 : branchOf(st), tierOf(st)) == st);
    }
}

struct TowerStats {
    string name;
    /// Gold to build (lv1) or to upgrade into this stage.
    int cost;
    /// World units.
    int range;
    /// Ticks between attacks.
    int cooldown;
    int damage;
    DamageType type;
    /// Projectile speed in world units per tick; 0 = instant.
    int projSpeed;
    /// Splash radius (0 = single target) and the damage percent left at its edge.
    int splash;
    int splashEdge = 100;
    int slowPct, slowTicks;
    /// Tesla: extra hops, how far a hop reaches, damage kept per hop (percent).
    int chains, chainRange, chainKeep = 100;
    /// Burn: damage every `burnEvery` ticks while it lasts.
    int burnDmg, burnTicks;
    /// Arrows loosed at once at different targets.
    int targets = 1;
    /// Percent of armor ignored, and armor points shredded per hit (down to 0).
    int pierce, shred;
    /// Chilled creeps take this many percent more damage for `chillTicks`.
    int chillPct, chillTicks;
    int stunTicks;
    /// Flame cone: cosine of the half angle in percent (100 = a line, 0 = a half circle).
    int coneCos;
    /// Cluster bomblets thrown from the impact.
    int bomblets;
    /// Napalm: burning ground left at the target, for this many ticks.
    int patchTicks;
    /// Blizzard: hits everything in range each attack instead of firing.
    bool pulse;
    /// Mine: gold paid when a wave is cleared.
    int income;
    string blurb;
}

enum int burnEvery = 10;

/// Hand-tuned anchors by kind: Lv1, Lv2 and the first level of each branch. The other stages grow
/// from these (see `grownTable`). The mine has no branches.
private immutable TowerStats[4][numTowerKinds] anchorTable = [
    // Arrow: cheap, fast, single target.
    [
        TowerStats("Arrow", 50, 2800, 20, 12, DamageType.physical, 320, blurb: "Fast single shots"),
        TowerStats("Arrow II", 60, 3000, 16, 20, DamageType.physical, 340, blurb: "Faster, harder"),
        TowerStats("Longbow", 140, 4600, 24, 64, DamageType.physical, 420, pierce: 60, blurb: "Huge range, pierces armor"),
        TowerStats("Volley", 130, 3000, 15, 22, DamageType.physical, 340, targets: 3, blurb: "Three arrows at once")
    ],
    // Cannon: slow shells that splash.
    [
        TowerStats("Cannon", 80, 2600, 50, 30, DamageType.physical, 110, splash: 900, splashEdge: 40,
            blurb: "Explosive splash"),
        TowerStats("Cannon II", 90, 2700, 48, 50, DamageType.physical, 115, splash: 1100,
            splashEdge: 40, blurb: "Bigger blast"),
        TowerStats("Cluster", 170, 2800, 48, 45, DamageType.physical, 115, splash: 1000,
            splashEdge: 40, bomblets: 4, blurb: "Scatters 4 bomblets"),
        TowerStats("Siege", 190, 3100, 72, 150, DamageType.physical, 100, splash: 1500,
            splashEdge: 50, shred: 10, blurb: "Massive blast, shreds armor")
    ],
    // Frost: chilling shards that slow.
    [
        TowerStats("Frost", 70, 2400, 35, 6, DamageType.magic, 220, splash: 700, splashEdge: 100,
            slowPct: 35, slowTicks: 60, blurb: "Slows a small area"),
        TowerStats("Frost II", 80, 2500, 32, 10, DamageType.magic, 230, splash: 800, splashEdge: 100,
            slowPct: 45, slowTicks: 75, blurb: "Deeper slow"),
        TowerStats("Blizzard", 160, 2600, 45, 8, DamageType.magic, 0, slowPct: 55, slowTicks: 60,
            pulse: true, blurb: "Pulses: slows all in range"),
        TowerStats("Shatter", 150, 2600, 32, 18, DamageType.magic, 240, splash: 900, splashEdge: 100,
            slowPct: 40, slowTicks: 75, chillPct: 40, chillTicks: 90, blurb: "Chilled take +40% damage")
    ],
    // Tesla: instant chain lightning, ignores armor.
    [
        TowerStats("Tesla", 100, 2600, 40, 22, DamageType.magic, 0, chains: 2, chainRange: 1800,
            chainKeep: 85, blurb: "Chain lightning"),
        TowerStats("Tesla II", 110, 2700, 38, 34, DamageType.magic, 0, chains: 3, chainRange: 1900,
            chainKeep: 85, blurb: "Longer chains"),
        TowerStats("Storm", 200, 2800, 36, 30, DamageType.magic, 0, chains: 8, chainRange: 2200,
            chainKeep: 90, blurb: "Arcs through 9 creeps"),
        TowerStats("Overload", 220, 3000, 60, 170, DamageType.magic, 0, stunTicks: 30, blurb: "One huge bolt that stuns")
    ],
    // Flame: short-range cone that sets creeps alight.
    [
        TowerStats("Flame", 90, 1900, 12, 4, DamageType.fire, 0, burnDmg: 3, burnTicks: 60,
            coneCos: 70, blurb: "Burning cone"),
        TowerStats("Flame II", 100, 2000, 12, 6, DamageType.fire, 0, burnDmg: 5, burnTicks: 60,
            coneCos: 70, blurb: "Hotter flames"),
        TowerStats("Inferno", 190, 2300, 10, 7, DamageType.fire, 0, burnDmg: 7, burnTicks: 120,
            coneCos: 45, blurb: "Wide cone, long burn"),
        TowerStats("Napalm", 180, 2100, 12, 6, DamageType.fire, 0, splash: 750, burnDmg: 5,
            burnTicks: 60, coneCos: 70, patchTicks: 150, blurb: "Leaves burning ground")
    ],
    // Mine: gold income per cleared wave.
    [
        TowerStats("Mine", 120, 0, 0, 0, DamageType.physical, 0, income: 25, blurb: "+25 gold per wave"),
        TowerStats("Mine II", 150, 0, 0, 0, DamageType.physical, 0, income: 60, blurb: "+60 gold per wave"),
        TowerStats.init, TowerStats.init
    ]
];

/// `b` made stronger by `steps` levels: more damage, range and effect for more gold, renamed.
private TowerStats grow(TowerStats b, int steps, string name, string blurb) @nogc nothrow pure @safe {
    static int pct(int v, int p, int n) {
        long x = v;
        foreach (i; 0 .. n)
            x = x * p / 100;
        return cast(int)x;
    }

    static int cap(int v, int c) {
        return v > c ? c : v;
    }

    if (steps == 0)
        return b;
    TowerStats t = b;
    t.name = name;
    t.cost = pct(b.cost, 130, steps);
    t.range = pct(b.range, 104, steps);
    t.cooldown = pct(b.cooldown, 95, steps);
    if (t.cooldown < 4 && b.cooldown > 0)
        t.cooldown = 4;
    t.damage = pct(b.damage, 135, steps);
    t.splash = pct(b.splash, 104, steps);
    if (b.slowPct)
        t.slowPct = cap(b.slowPct + 3 * steps, 75);
    t.slowTicks = pct(b.slowTicks, 110, steps);
    if (b.chains)
        t.chains = b.chains + steps;
    t.burnDmg = pct(b.burnDmg, 135, steps);
    if (b.targets > 1)
        t.targets = b.targets + steps / 2;
    if (b.pierce)
        t.pierce = cap(b.pierce + 5 * steps, 90);
    if (b.shred)
        t.shred = b.shred + 2 * steps;
    if (b.chillPct)
        t.chillPct = b.chillPct + 5 * steps;
    if (b.stunTicks)
        t.stunTicks = b.stunTicks + 5 * steps;
    if (b.bomblets)
        t.bomblets = b.bomblets + (steps + 1) / 2;
    t.patchTicks = pct(b.patchTicks, 115, steps);
    t.income = pct(b.income, 140, steps);
    t.blurb = blurb;
    return t;
}

private enum string[maxTier + 1] roman = ["", "", " II", " III", " IV", " V", " VI", " VII"];
/// Names and blurbs of grown stages, joined at compile time.
private enum string numbered(string base, int n) = base ~ roman[n];
private enum string stronger(string blurb) = blurb ~ ", stronger";

private TowerStats[numStages][numTowerKinds] grownTable() @nogc nothrow pure @safe {
    TowerStats[numStages][numTowerKinds] r;
    static foreach (k; 0 .. numTowerKinds) {
        r[k][Stage.lv1] = anchorTable[k][0];
        r[k][Stage.lv2] = anchorTable[k][1];
        r[k][Stage.lv3] = grow(anchorTable[k][1], 1, numbered!(anchorTable[k][0].name, 3),
                stronger!(anchorTable[k][1].blurb));
        static foreach (i; 0 .. branchLevels) {
            static if (k == TowerKind.mine) {
                r[k][stageAt(0, linearLevels + 1 + i)] = grow(anchorTable[k][1], 2 + i,
                        numbered!(anchorTable[k][0].name, 4 + i), stronger!(anchorTable[k][1].blurb));
            } else {
                static foreach (br; 0 .. 2)
                    r[k][stageAt(br, linearLevels + 1 + i)] = grow(anchorTable[k][2 + br], i,
                            numbered!(anchorTable[k][2 + br].name, 1 + i), stronger!(anchorTable[k][2 + br].blurb));
            }
        }
    }
    return r;
}

/// Stats by kind and stage. Path B of the mine is unused (cost 0).
immutable TowerStats[numStages][numTowerKinds] towerTable = grownTable();

ref immutable(TowerStats) towerStats(TowerKind k, Stage s) @nogc nothrow pure @safe {
    return towerTable[k][s];
}

/// True where an upgrade picks a specialization (Lv3 of a combat tower).
bool isBranchPoint(TowerKind k, Stage s) @nogc nothrow pure @safe {
    return s == Stage.lv3 && k != TowerKind.mine;
}

/// Stage an upgrade from `s` leads to (`branch` 0 = A, 1 = B, only read at the branch point), or
/// false at max.
bool nextStage(TowerKind k, Stage s, int branch, out Stage next) @nogc nothrow pure @safe {
    immutable tier = tierOf(s);
    if (tier >= maxTier)
        return false;
    immutable br = branchOf(s) >= 0 ? branchOf(s) : (k == TowerKind.mine ? 0 : branch != 0);
    next = stageAt(br, tier + 1);
    return true;
}

/// Gold spent to bring a tower to stage `s` (its build cost plus the upgrades on the way).
int investedIn(TowerKind k, Stage s) @nogc nothrow pure @safe {
    immutable br = branchOf(s) < 0 ? 0 : branchOf(s);
    int g = 0;
    foreach (t; 1 .. tierOf(s) + 1)
        g += towerTable[k][stageAt(br, t)].cost;
    return g;
}

/// Selling refunds this percentage of what was invested.
enum int sellPercent = 70;

@nogc nothrow pure @safe unittest {
    Stage n;
    assert(nextStage(TowerKind.arrow, Stage.lv1, 0, n) && n == Stage.lv2);
    assert(nextStage(TowerKind.arrow, Stage.lv2, 1, n) && n == Stage.lv3);
    assert(nextStage(TowerKind.arrow, Stage.lv3, 1, n) && n == Stage.b1);
    assert(nextStage(TowerKind.arrow, Stage.a1, 1, n) && n == Stage.a2); // the branch sticks
    assert(!nextStage(TowerKind.arrow, Stage.a4, 0, n) && !nextStage(TowerKind.arrow, Stage.b4, 0, n));
    assert(nextStage(TowerKind.mine, Stage.lv3, 1, n) && n == Stage.a1);
    assert(isBranchPoint(TowerKind.frost, Stage.lv3) && !isBranchPoint(TowerKind.mine, Stage.lv3));
    // Six upgrades from Lv1 to the top of either branch.
    foreach (k; 0 .. numTowerKinds)
        foreach (br; 0 .. 2) {
            Stage s = Stage.lv1, up;
            int ups = 0;
            while (nextStage(cast(TowerKind)k, s, br, up)) {
                s = up;
                ++ups;
            }
            assert(ups == 6 && tierOf(s) == maxTier);
        }
    assert(investedIn(TowerKind.cannon, Stage.b1) == 80 + 90 + towerTable[1][Stage.lv3].cost + 190);
    assert(investedIn(TowerKind.cannon, Stage.lv1) == 80);
    // Every combat stage can hurt something and costs something; each level beats the last.
    foreach (k; 0 .. numCombatKinds)
        foreach (s; 0 .. numStages) {
            immutable t = towerTable[k][s];
            assert(t.cost > 0 && t.range > 0 && t.cooldown > 0 && t.damage > 0, t.name);
            if (tierOf(cast(Stage)s) > linearLevels + 1)
                assert(t.damage > towerTable[k][s - 1].damage && t.range > towerTable[k][s - 1].range);
        }
    foreach (s; 0 .. Stage.a4 + 1)
        assert(towerTable[TowerKind.mine][s].income > 0);
    assert(towerTable[TowerKind.arrow][Stage.a4].name == "Longbow IV");
    assert(towerTable[TowerKind.mine][Stage.a4].name == "Mine VII");
}

enum CreepKind : ubyte {
    grunt,
    runner,
    brute,
    swarm,
    boss
}

enum int numCreepKinds = 5;

struct CreepStats {
    string name;
    int hp;
    /// Step progress per tick (stepUnits = one cell).
    int speed;
    /// Percent of physical damage blocked.
    int armor;
    int bounty;
    /// Lives lost when it reaches a sink.
    int leak;
    /// Wave budget points it costs.
    int cost;
    /// Spawn gap after it, in ticks.
    int gap;
    /// Percent of slow it shrugs off.
    int slowResist;
}

immutable CreepStats[numCreepKinds] creepTable = [
    CreepStats("Grunt", 60, 34, 0, 5, 1, 10, 18, 0), CreepStats("Runner", 35, 62, 0, 5, 1, 10, 12,
            0), CreepStats("Brute", 200, 22, 45, 10, 2, 30, 30, 20),
    CreepStats("Swarmling", 18, 44, 0, 1, 1, 3, 6, 0),
    CreepStats("Boss", 1500, 16, 30, 150, 5, 0, 60, 50)
];

ref immutable(CreepStats) creepStats(CreepKind k) @nogc nothrow pure @safe {
    return creepTable[k];
}

/// Physical damage after armor (`pierce` percent of the armor ignored) and the chill bonus.
int mitigate(int dmg, DamageType t, int armor, int pierce, int chillPct) @nogc nothrow pure @safe {
    if (t == DamageType.physical) {
        immutable eff = armor * (100 - pierce) / 100;
        dmg = dmg * (100 - eff) / 100;
    }
    if (chillPct > 0)
        dmg = dmg * (100 + chillPct) / 100;
    return dmg < 1 ? 1 : dmg;
}

@nogc nothrow pure @safe unittest {
    assert(mitigate(100, DamageType.physical, 45, 0, 0) == 55);
    assert(mitigate(100, DamageType.physical, 45, 60, 0) == 82); // 18% armor left
    assert(mitigate(100, DamageType.magic, 45, 0, 0) == 100);
    assert(mitigate(100, DamageType.fire, 90, 0, 40) == 140);
    assert(mitigate(1, DamageType.physical, 99, 0, 0) == 1);
}

/// Damage percent at distance² `d2` inside a splash of `radius` (full at the center, `edge`
/// percent at the rim), or 0 outside.
int splashPercent(long d2, int radius, int edge) @nogc nothrow pure @safe {
    immutable long r2 = cast(long)radius * radius;
    if (d2 > r2)
        return 0;
    // Linear in distance² is cheap and close enough: full in the middle, `edge` at the rim.
    return cast(int)(100 - (100 - edge) * d2 / (r2 > 0 ? r2 : 1));
}

@nogc nothrow pure @safe unittest {
    assert(splashPercent(0, 1000, 40) == 100);
    assert(splashPercent(1000L * 1000, 1000, 40) == 40);
    assert(splashPercent(1001L * 1001, 1000, 40) == 0);
    immutable mid = splashPercent(500L * 500, 1000, 40);
    assert(mid > 40 && mid < 100);
}

/// Hit points of a creep in wave `wave` (1-based): +11% compounding per wave.
int scaledHp(CreepKind k, int wave) @nogc nothrow pure @safe {
    long hp = creepTable[k].hp * 1000L;
    foreach (w; 1 .. wave)
        hp = hp * 111 / 100;
    return cast(int)(hp / 1000);
}

@nogc nothrow pure @safe unittest {
    assert(scaledHp(CreepKind.grunt, 1) == 60);
    assert(scaledHp(CreepKind.grunt, 2) == 66);
    assert(scaledHp(CreepKind.grunt, 10) > 150 && scaledHp(CreepKind.grunt, 10) < 160);
}

/// Economy.
enum int startGold = 300;
enum int startLives = 20;
enum int totalWaves = 30;
/// Ticks before the first wave, and between waves.
enum int firstWaveDelay = 30 * ticksPerSecond;
enum int waveBreak = 15 * ticksPerSecond;

/// Gold for clearing wave `wave`.
int waveClearBonus(int wave) @nogc nothrow pure @safe {
    return 30 + 3 * wave;
}

/// Special tiles.
enum SpecialKind : ubyte {
    none,
    /// Only mines can be built here.
    goldVein,
    /// Towers here deal +leyDamagePct damage.
    leyStone
}

enum int leyDamagePct = 25;
/// Range bonus per level a tower stands above its nearest road, and its cap (percent).
enum int highGroundPctPerLevel = 12, highGroundCapPct = 36;
