// Source and sink placement for tower defense maps.
//
// Endpoints are charged particles: every pair repels (1/r^2), sinks additionally pull on each
// other through a spring whose rest length is `sinkClusterDist` (attract beyond it, repel
// inside it), and the map boundary pushes lightly inward. After relaxation each endpoint is
// snapped to a cell and hard minimum spacings are enforced. All math is integer so placement is
// identical on every platform.
module wfc.placement;

import core.random : Random;
import core.result;
import core.stdc.stdlib : malloc, free;
import wfc.grid_connector : MapRect;
import wfc.hex;

enum int maxSources = 16;
enum int maxSinks = 16;

/// Returns true for cells that belong to the playable map.
alias InMapLookup = bool delegate(const CubeCoord) @nogc nothrow;

/// Distance (in cells) from every cell to the nearest cell outside the map: 0 outside, 1 on the
/// outermost ring of map cells. Saturates at ushort.max.
struct BoundaryField {
    MapRect rect;
    private ushort* dist;

    @disable this(this);

    /// `inMap` null means the whole rectangle is map.
    this(MapRect rect, scope InMapLookup inMap) @nogc nothrow @trusted {
        this.rect = rect;
        immutable n = rect.cellCount;
        dist = cast(ushort*)malloc(n * ushort.sizeof);
        auto queue = cast(uint*)malloc(n * uint.sizeof);
        assert(dist !is null && queue !is null, "boundary field allocation failed");
        scope (exit)
            free(queue);
        size_t head = 0, tail = 0;
        foreach (i; 0 .. n) {
            immutable c = rect.cellAt(i);
            if (inMap !is null && !inMap(c)) {
                dist[i] = 0;
                continue;
            }
            dist[i] = ushort.max;
            foreach (d; 0 .. numHexDirs) {
                immutable nc = c.neighbor(cast(HexDir)d);
                if (!rect.contains(nc) || (inMap !is null && !inMap(nc))) {
                    dist[i] = 1;
                    queue[tail++] = cast(uint)i;
                    break;
                }
            }
        }
        while (head < tail) {
            immutable i = queue[head++];
            immutable c = rect.cellAt(i);
            immutable nd = dist[i] == ushort.max ? ushort.max : cast(ushort)(dist[i] + 1);
            foreach (d; 0 .. numHexDirs) {
                immutable nc = c.neighbor(cast(HexDir)d);
                if (!rect.contains(nc))
                    continue;
                immutable j = rect.index(nc);
                if (dist[j] > nd) {
                    dist[j] = nd;
                    queue[tail++] = cast(uint)j;
                }
            }
        }
    }

    ~this() @nogc nothrow @trusted {
        free(dist);
    }

    /// Distance of a cell to the outside (0 for cells outside the rectangle).
    int get(const CubeCoord c) const @nogc nothrow @trusted {
        if (dist is null || !rect.contains(c))
            return 0;
        return dist[rect.index(c)];
    }

    /// Number of cells farther than `margin` from the outside.
    size_t countBeyond(int margin) const @nogc nothrow @trusted {
        size_t n = 0;
        foreach (i; 0 .. rect.cellCount)
            if (dist[i] > margin)
                n++;
        return n;
    }
}

@nogc nothrow unittest {
    auto f = BoundaryField(MapRect(10, 8), null);
    assert(f.get(offsetToCube(0, 0)) == 1 && f.get(offsetToCube(9, 7)) == 1);
    assert(f.get(offsetToCube(1, 1)) == 2 && f.get(offsetToCube(4, 4)) == 4);
    assert(f.get(offsetToCube(-1, 0)) == 0);
    // A hole in the map counts as outside.
    immutable hole = offsetToCube(5, 4);
    scope InMapLookup inMap = (const CubeCoord c) @nogc nothrow => c != hole;
    auto g = BoundaryField(MapRect(10, 8), inMap);
    assert(g.get(hole) == 0);
    foreach (d; 0 .. numHexDirs)
        assert(g.get(hole.neighbor(cast(HexDir)d)) == 1);
    assert(g.countBeyond(0) == 79);
}

struct PlacementParams {
    int sources = 2;
    int sinks = 1;
    /// Endpoints keep at least this many cells of land between them and the map edge.
    int edgeMargin = 3;
    /// Hard minimum hex distances; 0 picks a value from the map size (relaxed if needed).
    int minSourceSpacing = 0;
    int minSourceSinkSpacing = 0;
    int minSinkSpacing = 0;
    /// Rest length of the sink-sink spring; 0 picks a value from the map size.
    int sinkClusterDist = 0;
    /// Sink spring strength in percent (0 disables sink attraction).
    int sinkAttraction = 100;
    /// Boundary repulsion relative to an endpoint's charge, in percent.
    int wallCharge = 30;
    int iterations = 300;
}

enum EndpointKind : ubyte {
    source,
    sink
}

struct Endpoints {
    CubeCoord[maxSources] sources;
    CubeCoord[maxSinks] sinks;
    int numSources;
    int numSinks;

    const(CubeCoord)[] sourceCells() const return @nogc nothrow pure @safe {
        return sources[0 .. numSources];
    }

    const(CubeCoord)[] sinkCells() const return @nogc nothrow pure @safe {
        return sinks[0 .. numSinks];
    }

    /// Endpoint `i` over sources then sinks.
    CubeCoord at(int i) const @nogc nothrow pure @safe {
        return i < numSources ? sources[i] : sinks[i - numSources];
    }

    EndpointKind kindAt(int i) const @nogc nothrow pure @safe {
        return i < numSources ? EndpointKind.source : EndpointKind.sink;
    }

    int count() const @nogc nothrow pure @safe {
        return numSources + numSinks;
    }

    bool isEndpoint(const CubeCoord c) const @nogc nothrow pure @safe {
        foreach (i; 0 .. count)
            if (at(i) == c)
                return true;
        return false;
    }
}

/// Resolved hard spacings (hex distance).
struct Spacing {
    int sourceSource, sourceSink, sinkSink, cluster;
}

/// Integer square root (floor).
long isqrt(long v) @nogc nothrow pure @safe {
    if (v <= 0)
        return 0;
    long x = v;
    long y = (x + 1) / 2;
    while (y < x) {
        x = y;
        y = (x + v / x) / 2;
    }
    return x;
}

@nogc nothrow pure @safe unittest {
    foreach (long v; 0 .. 2000)
        assert(isqrt(v) * isqrt(v) <= v && (isqrt(v) + 1) * (isqrt(v) + 1) > v);
    assert(isqrt(1L << 62) == 1L << 31);
}

// World units: neighbor centers are `cellUnit` apart (x = (2q + r) * 1000, y = r * 1732).
private enum long cellUnit = 2000;

private struct Vec {
    long x, y;
}

private Vec toWorld(const CubeCoord c) @nogc nothrow pure @safe {
    return Vec((2L * c.q + c.r) * 1000, c.r * 1732L);
}

/// Nearest cell to a world position (cube rounding in fixed point).
private CubeCoord toCell(const Vec p) @nogc nothrow pure @safe {
    // Axial coordinates scaled by 1024.
    immutable long rs = p.y * 1024 / 1732;
    immutable long qs = (p.x * 1024 / 1000 - rs) / 2;
    immutable long ss = -qs - rs;
    long roundDiv(long v) {
        return v >= 0 ? (v + 512) / 1024 : -((-v + 512) / 1024);
    }

    long q = roundDiv(qs), r = roundDiv(rs), s = roundDiv(ss);
    immutable long dq = q * 1024 - qs, dr = r * 1024 - rs, ds = s * 1024 - ss;
    immutable long aq = dq < 0 ? -dq : dq, ar = dr < 0 ? -dr : dr, as = ds < 0 ? -ds : ds;
    if (aq > ar && aq > as)
        q = -r - s;
    else if (ar > as)
        r = -q - s;
    return CubeCoord(cast(int)q, cast(int)r, cast(int)(-q - r));
}

@nogc nothrow pure @safe unittest {
    foreach (row; -6 .. 7)
        foreach (col; -6 .. 7) {
            immutable c = offsetToCube(col, row);
            immutable w = toWorld(c);
            assert(toCell(w) == c);
            assert(toCell(Vec(w.x + 300, w.y - 300)) == c);
        }
    // Neighbors are one cell unit apart.
    immutable a = toWorld(CubeCoord(0, 0, 0));
    foreach (d; 0 .. numHexDirs) {
        immutable b = toWorld(CubeCoord(0, 0, 0).neighbor(cast(HexDir)d));
        immutable dist = isqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y));
        assert(dist >= 1999 && dist <= 2001);
    }
}

/// Hard spacings for `p` on a map with `area` valid cells, scaled by `relax` percent.
Spacing resolveSpacing(const PlacementParams p, size_t area, int relax) @nogc nothrow pure @safe {
    immutable side = cast(int)isqrt(cast(long)area);
    int pick(int explicit, int auto_) {
        if (explicit > 0)
            return explicit;
        immutable v = auto_ * relax / 100;
        return v < 3 ? 3 : v;
    }

    Spacing s;
    s.sourceSource = pick(p.minSourceSpacing, side / (2 + p.sources));
    s.sourceSink = pick(p.minSourceSinkSpacing, side / 3);
    s.sinkSink = pick(p.minSinkSpacing, side / (3 + p.sinks));
    s.cluster = p.sinkClusterDist > 0 ? p.sinkClusterDist : (s.sinkSink > side / 4 ? s.sinkSink : side / 4);
    return s;
}

private int requiredSpacing(const Spacing s, EndpointKind a, EndpointKind b) @nogc nothrow pure @safe {
    if (a != b)
        return s.sourceSink;
    return a == EndpointKind.source ? s.sourceSource : s.sinkSink;
}

private bool validCell(ref const BoundaryField field, const CubeCoord c, int margin) @nogc nothrow @safe {
    return field.get(c) > margin;
}

/// Random valid cell (rejection sampling, then a scan).
private bool randomValidCell(ref const BoundaryField field, int margin, ref Random rng, out CubeCoord c) @nogc nothrow @safe {
    immutable rect = field.rect;
    foreach (_; 0 .. 4096) {
        c = offsetToCube(cast(int)rng.below(rect.cols), cast(int)rng.below(rect.rows));
        if (validCell(field, c, margin))
            return true;
    }
    foreach (i; 0 .. rect.cellCount) {
        c = rect.cellAt(i);
        if (validCell(field, c, margin))
            return true;
    }
    return false;
}

/// Electrostatic relaxation of `n` endpoints in world space.
private void relax(ref const BoundaryField field, const PlacementParams p, const Spacing sp, Vec[] pos,
        const EndpointKind[] kinds) @nogc nothrow @trusted {
    immutable n = pos.length;
    enum long charge = 4 * cellUnit; // repulsion displacement at one cell distance
    immutable long wall = charge * p.wallCharge / 100;
    immutable long rest = sp.cluster * cellUnit;
    Vec[maxSources + maxSinks] force = void;
    foreach (it; 0 .. p.iterations) {
        // Step cap anneals from 3 cells down to a quarter cell.
        immutable long cap = cellUnit / 4 + (3 * cellUnit - cellUnit / 4) * (p.iterations - it) / p.iterations;
        foreach (i; 0 .. n)
            force[i] = Vec(0, 0);
        foreach (i; 0 .. n)
            foreach (j; i + 1 .. n) {
                long dx = pos[i].x - pos[j].x, dy = pos[i].y - pos[j].y;
                long r = isqrt(dx * dx + dy * dy);
                if (r < 1) {
                    // Coincident: separate along a fixed axis.
                    dx = cellUnit;
                    dy = 0;
                    r = cellUnit;
                }
                // Coulomb: charge * (cellUnit / r)^2, along the unit vector.
                long mag = charge * cellUnit / r * cellUnit / r;
                if (kinds[i] == EndpointKind.sink && kinds[j] == EndpointKind.sink && p.sinkAttraction > 0) {
                    // Spring toward the rest length: negative pulls the pair together.
                    mag -= (r - rest) * p.sinkAttraction / 100 / 8;
                }
                immutable fx = dx * mag / r, fy = dy * mag / r;
                force[i].x += fx;
                force[i].y += fy;
                force[j].x -= fx;
                force[j].y -= fy;
            }
        foreach (i; 0 .. n) {
            // Light boundary push along the gradient of the boundary distance.
            immutable c = toCell(pos[i]);
            immutable d0 = field.get(c);
            long gx = 0, gy = 0;
            immutable w0 = toWorld(c);
            foreach (d; 0 .. numHexDirs) {
                immutable nc = c.neighbor(cast(HexDir)d);
                immutable delta = field.get(nc) - d0;
                immutable w = toWorld(nc);
                gx += (w.x - w0.x) * delta;
                gy += (w.y - w0.y) * delta;
            }
            immutable gl = isqrt(gx * gx + gy * gy);
            if (gl > 0) {
                immutable long dd = d0 < 1 ? 1 : d0;
                immutable mag = wall / (dd * dd);
                force[i].x += gx * mag / gl;
                force[i].y += gy * mag / gl;
            }
            // Clamp, move, and stay on valid land.
            long fx = force[i].x, fy = force[i].y;
            immutable fl = isqrt(fx * fx + fy * fy);
            if (fl > cap) {
                fx = fx * cap / fl;
                fy = fy * cap / fl;
            }
            immutable next = Vec(pos[i].x + fx, pos[i].y + fy);
            if (validCell(field, toCell(next), p.edgeMargin))
                pos[i] = next;
            else if (validCell(field, toCell(Vec(next.x, pos[i].y)), p.edgeMargin))
                pos[i].x = next.x; // slide along the wall
            else if (validCell(field, toCell(Vec(pos[i].x, next.y)), p.edgeMargin))
                pos[i].y = next.y;
        }
    }
}

private bool spacingOk(const CubeCoord c, EndpointKind kind, const CubeCoord[] cells,
        const EndpointKind[] kinds, size_t skip, const Spacing sp) @nogc nothrow pure @safe {
    foreach (j, ref o; cells) {
        if (j == skip)
            continue;
        if (cubeDistance(c, o) < requiredSpacing(sp, kind, kinds[j]))
            return false;
    }
    return true;
}

/// Places `p.sources` sources and `p.sinks` sinks on valid land. Fails with PlacementFailed if
/// the hard spacings cannot be met even after relaxing the automatic ones.
Result!Endpoints placeEndpoints(ref const BoundaryField field, const PlacementParams p, ref Random rng) @nogc nothrow @trusted {
    alias R = Result!Endpoints;
    if (p.sources < 1 || p.sinks < 1 || p.sources > maxSources || p.sinks > maxSinks || p.edgeMargin < 0)
        return R.err(EngineError.InvalidHexCoordinates);
    immutable area = field.countBeyond(p.edgeMargin);
    if (area < cast(size_t)(p.sources + p.sinks))
        return R.err(EngineError.PlacementFailed);

    immutable n = cast(size_t)(p.sources + p.sinks);
    EndpointKind[maxSources + maxSinks] kinds;
    foreach (i; 0 .. n)
        kinds[i] = i < p.sources ? EndpointKind.source : EndpointKind.sink;

    Vec[maxSources + maxSinks] pos;
    foreach (i; 0 .. n) {
        CubeCoord c;
        if (!randomValidCell(field, p.edgeMargin, rng, c))
            return R.err(EngineError.PlacementFailed);
        pos[i] = toWorld(c);
    }

    // Relax with the full spacing; if the snapped layout violates it, re-draw offenders, then
    // retry with automatic spacings relaxed.
    static immutable int[4] relaxSteps = [100, 75, 50, 30];
    foreach (relaxPct; relaxSteps) {
        immutable sp = resolveSpacing(p, area, relaxPct);
        Vec[maxSources + maxSinks] work = pos;
        relax(field, p, sp, work[0 .. n], kinds[0 .. n]);
        CubeCoord[maxSources + maxSinks] cells;
        foreach (i; 0 .. n)
            cells[i] = toCell(work[i]);

        bool ok = true;
        foreach (i; 0 .. n) {
            if (validCell(field, cells[i], p.edgeMargin) && spacingOk(cells[i], kinds[i],
                    cells[0 .. i], kinds[0 .. i], size_t.max, sp))
                continue;
            // Best of K random candidates: satisfies spacing, maximizes the closest distance.
            bool found = false;
            CubeCoord best;
            int bestScore = -1;
            foreach (_; 0 .. 256) {
                CubeCoord c;
                if (!randomValidCell(field, p.edgeMargin, rng, c))
                    break;
                if (!spacingOk(c, kinds[i], cells[0 .. i], kinds[0 .. i], size_t.max, sp))
                    continue;
                int score = int.max;
                foreach (j; 0 .. i) {
                    immutable d = cubeDistance(c, cells[j]);
                    if (d < score)
                        score = d;
                }
                if (!found || score > bestScore) {
                    found = true;
                    best = c;
                    bestScore = score;
                }
            }
            if (!found) {
                ok = false;
                break;
            }
            cells[i] = best;
        }
        if (!ok)
            continue;
        Endpoints e;
        e.numSources = p.sources;
        e.numSinks = p.sinks;
        foreach (i; 0 .. n) {
            if (i < p.sources)
                e.sources[i] = cells[i];
            else
                e.sinks[i - p.sources] = cells[i];
        }
        return R.ok(e);
    }
    return R.err(EngineError.PlacementFailed);
}

version (unittest) {
    private void checkPlacement(ref const BoundaryField f, const PlacementParams p, const Endpoints e) @nogc nothrow @safe {
        immutable sp = resolveSpacing(p, f.countBeyond(p.edgeMargin), 30);
        assert(e.numSources == p.sources && e.numSinks == p.sinks);
        foreach (i; 0 .. e.count) {
            assert(f.get(e.at(i)) > p.edgeMargin);
            foreach (j; 0 .. i) {
                assert(e.at(i) != e.at(j));
                assert(cubeDistance(e.at(i), e.at(j)) >= requiredSpacing(sp, e.kindAt(i), e.kindAt(j)));
            }
        }
    }
}

@nogc nothrow unittest {
    // Deterministic, inside the margin, and spaced, for several counts and seeds.
    auto f = BoundaryField(MapRect(96, 54), null);
    static immutable int[2][5] counts = [[1, 1], [2, 1], [4, 2], [2, 4], [6, 3]];
    foreach (cnt; counts)
        foreach (seed; 1 .. 6) {
            PlacementParams p;
            p.sources = cnt[0];
            p.sinks = cnt[1];
            auto r1 = Random(seed), r2 = Random(seed);
            auto a = placeEndpoints(f, p, r1);
            auto b = placeEndpoints(f, p, r2);
            assert(a.isOk && b.isOk);
            assert(a.value.sources == b.value.sources && a.value.sinks == b.value.sinks);
            checkPlacement(f, p, a.value);
        }
}

@nogc nothrow unittest {
    // Explicit spacings are hard; sink attraction pulls sinks together.
    auto f = BoundaryField(MapRect(96, 54), null);
    PlacementParams p;
    p.sources = 3;
    p.sinks = 2;
    p.minSourceSpacing = 12;
    p.minSourceSinkSpacing = 15;
    p.minSinkSpacing = 6;
    long withAttraction = 0, without = 0;
    foreach (seed; 1 .. 9) {
        auto rng = Random(seed);
        auto e = placeEndpoints(f, p, rng);
        assert(e.isOk);
        foreach (i; 0 .. e.value.count)
            foreach (j; 0 .. i) {
                immutable d = cubeDistance(e.value.at(i), e.value.at(j));
                if (e.value.kindAt(i) != e.value.kindAt(j))
                    assert(d >= 15);
                else if (e.value.kindAt(i) == EndpointKind.source)
                    assert(d >= 12);
                else
                    assert(d >= 6);
            }
        withAttraction += cubeDistance(e.value.sinks[0], e.value.sinks[1]);
        PlacementParams q = p;
        q.sinkAttraction = 0;
        auto rng2 = Random(seed);
        auto e2 = placeEndpoints(f, q, rng2);
        assert(e2.isOk);
        without += cubeDistance(e2.value.sinks[0], e2.value.sinks[1]);
    }
    assert(withAttraction < without);
}

@nogc nothrow unittest {
    // Impossible requests fail cleanly.
    auto f = BoundaryField(MapRect(12, 10), null);
    PlacementParams p;
    p.sources = 4;
    p.minSourceSpacing = 40;
    auto rng = Random(1);
    assert(placeEndpoints(f, p, rng).error == EngineError.PlacementFailed);
    p = PlacementParams.init;
    p.sources = 0;
    assert(placeEndpoints(f, p, rng).error == EngineError.InvalidHexCoordinates);
    p = PlacementParams.init;
    p.edgeMargin = 20;
    assert(placeEndpoints(f, p, rng).error == EngineError.PlacementFailed);
}
