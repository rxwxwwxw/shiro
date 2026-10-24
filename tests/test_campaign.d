// Integration: the week loop on the shipped story. A campaign starts on Monday at dawn, its day
// and slot scenes play, Saturday afternoon holds the clock until the battle is fought, and the
// campaign ends after its last Sunday night, the same way on every run.
module tests.test_campaign;

import campaign.calendar;
import campaign.campaign;
import core.stdc.stdio : printf;
import story.program;
import story.state;
import story.vm;
import tests.harness : Report;
import tests.test_dialogue : compileShippedStory;

/// Plays a scene to its end, taking the first choice; returns the lines shown.
private int playScene(ref const StoryProgram p, ref StoryState st, int entry) @nogc nothrow @trusted {
    StoryRunner r;
    StoryEvents ev;
    r.start(p, entry, st, ev);
    int lines = 0;
    foreach (_; 0 .. 64) {
        if (!r.active)
            break;
        lines++;
        if (r.choiceCount > 0)
            r.choose(0, st, ev);
        else
            r.advance(st, ev);
    }
    return lines;
}

void run(ref Report rep) @nogc nothrow @trusted {
    StoryProgram p;
    StoryState st;
    if (compileShippedStory(p, st) != StoryError.none) {
        rep.check(false, "campaign: story compiles");
        return;
    }
    ulong[2] hashes;
    foreach (pass; 0 .. 2) {
        st.reset(11);
        initialize(p, st);
        Campaign c;
        c.setup(&p, &st);
        c.begin();
        int scenes = 0, battles = 0, directors = 0, lines = 0;
        bool held = true;
        foreach (step; 0 .. 2000) {
            int entry;
            while (c.popScene(entry)) {
                scenes++;
                lines += playScene(p, st, entry);
            }
            if (c.directorDue) {
                directors++;
                held &= c.cal.day == Day.wed && c.cal.slot == Slot.night;
                c.directorDue = false;
            }
            if (c.battleDue) {
                battles++;
                held &= c.cal.day == Day.sat && c.cal.slot == Slot.afternoon && c.spend(3) == 0;
                c.battleOver();
            }
            if (c.over)
                break;
            c.act("rest");
        }
        rep.check(c.over && c.cal.week == c.weeks && c.cal.day == Day.sun && c.cal.slot == Slot.night,
                "campaign runs to its last Sunday night");
        rep.check(battles == c.weeks && directors == c.weeks && held,
                "a director beat on Wednesday night and a battle on Saturday afternoon each week");
        rep.check(scenes >= 2 * c.weeks && lines >= scenes && c.droppedScenes == 0, "day and slot scenes play");
        hashes[pass] = st.hash() ^ c.hash();
        if (pass == 0)
            printf("  campaign: %d weeks, %d scenes, %d lines\n", c.weeks, scenes, lines);
    }
    rep.check(hashes[0] == hashes[1], "campaign replays exactly");
}
