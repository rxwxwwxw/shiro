// Microbenchmark: Wednesday night's planning (campaign.director) against a built-up defense on a
// generated battlefield. The work is sliced into frames; fails (exit 1) when the whole plan takes
// longer than its budget or one slice takes longer than a frame's share.
module benchmarks.bench_director;

import campaign.director;
import campaign.fort;
import core.stdc.stdio : printf;
import core.time : MonoTime;
import td.bot;
import td.catalog;
import td.game;
import wfc.map_session;

/// The whole plan (it runs while the night falls), and one slice of it.
enum double planBudgetMs = 2000, sliceBudgetMs = 16;
enum uint sliceTicks = 1500;

int main() @nogc nothrow {
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    GenParams p;
    p.cols = 72;
    p.rows = 40;
    p.radius = 6;
    p.seed = 4;
    p.reveal.enabled = false;
    if (!s.regenerate(p).isOk)
        return 1;
    static Fort f;
    f.begin(defaultCatalog);
    {
        Game g;
        g.start(*s, 1);
        g.startPlanning();
        g.gold = 3000;
        Bot bot;
        bot.setup(g);
        foreach (k; 0 .. 80)
            bot.act(g);
        f.save(g);
    }
    CrewSnapshot crews;
    crews.count = f.numTowers;
    RunModifiers mods;
    mods.waves = 5;
    mods.waveOffset = 10;
    static Director d;
    immutable t0 = MonoTime.currTime;
    d.start(s, &f, &defaultCatalog, crews, mods, 7);
    double worst = 0;
    int slices = 0;
    bool finished;
    do {
        immutable a = MonoTime.currTime;
        finished = d.step(sliceTicks);
        immutable ms = (MonoTime.currTime - a).total!"usecs" / 1000.0;
        worst = ms > worst ? ms : worst;
        slices++;
    }
    while (!finished);
    immutable total = (MonoTime.currTime - t0).total!"usecs" / 1000.0;
    printf("director: %d towers, %d probes, %d slices; plan %.1f ms (budget %.0f), worst slice %.2f ms (budget %.0f); holds %d%%, plans %d%%\n",
            f.numTowers, d.plan.probes, slices, total, planBudgetMs, worst, sliceBudgetMs,
            d.plan.capacityPct, d.plan.budgetPct);
    return total <= planBudgetMs && worst <= sliceBudgetMs ? 0 : 1;
}
