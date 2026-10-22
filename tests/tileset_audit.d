// Copyright (c) 2026 Felix Turner (MIT License) — original Hex-Map-WFC reference implementation.
// https://github.com/felixturner/hex-map-wfc
// Ported from tools/tileset-audit.js. D port for the Shiro engine.
//
// Headless audit of tileset completeness: for every (edgeType, level) that appears on a tile,
// how many states can sit across from it, which states can never be completed on an infinite
// lattice (dead ends), and the branching factor of each direction.
module tests.tileset_audit;

import core.stdc.stdio : printf;
import wfc.hex;
import wfc.rules;
import wfc.tile_data;
import tests.harness : Report;

struct AuditResult {
    size_t edgeCombos;
    /// (edgeType, level) edges that appear on a state but have no matching state opposite.
    size_t deadEdges;
    /// Combos with 1..3 matching states.
    size_t fragileEdges;
    /// States removed by arc-consistency pruning on an unbounded lattice (unresolvable states).
    size_t unresolvableStates;
    /// Adjacent-edge pairs (NE+E) with no state satisfying both.
    size_t impossiblePairs;
    /// Pairs with one or two satisfying states.
    size_t fragilePairs;
    double meanBranching;
    size_t minBranching;
    size_t maxBranching;
}

private immutable string[numEdgeTypes] edgeNames = ["grass", "water", "road", "river", "coast"];

AuditResult audit(ref const AdjacencyRules rules, bool verbose) @nogc nothrow @trusted {
    AuditResult r;

    // Audit 1: for each edge (type, level, dir) present, how many states match across it.
    foreach (t; 0 .. numEdgeTypes)
        foreach (d; 0 .. numHexDirs) {
            immutable opp = opposite(cast(HexDir)d);
            foreach (l; 0 .. levelsCount) {
                if (!rules.byEdge[t][d][l].any)
                    continue; // never appears on this side
                r.edgeCombos++;
                immutable matches = rules.byEdge[t][opp][l].count;
                if (matches == 0) {
                    r.deadEdges++;
                    if (verbose)
                        printf("[DEAD] %s@%d on %d has no match across\n", edgeNames[t].ptr, cast(int)l, cast(int)d);
                } else if (matches <= 3) {
                    r.fragileEdges++;
                    if (verbose)
                        printf("[FRAGILE] %s@%d dir %d: %d matching states\n", edgeNames[t].ptr,
                                cast(int)l, cast(int)d, cast(int)matches);
                }
            }
        }

    // Audit 2: arc-consistency on an infinite lattice. A state survives only if every one of its
    // six edges still has a surviving partner across it.
    StateSet alive;
    alive.setFirst(numStates);
    bool changed = true;
    while (changed) {
        changed = false;
        foreach (s; 0 .. numStates) {
            if (!alive.test(s))
                continue;
            foreach (d; 0 .. numHexDirs) {
                immutable e = rules.stateEdges[s][d];
                if (!rules.byEdge[e.type][opposite(cast(HexDir)d)][e.level].intersects(alive)) {
                    alive.clear(s);
                    r.unresolvableStates++;
                    changed = true;
                    break;
                }
            }
        }
    }
    if (verbose && r.unresolvableStates)
        printf("[UNRESOLVABLE] %d states cannot be completed\n", cast(int)r.unresolvableStates);

    // Audit 3: adjacent-edge pairs on NE+E (representative by rotation).
    foreach (t1; 0 .. numEdgeTypes)
        foreach (l1; 0 .. levelsCount)
            foreach (t2; 0 .. numEdgeTypes)
                foreach (l2; 0 .. levelsCount) {
                    if (!rules.byEdge[t1][HexDir.NE][l1].any || !rules.byEdge[t2][HexDir.E][l2].any)
                        continue;
                    StateSet both = rules.byEdge[t1][HexDir.NE][l1];
                    both.intersect(rules.byEdge[t2][HexDir.E][l2]);
                    immutable n = both.count;
                    if (n == 0)
                        r.impossiblePairs++;
                    else if (n <= 2)
                        r.fragilePairs++;
                }

    // Branching factor: compatible neighbor states per (state, direction).
    size_t sum = 0, cnt = 0;
    r.minBranching = size_t.max;
    foreach (s; 0 .. numStates)
        foreach (d; 0 .. numHexDirs) {
            immutable e = rules.stateEdges[s][d];
            immutable b = rules.byEdge[e.type][opposite(cast(HexDir)d)][e.level].count;
            sum += b;
            cnt++;
            if (b < r.minBranching)
                r.minBranching = b;
            if (b > r.maxBranching)
                r.maxBranching = b;
        }
    r.meanBranching = cast(double)sum / cnt;

    if (verbose) {
        printf("states %d, edge combos %d, dead %d, fragile %d, unresolvable %d\n",
                cast(int)numStates, cast(int)r.edgeCombos, cast(int)r.deadEdges,
                cast(int)r.fragileEdges, cast(int)r.unresolvableStates);
        printf("impossible NE+E pairs %d, fragile pairs %d\n", cast(int)r.impossiblePairs, cast(int)r.fragilePairs);
        printf("branching min %d mean %.1f max %d\n", cast(int)r.minBranching, r.meanBranching,
                cast(int)r.maxBranching);
    }
    return r;
}

/// Integration test: the shipped tileset has no dead ends.
void run(ref const AdjacencyRules rules, ref Report rep, bool verbose) @nogc nothrow {
    immutable r = audit(rules, verbose);
    rep.check(r.edgeCombos > 0, "audit found edge combos");
    rep.check(r.deadEdges == 0, "no edge without a matching partner (dead end)");
    rep.check(r.unresolvableStates == 0, "no state is unresolvable on an infinite lattice");
    rep.check(r.minBranching >= 1, "every state side has at least one compatible neighbor");
}

version (TilesetAuditCli) {
    __gshared AdjacencyRules cliRules;

    int main() {
        AdjacencyRules.build(cliRules);
        Report rep;
        run(cliRules, rep, true);
        return rep.failed == 0 ? 0 : 1;
    }
}
