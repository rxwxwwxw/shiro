// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Ported from src/workers/wfc.worker.js (HexWFCSolver). D port for the Shiro engine.
//
// Headless, allocation-free-after-construction WFC solver over cube-coordinate cell sets:
// bitset possibility masks, undo-trail backtracking, no-chaining pruning, and fixed
// (read-only) boundary cells.
module wfc.solver;

import core.stdc.stdlib : calloc, free;
import core.random : Random;
import core.result : Result;
import wfc.cell : HexWFCCell;
import wfc.hex;
import wfc.rules;
import wfc.tile_data;

enum size_t maxSolveCells = 384;
enum size_t maxFixedCells = 256;
private enum size_t maxEntries = maxSolveCells + maxFixedCells;
private enum size_t hashSize = 2048;
private enum size_t hashMask = hashSize - 1;
private enum size_t trailCapacity = maxSolveCells * numStates;

enum SolveError : int {
    None = 0,
    /// More solve/fixed cells than the solver's static capacity, or duplicate coordinates.
    InvalidInput,
    /// Boundary constraints alone produced a contradiction.
    NeighborConflict,
    /// Every try hit the backtrack limit.
    BacktrackLimit
}

struct SolverOptions {
    int maxTries = 2;
    int maxBacktracks = 500;
}

struct SolveStats {
    int backtracks;
    int tries;
}

/// A cell with a known tile state (boundary constraint or forced collapse).
struct FixedCell {
    CubeCoord coord;
    TileState state;
    /// Soft cells may be unfixed (turned into solve cells) to resolve a boundary conflict.
    bool soft;
}

/// Returns the state ID stored at a global cell, or -1 if the cell is empty/unsolved. Used to
/// find the anchors of a cell that gets unfixed.
alias TileLookup = int delegate(const CubeCoord) @nogc nothrow;

/// Returns the set of states a cell may take, or null if the cell is unconstrained. Applied to
/// every solve cell (including unfixed ones), e.g. to force planned roads.
alias CellMaskLookup = const(StateSet)* delegate(const CubeCoord) @nogc nothrow;

/// True for cells whose boundary constraint recovery should drop last (e.g. planned roads, where
/// a dropped seam would put a mountain on the road).
alias CellProtectLookup = bool delegate(const CubeCoord) @nogc nothrow;

/// Optional per-cell constraints threaded through generation and recovery.
struct CellConstraints {
    CellMaskLookup mask;
    CellProtectLookup protect;
}

struct PlacedTile {
    CubeCoord coord;
    TileState state;
}

/// Description of the most recent propagation contradiction.
struct Conflict {
    bool valid;
    CubeCoord failed;
    CubeCoord source;
    bool sourceIsFixed;
    HexDir dir;
}

private struct TrailEntry {
    ushort cell;
    ushort state;
}

private struct Decision {
    StateSet prev;
    StateSet tried;
    uint trailStart;
    uint orderLen;
    ushort cell;
}

private struct Storage {
    /// Working solve/fixed lists; unfixing edits these between attempts.
    CubeCoord[maxSolveCells] workSolve;
    FixedCell[maxFixedCells] workFixed;
    /// Cells unfixed during the current solve, with their original (pre-unfix) states.
    FixedCell[maxFixedCells] unfixed;
    CubeCoord[maxEntries] coords;
    /// Neighbor entry index per direction, or -1. Fixed entries only link to solve cells.
    short[6][maxEntries] nbr;
    short[hashSize] table; // entry index + 1, 0 = empty
    HexWFCCell[maxSolveCells] cells;
    short[maxFixedCells] fixedState;
    ushort[maxEntries] stack;
    bool[maxEntries] inStack;
    PlacedTile[maxSolveCells] order;
    Decision[maxSolveCells] decisions;
    StateSet[numTiles] tileMask;
    TrailEntry[trailCapacity] trail;
}

struct Solver {
    private const(AdjacencyRules)* rules;
    private Storage* st;
    private SolverOptions opt;
    private size_t numSolve, numFixed, stackLen, trailLen, orderLen, decisionLen;
    private int backtracks;
    private bool initConflict;
    private size_t unfixedLen;
    Conflict lastConflict;

    /// Size of the solver's one-time working allocation.
    enum size_t storageBytes = Storage.sizeof;

    @disable this(this);

    this(const(AdjacencyRules)* rules, SolverOptions options = SolverOptions.init) @nogc nothrow {
        this.rules = rules;
        this.opt = options;
        st = cast(Storage*)calloc(1, Storage.sizeof);
        assert(st !is null, "solver storage allocation failed");
        foreach (i; 0 .. numStates)
            st.tileMask[rules.states[i].tile].set(i);
    }

    ~this() @nogc nothrow {
        free(st);
    }

    size_t cellCount() const @nogc nothrow pure @safe {
        return numSolve;
    }

    /// Placed tiles of the last successful solve, in collapse order (initial collapses first).
    const(PlacedTile)[] collapseOrder() const @nogc nothrow pure @trusted {
        return st.order[0 .. orderLen];
    }

    /// Final tile state of solve cell `i` (index in the order passed to solve), or null state ID -1.
    int stateOf(size_t i) const @nogc nothrow pure @trusted {
        return st.cells[i].state;
    }

    /// Copies solved tiles (solve cells only) into `buf`; returns the count.
    size_t extract(PlacedTile[] buf) const @nogc nothrow @trusted {
        size_t n = 0;
        foreach (i; 0 .. numSolve) {
            immutable s = st.cells[i].state;
            if (s < 0)
                continue;
            assert(n < buf.length);
            buf[n++] = PlacedTile(st.coords[i], rules.states[s]);
        }
        return n;
    }

    const(AdjacencyRules)* rulesPtr() const @nogc nothrow pure @safe {
        return rules;
    }

    /// State for a state ID.
    TileState rulesState(int id) const @nogc nothrow pure @trusted {
        return rules.states[id];
    }

    /// State ID for a tile state (-1 if invalid).
    int stateIdOf(const TileState s) const @nogc nothrow pure @trusted {
        return rules.stateId(s.tile, s.rotation, s.level);
    }

    /// Cells that were unfixed by the last solve (successful or not), with original states.
    const(FixedCell)[] unfixedCells() const @nogc nothrow pure @trusted {
        return st.unfixed[0 .. unfixedLen];
    }

    /// Unfixed cells that ended up with a different tile than before. The caller must write these
    /// back to its global map. Returns the count written to `buf`.
    size_t changedCells(FixedCell[] buf) const @nogc nothrow @trusted {
        size_t n = 0;
        foreach (ref u; st.unfixed[0 .. unfixedLen]) {
            immutable idx = find(u.coord);
            if (idx < 0 || idx >= numSolve)
                continue;
            immutable s = st.cells[idx].state;
            if (s < 0)
                continue;
            immutable ns = rules.states[s];
            if (ns == u.state)
                continue;
            assert(n < buf.length);
            buf[n++] = FixedCell(u.coord, ns, true);
        }
        return n;
    }

    /// Solves `solveCells` given read-only `fixedCells`.
    ///
    /// Soft fixed cells may be unfixed when the boundary alone is contradictory: the offending
    /// neighbor becomes a solve cell and its own neighbors in the global map (found through
    /// `lookup`) become fixed anchors, so the unfixed cell stays compatible with the rest of the
    /// map. Result indexes of solve cells keep their input order; unfixed cells are appended.
    /// `mask`, if given, restricts the possibilities of each solve cell.
    Result!(SolveStats, SolveError) solve(const CubeCoord[] solveCells, const FixedCell[] fixedCells,
            const FixedCell[] initialCollapses, ref Random rng, scope TileLookup lookup = null,
            scope CellMaskLookup mask = null) @nogc nothrow @trusted {
        alias R = Result!(SolveStats, SolveError);
        lastConflict = Conflict.init;
        unfixedLen = 0;
        if (solveCells.length > maxSolveCells || fixedCells.length > maxFixedCells)
            return R.err(SolveError.InvalidInput);

        numSolve = solveCells.length;
        numFixed = fixedCells.length;
        st.workSolve[0 .. numSolve] = solveCells[];
        st.workFixed[0 .. numFixed] = fixedCells[];
        size_t unfixBudget = 0;
        foreach (ref f; fixedCells)
            if (f.soft)
                unfixBudget++;

        int totalBacktracks = 0;
        foreach (attempt; 1 .. opt.maxTries + 1) {
            // Seed from boundary and forced collapses; unfix soft neighbors on contradiction.
            while (true) {
                if (!init(mask))
                    return R.err(SolveError.InvalidInput);
                // Boundary first, so forced collapses can be checked against it.
                foreach (i; 0 .. numFixed)
                    push(numSolve + i);
                bool seeded = !initConflict && propagate();
                // Forced collapses are hints: skipped if the boundary (or an earlier seed) already
                // ruled the state out.
                foreach (ref ic; initialCollapses) {
                    if (!seeded)
                        break;
                    immutable idx = find(ic.coord);
                    if (idx < 0 || idx >= numSolve || st.cells[idx].collapsed)
                        continue;
                    immutable id = rules.stateId(ic.state.tile, ic.state.rotation, ic.state.level);
                    if (id < 0 || !st.cells[idx].has(id))
                        continue;
                    collapseCell(idx, id);
                    push(idx);
                    seeded = propagate();
                }
                if (seeded)
                    break;
                clearStack();
                if (unfixBudget == 0 || !unfixNeighborOfConflict(lookup))
                    return R.err(SolveError.NeighborConflict);
                unfixBudget--;
            }

            immutable ok = runSearch(rng);
            totalBacktracks += backtracks;
            if (ok)
                return R.ok(SolveStats(totalBacktracks, attempt));
        }
        return R.err(SolveError.BacktrackLimit);
    }

    // ---- unfixing ----------------------------------------------------------------------------

    private int workFixedIndex(const CubeCoord c) const @nogc nothrow @trusted {
        foreach (i; 0 .. numFixed)
            if (st.workFixed[i].coord == c)
                return cast(int)i;
        return -1;
    }

    private bool inWorkSolve(const CubeCoord c) const @nogc nothrow @trusted {
        foreach (i; 0 .. numSolve)
            if (st.workSolve[i] == c)
                return true;
        return false;
    }

    /// Picks the soft fixed cell that caused (or borders) the last conflict and unfixes it.
    /// Returns false if no candidate exists or capacity would be exceeded.
    private bool unfixNeighborOfConflict(scope TileLookup lookup) @nogc nothrow @trusted {
        if (!lastConflict.valid)
            return false;
        int cand = -1;
        if (lastConflict.sourceIsFixed) {
            immutable i = workFixedIndex(lastConflict.source);
            if (i >= 0 && st.workFixed[i].soft)
                cand = i;
        }
        if (cand < 0) {
            foreach (d; 0 .. numHexDirs) {
                immutable i = workFixedIndex(lastConflict.failed.neighbor(cast(HexDir)d));
                if (i >= 0 && st.workFixed[i].soft) {
                    cand = i;
                    break;
                }
            }
        }
        if (cand < 0 || numSolve >= maxSolveCells || unfixedLen >= maxFixedCells)
            return false;

        immutable target = st.workFixed[cand];
        // Remove from fixed (swap with last), add to solve.
        st.workFixed[cand] = st.workFixed[--numFixed];
        st.workSolve[numSolve++] = target.coord;
        st.unfixed[unfixedLen++] = target;

        // Anchors: mapped neighbors that are neither solve nor fixed become fixed (hard).
        if (lookup !is null) {
            foreach (d; 0 .. numHexDirs) {
                immutable nc = target.coord.neighbor(cast(HexDir)d);
                if (inWorkSolve(nc) || workFixedIndex(nc) >= 0)
                    continue;
                immutable id = lookup(nc);
                if (id < 0)
                    continue;
                if (numFixed >= maxFixedCells)
                    return false;
                st.workFixed[numFixed++] = FixedCell(nc, rules.states[id], false);
            }
        }
        return true;
    }

    // ---- setup -------------------------------------------------------------------------------

    private static size_t hashOf(const CubeCoord c) @nogc nothrow pure @safe {
        return (cast(uint)(c.q * 73_856_093) ^ cast(uint)(c.r * 19_349_663)) & hashMask;
    }

    private int find(const CubeCoord c) const @nogc nothrow @trusted {
        size_t h = hashOf(c);
        while (st.table[h]) {
            immutable e = st.table[h] - 1;
            if (st.coords[e] == c)
                return e;
            h = (h + 1) & hashMask;
        }
        return -1;
    }

    private bool insert(const CubeCoord c, size_t entry) @nogc nothrow @trusted {
        size_t h = hashOf(c);
        while (st.table[h]) {
            if (st.coords[st.table[h] - 1] == c)
                return false; // duplicate
            h = (h + 1) & hashMask;
        }
        st.table[h] = cast(short)(entry + 1);
        st.coords[entry] = c;
        return true;
    }

    private bool init(scope CellMaskLookup mask) @nogc nothrow @trusted {
        stackLen = trailLen = orderLen = decisionLen = 0;
        backtracks = 0;
        initConflict = false;
        st.table[] = 0;
        st.inStack[] = false;

        foreach (i, ref c; st.workSolve[0 .. numSolve]) {
            if (!c.isValid || !insert(c, i))
                return false;
            st.cells[i].reset();
        }
        foreach (i, ref f; st.workFixed[0 .. numFixed]) {
            immutable id = rules.stateId(f.state.tile, f.state.rotation, f.state.level);
            if (id < 0 || !f.coord.isValid || !insert(f.coord, numSolve + i))
                return false;
            st.fixedState[i] = cast(short)id;
        }

        foreach (e; 0 .. numSolve + numFixed) {
            immutable isFixed = e >= numSolve;
            foreach (d; 0 .. numHexDirs) {
                immutable n = find(st.coords[e].neighbor(cast(HexDir)d));
                st.nbr[e][d] = (n >= 0 && (!isFixed || n < numSolve)) ? cast(short)n : cast(short)-1;
            }
        }

        // Per-cell masks; restricted cells are queued so the restriction propagates.
        if (mask !is null) {
            foreach (i; 0 .. numSolve) {
                const m = mask(st.coords[i]);
                if (m is null)
                    continue;
                st.cells[i].possibilities.intersect(*m);
                if (st.cells[i].possibilities.empty) {
                    lastConflict = Conflict(true, st.coords[i], st.coords[i], false, HexDir.NE);
                    initConflict = true;
                }
                push(i);
            }
        }

        // No-chaining pruning from fixed cells into adjacent solve cells.
        foreach (i; 0 .. numFixed) {
            immutable tile = rules.states[st.fixedState[i]].tile;
            if (tileList[tile].preventChaining && !pruneChaining(numSolve + i, tile))
                initConflict = true;
        }
        return true;
    }

    // ---- propagation -------------------------------------------------------------------------

    private void push(size_t e) @nogc nothrow @trusted {
        if (st.inStack[e])
            return;
        st.inStack[e] = true;
        st.stack[stackLen++] = cast(ushort)e;
    }

    private void clearStack() @nogc nothrow @trusted {
        foreach (i; 0 .. stackLen)
            st.inStack[st.stack[i]] = false;
        stackLen = 0;
    }

    private void removeStates(size_t cell, const ref StateSet remove) @nogc nothrow @trusted {
        auto c = &st.cells[cell];
        foreach (s; remove.bits) {
            assert(trailLen < trailCapacity);
            st.trail[trailLen++] = TrailEntry(cast(ushort)cell, cast(ushort)s);
            c.possibilities.clear(s);
        }
    }

    /// Removes every state of `tile` from the uncollapsed solve neighbors of entry `e`.
    /// Returns false if a neighbor is left with no possibilities.
    private bool pruneChaining(size_t e, size_t tile) @nogc nothrow @trusted {
        foreach (d; 0 .. numHexDirs) {
            immutable n = st.nbr[e][d];
            if (n < 0 || st.cells[n].collapsed)
                continue;
            StateSet gone = st.cells[n].possibilities;
            gone.intersect(st.tileMask[tile]);
            if (!gone.any)
                continue;
            removeStates(n, gone);
            if (st.cells[n].possibilities.empty) {
                lastConflict = Conflict(true, st.coords[n], st.coords[e], e >= numSolve, cast(HexDir)d);
                return false;
            }
            push(n);
        }
        return true;
    }

    private bool propagate() @nogc nothrow @trusted {
        // Edge (type, level) pairs already unioned for the current source/direction.
        while (stackLen > 0) {
            immutable e = st.stack[--stackLen];
            st.inStack[e] = false;

            StateSet single;
            const(StateSet)* poss;
            if (e >= numSolve) {
                single.set(st.fixedState[e - numSolve]);
                poss = &single;
            } else {
                poss = &st.cells[e].possibilities;
            }

            foreach (d; 0 .. numHexDirs) {
                immutable n = st.nbr[e][d];
                if (n < 0 || st.cells[n].collapsed)
                    continue;
                immutable dir = cast(HexDir)d;
                immutable allowed = rules.allowedAcross(*poss, dir);

                StateSet gone = st.cells[n].possibilities;
                gone.subtract(allowed);
                if (!gone.any)
                    continue;
                removeStates(n, gone);

                if (st.cells[n].possibilities.empty) {
                    lastConflict = Conflict(true, st.coords[n], st.coords[e], e >= numSolve, dir);
                    clearStack();
                    return false;
                }
                push(n);
            }
        }
        return true;
    }

    // ---- search ------------------------------------------------------------------------------

    private void collapseCell(size_t cell, size_t stateId) @nogc nothrow @trusted {
        st.cells[cell].collapse(stateId);
        st.order[orderLen++] = PlacedTile(st.coords[cell], rules.states[stateId]);
    }

    private int lowestEntropyCell(ref Random rng) @nogc nothrow @trusted {
        uint best = uint.max;
        int bestCell = -1;
        foreach (i; 0 .. numSolve) {
            if (st.cells[i].collapsed || st.cells[i].possibilities.empty)
                continue;
            immutable k = st.cells[i].entropyKey(rng);
            if (k < best) {
                best = k;
                bestCell = cast(int)i;
            }
        }
        return bestCell;
    }

    /// Weighted random pick among possibilities of the decision's cell not yet tried.
    private bool collapseWithExclusions(ref Decision dec, ref Random rng) @nogc nothrow @trusted {
        StateSet avail = st.cells[dec.cell].possibilities;
        avail.subtract(dec.tried);
        if (!avail.any)
            return false;
        uint total = 0;
        foreach (s; avail.bits)
            total += tileList[rules.states[s].tile].weight;
        uint r = rng.below(total);
        size_t chosen = avail.firstSet;
        foreach (s; avail.bits) {
            immutable w = tileList[rules.states[s].tile].weight;
            if (r < w) {
                chosen = s;
                break;
            }
            r -= w;
        }
        dec.tried.set(chosen);
        collapseCell(dec.cell, chosen);
        push(dec.cell);
        return true;
    }

    private void undo(ref Decision dec) @nogc nothrow @trusted {
        while (trailLen > dec.trailStart) {
            immutable t = st.trail[--trailLen];
            st.cells[t.cell].possibilities.set(t.state);
        }
        auto c = &st.cells[dec.cell];
        c.possibilities = dec.prev;
        c.collapsed = false;
        c.state = -1;
        orderLen = dec.orderLen;
        clearStack();
    }

    /// Undoes decisions until one has an untried state left. Returns false when the backtrack
    /// budget is spent or the stack is exhausted.
    private bool backtrack() @nogc nothrow @trusted {
        while (true) {
            backtracks++;
            if (backtracks >= opt.maxBacktracks || decisionLen == 0)
                return false;
            auto dec = &st.decisions[decisionLen - 1];
            undo(*dec);
            StateSet avail = dec.prev;
            avail.subtract(dec.tried);
            if (avail.any)
                return true;
            decisionLen--;
        }
    }

    private bool runSearch(ref Random rng) @nogc nothrow @trusted {
        bool retry = false;
        while (true) {
            if (!retry) {
                immutable target = lowestEntropyCell(rng);
                if (target < 0)
                    return true;
                auto d = &st.decisions[decisionLen++];
                d.prev = st.cells[target].possibilities;
                d.tried.reset();
                d.trailStart = cast(uint)trailLen;
                d.orderLen = cast(uint)orderLen;
                d.cell = cast(ushort)target;
            }
            retry = false;
            auto dec = &st.decisions[decisionLen - 1];
            if (!collapseWithExclusions(*dec, rng)) {
                // Cannot happen for a fresh decision; treat as exhausted.
                decisionLen--;
                if (!backtrack())
                    return false;
                retry = true;
                continue;
            }
            immutable tile = rules.states[st.cells[dec.cell].state].tile;
            immutable ok = (!tileList[tile].preventChaining || pruneChaining(dec.cell, tile)) && propagate();
            if (!ok) {
                clearStack();
                if (!backtrack())
                    return false;
                retry = true;
            }
        }
    }
}

// ---- tests -----------------------------------------------------------------------------------

version (unittest) {
    private __gshared AdjacencyRules testRules;
    private __gshared bool testRulesReady;

    private const(AdjacencyRules)* rulesForTest() @nogc nothrow @trusted {
        if (!testRulesReady) {
            AdjacencyRules.build(testRules);
            testRulesReady = true;
        }
        return &testRules;
    }

    /// Cells of a radius-`radius` grid around (0,0,0) into `buf`.
    private CubeCoord[] gridCells(int radius, return ref CubeCoord[maxSolveCells] buf) @nogc nothrow @trusted {
        immutable n = cubeCoordsInRadius(CubeCoord(0, 0, 0), radius, buf[]);
        return buf[0 .. n];
    }

    /// Verifies every solved cell agrees with every solved/fixed neighbor.
    private void checkConsistent(ref Solver s, const(PlacedTile)[] tiles, const FixedCell[] fixed = null) @nogc nothrow @trusted {
        const rules = rulesForTest();
        foreach (ref a; tiles) {
            immutable ia = rules.stateId(a.state.tile, a.state.rotation, a.state.level);
            foreach (d; 0 .. numHexDirs) {
                immutable nc = a.coord.neighbor(cast(HexDir)d);
                int ib = -1;
                foreach (ref b; tiles)
                    if (b.coord == nc)
                        ib = rules.stateId(b.state.tile, b.state.rotation, b.state.level);
                foreach (ref f; fixed)
                    if (f.coord == nc)
                        ib = rules.stateId(f.state.tile, f.state.rotation, f.state.level);
                if (ib < 0)
                    continue;
                immutable ea = rules.stateEdges[ia][d];
                immutable eb = rules.stateEdges[ib][opposite(cast(HexDir)d)];
                assert(edgesCompatible(ea.type, ea.level, eb.type, eb.level));
            }
        }
    }
}

unittest {
    // Small patch solves; every cell is placed and mutually consistent.
    auto s = Solver(rulesForTest());
    auto rng = Random(1);
    CubeCoord[maxSolveCells] buf;
    auto cells = gridCells(2, buf);
    auto r = s.solve(cells, null, null, rng);
    assert(r.isOk, "radius-2 patch must solve");
    PlacedTile[maxSolveCells] out_;
    immutable n = s.extract(out_[]);
    assert(n == 19);
    checkConsistent(s, out_[0 .. n]);
    assert(s.collapseOrder.length >= 19);
}

unittest {
    // Full 217-cell grids across many seeds: always solved, always consistent.
    auto s = Solver(rulesForTest());
    CubeCoord[maxSolveCells] buf;
    auto cells = gridCells(8, buf);
    assert(cells.length == 217);
    foreach (seed; 1 .. 21) {
        auto rng = Random(seed);
        auto r = s.solve(cells, null, null, rng);
        assert(r.isOk, "grid failed to solve");
        PlacedTile[maxSolveCells] out_;
        immutable n = s.extract(out_[]);
        assert(n == 217);
        checkConsistent(s, out_[0 .. n]);
    }
}

unittest {
    // Determinism: same seed gives identical layouts, different seeds differ.
    CubeCoord[maxSolveCells] buf;
    auto cells = gridCells(5, buf);
    PlacedTile[maxSolveCells][3] res;
    size_t[3] counts;
    immutable uint[3] seeds = [11, 11, 12];
    foreach (k; 0 .. 3) {
        auto s = Solver(rulesForTest());
        auto rng = Random(seeds[k]);
        assert(s.solve(cells, null, null, rng).isOk);
        counts[k] = s.extract(res[k][]);
    }
    assert(counts[0] == counts[1]);
    foreach (i; 0 .. counts[0])
        assert(res[0][i] == res[1][i]);
    bool differs = false;
    foreach (i; 0 .. counts[0])
        if (res[0][i] != res[2][i])
            differs = true;
    assert(differs);
}

unittest {
    // Fixed boundary cells constrain their neighbors; initial collapses are honored.
    const rules = rulesForTest();
    auto s = Solver(rules);
    CubeCoord[maxSolveCells] buf;
    auto all = gridCells(3, buf);
    // Fixed ring-4 water on the east side, solve the rest of radius 3.
    FixedCell[8] fixed;
    size_t nf = 0;
    CubeCoord[maxSolveCells] solveBuf;
    size_t ns = 0;
    foreach (c; all) {
        if (c.q == 3 || (c.q == 2 && c.r == -2))
            continue;
        solveBuf[ns++] = c;
    }
    // Put water (level 0) at two cells adjacent to the solve region.
    fixed[nf++] = FixedCell(CubeCoord(3, -3, 0), TileState(1, 0, 0));
    fixed[nf++] = FixedCell(CubeCoord(3, -2, -1), TileState(1, 0, 0));
    FixedCell[1] init = [FixedCell(CubeCoord(0, 0, 0), TileState(0, 0, 0))];
    auto rng = Random(3);
    auto r = s.solve(solveBuf[0 .. ns], fixed[0 .. nf], init[], rng);
    assert(r.isOk);
    PlacedTile[maxSolveCells] out_;
    immutable n = s.extract(out_[]);
    assert(n == ns);
    checkConsistent(s, out_[0 .. n], fixed[0 .. nf]);
    foreach (i; 0 .. n)
        if (out_[i].coord == CubeCoord(0, 0, 0))
            assert(out_[i].state == TileState(0, 0, 0));
    assert(s.collapseOrder[0].coord == CubeCoord(0, 0, 0));
}

unittest {
    // preventChaining tiles never touch themselves.
    auto s = Solver(rulesForTest());
    CubeCoord[maxSolveCells] buf;
    auto cells = gridCells(8, buf);
    foreach (seed; 100 .. 110) {
        auto rng = Random(seed);
        assert(s.solve(cells, null, null, rng).isOk);
        PlacedTile[maxSolveCells] out_;
        immutable n = s.extract(out_[]);
        foreach (i; 0 .. n) {
            if (!tileList[out_[i].state.tile].preventChaining)
                continue;
            foreach (d; 0 .. numHexDirs)
                foreach (j; 0 .. n)
                    if (out_[j].coord == out_[i].coord.neighbor(cast(HexDir)d))
                        assert(out_[j].state.tile != out_[i].state.tile);
        }
    }
}

unittest {
    // Contradictory fixed neighbors (grass at levels 0 and 3 on opposite sides) are reported.
    auto s = Solver(rulesForTest());
    immutable x = CubeCoord(0, 0, 0);
    CubeCoord[1] cells = [x];
    FixedCell[2] fixed = [
        FixedCell(x.neighbor(HexDir.E), TileState(0, 0, 0)),
        FixedCell(x.neighbor(HexDir.W), TileState(0, 0, 3))
    ];
    auto rng = Random(1);
    auto r = s.solve(cells[], fixed[], null, rng);
    assert(!r.isOk && r.error == SolveError.NeighborConflict);
    assert(s.lastConflict.valid && s.lastConflict.failed == x && s.lastConflict.sourceIsFixed);
}

unittest {
    // Input validation: duplicate coordinates and over-capacity requests.
    auto s = Solver(rulesForTest());
    auto rng = Random(1);
    CubeCoord[2] dup = [CubeCoord(0, 0, 0), CubeCoord(0, 0, 0)];
    auto r = s.solve(dup[], null, null, rng);
    assert(!r.isOk && r.error == SolveError.InvalidInput);
    CubeCoord[maxSolveCells + 1] big;
    r = s.solve(big[], null, null, rng);
    assert(!r.isOk && r.error == SolveError.InvalidInput);
}

unittest {
    // A no-chain fixed tile (ROAD_END) with a single solve neighbor surrounded so that neighbor
    // can only be ROAD_END-compatible is still solvable; chaining never yields the same tile.
    const rules = rulesForTest();
    auto s = Solver(rules);
    immutable x = CubeCoord(0, 0, 0);
    immutable roadEnd = cast(ubyte)tileIdByName("ROAD_END");
    CubeCoord[1] cells = [x];
    FixedCell[1] fixed = [FixedCell(x.neighbor(HexDir.E), TileState(roadEnd, 0, 0))];
    foreach (seed; 1 .. 30) {
        auto rng = Random(seed);
        auto r = s.solve(cells[], fixed[], null, rng);
        assert(r.isOk);
        PlacedTile[1] o;
        assert(s.extract(o[]) == 1);
        assert(o[0].state.tile != roadEnd);
    }
}

unittest {
    // Soft boundary unfixing: grass at level 0 east and level 3 west of one cell is
    // contradictory, but unfixing a soft neighbor resolves it.
    const rules = rulesForTest();
    auto s = Solver(rules);
    immutable x = CubeCoord(0, 0, 0);
    immutable a = x.neighbor(HexDir.E);
    immutable b = x.neighbor(HexDir.W);
    immutable anchorCoord = a.neighbor(HexDir.E);
    immutable anchorState = TileState(0, 0, 0); // grass, level 0
    CubeCoord[1] cells = [x];
    FixedCell[2] fixed = [
        FixedCell(a, TileState(0, 0, 0), true), FixedCell(b, TileState(0, 0, 3), true)
    ];
    scope TileLookup lookup = (const CubeCoord c) @nogc nothrow{
        return c == anchorCoord ? cast(int)rulesForTest().stateId(0, 0, 0) : -1;
    };
    foreach (seed; 1 .. 20) {
        auto rng = Random(seed);
        auto r = s.solve(cells[], fixed[], null, rng, lookup);
        assert(r.isOk, "unfixing should resolve the contradiction");
        assert(s.unfixedCells.length >= 1);

        PlacedTile[maxSolveCells] placed;
        immutable n = s.extract(placed[]);
        assert(n == 1 + s.unfixedCells.length);

        // Rebuild the effective fixed set: untouched originals plus the anchor.
        FixedCell[3] eff;
        size_t ne = 0;
        foreach (ref f; fixed) {
            bool wasUnfixed = false;
            foreach (ref u; s.unfixedCells)
                if (u.coord == f.coord)
                    wasUnfixed = true;
            if (!wasUnfixed)
                eff[ne++] = f;
        }
        eff[ne++] = FixedCell(anchorCoord, anchorState);
        checkConsistent(s, placed[0 .. n], eff[0 .. ne]);

        // changedCells reports exactly the unfixed cells whose tile differs from the original.
        FixedCell[maxFixedCells] changed;
        immutable nc = s.changedCells(changed[]);
        foreach (i; 0 .. nc)
            assert(changed[i].state != (changed[i].coord == a ? fixed[0].state : fixed[1].state));
    }
}

unittest {
    // Without soft cells the same contradiction is a hard NeighborConflict (no unfixing).
    auto s = Solver(rulesForTest());
    immutable x = CubeCoord(0, 0, 0);
    CubeCoord[1] cells = [x];
    FixedCell[2] fixed = [
        FixedCell(x.neighbor(HexDir.E), TileState(0, 0, 0), false),
        FixedCell(x.neighbor(HexDir.W), TileState(0, 0, 3), false)
    ];
    auto rng = Random(1);
    auto r = s.solve(cells[], fixed[], null, rng);
    assert(!r.isOk && r.error == SolveError.NeighborConflict);
    assert(s.unfixedCells.length == 0);
}

unittest {
    // Per-cell masks: a masked cell only collapses to states in its mask, the restriction
    // propagates to neighbors, and an empty mask is a NeighborConflict.
    const rules = rulesForTest();
    auto s = Solver(rules);
    CubeCoord[maxSolveCells] buf;
    auto cells = gridCells(3, buf);
    immutable roadA = cast(ubyte)tileIdByName("ROAD_A");
    StateSet only;
    foreach (lvl; 0 .. levelsCount)
        only.set(rules.stateId(roadA, 0, lvl)); // straight E-W road
    StateSet none;
    immutable center = CubeCoord(0, 0, 0);
    scope CellMaskLookup mask = (const CubeCoord c) @nogc nothrow{ return c == center ? &only : null; };
    foreach (seed; 1 .. 20) {
        auto rng = Random(seed);
        assert(s.solve(cells, null, null, rng, null, mask).isOk);
        PlacedTile[maxSolveCells] out_;
        immutable n = s.extract(out_[]);
        checkConsistent(s, out_[0 .. n]);
        foreach (i; 0 .. n) {
            if (out_[i].coord == center)
                assert(out_[i].state.tile == roadA && out_[i].state.rotation == 0);
            // The east neighbor must continue the road.
            if (out_[i].coord == center.neighbor(HexDir.E))
                assert(rules.stateEdges[rules.stateId(out_[i].state.tile, out_[i].state.rotation, out_[i].state.level)][HexDir
                        .W].type == EdgeType.road);
        }
    }
    scope CellMaskLookup empty = (const CubeCoord c) @nogc nothrow{ return c == center ? &none : null; };
    auto rng = Random(1);
    auto r = s.solve(cells, null, null, rng, null, empty);
    assert(!r.isOk && r.error == SolveError.NeighborConflict);
}
