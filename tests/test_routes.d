// Integration: tower defense maps with sources, sinks and walled roads, across seeds, counts and
// layouts. Checks playability, determinism and the cost of routing against plain terrain.
module tests.test_routes;

import core.stdc.stdio : printf;
import wfc.map_session;
import wfc.tile_map;
import tests.harness : Report;

void run(ref Report rep, int seeds) @nogc nothrow @trusted {
    auto a = MapSession.create().value;
    auto b = MapSession.create().value;
    scope (exit) {
        MapSession.release(a);
        MapSession.release(b);
    }
    size_t maps = 0, valid = 0, deterministic = 0, attempts = 0, solved = 0;
    double routedMs = 0, plainMs = 0;
    static immutable int[2][6] counts = [[1, 1], [2, 1], [4, 2], [2, 4], [6, 3], [8, 8]];
    foreach (layout; 0 .. 2)
        foreach (cnt; counts)
            foreach (seed; 1 .. seeds + 1) {
                GenParams p;
                p.layout = layout == 0 ? Layout.rect : Layout.island;
                p.radius = 6;
                p.rings = 2;
                p.seed = cast(uint)seed;
                p.routes.place.sources = cnt[0];
                p.routes.place.sinks = cnt[1];
                if (!a.regenerate(p).isOk)
                    continue;
                maps++;
                routedMs += a.genMillis;
                attempts += a.routeAttempts;
                if (a.routeReport.ok)
                    valid++;
                if (a.stats.gridsFailed == 0)
                    solved++;
                b.regenerate(p);
                bool same = true;
                foreach (i; 0 .. a.tiles.rect.cellCount) {
                    immutable c = a.tiles.rect.cellAt(i);
                    same &= a.tiles.get(c) == b.tiles.get(c) && a.decorations.get(c) == b.decorations.get(c);
                }
                if (same)
                    deterministic++;
                p.routes.enabled = false;
                b.regenerate(p);
                plainMs += b.genMillis;
            }
    immutable expected = cast(size_t)(2 * counts.length * seeds);
    printf("  routes: %zu/%zu maps, %zu valid, %zu deterministic, %.2f attempts avg, %.1f ms vs %.1f ms plain\n",
            maps, expected, valid, deterministic, attempts * 1.0 / (maps ? maps : 1),
            routedMs / (maps ? maps : 1), plainMs / (maps ? maps : 1));
    rep.check(maps == expected, "every routed map generates");
    rep.check(valid == maps, "every routed map is playable (connected, matching tiles, no leaks)");
    rep.check(solved == maps, "every routed map is fully solved");
    rep.check(deterministic == maps, "routed maps are deterministic");
}
