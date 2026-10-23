// Integration: the shipped story compiles without errors or warnings, every speaker has art keys,
// and a scripted playthrough of the elder's conversation reaches the open gate deterministically.
module tests.test_dialogue;

import core.file;
import core.result : EngineError;
import core.stdc.stdio : printf;
import story.compile;
import story.program;
import story.state;
import story.td_link;
import story.vm;
import tests.harness : Report;

enum string storyPath = "assets/story/main.story";

/// Compiles the shipped story (imports resolved from disk) into `p`, interning into `st`.
StoryError compileShippedStory(ref StoryProgram p, ref StoryState st) @nogc nothrow @trusted {
    const(char)[] loader(const(char)[] path, ref FileBytes scratch) @nogc nothrow {
        return scratch.load(path.ptr) == EngineError.None ? scratch.text : null;
    }

    internLinkVars(st);
    return compileStory(p, st, storyPath, &loader);
}

/// Plays one conversation, taking choice `pick` whenever there is one (first choice when out of
/// range); returns the number of lines shown.
private int playThrough(ref StoryRunner r, ref StoryState st, ref StoryEvents ev, int pick) @nogc nothrow @safe {
    int lines = 0;
    foreach (_; 0 .. 64) {
        if (!r.active)
            break;
        lines++;
        if (r.choiceCount > 0)
            r.choose(pick < r.choiceCount ? pick : 0, st, ev);
        else
            r.advance(st, ev);
    }
    return lines;
}

void run(ref Report rep) @nogc nothrow @trusted {
    StoryState st;
    StoryProgram db;
    immutable err = compileShippedStory(db, st);
    foreach (ref d; db.diagnostics)
        printf("  %.*s:%u:%u: %s: %.*s\n", cast(int)d.file.length, d.file.ptr, d.line, d.col,
                d.severity == Severity.error ? "error".ptr : "warning".ptr, cast(int)d.message.length, d.message.ptr);
    rep.check(err == StoryError.none, "story files compile");
    if (err != StoryError.none)
        return;
    // Warnings catch unused labels and flags tested but never set (typos in story data).
    rep.check(db.diagnostics.length == 0, "story compiles without warnings");

    bool art = true;
    foreach (ref s; db.speakers)
        art &= s.name.length > 0 && s.portrait.length > 0 && s.figure.length > 0 && s.sprite >= 0;
    rep.check(art, "every speaker has a name, portrait, figure and sprite");
    rep.check(db.npcs.length == 5 && db.places.length == 5, "five villagers and five interiors");

    ulong[2] hashes;
    foreach (pass; 0 .. 2) {
        st.reset(7);
        initialize(db, st);
        StoryRunner r;
        StoryEvents ev;
        int entry;
        bool ok = st.named("coins") == 40;
        ok &= trigger(db, TriggerKind.start, null, st, entry) >= 0;
        r.start(db, entry, st, ev);
        ok &= playThrough(r, st, ev, 0) == 2;
        // Ask what is out there first (the choice then hides itself), then agree.
        ok &= trigger(db, TriggerKind.talk, "elder", st, entry) >= 0;
        r.start(db, entry, st, ev);
        ok &= r.line.id == "elder_hi" && r.speaker !is null && r.line.expr == "worried";
        r.advance(st, ev);
        r.advance(st, ev);
        ok &= r.line.id == "elder_hi.ask" && r.choiceCount == 3;
        r.choose(1, st, ev);
        r.advance(st, ev);
        ok &= r.choiceCount == 2 && st.named("asked_west") == 1;
        r.choose(0, st, ev);
        ok &= st.named(varGateOpen) == 1 && ev.has(db.findEvent("gate_open"));
        ok &= r.line.expr == "happy" && r.advance(st, ev) && !r.active;
        // Coming home after a win: the elder reacts once.
        recordRun(st, true, 12);
        ok &= trigger(db, TriggerKind.returned, "won", st, entry) >= 0;
        r.start(db, entry, st, ev);
        ok &= r.line.id == "return_won";
        playThrough(r, st, ev, 0);
        trigger(db, TriggerKind.talk, "elder", st, entry);
        r.start(db, entry, st, ev);
        ok &= r.line.id == "elder_won";
        playThrough(r, st, ev, 1);
        ok &= st.named("elder_heard") == 1 && r.faults == 0;
        rep.check(ok, pass == 0 ? "scripted elder playthrough" : "scripted playthrough replays");
        hashes[pass] = st.hash();
    }
    rep.check(hashes[0] == hashes[1], "story state hash is deterministic");
    printf("  story: %d speakers, %d labels, %d triggers, %d instructions, %d variables\n",
            cast(int)db.speakers.length, cast(int)db.labelNames.length,
            cast(int)db.triggers.length, cast(int)db.code.length, st.length);
}
