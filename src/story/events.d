// Data-driven story triggers: "when the player talks to X / enters zone Y / starts the game /
// returns from tower defense, if <condition>, run <effects> and open dialogue node N". Triggers
// are tried in file order and the first that matches wins, so outcomes are deterministic.
// Model layer: no SDL, @nogc nothrow.
module story.events;

import story.script;
import story.state;

enum TriggerKind : ubyte {
    /// Once, when a new playthrough starts in the village.
    start,
    /// The player interacts with the NPC whose id is `target`.
    talk,
    /// The player walks into the village zone `target`.
    enter,
    /// The player comes back from tower defense; `target` is "won" or "lost" (empty: either).
    returned
}

struct Trigger {
    TriggerKind on;
    const(char)[] target;
    uint condStart, condLen;
    uint effStart, effLen;
    /// Dialogue node to open, or -1 for effects only.
    int node = -1;
    /// Variable marking a `once` trigger as spent, or -1 when it may fire again.
    short onceVar = -1;
}

/// Index of the first trigger of `kind` for `target` whose condition holds, or -1.
int pickTrigger(const(Trigger)[] ts, const(Cond)[] conds, TriggerKind kind, const(char)[] target, ref const StoryState st) @nogc nothrow @safe {
    foreach (i, ref t; ts) {
        if (t.on != kind || (t.target.length > 0 && t.target != target))
            continue;
        if (t.onceVar >= 0 && st.flag(t.onceVar))
            continue;
        if (!evaluate(conds[t.condStart .. t.condStart + t.condLen], st))
            continue;
        return cast(int)i;
    }
    return -1;
}

/// Runs trigger `t`'s effects (and spends it if `once`); returns the dialogue node to open or -1.
int fireTrigger(ref const Trigger t, const(Effect)[] effects, ref StoryState st, ref StoryEvents ev) @nogc nothrow @safe {
    if (t.onceVar >= 0)
        st.set(t.onceVar, 1);
    apply(effects[t.effStart .. t.effStart + t.effLen], st, ev);
    return t.node;
}

@nogc nothrow @safe unittest {
    StoryState st;
    Cond[4] conds;
    immutable met = st.intern("met");
    immutable spent = st.intern("_once0");
    assert(parseCondition("met", st, conds[0 .. 1]) == 1);
    Effect[1] effs = [Effect(EffectOp.set, cast(short)met, 1)];
    Trigger[4] ts = [
        Trigger(TriggerKind.start, null, 0, 0, 0, 1, 7, cast(short)spent),
        Trigger(TriggerKind.talk, "elder", 0, 1, 0, 0, 2),
        Trigger(TriggerKind.talk, "elder", 0, 0, 0, 0, 3),
        Trigger(TriggerKind.returned, null, 0, 0, 0, 0, 4),
    ];
    StoryEvents ev;
    // Talking before the intro falls through to the unconditional line.
    assert(pickTrigger(ts[], conds[], TriggerKind.talk, "elder", st) == 2);
    assert(pickTrigger(ts[], conds[], TriggerKind.talk, "smith", st) == -1);
    immutable s = pickTrigger(ts[], conds[], TriggerKind.start, null, st);
    assert(s == 0 && fireTrigger(ts[s], effs[], st, ev) == 7);
    assert(st.flag(met) && pickTrigger(ts[], conds[], TriggerKind.start, null, st) == -1);
    assert(pickTrigger(ts[], conds[], TriggerKind.talk, "elder", st) == 1);
    // An empty target matches any outcome.
    assert(pickTrigger(ts[], conds[], TriggerKind.returned, "lost", st) == 3);
}
