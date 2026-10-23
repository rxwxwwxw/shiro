// Headless stand-in for the player's hands in the village: steers toward a cell along the walk
// grid's shortest path, one move command per tick. Used by tests and scripted runs (the SDL
// controller is replaced by this). Model layer: no SDL, @nogc nothrow.
module village.bot;

import core.stdc.stdlib : free, malloc;
import td.defs : cellWorld;
import village.walk;
import village.world;
import wfc.hex;
import wfc.passability : unreachable;

struct VillageBot {
    private ushort* dist;
    private size_t cap;
    private CubeCoord target;
    private bool haveTarget;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(dist);
    }

    /// Aims at `t` (recomputing the distance field only when the target changes).
    void aim(ref const WalkGrid walk, const CubeCoord t) @nogc nothrow @trusted {
        if (haveTarget && t == target)
            return;
        immutable n = walk.rect.cellCount;
        if (cap < n) {
            free(dist);
            dist = cast(ushort*)malloc(n * ushort.sizeof);
            assert(dist !is null, "village bot allocation failed");
            cap = n;
        }
        walk.distances(t, dist[0 .. n]);
        target = t;
        haveTarget = true;
    }

    /// True once the player stands within `near` cells of the target.
    bool arrived(ref const VillageWorld w, int near = 1) const @nogc nothrow @safe {
        return haveTarget && cubeDistance(worldCell(w.player.x, w.player.y), target) <= near;
    }

    /// The move toward the next cell on the path (a stop when there or when no path exists).
    VillageCommand steer(ref const VillageWorld w, ref const WalkGrid walk) const @nogc nothrow @trusted {
        auto stop = VillageCommand(VillageCmd.move, 0, 0);
        if (!haveTarget || arrived(w))
            return stop;
        immutable here = worldCell(w.player.x, w.player.y);
        if (!walk.rect.contains(here))
            return stop;
        int best = dist[walk.rect.index(here)];
        int bx, by;
        bool found;
        foreach (d; 0 .. numHexDirs) {
            if (!walk.canStep(here, cast(HexDir)d))
                continue;
            immutable n = here.neighbor(cast(HexDir)d);
            if (dist[walk.rect.index(n)] < best) {
                best = dist[walk.rect.index(n)];
                cellWorld(n, bx, by);
                found = true;
            }
        }
        if (!found || best == unreachable)
            return stop;
        immutable px = w.player.x, py = w.player.y;
        return VillageCommand(VillageCmd.move, cast(byte)(bx > px + 60 ? 1 : (bx < px - 60 ? -1 : 0)),
                cast(byte)(by > py + 60 ? 1 : (by < py - 60 ? -1 : 0)));
    }

    /// Walks the player toward `t` for up to `ticks` ticks; true if it got there.
    bool walkTo(ref VillageWorld w, ref const WalkGrid walk, const CubeCoord t, int ticks) @nogc nothrow @trusted {
        aim(walk, t);
        foreach (_; 0 .. ticks) {
            if (arrived(w))
                break;
            w.clearEvents();
            w.apply(steer(w, walk));
            w.step();
            if (w.talking)
                break;
        }
        w.apply(VillageCommand(VillageCmd.move, 0, 0));
        return arrived(w);
    }
}
