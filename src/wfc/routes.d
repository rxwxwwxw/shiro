// Road network planning for tower defense maps.
//
// Given placed sources and sinks, plans a road network so that every source is connected to
// some sink and every sink to some source. Routes are found with A* over (cell, heading) states
// because the tileset has no sharp turns: a road may only go straight or turn 60 degrees per
// cell. Routes may merge into existing roads (trunks) where the resulting junction is a real
// tile, and optional loops add alternative paths. Integer value noise, waypoint detours and
// per-route attraction/repulsion between roads make the roads bend.
//
// The result is a per-cell mask of road exits, which becomes a hard WFC constraint.
module wfc.routes;

import core.random : Random;
import core.result;
import core.stdc.stdlib : malloc, calloc, realloc, free;
import core.stdc.string : memset;
import wfc.grid_connector : MapRect;
import wfc.hex;
import wfc.placement;
import wfc.road_rules;

enum int maxRoutes = 64;
private enum int maxComps = maxSources + maxSinks;
private enum ubyte sourceFlag = 1 << 6;
private enum ubyte sinkFlag = 1 << 7;
private enum ubyte dirsMask = 63;

struct RouteParams {
    /// Plan sources, sinks and roads (off = plain terrain, as before).
    bool enabled = true;
    PlacementParams place;
    /// Roads keep more than this many cells from the map edge.
    int roadMargin = 2;
    /// Amplitude of the cost noise that makes roads meander (base step cost is 100).
    int bendiness = 250;
    /// Cells per noise lattice step.
    int noiseScale = 4;
    int turnPenalty = 10;
    /// Random detour points per route, offset sideways by up to `detour` percent of its length.
    int waypoints = 1;
    int detour = 30;
    /// Each route attracts (negative) or repels (positive) later routes by up to this much per
    /// step within `affinityRadius` cells.
    int affinity = 50;
    int affinityRadius = 5;
    /// Extra cost for a new road cell next to an unrelated road.
    int parallelPenalty = 300;
    /// Extra roads that connect a network to itself, giving creeps a choice of path.
    int loops = 1;
    /// A loop only rejoins at least this many road cells away from where it leaves.
    int minLoopLength = 14;
    /// Walkable cells within this distance of a road become walls (forest or rock).
    int wallDepth = 1;
    /// Bias WFC toward natural walls (cliffs, rivers, coast) beside roads.
    bool flankTerrain = true;
}

/// Planned road network: exits per cell, endpoints, connectivity and route spans.
struct RoadNetwork {
    MapRect rect;
    Endpoints endpoints;
    private ubyte* cells; // road exits (bits 0-5) | sourceFlag | sinkFlag
    private ubyte* comp; // component id + 1 (0 = not on the network)
    private ubyte[maxComps] parent;
    private ubyte[maxComps] compFlags;
    private int numComps;
    private CubeCoord* routeBuf;
    private size_t routeLen, routeCap;
    private uint[maxRoutes + 1] routeStart;
    int numRoutes;
    /// Routes that are loops (alternative paths), counted within numRoutes.
    int numLoops;

    @disable this(this);

    this(MapRect rect) @nogc nothrow @trusted {
        this.rect = rect;
        cells = cast(ubyte*)calloc(rect.cellCount, 1);
        comp = cast(ubyte*)calloc(rect.cellCount, 1);
        assert(cells !is null && comp !is null, "road network allocation failed");
    }

    ~this() @nogc nothrow @trusted {
        free(cells);
        free(comp);
        free(routeBuf);
    }

    bool allocated() const @nogc nothrow pure @safe {
        return cells !is null;
    }

    size_t bytes() const @nogc nothrow pure @safe {
        return rect.cellCount * 2 + routeCap * CubeCoord.sizeof;
    }

    private ubyte raw(const CubeCoord c) const @nogc nothrow @trusted {
        if (cells is null || !rect.contains(c))
            return 0;
        return cells[rect.index(c)];
    }

    /// Road exits of a cell (0 = no road).
    ubyte roadDirs(const CubeCoord c) const @nogc nothrow @safe {
        return raw(c) & dirsMask;
    }

    /// True for road cells and endpoints.
    bool onNetwork(const CubeCoord c) const @nogc nothrow @safe {
        return raw(c) != 0;
    }

    bool isSource(const CubeCoord c) const @nogc nothrow @safe {
        return (raw(c) & sourceFlag) != 0;
    }

    bool isSink(const CubeCoord c) const @nogc nothrow @safe {
        return (raw(c) & sinkFlag) != 0;
    }

    RoadShape shapeAt(const CubeCoord c) const @nogc nothrow @safe {
        return classify(roadDirs(c));
    }

    private int findRoot(int x) const @nogc nothrow pure @safe {
        while (parent[x] != x)
            x = parent[x];
        return x;
    }

    /// Connected component of a network cell, or -1.
    int componentOf(const CubeCoord c) const @nogc nothrow @trusted {
        if (comp is null || !rect.contains(c))
            return -1;
        immutable id = comp[rect.index(c)];
        return id == 0 ? -1 : findRoot(id - 1);
    }

    bool componentHas(int component, EndpointKind kind) const @nogc nothrow pure @safe {
        if (component < 0)
            return false;
        return (compFlags[findRoot(component)] & (kind == EndpointKind.source ? sourceFlag : sinkFlag)) != 0;
    }

    /// Cells of route `i` in order, from its start (an endpoint or road) to where it joined.
    const(CubeCoord)[] route(int i) const @nogc nothrow pure @trusted {
        return routeBuf[routeStart[i] .. routeStart[i + 1]];
    }

    size_t roadCellCount() const @nogc nothrow @trusted {
        size_t n = 0;
        foreach (i; 0 .. rect.cellCount)
            if (cells[i] & dirsMask)
                n++;
        return n;
    }

    private void addEndpoint(const CubeCoord c, EndpointKind kind) @nogc nothrow @trusted {
        immutable i = rect.index(c);
        immutable flag = kind == EndpointKind.source ? sourceFlag : sinkFlag;
        cells[i] |= flag;
        immutable id = numComps++;
        parent[id] = cast(ubyte)id;
        compFlags[id] = flag;
        comp[i] = cast(ubyte)(id + 1);
    }

    private void unite(int a, int b) @nogc nothrow @safe {
        a = findRoot(a);
        b = findRoot(b);
        if (a == b)
            return;
        if (b < a) {
            immutable t = a;
            a = b;
            b = t;
        }
        parent[b] = cast(ubyte)a;
        compFlags[a] |= compFlags[b];
    }

    /// Commits a path (consecutive adjacent cells; first and last already on the network).
    private void commit(const CubeCoord[] path, bool loop) @nogc nothrow @trusted {
        assert(path.length >= 2 && numRoutes < maxRoutes);
        immutable startComp = componentOf(path[0]);
        immutable endComp = componentOf(path[$ - 1]);
        assert(startComp >= 0 && endComp >= 0);
        foreach (k; 0 .. path.length - 1) {
            HexDir d;
            immutable adj = directionTo(path[k], path[k + 1], d);
            assert(adj);
            cells[rect.index(path[k])] |= dirBit(d);
            cells[rect.index(path[k + 1])] |= dirBit(opposite(d));
        }
        foreach (k; 1 .. path.length - 1)
            comp[rect.index(path[k])] = cast(ubyte)(startComp + 1);
        unite(startComp, endComp);

        if (routeLen + path.length > routeCap) {
            immutable cap = (routeLen + path.length) * 2 + 64;
            routeBuf = cast(CubeCoord*)realloc(routeBuf, cap * CubeCoord.sizeof);
            assert(routeBuf !is null, "route buffer allocation failed");
            routeCap = cap;
        }
        routeBuf[routeLen .. routeLen + path.length] = path[];
        routeStart[numRoutes] = cast(uint)routeLen;
        routeLen += path.length;
        numRoutes++;
        routeStart[numRoutes] = cast(uint)routeLen;
        if (loop)
            numLoops++;
    }

    /// True if adding exits `add` to cell `c` gives a real tile that does not chain with its
    /// neighbors (ignoring neighbor `skip`, which is a new straight/bend road cell).
    bool canAddExits(const CubeCoord c, ubyte add) const @nogc nothrow @safe {
        immutable shape = classify(roadDirs(c) | add);
        if (shape == RoadShape.invalid)
            return false;
        foreach (d; 0 .. numHexDirs)
            if (!chainOk(shape, shapeAt(c.neighbor(cast(HexDir)d))))
                return false;
        return true;
    }
}

// ---- integer value noise ---------------------------------------------------------------------

private uint hashCell(int x, int y, uint seed) @nogc nothrow pure @safe {
    uint h = cast(uint)x * 0x8DA6B343u ^ cast(uint)y * 0xD8163841u ^ seed * 0xCB1AB31Fu;
    h ^= h >> 13;
    h *= 0x5BD1E995u;
    h ^= h >> 15;
    return h;
}

/// Smooth noise in [0, 1024) over offset coordinates; `scale` cells per lattice step.
int valueNoise(int col, int row, int scale, uint seed) @nogc nothrow pure @safe {
    if (scale < 1)
        scale = 1;
    int lattice(int s, uint sd) {
        immutable gx = col / s, gy = row / s;
        immutable fx = col % s, fy = row % s;
        immutable a = cast(int)(hashCell(gx, gy, sd) & 1023);
        immutable b = cast(int)(hashCell(gx + 1, gy, sd) & 1023);
        immutable c = cast(int)(hashCell(gx, gy + 1, sd) & 1023);
        immutable d = cast(int)(hashCell(gx + 1, gy + 1, sd) & 1023);
        immutable top = a + (b - a) * fx / s;
        immutable bot = c + (d - c) * fx / s;
        return top + (bot - top) * fy / s;
    }

    // Bilinear blending compresses values toward the middle; stretch the contrast back.
    immutable v = (lattice(scale * 2, seed) + lattice(scale, seed ^ 0x9E3779B9u)) / 2;
    immutable st = 512 + (v - 512) * 5 / 2;
    return st < 0 ? 0 : (st > 1023 ? 1023 : st);
}

@nogc nothrow pure @safe unittest {
    foreach (row; 0 .. 40)
        foreach (col; 0 .. 40) {
            immutable v = valueNoise(col, row, 5, 7);
            assert(v >= 0 && v < 1024);
            assert(v == valueNoise(col, row, 5, 7));
            // Smooth: neighbors differ by a bounded amount.
            immutable dv = valueNoise(col + 1, row, 5, 7) - v;
            assert(dv > -300 && dv < 300);
        }
}

// ---- planner ---------------------------------------------------------------------------------

private struct HeapEntry {
    uint f;
    uint g;
    uint state;
}

private enum ubyte fromNone = 255;
/// Seeded by leaving the route's start cell (previous cell is the start cell).
private enum ubyte fromStart = 6;
/// Seeded as a leg start (a waypoint already on the path).
private enum ubyte fromLeg = 7;

private enum GoalMode : ubyte {
    /// Enter a component that has an endpoint of `needKind`.
    component,
    /// Reach a free cell (a waypoint).
    cell,
    /// Re-enter `loopComp` at least `minLoopLength` road cells from the loop's start.
    loop
}

private struct Search {
    GoalMode mode;
    EndpointKind needKind;
    CubeCoord goalCell;
    int loopComp;
    /// Heuristic target.
    CubeCoord target;
    /// Start: either a network cell to leave (fromStart) or a leg start (cell + heading).
    CubeCoord start;
    bool startIsLeg;
    HexDir legHeading;
    /// Whole map instead of a window around start and target.
    bool fullWindow;
    bool relaxed;
}

private struct SearchResult {
    bool ok;
    /// Network cell entered (component/loop modes).
    CubeCoord entered;
}

private struct Planner {
    MapRect rect;
    const(BoundaryField)* field;
    RoadNetwork* net;
    RouteParams p;
    uint seed;

    // Map-sized scratch.
    short* aff;
    uint* stamp;
    uint curStamp;
    ubyte* bfsDist;
    ushort* netDist;
    uint* queue;
    /// Stamp marking cells already on the route being planned.
    uint routeStamp;

    // Window and A* state.
    int c0, r0, w, h;
    uint* g;
    ubyte* from;
    size_t stateCap;
    HeapEntry* heap;
    size_t heapLen, heapCap;

    // Path under construction (new cells only), and the committed full path.
    CubeCoord* path;
    size_t pathLen, pathCap;

    @disable this(this);

    this(ref RoadNetwork net, ref const BoundaryField field, const RouteParams p, uint seed) @nogc nothrow @trusted {
        this.net = &net;
        this.field = &field;
        this.rect = net.rect;
        this.p = p;
        this.seed = seed;
        immutable n = rect.cellCount;
        aff = cast(short*)calloc(n, short.sizeof);
        stamp = cast(uint*)calloc(n, uint.sizeof);
        bfsDist = cast(ubyte*)calloc(n, 1);
        netDist = cast(ushort*)malloc(n * ushort.sizeof);
        queue = cast(uint*)malloc(n * uint.sizeof);
        assert(aff && stamp && bfsDist && netDist && queue, "route planner allocation failed");
    }

    ~this() @nogc nothrow @trusted {
        free(aff);
        free(stamp);
        free(bfsDist);
        free(netDist);
        free(queue);
        free(g);
        free(from);
        free(heap);
        free(path);
    }

    private uint newStamp() @nogc nothrow @safe {
        return ++curStamp;
    }

    // ---- path buffer ----

    private void pathPush(const CubeCoord c) @nogc nothrow @trusted {
        if (pathLen == pathCap) {
            pathCap = pathCap * 2 + 256;
            path = cast(CubeCoord*)realloc(path, pathCap * CubeCoord.sizeof);
            assert(path !is null);
        }
        path[pathLen++] = c;
    }

    // ---- affinity field ----

    /// Rebuilds the attraction/repulsion field for route number `routeIndex`.
    private void buildAffinity(int routeIndex) @nogc nothrow @trusted {
        memset(aff, 0, rect.cellCount * short.sizeof);
        if (p.affinity == 0 || p.affinityRadius <= 0)
            return;
        immutable radius = p.affinityRadius > 30 ? 30 : p.affinityRadius;
        foreach (j; 0 .. net.numRoutes) {
            // Signed affinity of this pair of routes, deterministic per seed.
            immutable hv = hashCell(routeIndex, j, seed ^ 0xA5A5u);
            immutable int a = cast(int)(hv % cast(uint)(2 * p.affinity + 1)) - p.affinity;
            if (a == 0)
                continue;
            immutable st = newStamp();
            size_t head = 0, tail = 0;
            foreach (ref c; net.route(j)) {
                immutable i = rect.index(c);
                if (stamp[i] == st)
                    continue;
                stamp[i] = st;
                bfsDist[i] = 0;
                queue[tail++] = cast(uint)i;
            }
            while (head < tail) {
                immutable i = queue[head++];
                immutable d = bfsDist[i];
                // Linear falloff; cells on the route itself are blocked anyway.
                immutable v = aff[i] + a * (radius + 1 - d) / (radius + 1);
                aff[i] = cast(short)(v > 2 * p.affinity ? 2 * p.affinity : (v < -2 * p.affinity ? -2 * p.affinity : v));
                if (d >= radius)
                    continue;
                immutable c = rect.cellAt(i);
                foreach (k; 0 .. numHexDirs) {
                    immutable nc = c.neighbor(cast(HexDir)k);
                    if (!rect.contains(nc))
                        continue;
                    immutable ni = rect.index(nc);
                    if (stamp[ni] == st)
                        continue;
                    stamp[ni] = st;
                    bfsDist[ni] = cast(ubyte)(d + 1);
                    queue[tail++] = cast(uint)ni;
                }
            }
        }
    }

    // ---- network distance (for loops) ----

    private void buildNetDist(const CubeCoord from_) @nogc nothrow @trusted {
        memset(netDist, 0xFF, rect.cellCount * ushort.sizeof);
        size_t head = 0, tail = 0;
        immutable s = rect.index(from_);
        netDist[s] = 0;
        queue[tail++] = cast(uint)s;
        while (head < tail) {
            immutable i = queue[head++];
            immutable c = rect.cellAt(i);
            immutable dirs = net.roadDirs(c);
            foreach (k; 0 .. numHexDirs) {
                if (!(dirs & (1 << k)))
                    continue;
                immutable ni = rect.index(c.neighbor(cast(HexDir)k));
                if (netDist[ni] != ushort.max)
                    continue;
                netDist[ni] = cast(ushort)(netDist[i] + 1);
                queue[tail++] = cast(uint)ni;
            }
        }
    }

    // ---- A* ----

    private bool inWindow(const CubeCoord c) const @nogc nothrow pure @safe {
        immutable o = cubeToOffset(c);
        return o.col >= c0 && o.col < c0 + w && o.row >= r0 && o.row < r0 + h;
    }

    private uint stateOf(const CubeCoord c, int heading) const @nogc nothrow pure @safe {
        immutable o = cubeToOffset(c);
        return cast(uint)(((o.row - r0) * w + (o.col - c0)) * 6 + heading);
    }

    private CubeCoord cellOfState(uint s) const @nogc nothrow pure @safe {
        immutable local = s / 6;
        return offsetToCube(c0 + cast(int)(local % w), r0 + cast(int)(local / w));
    }

    private void setWindow(const ref Search s, const CubeCoord[] extra) @nogc nothrow @trusted {
        if (s.fullWindow) {
            c0 = 0;
            r0 = 0;
            w = rect.cols;
            h = rect.rows;
        } else {
            int minC = int.max, maxC = int.min, minR = int.max, maxR = int.min;
            void include(const CubeCoord c) {
                immutable o = cubeToOffset(c);
                minC = o.col < minC ? o.col : minC;
                maxC = o.col > maxC ? o.col : maxC;
                minR = o.row < minR ? o.row : minR;
                maxR = o.row > maxR ? o.row : maxR;
            }

            include(s.start);
            include(s.target);
            foreach (ref c; extra)
                include(c);
            immutable span = (maxC - minC) > (maxR - minR) ? (maxC - minC) : (maxR - minR);
            immutable pad = 10 + span / 2;
            minC = minC - pad < 0 ? 0 : minC - pad;
            minR = minR - pad < 0 ? 0 : minR - pad;
            maxC = maxC + pad >= rect.cols ? rect.cols - 1 : maxC + pad;
            maxR = maxR + pad >= rect.rows ? rect.rows - 1 : maxR + pad;
            c0 = minC;
            r0 = minR;
            w = maxC - minC + 1;
            h = maxR - minR + 1;
        }
        immutable states = cast(size_t)w * h * 6;
        if (states > stateCap) {
            free(g);
            free(from);
            g = cast(uint*)malloc(states * uint.sizeof);
            from = cast(ubyte*)malloc(states);
            assert(g !is null && from !is null, "route search allocation failed");
            stateCap = states;
        }
        memset(g, 0xFF, states * uint.sizeof);
        memset(from, fromNone, states);
        heapLen = 0;
    }

    private void heapPush(HeapEntry e) @nogc nothrow @trusted {
        if (heapLen == heapCap) {
            heapCap = heapCap * 2 + 1024;
            heap = cast(HeapEntry*)realloc(heap, heapCap * HeapEntry.sizeof);
            assert(heap !is null);
        }
        size_t i = heapLen++;
        while (i > 0) {
            immutable parent = (i - 1) / 2;
            if (heap[parent].f <= e.f)
                break;
            heap[i] = heap[parent];
            i = parent;
        }
        heap[i] = e;
    }

    private HeapEntry heapPop() @nogc nothrow @trusted {
        auto top = heap[0];
        immutable last = heap[--heapLen];
        size_t i = 0;
        while (true) {
            immutable l = 2 * i + 1;
            if (l >= heapLen)
                break;
            immutable r = l + 1;
            immutable c = (r < heapLen && heap[r].f < heap[l].f) ? r : l;
            if (heap[c].f >= last.f)
                break;
            heap[i] = heap[c];
            i = c;
        }
        if (heapLen > 0)
            heap[i] = last;
        return top;
    }

    /// Network cell `c` counts as the goal of the search.
    private bool isGoalNetworkCell(const ref Search s, const CubeCoord c) const @nogc nothrow @trusted {
        if (s.mode == GoalMode.component)
            return net.componentHas(net.componentOf(c), s.needKind);
        if (s.mode == GoalMode.loop) {
            immutable nd = netDist[rect.index(c)];
            return net.componentOf(c) == s.loopComp && nd != ushort.max && nd >= p.minLoopLength;
        }
        return false;
    }

    /// Penalized network neighbors of a new road cell.
    private int parallelCount(const ref Search s, const CubeCoord c, const CubeCoord prev) const @nogc nothrow @trusted {
        int n = 0;
        foreach (k; 0 .. numHexDirs) {
            immutable m = c.neighbor(cast(HexDir)k);
            if (m == prev || !rect.contains(m))
                continue;
            immutable mi = rect.index(m);
            if (stamp[mi] == routeStamp) {
                n++; // own earlier cells (not the predecessor)
                continue;
            }
            if (!net.onNetwork(m))
                continue;
            if (!s.startIsLeg && m == s.start)
                continue;
            if (s.mode == GoalMode.component && isGoalNetworkCell(s, m))
                continue;
            if (s.mode == GoalMode.loop && net.componentOf(m) == s.loopComp) {
                immutable nd = netDist[mi];
                if (nd <= 1 || (nd != ushort.max && nd + 1 >= p.minLoopLength))
                    continue;
            }
            n++;
        }
        return n;
    }

    private int stepCost(const ref Search s, const CubeCoord c, bool turned, int parallel) const @nogc nothrow @trusted {
        immutable o = cubeToOffset(c);
        int cost = 100;
        if (turned)
            cost += p.turnPenalty;
        if (!s.relaxed) {
            cost += valueNoise(o.col, o.row, p.noiseScale, seed) * p.bendiness / 1024;
            cost += aff[rect.index(c)];
            cost += parallel * p.parallelPenalty;
        }
        immutable bd = field.get(c);
        immutable soft = p.roadMargin + 4;
        if (bd < soft)
            cost += (soft - bd) * 40;
        return cost < 20 ? 20 : cost;
    }

    private bool freeCell(const CubeCoord c) const @nogc nothrow @trusted {
        if (!rect.contains(c) || !inWindow(c))
            return false;
        if (field.get(c) <= p.roadMargin)
            return false;
        if (net.onNetwork(c))
            return false;
        return stamp[rect.index(c)] != routeStamp;
    }

    /// Runs one A* search; on success appends the new cells to `path` and stamps them.
    private SearchResult search(const ref Search s, const CubeCoord[] windowExtra, out HexDir arrival) @nogc nothrow @trusted {
        SearchResult res;
        setWindow(s, windowExtra);
        uint bestGoal = uint.max;
        uint bestPred = uint.max;
        CubeCoord bestCell;

        uint heuristic(const CubeCoord c) {
            return cast(uint)(cubeDistance(c, s.target) * 50);
        }

        void relaxInto(const CubeCoord n, int heading, uint gNew, ubyte fromVal) {
            immutable st = stateOf(n, heading);
            if (gNew >= g[st])
                return;
            g[st] = gNew;
            from[st] = fromVal;
            heapPush(HeapEntry(gNew + heuristic(n), gNew, st));
        }

        // Tries the move from `c` (state `pred`, or the start) into neighbor n heading `nh`.
        void tryMove(const CubeCoord c, uint gc, int heading, int nh, uint pred, ubyte fromVal) {
            immutable n = c.neighbor(cast(HexDir)nh);
            if (!rect.contains(n))
                return;
            if (net.onNetwork(n)) {
                if (s.mode == GoalMode.cell || !isGoalNetworkCell(s, n))
                    return;
                if (!net.canAddExits(n, dirBit(opposite(cast(HexDir)nh))))
                    return;
                immutable total = gc + 100;
                if (total < bestGoal) {
                    bestGoal = total;
                    bestPred = pred;
                    bestCell = n;
                    arrival = cast(HexDir)nh;
                }
                return;
            }
            if (!freeCell(n))
                return;
            immutable cost = stepCost(s, n, heading >= 0 && nh != heading, parallelCount(s, n, c));
            if (s.mode == GoalMode.cell && n == s.goalCell) {
                immutable total = gc + cost;
                if (total < bestGoal) {
                    bestGoal = total;
                    bestPred = pred;
                    bestCell = n;
                    arrival = cast(HexDir)nh;
                }
                return;
            }
            relaxInto(n, nh, gc + cost, fromVal);
        }

        // Seed.
        if (s.startIsLeg) {
            immutable st = stateOf(s.start, s.legHeading);
            g[st] = 0;
            from[st] = fromLeg;
            heapPush(HeapEntry(heuristic(s.start), 0, st));
        } else {
            foreach (nh; 0 .. 6)
                if (net.canAddExits(s.start, dirBit(cast(HexDir)nh)))
                    tryMove(s.start, 0, -1, nh, uint.max, fromStart);
        }

        while (heapLen > 0) {
            immutable e = heapPop();
            if (e.f >= bestGoal)
                break;
            if (e.g != g[e.state])
                continue;
            immutable c = cellOfState(e.state);
            immutable heading = cast(int)(e.state % 6);
            foreach (dt; -1 .. 2)
                tryMove(c, e.g, heading, (heading + dt + 6) % 6, e.state, cast(ubyte)heading);
        }
        if (bestGoal == uint.max)
            return res;

        // Reconstruct new cells (reverse), then append in order.
        immutable mark = pathLen;
        if (s.mode == GoalMode.cell)
            pathPush(bestCell);
        uint st = bestPred;
        while (st != uint.max) {
            immutable c = cellOfState(st);
            pathPush(c);
            immutable f = from[st];
            if (f == fromStart || f == fromLeg)
                break;
            st = stateOf(c.neighbor(opposite(cast(HexDir)(st % 6))), f);
        }
        // The leg start is already on the path.
        if (s.startIsLeg)
            pathLen--;
        // Reverse the appended slice.
        for (size_t a = mark, b = pathLen; b > a + 1; a++, b--) {
            immutable t = path[a];
            path[a] = path[b - 1];
            path[b - 1] = t;
        }
        // Reject self-crossing paths.
        foreach (k; mark .. pathLen) {
            immutable i = rect.index(path[k]);
            if (stamp[i] == routeStamp) {
                foreach (j; mark .. k)
                    stamp[rect.index(path[j])] = 0;
                pathLen = mark;
                return res;
            }
            stamp[i] = routeStamp;
        }
        res.ok = true;
        res.entered = bestCell;
        return res;
    }

    private void clearRouteStamps(size_t from_) @nogc nothrow @trusted {
        foreach (k; from_ .. pathLen)
            stamp[rect.index(path[k])] = 0;
        pathLen = from_;
    }

    /// Waypoints between `a` and `b`, offset sideways; returns the count written.
    private size_t pickWaypoints(const CubeCoord a, const CubeCoord b, ref Random rng, CubeCoord[] out_) @nogc nothrow @trusted {
        immutable len = cubeDistance(a, b);
        if (p.waypoints <= 0 || len < 8)
            return 0;
        size_t n = 0;
        immutable k = p.waypoints > cast(int)out_.length ? cast(int)out_.length : p.waypoints;
        foreach (i; 0 .. k) {
            // Point along the line at t = (i+1)/(k+1), in cube coordinates scaled by (k+1).
            immutable t = i + 1, den = k + 1;
            immutable q = a.q + (b.q - a.q) * t / den;
            immutable r = a.r + (b.r - a.r) * t / den;
            immutable maxOff = len * p.detour / 100;
            immutable off = maxOff > 0 ? cast(int)rng.below(cast(uint)maxOff + 1) : 0;
            // Offset along one of the two hex directions most perpendicular to the line.
            immutable lx = 2L * (b.q - a.q) + (b.r - a.r), ly = (b.r - a.r) * 1732L / 1000;
            int best = 0, second = 1;
            long bestDot = long.max, secondDot = long.max;
            foreach (d; 0 .. 6) {
                immutable v = cubeDirs[d];
                long dot = (2L * v.q + v.r) * lx + (v.r * 1732L / 1000) * ly;
                dot = dot < 0 ? -dot : dot;
                if (dot < bestDot) {
                    second = best;
                    secondDot = bestDot;
                    best = d;
                    bestDot = dot;
                } else if (dot < secondDot) {
                    second = d;
                    secondDot = dot;
                }
            }
            immutable dir = cubeDirs[rng.below(2) == 0 ? best : second];
            auto c = CubeCoord.fromAxial(q + dir.q * off, r + dir.r * off);
            // Pull back toward the line until the cell is usable.
            int tries = off;
            while (tries-- > 0 && !(rect.contains(c) && field.get(c) > p.roadMargin + 2 && !net.onNetwork(c)))
                c = CubeCoord(c.q - dir.q, c.r - dir.r, c.s - dir.s);
            if (rect.contains(c) && field.get(c) > p.roadMargin + 2 && !net.onNetwork(c))
                out_[n++] = c;
        }
        return n;
    }

    /// Plans one route from `start` (on the network) to a goal; commits it on success.
    bool route(Search s, ref Random rng, bool loop) @nogc nothrow @trusted {
        if (net.numRoutes >= maxRoutes)
            return false;
        buildAffinity(net.numRoutes);
        CubeCoord[4] wps;
        immutable nw = loop ? 0 : pickWaypoints(s.start, s.target, rng, wps[]);
        foreach (attempt; 0 .. 4) {
            // 0: with waypoints, 1: direct, 2: whole map, 3: relaxed costs on the whole map.
            routeStamp = newStamp();
            pathLen = 0;
            pathPush(s.start);
            stamp[rect.index(s.start)] = routeStamp;
            Search cur = s;
            cur.fullWindow = attempt >= 2;
            cur.relaxed = attempt == 3;
            immutable useWps = attempt == 0 ? nw : 0;
            if (attempt == 1 && nw == 0)
                continue;
            bool failed = false;
            foreach (wi; 0 .. useWps) {
                Search leg = cur;
                leg.mode = GoalMode.cell;
                leg.goalCell = wps[wi];
                leg.target = wps[wi];
                if (!freeCell(wps[wi]))
                    continue;
                HexDir arr;
                immutable before = pathLen;
                auto r = search(leg, wps[0 .. useWps], arr);
                if (!r.ok) {
                    clearRouteStamps(before);
                    continue; // skip this waypoint
                }
                cur.startIsLeg = true;
                cur.start = path[pathLen - 1];
                cur.legHeading = arr;
            }
            HexDir arr;
            CubeCoord[1] extra = [s.start];
            auto r = search(cur, extra[], arr);
            if (!r.ok)
                failed = true;
            if (!failed) {
                pathPush(r.entered);
                net.commit(path[0 .. pathLen], loop);
                return true;
            }
            clearRouteStamps(0);
        }
        return false;
    }
}

/// Plans roads between the placed endpoints. Every source ends up connected to a sink and
/// every sink to a source. Returns RoutingFailed if some connection is impossible.
Result!int planNetwork(ref RoadNetwork net, ref const BoundaryField field, const Endpoints ep,
        const RouteParams p, ref Random rng) @nogc nothrow @trusted {
    alias R = Result!int;
    if (ep.numSources < 1 || ep.numSinks < 1)
        return R.err(EngineError.InvalidHexCoordinates);
    net.endpoints = ep;
    foreach (i; 0 .. ep.numSources)
        net.addEndpoint(ep.sources[i], EndpointKind.source);
    foreach (i; 0 .. ep.numSinks)
        net.addEndpoint(ep.sinks[i], EndpointKind.sink);

    auto planner = Planner(net, field, p, rng.next());

    CubeCoord nearest(const CubeCoord c, const(CubeCoord)[] among) {
        CubeCoord best = among[0];
        int bd = int.max;
        foreach (ref o; among) {
            immutable d = cubeDistance(c, o);
            if (d < bd) {
                bd = d;
                best = o;
            }
        }
        return best;
    }

    // Sources first (each needs a sink), then any sink still without a source.
    int[maxSources] so;
    foreach (i; 0 .. ep.numSources)
        so[i] = i;
    rng.shuffle(so[0 .. ep.numSources]);
    foreach (i; so[0 .. ep.numSources]) {
        immutable c = ep.sources[i];
        if (net.componentHas(net.componentOf(c), EndpointKind.sink))
            continue;
        Search s;
        s.mode = GoalMode.component;
        s.needKind = EndpointKind.sink;
        s.start = c;
        s.target = nearest(c, ep.sinkCells);
        if (!planner.route(s, rng, false))
            return R.err(EngineError.RoutingFailed);
    }
    int[maxSinks] si;
    foreach (i; 0 .. ep.numSinks)
        si[i] = i;
    rng.shuffle(si[0 .. ep.numSinks]);
    foreach (i; si[0 .. ep.numSinks]) {
        immutable c = ep.sinks[i];
        if (net.componentHas(net.componentOf(c), EndpointKind.source))
            continue;
        Search s;
        s.mode = GoalMode.component;
        s.needKind = EndpointKind.source;
        s.start = c;
        s.target = nearest(c, ep.sourceCells);
        if (!planner.route(s, rng, false))
            return R.err(EngineError.RoutingFailed);
    }

    // Loops: leave the network from a two-exit road cell and rejoin far along the network.
    foreach (l; 0 .. p.loops) {
        if (net.numRoutes == 0)
            break;
        bool done = false;
        foreach (attempt; 0 .. 8) {
            immutable ri = cast(int)rng.below(cast(uint)net.numRoutes);
            const rc = net.route(ri);
            if (rc.length < 6)
                continue;
            immutable x = rc[1 + rng.below(cast(uint)(rc.length - 2))];
            if (exitCount(net.roadDirs(x)) != 2 || net.isSource(x) || net.isSink(x))
                continue;
            planner.buildNetDist(x);
            // Aim at a far cell of the network close in space: the farthest-along cell of this
            // route within reach.
            CubeCoord target = rc[$ - 1];
            int bestScore = int.min;
            foreach (ref c; rc) {
                immutable nd = planner.netDist[net.rect.index(c)];
                if (nd == ushort.max || nd < p.minLoopLength)
                    continue;
                immutable score = -cubeDistance(c, x) * 2 + nd;
                if (score > bestScore) {
                    bestScore = score;
                    target = c;
                }
            }
            if (bestScore == int.min)
                continue;
            Search s;
            s.mode = GoalMode.loop;
            s.loopComp = net.componentOf(x);
            s.start = x;
            s.target = target;
            if (planner.route(s, rng, true)) {
                done = true;
                break;
            }
        }
        if (!done)
            break;
    }
    return R.ok(net.numRoutes);
}

// ---- tests -----------------------------------------------------------------------------------

version (unittest) {
    /// Structural invariants of a planned network.
    private void checkNetwork(ref const RoadNetwork net) @nogc nothrow @trusted {
        foreach (i; 0 .. net.rect.cellCount) {
            immutable c = net.rect.cellAt(i);
            immutable dirs = net.roadDirs(c);
            if (!net.onNetwork(c))
                continue;
            immutable shape = classify(dirs);
            assert(shape != RoadShape.invalid);
            foreach (d; 0 .. numHexDirs) {
                immutable nc = c.neighbor(cast(HexDir)d);
                // Symmetric exits.
                immutable has = (dirs & (1 << d)) != 0;
                immutable back = (net.roadDirs(nc) & (1 << opposite(cast(HexDir)d))) != 0;
                assert(has == back);
                assert(chainOk(shape, net.shapeAt(nc)));
            }
        }
        // Every endpoint has a road and is connected to the other kind.
        foreach (i; 0 .. net.endpoints.count) {
            immutable c = net.endpoints.at(i);
            assert(net.roadDirs(c) != 0);
            immutable other = net.endpoints.kindAt(i) == EndpointKind.source ? EndpointKind.sink : EndpointKind.source;
            assert(net.componentHas(net.componentOf(c), other));
        }
        // Route spans are connected chains.
        foreach (r; 0 .. net.numRoutes) {
            const rc = net.route(r);
            foreach (k; 0 .. rc.length - 1) {
                HexDir d;
                assert(directionTo(rc[k], rc[k + 1], d));
                assert(net.roadDirs(rc[k]) & dirBit(d));
            }
        }
    }

    private bool planFor(ref RoadNetwork net, ref const BoundaryField f, int sources, int sinks, uint seed,
            RouteParams p = RouteParams.init) @nogc nothrow @trusted {
        p.place.sources = sources;
        p.place.sinks = sinks;
        auto rng = Random(seed);
        auto ep = placeEndpoints(f, p.place, rng);
        if (!ep.isOk)
            return false;
        return planNetwork(net, f, ep.value, p, rng).isOk;
    }
}

@nogc nothrow unittest {
    // Valid, connected networks across counts and seeds; same seed gives the same network.
    immutable rect = MapRect(96, 54);
    auto f = BoundaryField(rect, null);
    static immutable int[2][6] counts = [[1, 1], [2, 1], [3, 1], [4, 2], [2, 4], [6, 3]];
    foreach (cnt; counts)
        foreach (seed; 1 .. 6) {
            auto a = RoadNetwork(rect);
            auto b = RoadNetwork(rect);
            assert(planFor(a, f, cnt[0], cnt[1], seed));
            assert(planFor(b, f, cnt[0], cnt[1], seed));
            checkNetwork(a);
            assert(a.numRoutes == b.numRoutes);
            foreach (i; 0 .. rect.cellCount)
                assert(a.roadDirs(rect.cellAt(i)) == b.roadDirs(rect.cellAt(i)));
            foreach (i; 0 .. rect.cellCount)
                assert(f.get(rect.cellAt(i)) > 2 || !a.onNetwork(rect.cellAt(i)));
        }
}

@nogc nothrow unittest {
    // Without noise, detours or affinity, two endpoints on one row are joined by a straight road.
    immutable rect = MapRect(40, 20);
    auto f = BoundaryField(rect, null);
    auto net = RoadNetwork(rect);
    Endpoints ep;
    ep.numSources = 1;
    ep.numSinks = 1;
    ep.sources[0] = offsetToCube(6, 10);
    ep.sinks[0] = offsetToCube(30, 10);
    RouteParams p;
    p.bendiness = 0;
    p.waypoints = 0;
    p.affinity = 0;
    p.loops = 0;
    auto rng = Random(1);
    assert(planNetwork(net, f, ep, p, rng).isOk);
    checkNetwork(net);
    assert(net.numRoutes == 1 && net.route(0).length == 25);
    foreach (col; 7 .. 30)
        assert(net.shapeAt(offsetToCube(col, 10)) == RoadShape.straight);
    assert(net.shapeAt(ep.sources[0]) == RoadShape.end && net.shapeAt(ep.sinks[0]) == RoadShape.end);
}

@nogc nothrow unittest {
    // Defaults bend: long routes contain bend tiles; three sources and one sink merge into
    // trunks (some junction exists, or the sink takes several roads).
    immutable rect = MapRect(96, 54);
    auto f = BoundaryField(rect, null);
    size_t bends = 0, junctions = 0;
    foreach (seed; 1 .. 6) {
        auto net = RoadNetwork(rect);
        assert(planFor(net, f, 3, 1, seed));
        foreach (i; 0 .. rect.cellCount) {
            immutable s = net.shapeAt(rect.cellAt(i));
            if (s == RoadShape.bend)
                bends++;
            if (s == RoadShape.junctionD || s == RoadShape.junctionE || s == RoadShape.junctionF)
                junctions++;
        }
    }
    assert(bends > 10 && junctions > 0);
}

@nogc nothrow unittest {
    // Loops add alternative paths.
    immutable rect = MapRect(96, 54);
    auto f = BoundaryField(rect, null);
    int loops = 0;
    foreach (seed; 1 .. 6) {
        auto net = RoadNetwork(rect);
        RouteParams p;
        p.loops = 2;
        assert(planFor(net, f, 2, 1, seed, p));
        checkNetwork(net);
        loops += net.numLoops;
    }
    assert(loops > 0);
}
