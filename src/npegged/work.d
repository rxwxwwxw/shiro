/** Report-only static work bounds (W1). Nothing here generates or changes a parser.

    For a rule `R` whose closed region is positionally LL(1) (`firstCertifiedRules`: no predicates, actions, left recursion
    or unknown nodes; FIRST-disjoint choices; loops whose bodies miss their continuation) the parse never re-reads consumed
    input. Every work unit (docs/WORK_UNITS.md) is then charged by an evaluation of a rule call or a repetition attempt
    node `e` that starts at some input position p, and the evaluations starting at p form chains through the *same-position
    graph*: an edge `f -> e` when `e` can start where `f` starts (a rule call to its body; a sequence to its children up to
    and including the first one that cannot succeed without consuming; a choice to every alternative; a repetition, option
    or wrapper to its body). A chain can begin at any node, so a node is evaluated at most `paths(e)` times per position, with
    `paths(e) = 1 + sum(paths(f) : f -> e)`. With `cost(e)` = 1 for a rule-call or repetition node and 0 otherwise,

        units(n)  <=  (1 + sum(cost(e) * paths(e))) * (n + 1)

    for an input of length n, summing over the closed region of `R` (every node reachable through children and rule
    references can begin a chain). A cycle in the same-position graph is left recursion (possibly through nullable
    prefixes) and gives `unknown`.

    The bound is for the combinator model; a DFA scanner charges `examined - pos + 1`, which can exceed the per-attempt units
    it replaces by the scanner's overscan, so for scanner regions the bound assumes an overscan of at most one byte per token.
    `unknown` is reported with a blocker whenever a premise is missing; it is never read as a bound.
*/
module npegged.work;
import npegged.analysis;
import npegged.ll : firstCertifiedRules;

nothrow:

/// A static bound `units <= perPosition * (n + 1)` for one rule, or the reason there is none.
struct WorkBound {
    bool known;
    size_t perPosition;
    string blocker;
}

private enum size_t saturation = size_t(1) << 40;

/// Compute a bound for every rule of the graph.
WorkBound[] workBounds(ref GrammarAnalysis graph) {
    const rules = graph.roots.length;
    auto result = new WorkBound[rules];
    if (!rules)
        return result;
    const certified = firstCertifiedRules(graph);
    const nodes = graph.expressions.length;

    // Same-position successors of every node.
    auto successors = new size_t[][nodes];
    auto cost = new size_t[nodes];
    auto malformed = new bool[nodes];
    foreach (index, node; graph.expressions) {
        final switch (node.kind) {
        case ExpressionKind.unknown:
        case ExpressionKind.predicate:
            malformed[index] = true;
            break;
        case ExpressionKind.terminal:
            break;
        case ExpressionKind.reference:
            cost[index] = 1;
            const target = graph.referenceRule(node);
            if (target == size_t.max || target >= rules)
                malformed[index] = true;
            else
                successors[index] = [graph.roots[target]];
            break;
        case ExpressionKind.wrapper:
            if (node.combinator == "oneOrMore")
                cost[index] = 1;
            successors[index] = node.children.dup;
            break;
        case ExpressionKind.optional:
        case ExpressionKind.repetition:
            cost[index] = 1;
            successors[index] = node.children.dup;
            break;
        case ExpressionKind.sequence:
            foreach (child; node.children) {
                successors[index] ~= child;
                if (child >= graph.facts.length || graph.facts[child].nullable == Nullable.no)
                    break;
            }
            break;
        case ExpressionKind.choice:
            successors[index] = node.children.dup;
            break;
        }
    }

    foreach (rule; 0 .. rules) {
        if (rule >= certified.length || !certified[rule]) {
            result[rule] = WorkBound(false, 0, "not-certified-ll1");
            continue;
        }
        // The closed region: every node reachable through children and rule references. Any of them can begin a chain.
        auto inRegion = new bool[nodes];
        auto stack = [graph.roots[rule]];
        string blocker;
        while (stack.length && blocker is null) {
            const at = stack[$ - 1];
            stack.length -= 1;
            if (at >= nodes) {
                blocker = "expression-budget";
                break;
            }
            if (inRegion[at])
                continue;
            if (malformed[at]) {
                blocker = "unknown-or-unresolved";
                break;
            }
            inRegion[at] = true;
            auto node = graph.expressions[at];
            if (node.kind == ExpressionKind.reference)
                stack ~= graph.roots[graph.referenceRule(node)];
            else
                stack ~= node.children;
        }
        if (blocker !is null) {
            result[rule] = WorkBound(false, 0, blocker);
            continue;
        }
        // Post-order over the same-position graph from every region node; a back edge is same-position recursion.
        auto color = new ubyte[nodes];
        auto order = new size_t[0];
        bool cyclic;
        void visit(size_t at) {
            if (cyclic || color[at] == 2)
                return;
            if (color[at] == 1) {
                cyclic = true;
                return;
            }
            color[at] = 1;
            foreach (next; successors[at])
                visit(next);
            color[at] = 2;
            order ~= at; // successors first
        }

        foreach (at; 0 .. nodes)
            if (inRegion[at])
                visit(at);
        if (cyclic) {
            result[rule] = WorkBound(false, 0, "same-position-recursion");
            continue;
        }
        auto paths = new size_t[nodes];
        foreach (at; order)
            paths[at] = 1;
        // Reverse post-order puts every node after all of its predecessors.
        size_t total = 1;
        foreach_reverse (at; order) {
            foreach (next; successors[at]) {
                const sum = paths[next] + paths[at];
                paths[next] = sum > saturation ? saturation : sum;
            }
        }
        foreach (at; order) {
            const part = cost[at] * paths[at];
            total = total + part > saturation ? saturation : total + part;
        }
        result[rule] = total >= saturation ? WorkBound(false, 0, "bound-too-large") : WorkBound(true, total, null);
    }
    return result;
}

/// Human-readable form used by the eligibility report.
string describe(const WorkBound bound) {
    if (!bound.known)
        return "unknown: " ~ bound.blocker;
    return decimal(bound.perPosition) ~ "*(n+1)";
}

private string decimal(size_t value) {
    char[20] digits;
    size_t at = digits.length;
    do {
        digits[--at] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value);
    return digits[at .. $].idup;
}

nothrow unittest {
    GrammarAnalysis empty;
    assert(workBounds(empty).length == 0);
    assert(decimal(0) == "0" && decimal(7) == "7" && decimal(1203) == "1203");
    assert(describe(WorkBound(true, 6, null)) == "6*(n+1)");
    assert(describe(WorkBound(false, 0, "x")) == "unknown: x");
}
