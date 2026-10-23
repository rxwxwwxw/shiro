// Integration: the shipped story file loads, every node can be reached, every speaker has art
// keys, and every flag a condition tests is set somewhere (catches typos in story data).
module tests.test_dialogue;

import core.file;
import core.stdc.stdio : printf;
import story.dialogue;
import story.script;
import story.state;
import story.td_link;
import tests.harness : Report;

enum string storyPath = "assets/story/village.json";

void run(ref Report rep) @nogc nothrow @trusted {
    FileBytes f;
    rep.check(f.load(storyPath) == 0, "story file readable");
    StoryState st;
    internLinkVars(st);
    DialogueDb db;
    immutable err = db.load(f.text, st);
    if (err != StoryError.none)
        printf("  story error %d at %.*s\n", err, cast(int)db.errorContext.length, db.errorContext.ptr);
    rep.check(err == StoryError.none, "story file compiles");
    if (err != StoryError.none)
        return;
    immutable orphan = db.unreachableNode();
    if (orphan >= 0)
        printf("  unreachable node %.*s\n", cast(int)db.nodes[orphan].id.length, db.nodes[orphan].id.ptr);
    rep.check(orphan < 0, "every story node reachable");

    bool art = true;
    foreach (ref s; db.speakers)
        art &= s.name.length > 0 && s.portrait.length > 0 && s.figure.length > 0 && s.sprite >= 0;
    rep.check(art, "every speaker has a name, portrait, figure and sprite");

    // Variables something can change: effects plus what the TD link writes.
    bool[maxStoryVars] written;
    foreach (ref e; db.effects)
        if (e.op != EffectOp.event)
            written[e.id] = true;
    foreach (n; [varResult, varRuns, varWins, varWaves])
        written[st.find(n)] = true;
    foreach (ref t; db.triggers)
        if (t.onceVar >= 0)
            written[t.onceVar] = true;
    bool known = true;
    foreach (ref c; db.conds)
        if (!written[c.var]) {
            known = false;
            printf("  condition tests %.*s, which nothing sets\n", cast(int)st.name(c.var).length, st.name(c.var).ptr);
        }
    rep.check(known, "every tested flag is set by some effect");
    printf("  story: %d speakers, %d nodes, %d choices, %d triggers, %d variables\n",
            cast(int)db.speakers.length, cast(int)db.nodes.length, cast(int)db.choices.length,
            cast(int)db.triggers.length, st.length);
}
