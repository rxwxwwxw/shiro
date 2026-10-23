// Microbenchmark: the tower defense tick under load (about 1,000 creeps and 200 towers of every
// kind on a generated map), and uncovering a reveal stage. Fails (exit 1) when the 95th-percentile
// tick or the worst reveal exceeds its budget.
module benchmarks.bench_td_tick;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import td.board;
import td.bot;
import td.defs;
import td.game;
import wfc.map_session;

enum double budgetUs = 2000;
/// A reveal runs once per stage, between waves: a few frames' worth is fine.
enum double revealBudgetUs = 20_000;

int main() @nogc nothrow {
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    GenParams p;
    p.cols = 128;
    p.rows = 72;
    p.radius = 8;
    p.seed = 3;
    p.routes.place.sources = 4;
    p.routes.place.sinks = 2;
    if (!s.regenerate(p).isOk)
        return 1;
    Game g;
    g.start(*s, 5);
    Bot bot;
    bot.every = 1;
    bot.setup(g);
    // Build up: lots of gold, a few hundred bot turns.
    foreach (t; 0 .. 600) {
        g.gold = 100_000;
        bot.act(g);
        g.advance();
    }
    g.lives = 1_000_000;
    int towers = 0;
    foreach (ref t; g.towers)
        towers += t.alive;

    enum int warm = 300, measured = 2000, target = 1000;
    static double[measured] us;
    foreach (t; 0 .. warm + measured) {
        // Keep the road full: top up to the target creep count, a few per tick.
        foreach (k; 0 .. 8)
            if (g.creepsAlive < target)
                g.inject(cast(CreepKind)((t + k) % 4), t + k);
        g.lives = 1_000_000;
        immutable t0 = MonoTime.currTime;
        g.advance();
        if (t >= warm)
            us[t - warm] = (MonoTime.currTime - t0).total!"nsecs" / 1000.0;
    }
    double sum = 0;
    foreach (i; 0 .. measured) {
        sum += us[i];
        immutable x = us[i];
        size_t j = i;
        for (; j > 0 && us[j - 1] > x; j--)
            us[j] = us[j - 1];
        us[j] = x;
    }
    immutable p95 = us[measured * 95 / 100];
    printf("td tick: %d towers, %d creeps alive at end, avg %.1f us, p50 %.1f us, p95 %.1f us, worst %.1f us (budget %.0f us)\n",
            towers, g.creepsAlive, sum / measured, us[measured / 2], p95, us[measured - 1], budgetUs);
    if (p95 > budgetUs) {
        printf("FAIL: td tick p95 over budget\n");
        return 1;
    }

    // Reveal: re-mask the board to each stage's window (entries, distance field) on the same size.
    p.reveal.enabled = true;
    if (!s.regenerate(p).isOk || !s.reveal.enabled)
        return 1;
    Board b;
    b.load(*s, 5);
    enum int reps = 20;
    double worst = 0, total = 0;
    foreach (r; 0 .. reps)
        foreach (k; 0 .. b.numStages) {
            immutable t0 = MonoTime.currTime;
            b.applyWindow(b.plan.window(k));
            immutable t = (MonoTime.currTime - t0).total!"nsecs" / 1000.0;
            total += t;
            worst = t > worst ? t : worst;
        }
    printf("td reveal: %d x %d board, %d stages, avg %.1f us, worst %.1f us (budget %.0f us)\n",
            b.rect.cols, b.rect.rows, b.numStages, total / (reps * b.numStages), worst, revealBudgetUs);
    if (worst > revealBudgetUs) {
        printf("FAIL: td reveal over budget\n");
        return 1;
    }
    return 0;
}
