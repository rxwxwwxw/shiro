// Fills a td Catalog from the story's `data` tables, so tower defense rules live in script
// (`assets/story/rules/*.story`) where mods can change them:
//
//   data towers = [{id: "arrow", behavior: :projectile, look: :arrow, stages: [{name: ...}, ...]}]
//   data creeps = [{id: "grunt", look: :grunt, stats: {hp: 60, ...}, unlockWave: 1, pickWeight: 5}]
//   data economy = {startGold: 300, ...}
//
// Map keys bind to the D struct fields of the same name (td.catalog, td.defs): numbers must be
// whole, enums are symbols naming a member, unknown keys are errors, missing keys keep their
// defaults. Model layer: no SDL, @nogc nothrow; runs once after the story initializes.
module story.catalog_load;

import core.stdc.stdio : snprintf;
import story.state;
import story.value;
import td.catalog;
import td.defs;

/// Story variables holding the rules.
enum string varTowers = "towers", varCreeps = "creeps", varEconomy = "economy";

/// Why a catalog could not be loaded: `file`-less, one line.
struct LoadError {
    char[256] buf;
    uint len;

    const(char)[] text() const return @nogc nothrow pure @safe {
        return buf[0 .. len];
    }
}

/// Builds `cat` from the `towers`, `creeps` and (optional) `economy` tables in `st` (after
/// `initialize`). False with `err` set when a table is missing or wrong; `cat` is then the
/// defaults.
bool loadCatalog(ref const StoryState st, ref Catalog cat, ref LoadError err) @nogc nothrow @trusted {
    cat.setDefault();
    cat.textLen = 0;
    immutable towers = st.value(st.find(varTowers)), creeps = st.value(st.find(varCreeps));
    if (towers.kind != ValueKind.list || creeps.kind != ValueKind.list) {
        fail(err, "no `data towers` / `data creeps` lists in the story");
        return false;
    }
    Binder b = Binder(&st, &cat, &err);
    bool ok = true;
    // Kinds come from script alone: none of the defaults survive.
    cat.towers[] = TowerDef.init;
    cat.creeps[] = CreepDef.init;
    cat.numTowers = cat.numCreeps = 0;
    if (st.count(towers) > maxTowerKinds || st.count(creeps) > maxCreepKinds) {
        fail(err, "more than 16 tower or creep kinds");
        ok = false;
    }
    foreach (i, ref t; st.items(towers)) {
        if (!ok || i >= maxTowerKinds)
            break;
        char[32] path;
        ok = b.bind(t, cat.towers[i], label(path, "towers", i));
        cat.numTowers = cast(int)i + 1;
    }
    foreach (i, ref c; st.items(creeps)) {
        if (!ok || i >= maxCreepKinds)
            break;
        char[32] path;
        ok = b.bind(c, cat.creeps[i], label(path, "creeps", i));
        cat.numCreeps = cast(int)i + 1;
    }
    immutable econ = st.value(st.find(varEconomy));
    if (ok && !econ.isNil)
        ok = b.bind(econ, cat.econ, "economy");
    if (ok)
        ok = validate(cat, err);
    if (!ok) {
        // Keep the message: setDefault copies over the whole catalog, not the error.
        cat.setDefault();
    }
    return ok;
}

private const(char)[] label(return ref char[32] buf, const(char)[] table, size_t i) @nogc nothrow @trusted {
    immutable n = snprintf(buf.ptr, buf.length, "%.*s[%d]", cast(int)table.length, table.ptr, cast(int)i);
    return buf[0 .. n < 0 ? 0 : (n < buf.length ? n : buf.length - 1)];
}

private void fail(Args...)(ref LoadError err, const(char)* fmt, Args args) @nogc nothrow @trusted {
    immutable n = snprintf(err.buf.ptr, err.buf.length, fmt, args);
    err.len = n < 0 ? 0 : (n < err.buf.length ? n : cast(uint)err.buf.length - 1);
}

/// Sanity rules the simulation relies on.
private bool validate(ref const Catalog cat, ref LoadError err) @nogc nothrow @trusted {
    if (cat.numTowers == 0 || cat.numCreeps == 0) {
        fail(err, "the rules need at least one tower and one creep kind");
        return false;
    }
    foreach (k; 0 .. cat.numTowers) {
        const d = &cat.towers[k];
        foreach (j; 0 .. k)
            if (cat.towers[j].id == d.id) {
                fail(err, "tower id \"%.*s\" used twice", cast(int)d.id.length, d.id.ptr);
                return false;
            }
        if (d.id.length == 0 || d.stages[Stage.lv1].cost <= 0) {
            fail(err, "towers[%d] needs an id and a Lv1 cost", k);
            return false;
        }
        foreach (s; 0 .. numStages) {
            const st = &d.stages[s];
            if (st.cost > 0 && d.behavior != Behavior.income && (st.range <= 0 || st.cooldown <= 0)) {
                fail(err, "%.*s stage %d: a fighting tower needs range and cooldown",
                        cast(int)d.id.length, d.id.ptr, s);
                return false;
            }
            if (st.chainKeep < 0 || st.splashEdge < 0 || st.targets < 0) {
                fail(err, "%.*s stage %d: negative stats", cast(int)d.id.length, d.id.ptr, s);
                return false;
            }
        }
    }
    bool pickable = false;
    foreach (k; 0 .. cat.numCreeps) {
        const c = &cat.creeps[k];
        foreach (j; 0 .. k)
            if (cat.creeps[j].id == c.id) {
                fail(err, "creep id \"%.*s\" used twice", cast(int)c.id.length, c.id.ptr);
                return false;
            }
        if (c.id.length == 0 || c.stats.hp <= 0 || c.stats.speed <= 0 || c.stats.cost < 0) {
            fail(err, "creeps[%d] needs an id, hp and speed", k);
            return false;
        }
        pickable |= !c.boss && c.pickWeight > 0 && c.stats.cost > 0;
    }
    if (!pickable) {
        fail(err, "no creep kind can be picked for a wave (pickWeight and cost)");
        return false;
    }
    return true;
}

/// Binds story maps onto D structs by field name.
private struct Binder {
@nogc nothrow @trusted:
    const(StoryState)* st;
    Catalog* cat;
    LoadError* err;

    bool bind(T)(const Value v, ref T out_, const(char)[] path) if (is(T == struct)) {
        if (v.kind != ValueKind.map) {
            fail(*err, "%.*s: expected a map", cast(int)path.length, path.ptr);
            return false;
        }
        const ks = st.keys(v);
        foreach (i, ref val; st.items(v)) {
            const key = st.text(ks[i]);
            bool known = false;
            static foreach (f; 0 .. T.tupleof.length) {
                {
                    enum name = __traits(identifier, T.tupleof[f]);
                    if (key == name) {
                        known = true;
                        char[96] sub;
                        immutable n = snprintf(sub.ptr, sub.length, "%.*s.%.*s",
                                cast(int)path.length, path.ptr, cast(int)name.length, name.ptr);
                        if (!field(val, out_.tupleof[f], sub[0 .. n < 0 ? 0 : (n < sub.length ? n : sub.length - 1)]))
                            return false;
                    }
                }
            }
            if (!known) {
                fail(*err, "%.*s: unknown field %.*s", cast(int)path.length, path.ptr, cast(int)key.length, key.ptr);
                return false;
            }
        }
        return true;
    }

    private bool field(F)(const Value v, ref F f, const(char)[] path) {
        static if (is(F == enum)) {
            const name = v.isSymbol ? st.symbolName(v) : st.text(v);
            static foreach (m; __traits(allMembers, F)) {
                if (name == m) {
                    f = __traits(getMember, F, m);
                    return true;
                }
            }
            fail(*err, "%.*s: no such value %.*s", cast(int)path.length, path.ptr, cast(int)name.length, name.ptr);
            return false;
        } else static if (is(F == bool)) {
            if (v.kind == ValueKind.boolean || v.isNil) {
                f = truthy(v);
                return true;
            }
            fail(*err, "%.*s: expected true or false", cast(int)path.length, path.ptr);
            return false;
        } else static if (is(F == int)) {
            if (toIntExact(v, f))
                return true;
            fail(*err, "%.*s: expected a whole number", cast(int)path.length, path.ptr);
            return false;
        } else static if (is(F == string)) {
            if (!v.isText && !v.isSymbol) {
                fail(*err, "%.*s: expected a string", cast(int)path.length, path.ptr);
                return false;
            }
            const s = st.keyText(v);
            f = s.length ? cat.keepText(s) : "";
            if (s.length && f is null) {
                fail(*err, "names too long in total");
                return false;
            }
            return true;
        } else static if (is(F == struct)) {
            return bind(v, f, path);
        } else static if (is(F == E[n], E, size_t n)) {
            const items = st.items(v);
            if (v.kind != ValueKind.list || items.length != n) {
                fail(*err, "%.*s: expected a list of %d", cast(int)path.length, path.ptr, cast(int)n);
                return false;
            }
            foreach (i, ref e; items) {
                char[96] sub;
                immutable k = snprintf(sub.ptr, sub.length, "%.*s[%d]", cast(int)path.length, path.ptr, cast(int)i);
                if (!field(e, f[i], sub[0 .. k < 0 ? 0 : (k < sub.length ? k : sub.length - 1)]))
                    return false;
            }
            return true;
        } else
            static assert(0, "cannot bind a " ~ F.stringof);
    }
}

version (unittest) {
    import story.compile : compileText;
    import story.program : StoryError, StoryProgram;
    import story.vm : initialize;

    private bool loadFrom(const(char)[] text, ref Catalog cat, ref LoadError err) @nogc nothrow @trusted {
        StoryProgram p;
        StoryState st;
        immutable e = compileText(p, st, text);
        assert(e == StoryError.none);
        initialize(p, st);
        return loadCatalog(st, cat, err);
    }
}

@nogc nothrow @trusted unittest {
    // A small modded rule set: one tower with two stages, one creep, a cheaper economy.
    static Catalog cat;
    LoadError err;
    immutable ok = loadFrom(`
data towers = [
    {id: "ballista", behavior: :projectile, look: :arrow, stages: [
        {name: "Ballista", cost: 70, range: 3000, cooldown: 25, damage: 30, type: :physical, projSpeed: 300, pierce: 50},
        {name: "Ballista II", cost: 40, range: 3100, cooldown: 24, damage: 40, type: :physical, projSpeed: 300},
        {}, {}, {}, {}, {}, {}, {}, {}, {}
    ], branches: false},
]
data creeps = [{id: "rat", look: :swarm, stats: {name: "Rat", hp: 10, speed: 50, bounty: 1, leak: 1, cost: 2, gap: 5}, pickWeight: 1, pack: 4}]
data economy = {startGold: 99, sellPercent: 50}
`, cat, err);
    assert(ok, err.text);
    assert(cat.numTowers == 1 && cat.towers[0].id == "ballista" && cat.towers[0].stages[0].pierce == 50);
    assert(cat.tower(cast(TowerKind)0, Stage.lv2).name == "Ballista II" && !cat.towers[0].branches);
    assert(cat.towers[0].stages[0].splashEdge == 100 && cat.towers[0].stages[0].targets == 1);
    Stage next;
    assert(cat.nextStage(cast(TowerKind)0, Stage.lv1, 0, next) && next == Stage.lv2);
    assert(!cat.nextStage(cast(TowerKind)0, Stage.lv2, 0, next)); // Lv3 has no cost: the top
    assert(cat.numCreeps == 1 && cat.creeps[0].look == CreepKind.swarm && cat.creeps[0].pack == 4);
    assert(cat.econ.startGold == 99 && cat.econ.sellPercent == 50 && cat.econ.totalWaves == totalWaves);
    assert(cat.hash() != defaultCatalog.hash());
}

@nogc nothrow @trusted unittest {
    // Mistakes are reported with where they are, and leave the defaults in place.
    static Catalog cat;
    static void expect(const(char)[] text, const(char)[] what) @nogc nothrow @trusted {
        LoadError err;
        assert(!loadFrom(text, cat, err));
        const m = err.text;
        bool found = false;
        foreach (k; 0 .. m.length + 1)
            found |= k + what.length <= m.length && m[k .. k + what.length] == what;
        assert(found, m);
        assert(cat.hash() == defaultCatalog.hash());
    }

    expect("data x = 1\n", "no `data towers`");
    enum creeps = "data creeps = [{id: \"c\", stats: {hp: 1, speed: 1, cost: 1}, pickWeight: 1}]\n";
    expect("data towers = [{id: \"t\", colour: 3}]\n" ~ creeps, "towers[0]: unknown field colour");
    expect("data towers = [{id: \"t\", behavior: :laser}]\n" ~ creeps, "towers[0].behavior: no such value laser");
    expect("data towers = [{id: \"t\", stages: [{cost: 2.5}]}]\n" ~ creeps, "expected a list of 11");
    expect("data towers = [{id: \"t\", stages: [{cost: 2.5},{},{},{},{},{},{},{},{},{},{}]}]\n" ~ creeps,
            "towers[0].stages[0].cost: expected a whole number");
    expect("data towers = [{id: \"t\", stages: [{cost: 5},{},{},{},{},{},{},{},{},{},{}]}]\n" ~ creeps,
            "needs range and cooldown");
    expect("data towers = [{id: \"t\", behavior: :income, stages: [{cost: 5},{},{},{},{},{},{},{},{},{},{}]}]\n"
            ~ "data creeps = [{id: \"c\", stats: {hp: 1, speed: 1, cost: 1}, boss: true}]\n",
            "no creep kind can be picked");
}
