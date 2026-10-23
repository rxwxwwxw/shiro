// Microbenchmark: village generation (layout plan, anchored WFC with landmark roads, walk grid
// and the walkability check) over a run of seeds, including the layouts a seed retries.
module benchmarks.bench_village_gen;

import core.stdc.stdio : printf;
import core.time : MonoTime;
import village.plan;
import village.walk;
import wfc.map_session;

int main() @nogc nothrow {
    auto s = MapSession.create().value;
    scope (exit)
        MapSession.release(s);
    enum int seeds = 40;
    VillagePlan plan;
    WalkGrid walk;
    long totalUs = 0, worstUs = 0;
    int attempts = 0, failed = 0;
    foreach (seed; 1 .. seeds + 1) {
        immutable t0 = MonoTime.currTime;
        auto r = buildVillage(s, seed, plan, walk);
        immutable us = (MonoTime.currTime - t0).total!"usecs";
        totalUs += us;
        worstUs = us > worstUs ? us : worstUs;
        if (r.isOk)
            attempts += r.value;
        else
            failed++;
    }
    printf("village %d x %d: %d seeds, avg %lld us, worst %lld us, %.2f layouts per village, %d failed\n", villageCols,
            villageRows, seeds, totalUs / seeds, worstUs, seeds > failed
            ? attempts / cast(double)(seeds - failed) : 0.0, failed);
    return failed == 0 ? 0 : 1;
}
