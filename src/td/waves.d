// Wave composition: a pure function of (seed, wave number). Each wave gets a budget that grows
// with its number, spends it on the creep kinds unlocked so far, and spaces the spawns out.
// Headless Model.
module td.waves;

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
    return 60 + 25 * wave + 2 * wave * wave;
}

/// Wave from which each creep kind may appear (the boss is added separately).
private immutable int[numCreepKinds] unlockWave = [1, 3, 6, 4, int.max];
private immutable int[numCreepKinds] pickWeight = [5, 3, 2, 2, 0];
enum int swarmPack = 5;
enum int bossEvery = 10;

void buildWave(int wave, uint seed, ref Wave w) @nogc nothrow pure @safe {
    w.number = wave;
    w.count = 0;
    int budget = waveBudget(wave);
    int t = 0;
    uint draw = 0;
    uint rnd() {
        return mix(seed, cast(uint)wave, draw++);
    }

    void add(CreepKind k, ubyte src) {
        if (w.count == maxWaveSpawns)
            return;
        w.spawns[w.count++] = Spawn(t, k, src);
        t += creepTable[k].gap;
    }

    int weightSum = 0;
    foreach (k; 0 .. numCreepKinds)
        if (wave >= unlockWave[k])
            weightSum += pickWeight[k];
    // Runs of one kind from one source read as groups rather than noise.
    while (budget >= creepTable[CreepKind.swarm].cost && w.count < maxWaveSpawns - swarmPack) {
        int pick = cast(int)(rnd() % cast(uint)weightSum);
        CreepKind k = CreepKind.grunt;
        foreach (kk; 0 .. numCreepKinds) {
            if (wave < unlockWave[kk])
                continue;
            if (pick < pickWeight[kk]) {
                k = cast(CreepKind)kk;
                break;
            }
            pick -= pickWeight[kk];
        }
        // Out of budget for that kind: fall back to the cheapest unlocked one, or stop.
        if (budget < creepTable[k].cost) {
            bool found = false;
            foreach (kk; 0 .. numCreepKinds)
                if (wave >= unlockWave[kk] && pickWeight[kk] > 0 && budget >= creepTable[kk].cost
                        && (!found || creepTable[kk].cost < creepTable[k].cost)) {
                    k = cast(CreepKind)kk;
                    found = true;
                }
            if (!found)
                break;
        }
        immutable src = cast(ubyte)(rnd() % 8);
        immutable run = k == CreepKind.swarm ? swarmPack : 1 + cast(int)(rnd() % 3);
        foreach (i; 0 .. run) {
            if (budget < creepTable[k].cost)
                break;
            budget -= creepTable[k].cost;
            add(k, src);
        }
        t += 20;
    }
    if (wave % bossEvery == 0) {
        t += 60;
        add(CreepKind.boss, cast(ubyte)(rnd() % 8));
    }
}

@nogc nothrow pure @safe unittest {
    Wave a, b;
    foreach (wave; 1 .. 31) {
        buildWave(wave, 7, a);
        buildWave(wave, 7, b);
        assert(a.count > 0 && a.count == b.count);
        int spent = 0, bosses = 0;
        foreach (i; 0 .. a.count) {
            assert(a.spawns[i] == b.spawns[i]);
            assert(i == 0 || a.spawns[i].at > a.spawns[i - 1].at);
            spent += creepTable[a.spawns[i].kind].cost;
            bosses += a.spawns[i].kind == CreepKind.boss;
            // Locked kinds never show up early.
            if (wave < 6)
                assert(a.spawns[i].kind != CreepKind.brute);
        }
        assert(spent <= waveBudget(wave));
        assert(bosses == (wave % bossEvery == 0 ? 1 : 0));
    }
    buildWave(5, 8, b);
    buildWave(5, 7, a);
    bool differs = a.count != b.count;
    foreach (i; 0 .. a.count < b.count ? a.count : b.count)
        differs |= a.spawns[i] != b.spawns[i];
    assert(differs);
}
