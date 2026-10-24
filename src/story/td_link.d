// The bridge between the village story and a tower defense run: story variables decide the run's
// modifiers on the way out of the west gate, and the run's outcome is written back into the
// story on the way home. Model layer: no SDL, @nogc nothrow.
module story.td_link;

import story.state;
import td.defs : TowerKind;
import td.game : RunModifiers;

/// Story variables the link reads and writes (story data may set or test any of them).
enum string varBonusGold = "td_gold";
enum string varHpPct = "td_hp_pct";
enum string varUnlockTesla = "unlock_tesla";
enum string varUnlockFlame = "unlock_flame";
/// 0 before the first run, then 1 after a win and 2 after a loss.
enum string varResult = "td_result";
enum string varRuns = "td_runs";
enum string varWins = "td_wins";
enum string varWaves = "td_waves";
/// Set by the story when the gate may be passed.
enum string varGateOpen = "gate_open";

/// Interns every link variable, so `fromStory` and `recordRun` never meet an unknown name.
void internLinkVars(ref StoryState st) @nogc nothrow @safe {
    foreach (n; [
        varBonusGold, varHpPct, varUnlockTesla, varUnlockFlame, varResult, varRuns, varWins, varWaves,
        varGateOpen
    ])
        st.intern(n);
}

/// Where in the village a locked tower kind is earned (null if the story never locks it).
const(char)* unlockHint(TowerKind k) @nogc nothrow pure @safe {
    switch (k) {
    case TowerKind.tesla:
        return "Locked: ask Itzel at the temple for the serpent's lightning";
    case TowerKind.flame:
        return "Locked: ask Chu Tu at the smithy for fire pots";
    default:
        return null;
    }
}

@nogc nothrow pure @safe unittest {
    assert(unlockHint(TowerKind.tesla) !is null && unlockHint(TowerKind.flame) !is null);
    assert(unlockHint(TowerKind.arrow) is null);
}

/// The run the story has earned: tesla and flame towers stay locked until their flags are set,
/// bonus gold and a creep strength offset (in percent, clamped to 50..200) come from variables.
RunModifiers fromStory(ref const StoryState st) @nogc nothrow @safe {
    RunModifiers m;
    m.bonusGold = st.named(varBonusGold);
    if (!st.named(varUnlockTesla))
        m.lockedKinds |= cast(ushort)(1 << TowerKind.tesla);
    if (!st.named(varUnlockFlame))
        m.lockedKinds |= cast(ushort)(1 << TowerKind.flame);
    immutable hp = 100 + st.named(varHpPct);
    m.hpPct = hp < 50 ? 50 : (hp > 200 ? 200 : hp);
    return m;
}

/// Writes a finished (or abandoned) run back into the story.
void recordRun(ref StoryState st, bool won, int wavesCleared) @nogc nothrow @safe {
    internLinkVars(st);
    st.set(st.find(varResult), won ? 1 : 2);
    st.add(st.find(varRuns), 1);
    if (won)
        st.add(st.find(varWins), 1);
    st.set(st.find(varWaves), wavesCleared);
}

@nogc nothrow @safe unittest {
    StoryState st;
    internLinkVars(st);
    auto m = fromStory(st);
    assert(m.bonusGold == 0 && m.hpPct == 100);
    assert((m.lockedKinds & (1 << TowerKind.tesla)) && (m.lockedKinds & (1 << TowerKind.flame)));
    assert(!(m.lockedKinds & (1 << TowerKind.arrow)));
    st.set(st.find(varUnlockFlame), 1);
    st.set(st.find(varBonusGold), 75);
    st.set(st.find(varHpPct), 500);
    m = fromStory(st);
    assert(m.bonusGold == 75 && m.hpPct == 200 && !(m.lockedKinds & (1 << TowerKind.flame)));
    st.set(st.find(varHpPct), -90);
    assert(fromStory(st).hpPct == 50);

    recordRun(st, false, 7);
    assert(st.named(varResult) == 2 && st.named(varRuns) == 1 && st.named(varWins) == 0 && st.named(varWaves) == 7);
    recordRun(st, true, 30);
    assert(st.named(varResult) == 1 && st.named(varRuns) == 2 && st.named(varWins) == 1);
}
