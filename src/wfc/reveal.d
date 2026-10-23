// Progressive map reveal for tower defense campaigns.
//
// The world is generated once, but play starts on a small window of it. The window grows in planned
// stages (nested rectangles, the last one the whole world). Stage 0 holds a single sink near the
// edge across from the side creeps come from. Its source is out in the fog, and creeps enter where
// its road crosses into the window. Later sinks sit far (by road) from every source, so a reveal
// never puts a sink within easy reach of the creeps. Road fragments in the window that do not lead
// from the fog to a visible sink get no creeps. Headless Model.
module wfc.reveal;

import core.random : Random;
import core.result;
import core.stdc.stdlib : malloc, free;
import wfc.grid_connector : MapRect;
import wfc.hex;
import wfc.placement;

enum int maxStages = 8;

/// The side of the starting window that creeps come from.
enum Side : ubyte {
    west,
    east,
    north,
    south
}

/// An axis-aligned window of the world in offset space: columns [col0, col0 + cols), rows
/// [row0, row0 + rows).
struct Window {
    int col0, row0, cols, rows;

    static Window of(const MapRect r) @nogc nothrow pure @safe {
        return Window(0, 0, r.cols, r.rows);
    }

    bool containsOffset(int col, int row) const @nogc nothrow pure @safe {
        return col >= col0 && col < col0 + cols && row >= row0 && row < row0 + rows;
    }

    bool contains(const CubeCoord c) const @nogc nothrow pure @safe {
        immutable o = cubeToOffset(c);
        return containsOffset(o.col, o.row);
    }

    /// True if this window lies inside `o`.
    bool within(const Window o) const @nogc nothrow pure @safe {
        return col0 >= o.col0 && row0 >= o.row0 && col0 + cols <= o.col0 + o.cols && row0 + rows <= o.row0 + o.rows;
    }

    size_t cellCount() const @nogc nothrow pure @safe {
        return cast(size_t)cols * rows;
    }
}

struct RevealParams {
    /// Start on a small window and uncover the rest stage by stage (rect layout with routes only).
    bool enabled = false;
    /// Windows, the last one the whole map (2 .. maxStages).
    int stages = 4;
    /// Size of the first window; 0 picks 40% of the map on that axis.
    int startCols = 0, startRows = 0;
    /// Every visible entry is at least this many walking steps from the nearest visible sink.
    int minDefensePath = 18;
    /// Waves per stage; clearing the last wave of a stage reveals the next.
    int wavesPerStage = 8;
}

struct RevealPlan {
    MapRect world;
    Window[maxStages] windows;
    /// 0 = no reveal (the whole map is visible from the start).
    int numStages;
    Side entrySide;

    bool enabled() const @nogc nothrow pure @safe {
        return numStages > 0;
    }

    ref const(Window) window(int k) const return @nogc nothrow pure @safe {
        assert(k >= 0 && k < numStages);
        return windows[k];
    }

    /// First stage whose window holds `c` (numStages if none).
    int stageOf(const CubeCoord c) const @nogc nothrow pure @safe {
        foreach (k; 0 .. numStages)
            if (windows[k].contains(c))
                return k;
        return numStages;
    }

    /// Distance of `c` from the window's edge on the entry side, in cells along the axis (0 on
    /// the edge row / column itself).
    int fromFront(const Window w, const CubeCoord c) const @nogc nothrow pure @safe {
        immutable o = cubeToOffset(c);
        final switch (entrySide) {
        case Side.west:
            return o.col - w.col0;
        case Side.east:
            return w.col0 + w.cols - 1 - o.col;
        case Side.north:
            return o.row - w.row0;
        case Side.south:
            return w.row0 + w.rows - 1 - o.row;
        }
    }

    /// Length of a window along the entry axis.
    int depth(const Window w) const @nogc nothrow pure @safe {
        return entrySide == Side.west || entrySide == Side.east ? w.cols : w.rows;
    }
}

/// Nested windows from a start window at the back of `world` (the edge across from the entry
/// side) out to the whole world. Deterministic in `rng`.
Result!RevealPlan planReveal(const MapRect world, const RevealParams p, ref Random rng) @nogc nothrow @safe {
    alias R = Result!RevealPlan;
    if (p.stages < 2 || p.stages > maxStages || p.startCols < 0 || p.startRows < 0)
        return R.err(EngineError.InvalidHexCoordinates);
    int size(int explicit, int full) {
        int v = explicit > 0 ? explicit : full * 40 / 100;
        if (v < 12)
            v = 12;
        return v > full ? full : v;
    }

    immutable sc = size(p.startCols, world.cols), sr = size(p.startRows, world.rows);
    RevealPlan plan;
    plan.world = world;
    plan.numStages = p.stages;
    // Creeps come along the longer world axis (pointy-top: a column is sqrt(3), a row 1.5 wide).
    immutable horizontal = world.cols * 1732 >= world.rows * 1500;
    immutable flip = (rng.next() & 1) != 0;
    plan.entrySide = horizontal ? (flip ? Side.west : Side.east) : (flip ? Side.north : Side.south);
    // Centered across the axis with some jitter; flush with the back edge along it.
    int jitter(int slack) {
        return slack <= 0 ? 0 : slack / 2 + cast(int)rng.below(cast(uint)(slack / 2 + 1)) - slack / 4;
    }

    Window w0;
    w0.cols = sc;
    w0.rows = sr;
    final switch (plan.entrySide) {
    case Side.east:
        w0.col0 = 0;
        w0.row0 = jitter(world.rows - sr);
        break;
    case Side.west:
        w0.col0 = world.cols - sc;
        w0.row0 = jitter(world.rows - sr);
        break;
    case Side.south:
        w0.row0 = 0;
        w0.col0 = jitter(world.cols - sc);
        break;
    case Side.north:
        w0.row0 = world.rows - sr;
        w0.col0 = jitter(world.cols - sc);
        break;
    }
    if (w0.col0 + w0.cols > world.cols)
        w0.col0 = world.cols - w0.cols;
    if (w0.row0 + w0.rows > world.rows)
        w0.row0 = world.rows - w0.rows;
    // Each edge moves linearly out to the world edge.
    immutable n = p.stages - 1;
    foreach (k; 0 .. p.stages) {
        immutable l = w0.col0 - w0.col0 * k / n;
        immutable t = w0.row0 - w0.row0 * k / n;
        immutable r = w0.col0 + w0.cols + (world.cols - w0.col0 - w0.cols) * k / n;
        immutable b = w0.row0 + w0.rows + (world.rows - w0.row0 - w0.rows) * k / n;
        plan.windows[k] = Window(l, t, r - l, b - t);
    }
    return R.ok(plan);
}

@nogc nothrow @safe unittest {
    // Nested, the last window is the world, the first is flush with the back edge, deterministic.
    foreach (seed; 1 .. 9) {
        immutable world = MapRect(96, 54);
        RevealParams p;
        auto r1 = Random(seed), r2 = Random(seed);
        auto a = planReveal(world, p, r1), b = planReveal(world, p, r2);
        assert(a.isOk && b.isOk);
        const plan = a.value;
        assert(plan.numStages == 4 && plan.windows == b.value.windows);
        assert(plan.window(3) == Window.of(world));
        assert(plan.window(0).cols == 38 && plan.window(0).rows == 21);
        foreach (k; 1 .. plan.numStages)
            assert(plan.window(k - 1).within(plan.window(k)) && plan.window(k - 1) != plan.window(k));
        immutable w0 = plan.window(0);
        // Horizontal world: creeps come from the west or east; the back edge is the world edge.
        assert(plan.entrySide == Side.west || plan.entrySide == Side.east);
        assert(plan.entrySide == Side.east ? w0.col0 == 0 : w0.col0 + w0.cols == world.cols);
        // The entry edge itself is 0 from the front, the back edge is depth - 1.
        immutable front = plan.entrySide == Side.east ? w0.col0 + w0.cols - 1 : w0.col0;
        immutable back = plan.entrySide == Side.east ? w0.col0 : w0.col0 + w0.cols - 1;
        assert(plan.fromFront(w0, offsetToCube(front, w0.row0)) == 0);
        assert(plan.fromFront(w0, offsetToCube(back, w0.row0)) == plan.depth(w0) - 1);
        assert(plan.stageOf(offsetToCube(w0.col0, w0.row0)) == 0);
    }
    // Tall worlds reveal along the rows; bad stage counts are rejected.
    auto rng = Random(3);
    auto tall = planReveal(MapRect(20, 80), RevealParams.init, rng);
    assert(tall.isOk && (tall.value.entrySide == Side.north || tall.value.entrySide == Side.south));
    RevealParams bad;
    bad.stages = 1;
    assert(planReveal(MapRect(40, 40), bad, rng).error == EngineError.InvalidHexCoordinates);
    bad.stages = maxStages + 1;
    assert(planReveal(MapRect(40, 40), bad, rng).error == EngineError.InvalidHexCoordinates);
}

// ---- staged endpoint placement ----

/// Random cell of `w` on valid land that passes `ok`, best of `tries` by `score` (higher wins).
private bool pickCell(ref const BoundaryField field, const Window w, int margin, ref Random rng,
        scope bool delegate(const CubeCoord) @nogc nothrow ok,
        scope int delegate(const CubeCoord) @nogc nothrow score, out CubeCoord best) @nogc nothrow @trusted {
    bool found = false;
    int bestScore = int.min;
    foreach (_; 0 .. 512) {
        immutable c = offsetToCube(w.col0 + cast(int)rng.below(cast(uint)w.cols),
                w.row0 + cast(int)rng.below(cast(uint)w.rows));
        if (field.get(c) <= margin || !ok(c))
            continue;
        immutable s = score(c);
        if (!found || s > bestScore) {
            found = true;
            bestScore = s;
            best = c;
        }
    }
    return found;
}

/// Stage band of the `i`-th of `count` endpoints spread over stages 1 .. numStages - 1.
private int bandOf(int i, int count, int numStages) @nogc nothrow pure @safe {
    return 1 + (count <= 1 ? 0 : i * (numStages - 1) / count);
}

@nogc nothrow pure @safe unittest {
    assert(bandOf(0, 1, 4) == 1);
    assert(bandOf(0, 3, 4) == 1 && bandOf(1, 3, 4) == 2 && bandOf(2, 3, 4) == 3);
    assert(bandOf(3, 4, 2) == 1);
}

/// Places endpoints for a reveal plan. Sink 0 sits at the back of window 0. Source 0 sits in
/// band 1 beyond window 0's entry edge, so its road has to cross into the window. Other sources
/// and sinks are spread over the later bands (band k = window k minus window k - 1). Later sinks
/// keep `minDefensePath` from every source and half that from the edges they will be revealed
/// across, and are farther from source 0 than sink 0 is.
Result!Endpoints placeStagedEndpoints(ref const BoundaryField field, ref const RevealPlan plan,
        const PlacementParams p, int minDefensePath, ref Random rng) @nogc nothrow @trusted {
    alias R = Result!Endpoints;
    if (!plan.enabled || plan.numStages < 2 || p.sources < 1 || p.sinks < 1 || p.sources > maxSources
            || p.sinks > maxSinks || p.edgeMargin < 0)
        return R.err(EngineError.InvalidHexCoordinates);
    immutable m = p.edgeMargin;
    immutable w0 = plan.window(0);
    immutable world = Window.of(plan.world);
    immutable area = field.countBeyond(m);
    immutable spacing = resolveSpacing(p, area, 50).sourceSource;
    Endpoints e;

    // Sink 0: back quarter of window 0, near the middle across the axis.
    immutable d0 = plan.depth(w0);
    immutable crossMid = plan.entrySide <= Side.east ? w0.row0 + w0.rows / 2 : w0.col0 + w0.cols / 2;
    int cross(const CubeCoord c) {
        immutable o = cubeToOffset(c);
        return plan.entrySide <= Side.east ? o.row : o.col;
    }

    scope bool delegate(const CubeCoord) @nogc nothrow backOk = (const CubeCoord c) @nogc nothrow => plan.fromFront(w0,
            c) >= d0 * 3 / 4;
    scope int delegate(const CubeCoord) @nogc nothrow centered = (const CubeCoord c) @nogc nothrow{
        immutable d = cross(c) - crossMid;
        return d < 0 ? d : -d;
    };
    CubeCoord sink0;
    if (!pickCell(field, w0, m, rng, backOk, centered, sink0))
        return R.err(EngineError.PlacementFailed);
    e.sinks[e.numSinks++] = sink0;

    // Sources: band by band, ahead of window 0, spaced apart, far from sink 0.
    foreach (i; 0 .. p.sources) {
        immutable band = bandOf(i, p.sources, plan.numStages);
        immutable outer = plan.window(band), inner = plan.window(band - 1);
        scope bool delegate(const CubeCoord) @nogc nothrow ok = (const CubeCoord c) @nogc nothrow{
            if (inner.contains(c) || plan.fromFront(w0, c) >= 0)
                return false; // must lie beyond window 0's entry edge
            if (cubeDistance(c, sink0) < minDefensePath)
                return false;
            foreach (j; 0 .. e.numSources)
                if (cubeDistance(c, e.sources[j]) < spacing)
                    return false;
            return true;
        };
        // Source 0 stays close to window 0 so its road enters it soon; others spread out.
        scope int delegate(const CubeCoord) @nogc nothrow sc = (const CubeCoord c) @nogc nothrow{
            if (i == 0)
                return plan.fromFront(w0, c) * 4 - (cross(c) - crossMid < 0 ? crossMid - cross(c) : cross(c) - crossMid);
            int nearest = int.max;
            foreach (j; 0 .. e.numSources) {
                immutable d = cubeDistance(c, e.sources[j]);
                if (d < nearest)
                    nearest = d;
            }
            return nearest;
        };
        CubeCoord c;
        if (!pickCell(field, outer, m, rng, ok, sc, c))
            return R.err(EngineError.PlacementFailed);
        e.sources[e.numSources++] = c;
    }

    // Further sinks: in the last bands, far from every source and from the window edges that
    // are not world edges (where entries will appear).
    immutable s0Dist = cubeDistance(e.sources[0], sink0);
    foreach (j; 1 .. p.sinks) {
        // Latest bands first: they leave the most room between sinks and sources.
        immutable band = plan.numStages - bandOf(j - 1, p.sinks - 1, plan.numStages);
        immutable outer = plan.window(band), inner = plan.window(band - 1);
        int edgeDist(const CubeCoord c) {
            immutable o = cubeToOffset(c);
            int d = int.max;
            void side(int dist, bool worldEdge) {
                if (!worldEdge && dist < d)
                    d = dist;
            }

            side(o.col - outer.col0, outer.col0 == world.col0);
            side(outer.col0 + outer.cols - 1 - o.col, outer.col0 + outer.cols == world.cols);
            side(o.row - outer.row0, outer.row0 == world.row0);
            side(outer.row0 + outer.rows - 1 - o.row, outer.row0 + outer.rows == world.rows);
            return d;
        }

        scope bool delegate(const CubeCoord) @nogc nothrow ok = (const CubeCoord c) @nogc nothrow{
            if (inner.contains(c) || edgeDist(c) < minDefensePath / 2)
                return false;
            if (cubeDistance(c, e.sources[0]) <= s0Dist)
                return false;
            foreach (k; 0 .. e.numSources)
                if (cubeDistance(c, e.sources[k]) < minDefensePath)
                    return false;
            foreach (k; 0 .. e.numSinks)
                if (cubeDistance(c, e.sinks[k]) < spacing)
                    return false;
            return true;
        };
        scope int delegate(const CubeCoord) @nogc nothrow far = (const CubeCoord c) @nogc nothrow{
            int nearest = int.max;
            foreach (k; 0 .. e.numSources) {
                immutable d = cubeDistance(c, e.sources[k]);
                if (d < nearest)
                    nearest = d;
            }
            return nearest;
        };
        CubeCoord c;
        if (!pickCell(field, outer, m, rng, ok, far, c))
            return R.err(EngineError.PlacementFailed);
        e.sinks[e.numSinks++] = c;
    }
    return R.ok(e);
}

@nogc nothrow unittest {
    // One sink at the back of window 0, sources out in the fog ahead of it, later sinks far from
    // every source; deterministic.
    immutable world = MapRect(96, 54);
    auto field = BoundaryField(world, null);
    int placed = 0;
    foreach (seed; 1 .. 9) {
        auto rng = Random(seed);
        const plan = planReveal(world, RevealParams.init, rng).value;
        PlacementParams p;
        p.sources = 2;
        p.sinks = 2;
        auto r1 = Random(seed * 7), r2 = Random(seed * 7);
        auto a = placeStagedEndpoints(field, plan, p, 18, r1);
        auto b = placeStagedEndpoints(field, plan, p, 18, r2);
        assert(a.isOk == b.isOk);
        if (!a.isOk)
            continue;
        placed++;
        const e = a.value;
        assert(e.sources == b.value.sources && e.sinks == b.value.sinks);
        immutable w0 = plan.window(0);
        assert(w0.contains(e.sinks[0]) && plan.fromFront(w0, e.sinks[0]) >= plan.depth(w0) * 3 / 4);
        foreach (i; 0 .. e.numSources) {
            assert(!w0.contains(e.sources[i]) && plan.fromFront(w0, e.sources[i]) < 0);
            assert(cubeDistance(e.sources[i], e.sinks[0]) >= 18);
        }
        foreach (j; 1 .. e.numSinks) {
            assert(!w0.contains(e.sinks[j]));
            foreach (i; 0 .. e.numSources)
                assert(cubeDistance(e.sinks[j], e.sources[i]) >= 18);
            assert(cubeDistance(e.sinks[j], e.sources[0]) > cubeDistance(e.sinks[0], e.sources[0]));
        }
    }
    assert(placed >= 6);
}

// ---- stage analysis ----

/// Which bits of a per-cell flag array mean what (NavFlag and td CellFlag differ on walking).
struct FlagBits {
    ubyte walk, source, sink;
}

/// Marks (`mark[i] = 1`, others 0) the cells of window `w` where creeps come in. These are road
/// cells of `w` with a road exit to a walkable cell outside `w` that a source outside `w` reaches
/// on foot without entering `w`, plus the sources inside `w`. `exits` holds each cell's road exits
/// (bits 0-5 by HexDir). Returns the number of cells marked.
size_t markEntries(const MapRect rect, const(ubyte)[] flags, const(ubyte)[] exits, const FlagBits bits,
        const Window w, ubyte[] mark) @nogc nothrow @trusted {
    immutable n = rect.cellCount;
    assert(flags.length >= n && exits.length >= n && mark.length >= n);
    mark[0 .. n] = 0;
    // Fog cells a fog source reaches on foot.
    auto queue = cast(uint*)malloc(n * uint.sizeof);
    auto fed = cast(ubyte*)malloc(n);
    assert(queue !is null && fed !is null, "entry scratch allocation failed");
    scope (exit) {
        free(queue);
        free(fed);
    }
    fed[0 .. n] = 0;
    size_t head = 0, tail = 0;
    foreach (i; 0 .. n)
        if ((flags[i] & bits.source) && (flags[i] & bits.walk) && !w.contains(rect.cellAt(i))) {
            fed[i] = 1;
            queue[tail++] = cast(uint)i;
        }
    while (head < tail) {
        immutable c = rect.cellAt(queue[head++]);
        foreach (d; 0 .. numHexDirs) {
            immutable nc = c.neighbor(cast(HexDir)d);
            if (!rect.contains(nc) || w.contains(nc))
                continue;
            immutable j = rect.index(nc);
            if (fed[j] || !(flags[j] & bits.walk))
                continue;
            fed[j] = 1;
            queue[tail++] = cast(uint)j;
        }
    }
    size_t marked = 0;
    foreach (row; w.row0 .. w.row0 + w.rows)
        foreach (col; w.col0 .. w.col0 + w.cols) {
            immutable c = offsetToCube(col, row);
            immutable i = rect.index(c);
            if (!(flags[i] & bits.walk))
                continue;
            bool entry = (flags[i] & bits.source) != 0;
            foreach (d; 0 .. numHexDirs) {
                if (entry || !(exits[i] & (1 << d)))
                    continue;
                immutable nc = c.neighbor(cast(HexDir)d);
                entry = rect.contains(nc) && !w.contains(nc) && fed[rect.index(nc)];
            }
            if (entry) {
                mark[i] = 1;
                marked++;
            }
        }
    return marked;
}

struct StageReport {
    /// Entry cells, and those of them with a path to a visible sink inside the window.
    int entries, active;
    /// Visible sinks.
    int sinks;
    /// Fewest steps from an active entry to its nearest visible sink (ushort.max if none).
    int minPath = ushort.max;
    /// How far the active entry nearest the window's entry edge sits from it (int.max if none).
    int entryDepth = int.max;

    bool ok(int minDefensePath) const @nogc nothrow pure @safe {
        return active > 0 && sinks > 0 && minPath >= minDefensePath;
    }
}

/// Entries, sinks and defence depth of stage `k` of `plan` on a per-cell flag map.
StageReport analyzeStage(ref const RevealPlan plan, int k, const(ubyte)[] flags,
        const(ubyte)[] exits, const FlagBits bits) @nogc nothrow @trusted {
    immutable rect = plan.world;
    immutable n = rect.cellCount;
    immutable w = plan.window(k);
    auto mark = cast(ubyte*)malloc(n);
    auto dist = cast(ushort*)malloc(n * ushort.sizeof);
    auto queue = cast(uint*)malloc(n * uint.sizeof);
    assert(mark && dist && queue, "stage scratch allocation failed");
    scope (exit) {
        free(mark);
        free(dist);
        free(queue);
    }
    StageReport rep;
    rep.entries = cast(int)markEntries(rect, flags, exits, bits, w, mark[0 .. n]);
    dist[0 .. n] = ushort.max;
    size_t head = 0, tail = 0;
    foreach (i; 0 .. n)
        if ((flags[i] & bits.sink) && (flags[i] & bits.walk) && w.contains(rect.cellAt(i))) {
            dist[i] = 0;
            queue[tail++] = cast(uint)i;
            rep.sinks++;
        }
    while (head < tail) {
        immutable i = queue[head++];
        immutable c = rect.cellAt(i);
        foreach (d; 0 .. numHexDirs) {
            immutable nc = c.neighbor(cast(HexDir)d);
            if (!rect.contains(nc) || !w.contains(nc))
                continue;
            immutable j = rect.index(nc);
            if (dist[j] != ushort.max || !(flags[j] & bits.walk))
                continue;
            dist[j] = cast(ushort)(dist[i] + 1);
            queue[tail++] = cast(uint)j;
        }
    }
    foreach (i; 0 .. n) {
        if (!mark[i] || dist[i] == ushort.max)
            continue;
        rep.active++;
        if (dist[i] < rep.minPath)
            rep.minPath = dist[i];
        immutable f = plan.fromFront(w, rect.cellAt(i));
        if (f < rep.entryDepth)
            rep.entryDepth = f;
    }
    return rep;
}

/// True if every stage of `plan` has an active entry far enough from the sinks, and stage 0's
/// entries come in on the side across from its sink (the front third of window 0).
bool stagesPlayable(ref const RevealPlan plan, const(ubyte)[] flags, const(ubyte)[] exits,
        const FlagBits bits, int minDefensePath) @nogc nothrow @trusted {
    foreach (k; 0 .. plan.numStages) {
        immutable rep = analyzeStage(plan, k, flags, exits, bits);
        if (!rep.ok(minDefensePath))
            return false;
        if (k == 0 && (rep.sinks != 1 || rep.entryDepth > plan.depth(plan.window(0)) / 3))
            return false;
    }
    return true;
}

version (unittest) {
    // A hand-made 30 x 9 world: a road along row 4 from a source at col 28 (east, in the fog) to a
    // sink at col 1, plus a bend that dips into the window from the fog and back out.
    private struct TestWorld {
        MapRect rect = MapRect(30, 9);
        ubyte[30 * 9] flags;
        ubyte[30 * 9] exits;
        enum FlagBits bits = FlagBits(1, 8, 16);

        void road(int col0, int row0, int col1, int row1) @nogc nothrow @safe {
            immutable a = offsetToCube(col0, row0), b = offsetToCube(col1, row1);
            HexDir d;
            immutable adj = directionTo(a, b, d);
            assert(adj);
            flags[rect.index(a)] |= 1;
            flags[rect.index(b)] |= 1;
            exits[rect.index(a)] |= cast(ubyte)(1 << d);
            exits[rect.index(b)] |= cast(ubyte)(1 << opposite(d));
        }
    }
}

@nogc nothrow unittest {
    TestWorld t;
    foreach (col; 1 .. 28)
        t.road(col, 4, col + 1, 4);
    t.flags[t.rect.index(offsetToCube(28, 4))] |= 8;
    t.flags[t.rect.index(offsetToCube(1, 4))] |= 16;
    RevealPlan plan;
    plan.world = t.rect;
    plan.numStages = 2;
    plan.entrySide = Side.east;
    plan.windows[0] = Window(0, 2, 20, 7);
    plan.windows[1] = Window.of(t.rect);
    ubyte[30 * 9] mark;
    // Stage 0: the road crossing at col 19 is the one entry, 18 steps from the sink.
    assert(markEntries(t.rect, t.flags[], t.exits[], t.bits, plan.window(0), mark[]) == 1);
    assert(mark[t.rect.index(offsetToCube(19, 4))] == 1);
    auto rep = analyzeStage(plan, 0, t.flags[], t.exits[], t.bits);
    assert(rep.entries == 1 && rep.active == 1 && rep.sinks == 1 && rep.minPath == 18);
    assert(rep.entryDepth == 0);
    assert(stagesPlayable(plan, t.flags[], t.exits[], t.bits, 18));
    assert(!stagesPlayable(plan, t.flags[], t.exits[], t.bits, 19));
    // Stage 1 (everything): the source itself is the entry.
    rep = analyzeStage(plan, 1, t.flags[], t.exits[], t.bits);
    assert(rep.entries == 1 && rep.active == 1 && rep.minPath == 27);
}

@nogc nothrow unittest {
    // A bend of road that dips into the window and leaves again, fed from a fog source, enters
    // twice but reaches no visible sink: no active entries, so no creeps.
    TestWorld t;
    // Sink inside the window on its own, with no road to it.
    t.flags[t.rect.index(offsetToCube(2, 6))] |= 1 | 16;
    // Fog source at (25, 1), a fog road along row 1 to (15, 1), and a bend off it through the
    // window (row 2, cols 15 .. 20) that rejoins it.
    t.flags[t.rect.index(offsetToCube(25, 1))] |= 8;
    foreach (col; 15 .. 25)
        t.road(col, 1, col + 1, 1);
    t.road(20, 1, 20, 2);
    foreach (col; 15 .. 20)
        t.road(col, 2, col + 1, 2);
    t.road(15, 2, 15, 1);
    RevealPlan plan;
    plan.world = t.rect;
    plan.numStages = 2;
    plan.entrySide = Side.east;
    plan.windows[0] = Window(0, 2, 21, 7); // cols 0 .. 20, rows 2 .. 8
    plan.windows[1] = Window.of(t.rect);
    immutable rep = analyzeStage(plan, 0, t.flags[], t.exits[], t.bits);
    assert(rep.entries == 2 && rep.active == 0 && rep.sinks == 1);
    assert(!rep.ok(1));
}
