// Wave composition: a pure function of (seed, wave number). Each wave gets a budget that grows
// with its number, spends it on the creep kinds unlocked so far, and spaces the spawns out.
// Headless Model.
module td.waves;

import td.catalog;
import td.defs;

enum int maxWaveSpawns = 512;

struct Spawn {
    /// Ticks after the wave starts.
    int at;
    CreepKind kind;
    /// Source index, taken modulo the number of sources.
    ubyte source;
}

struct Wave {
    int number;
    Spawn[maxWaveSpawns] spawns;
    int count;

    const(Spawn)[] list() const return @nogc nothrow pure @safe {
        return spawns[0 .. count];
    }

    /// Tick of the last spawn.
    int length() const @nogc nothrow pure @safe {
        return count == 0 ? 0 : spawns[count - 1].at;
    }
}

int waveBudget(int wave) @nogc nothrow pure @safe {
    return defaultCatalog.waveBudget(wave);
}

/// Wave `wave` under the rules in `cat`: spends the wave's budget on the creep kinds unlocked so
/// far (by pick weight, in runs), then adds a boss every `bossEvery` waves.
void buildWave(ref const Catalog cat, int wave, uint seed, ref Wave w) @nogc nothrow pure @safe {
    buildWave(cat, wave, seed, cat.waveBudget(wave), null, w);
}

/// As above with an explicit `budget` and, when not null, pick weights per creep kind replacing
/// the catalog's (unlock waves still apply; the planner uses this to aim a wave).
void buildWave(ref const Catalog cat, int wave, uint seed, int budget, scope const(int)[] weights, ref Wave w) @nogc nothrow pure @safe {
    w.number = wave;
    w.count = 0;
    int t = 0;
    uint draw = 0;
    uint rnd() {
        return mix(seed, cast(uint)wave, draw++);
    }

    void add(CreepKind k, ubyte src) {
        if (w.count == maxWaveSpawns)
            return;
        w.spawns[w.count++] = Spawn(t, k, src);
        t += cat.creep(k).gap;
    }

    int weightOf(int k) {
        if (cat.creeps[k].boss || wave < cat.creeps[k].unlockWave)
            return 0;
        return weights.length ? (k < weights.length && weights[k] > 0 ? weights[k] : 0) : cat.creeps[k].pickWeight;
    }

    int weightSum = 0, cheapest = int.max, biggestRun = 3;
    foreach (k; 0 .. cat.numCreeps) {
        // Room is kept for the biggest pack of any kind, so a wave's length does not depend on
        // which kinds are unlocked yet.
        if (cat.creeps[k].pack > biggestRun)
            biggestRun = cat.creeps[k].pack;
        if (weightOf(k) > 0) {
            weightSum += weightOf(k);
            if (cat.creeps[k].stats.cost > 0 && cat.creeps[k].stats.cost < cheapest)
                cheapest = cat.creeps[k].stats.cost;
        }
    }
    // Runs of one kind from one source read as groups rather than noise.
    while (weightSum > 0 && budget >= cheapest && w.count < maxWaveSpawns - biggestRun) {
        int pick = cast(int)(rnd() % cast(uint)weightSum);
        int k = -1;
        foreach (kk; 0 .. cat.numCreeps) {
            immutable wk = weightOf(kk);
            if (wk == 0)
                continue;
            if (pick < wk) {
                k = kk;
                break;
            }
            pick -= wk;
        }
        // Out of budget for that kind: fall back to the cheapest unlocked one, or stop.
        if (budget < cat.creeps[k].stats.cost) {
            bool found = false;
            foreach (kk; 0 .. cat.numCreeps)
                if (weightOf(kk) > 0 && budget >= cat.creeps[kk].stats.cost && (!found
                        || cat.creeps[kk].stats.cost < cat.creeps[k].stats.cost)) {
                    k = kk;
                    found = true;
                }
            if (!found)
                break;
        }
        immutable src = cast(ubyte)(rnd() % 8);
        immutable run = cat.creeps[k].pack > 0 ? cat.creeps[k].pack : 1 + cast(int)(rnd() % 3);
        immutable cost = cat.creeps[k].stats.cost;
        foreach (i; 0 .. run) {
            if (budget < cost)
                break;
            budget -= cost;
            add(cast(CreepKind)k, src);
        }
        t += 20;
    }
    if (cat.econ.bossEvery > 0 && wave % cat.econ.bossEvery == 0)
        foreach (k; 0 .. cat.numCreeps)
            if (cat.creeps[k].boss) {
                t += 60;
                add(cast(CreepKind)k, cast(ubyte)(rnd() % 8));
                break;
            }
}

@nogc nothrow pure @safe unittest {
    Wave a, b;
    foreach (wave; 1 .. 31) {
        buildWave(defaultCatalog, wave, 7, a);
        buildWave(defaultCatalog, wave, 7, b);
        assert(a.count > 0 && a.count == b.count);
        int spent = 0, bosses = 0;
        foreach (i; 0 .. a.count) {
            assert(a.spawns[i] == b.spawns[i]);
            assert(i == 0 || a.spawns[i].at > a.spawns[i - 1].at);
            spent += defaultCatalog.creep(a.spawns[i].kind).cost;
            bosses += a.spawns[i].kind == CreepKind.boss;
            // Locked kinds never show up early.
            if (wave < 6)
                assert(a.spawns[i].kind != CreepKind.brute);
        }
        assert(spent <= waveBudget(wave));
        assert(bosses == (wave % defaultCatalog.econ.bossEvery == 0 ? 1 : 0));
    }
    buildWave(defaultCatalog, 5, 8, b);
    buildWave(defaultCatalog, 5, 7, a);
    bool differs = a.count != b.count;
    foreach (i; 0 .. a.count < b.count ? a.count : b.count)
        differs |= a.spawns[i] != b.spawns[i];
    assert(differs);
}
