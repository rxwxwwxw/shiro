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

/// Upgrade stage: Lv1, Lv2, then one of two specializations.
enum Stage : ubyte {
    lv1,
    lv2,
    branchA,
    branchB
}

enum int numStages = 4;

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

/// Stats by kind and stage. Branch stages of the mine are unused (cost 0).
immutable TowerStats[numStages][numTowerKinds] towerTable = [
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

ref immutable(TowerStats) towerStats(TowerKind k, Stage s) @nogc nothrow pure @safe {
    return towerTable[k][s];
}

/// Stage an upgrade from `s` leads to (`branch` 0 = A, 1 = B, only read at Lv2), or false at max.
bool nextStage(TowerKind k, Stage s, int branch, out Stage next) @nogc nothrow pure @safe {
    final switch (s) {
    case Stage.lv1:
        next = Stage.lv2;
        return true;
    case Stage.lv2:
        if (k == TowerKind.mine)
            return false;
        next = branch == 0 ? Stage.branchA : Stage.branchB;
        return true;
    case Stage.branchA:
    case Stage.branchB:
        return false;
    }
}

/// Gold spent to bring a tower to stage `s` (its build cost plus the upgrades on the way).
int investedIn(TowerKind k, Stage s) @nogc nothrow pure @safe {
    int g = towerTable[k][Stage.lv1].cost;
    if (s >= Stage.lv2)
        g += towerTable[k][Stage.lv2].cost;
    if (s >= Stage.branchA)
        g += towerTable[k][s].cost;
    return g;
}

/// Selling refunds this percentage of what was invested.
enum int sellPercent = 70;

@nogc nothrow pure @safe unittest {
    Stage n;
    assert(nextStage(TowerKind.arrow, Stage.lv1, 0, n) && n == Stage.lv2);
    assert(nextStage(TowerKind.arrow, Stage.lv2, 1, n) && n == Stage.branchB);
    assert(!nextStage(TowerKind.arrow, Stage.branchA, 0, n));
    assert(!nextStage(TowerKind.mine, Stage.lv2, 0, n));
    assert(investedIn(TowerKind.cannon, Stage.branchB) == 80 + 90 + 190);
    // Every combat stage can hurt something and costs something.
    foreach (k; 0 .. numCombatKinds)
        foreach (s; 0 .. numStages) {
            immutable t = towerTable[k][s];
            assert(t.cost > 0 && t.range > 0 && t.cooldown > 0 && t.damage > 0, t.name);
        }
    assert(towerTable[TowerKind.mine][0].income > 0);
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
    CreepStats("Grunt", 60, 34, 0, 4, 1, 10, 18, 0), CreepStats("Runner", 35, 62, 0, 4, 1, 10, 12,
            0), CreepStats("Brute", 200, 22, 45, 10, 2, 30, 30, 20),
    CreepStats("Swarmling", 18, 44, 0, 1, 1, 3, 6, 0),
    CreepStats("Boss", 2000, 16, 30, 120, 10, 0, 60, 50)
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
enum int startGold = 250;
enum int startLives = 20;
enum int totalWaves = 30;
/// Ticks before the first wave, and between waves.
enum int firstWaveDelay = 30 * ticksPerSecond;
enum int waveBreak = 15 * ticksPerSecond;

/// Gold for clearing wave `wave`.
int waveClearBonus(int wave) @nogc nothrow pure @safe {
    return 20 + 2 * wave;
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
