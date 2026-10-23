// Microbenchmark: the story language. Compiling the shipped story (cold, once per launch), one
// conversation resume (talk / advance / choose: what a key press costs), and a collection- and
// string-heavy script (lists of maps, for loops, interpolation, concatenation, garbage). Fails
// (exit 1) when a measurement exceeds its budget on this machine.
module benchmarks.bench_story;

import core.file : FileBytes;
import core.result : EngineError;
import core.stdc.stdio : printf;
import core.time : MonoTime;
import story.compile;
import story.program;
import story.state;
import story.td_link : internLinkVars;
import story.vm;

/// Whole shipped story, every file, parse to bytecode.
enum double compileBudgetUs = 100_000;
/// One resume of a conversation (a key press in the dialogue box).
enum double resumeBudgetUs = 50;
/// The workload script below, start to finish.
enum double workloadBudgetUs = 20_000;

private immutable workload = `
on start -> work
label work:
    people = []
    for i in range(500):
        append(people, {name: "villager " + i, food: i % 7, tags: ["farmer", "fisher"]})
    total = 0
    names = ""
    for p in people:
        p.food += 1
        if p.food > 3 and len(p.tags) == 2:
            total += p.food * 2
        names = "{p.name}"
    groups = {}
    for p in people:
        k = "g" + (p.food % 5)
        if not has(groups, k):
            groups[k] = []
        append(groups[k], p.name)
    All done: {total} {len(groups)} {names}
`;

private double elapsedUs(MonoTime t0) @nogc nothrow {
    return (MonoTime.currTime - t0).total!"nsecs" / 1000.0;
}

/// Sorts `a` in place and returns its 95th percentile.
private double p95(double[] a) @nogc nothrow {
    foreach (i; 1 .. a.length) {
        immutable x = a[i];
        size_t j = i;
        for (; j > 0 && a[j - 1] > x; j--)
            a[j] = a[j - 1];
        a[j] = x;
    }
    return a[a.length * 95 / 100];
}

int main() @nogc nothrow {
    const(char)[] loader(const(char)[] path, ref FileBytes scratch) @nogc nothrow {
        return scratch.load(path.ptr) == EngineError.None ? scratch.text : null;
    }

    bool ok = true;

    // ---- compile -------------------------------------------------------------------------------
    enum int compiles = 20;
    static double[compiles] cus;
    int labels, instructions;
    foreach (i; 0 .. compiles) {
        StoryProgram p;
        StoryState st;
        internLinkVars(st);
        immutable t0 = MonoTime.currTime;
        immutable err = compileStory(p, st, "assets/story/main.story", &loader);
        cus[i] = elapsedUs(t0);
        if (err != StoryError.none) {
            printf("FAIL: story does not compile (error %d; run from the repository root)\n", err);
            return 1;
        }
        labels = cast(int)p.labelNames.length;
        instructions = cast(int)p.code.length;
    }
    immutable cp95 = p95(cus[]);
    printf("story compile: %d labels, %d instructions, p50 %.0f us, p95 %.0f us (budget %.0f us)\n",
            labels, instructions, cus[compiles / 2], cp95, compileBudgetUs);
    if (cp95 > compileBudgetUs) {
        printf("FAIL: story compile over budget\n");
        ok = false;
    }

    // ---- conversation resumes ------------------------------------------------------------------
    {
        StoryProgram p;
        StoryState st;
        internLinkVars(st);
        compileStory(p, st, "assets/story/main.story", &loader);
        // Timer ticks can be coarser than one resume, so time whole conversations and divide.
        enum int rounds = 2000;
        static double[rounds] rus;
        int resumes = 0, shown = 0, opened = 0;
        StoryRunner r;
        StoryEvents ev;
        foreach (round; 0 .. rounds) {
            st.reset(round);
            initialize(p, st);
            int steps = 0;
            immutable t0 = MonoTime.currTime;
            // Talk to the elder until the gate opens, choosing the second option first.
            foreach (pick; 0 .. 3) {
                int entry;
                trigger(p, TriggerKind.talk, "elder", st, entry);
                r.start(p, entry, st, ev);
                steps++;
                shown += r.active;
                foreach (_; 0 .. 16) {
                    if (!r.active)
                        break;
                    if (r.choiceCount > 0)
                        r.choose(pick < r.choiceCount ? pick : 0, st, ev);
                    else
                        r.advance(st, ev);
                    steps++;
                    shown += r.active;
                }
                ev.clear();
            }
            opened += st.named("gate_open") == 1;
            rus[round] = elapsedUs(t0) / steps;
            resumes += steps;
        }
        immutable n = rounds;
        if (opened != rounds || shown < rounds * 4) {
            printf("FAIL: conversations did not play (%d lines, gate opened %d times)\n", shown, opened);
            return 1;
        }
        immutable rp95 = p95(rus[]);
        printf("story resume: %d resumes (%d lines shown), per-conversation mean p50 %.3f us, p95 %.3f us (budget %.0f us)\n",
                resumes, shown, rus[n / 2], rp95, resumeBudgetUs);
        if (rp95 > resumeBudgetUs) {
            printf("FAIL: story resume over budget\n");
            ok = false;
        }
    }

    // ---- collection / string workload ----------------------------------------------------------
    {
        StoryProgram p;
        StoryState st;
        if (compileText(p, st, workload) != StoryError.none) {
            printf("FAIL: workload script does not compile\n");
            return 1;
        }
        enum int runs = 30;
        static double[runs] wus;
        StoryRunner r;
        StoryEvents ev;
        foreach (i; 0 .. runs) {
            st.reset(i);
            int entry;
            trigger(p, TriggerKind.start, null, st, entry);
            immutable t0 = MonoTime.currTime;
            r.start(p, entry, st, ev);
            wus[i] = elapsedUs(t0);
            if (!r.active || r.faults) {
                printf("FAIL: workload did not reach its last line\n");
                return 1;
            }
        }
        immutable wp95 = p95(wus[]);
        const line = r.line.text;
        printf("story workload: 500 maps, 3 loops; p50 %.0f us, p95 %.0f us (budget %.0f us); \"%.*s\"\n",
                wus[runs / 2], wp95, workloadBudgetUs, cast(int)line.length, line.ptr);
        if (wp95 > workloadBudgetUs) {
            printf("FAIL: story workload over budget\n");
            ok = false;
        }
    }
    return ok ? 0 : 1;
}
