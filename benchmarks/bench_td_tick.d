// Microbenchmark: the tower defense tick under load (about 1,000 creeps and 200 towers of every
// kind on a generated map). Fails (exit 1) when the 95th-percentile tick exceeds the budget.
module benchmarks.bench_td_tick;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import td.bot;
import td.defs;
import td.game;
import wfc.map_session;

enum double budgetUs = 2000;

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
    return 0;
}
