// Microbenchmark: endpoint placement, road network planning and the multi-sink ground distance
// field (flow-field basis) at several map sizes.
module benchmarks.bench_routes;

import core.random : Random;
import core.stdc.stdio : printf;
import core.stdc.stdlib : malloc, free;
import core.time : MonoTime;
import wfc.grid_connector : MapRect;
import wfc.passability;
import wfc.placement;
import wfc.routes;

int main() @nogc nothrow {
    static immutable size_t[3] sizes = [5_000, 50_000, 500_000];
    foreach (cells; sizes) {
        immutable rect = MapRect.withAspect(cells, 16, 9);
        auto field = BoundaryField(rect, null);
        enum int reps = 5;
        long placeUs = 0, planUs = 0, bfsUs = 0;
        int routes = 0;
        auto dist = cast(ushort*)malloc(rect.cellCount * ushort.sizeof);
        foreach (r; 0 .. reps) {
            RouteParams p;
            p.place.sources = 4;
            p.place.sinks = 2;
            auto rng = Random(r + 1);
            auto t0 = MonoTime.currTime;
            auto ep = placeEndpoints(field, p.place, rng);
            auto t1 = MonoTime.currTime;
            auto net = RoadNetwork(rect);
            auto res = planNetwork(net, field, ep.value, p, rng);
            auto t2 = MonoTime.currTime;
            routes += res.isOk ? res.value : 0;
            // Distance field over the roads only (the walled corridors).
            NavMap nav;
            nav.rect = rect;
            foreach (i; 0 .. rect.cellCount) {
                immutable c = rect.cellAt(i);
                if (net.onNetwork(c))
                    nav.setForTest(c, cast(ubyte)(NavFlag.ground | (net.isSink(c) ? NavFlag.sink : 0)));
            }
            auto t3 = MonoTime.currTime;
            groundDistanceToSinks(nav, dist[0 .. rect.cellCount]);
            auto t4 = MonoTime.currTime;
            placeUs += (t1 - t0).total!"usecs";
            planUs += (t2 - t1).total!"usecs";
            bfsUs += (t4 - t3).total!"usecs";
        }
        free(dist);
        printf("routes %7zu cells: place %7lld us, plan %8lld us (%d routes), sink distance %6lld us\n",
                rect.cellCount, placeUs / reps, planUs / reps, routes / reps, bfsUs / reps);
    }
    return 0;
}
