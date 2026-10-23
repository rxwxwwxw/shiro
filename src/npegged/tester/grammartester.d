/** Grammar tree-pattern testing, derived from Pegged (Boost 1.0). */
module npegged.tester.grammartester;
import npegged.grammar;
import npegged.storage : Buffer;
import npegged.tester.testerparser;

private string shortName(string name) @nogc nothrow pure {
    foreach_reverse (i, c; name)
        if (c == '.')
            return name[i + 1 .. $];
    return name;
}

@nogc nothrow unittest {
    assert(shortName("A.B") == "B");
    assert(shortName("B") == "B");
}

private bool compare(scope const ref ParseTree tree, scope const ref ParseTree pattern, ref Arena arena) @nogc nothrow {
    if (pattern.name != "TesterGrammar.Node" || !pattern.matches.length || shortName(tree.name) != pattern.matches[0])
        return false;
    auto visited = arena.allocate!bool(tree.children.length);
    if (arena.status != Status.ok)
        return false;
    size_t cursor;
    string branchType;
    foreach (ref branch; pattern.children) {
        if (branchType.length && branchType != branch.name)
            return false;
        branchType = branch.name;
        if (branch.name == "TesterGrammar.ConciseBranch")
            return true;
        foreach (ref expected; branch.children) {
            size_t found = size_t.max;
            if (branch.name == "TesterGrammar.OrderedBranch") {
                if (cursor < tree.children.length)
                    found = cursor++;
            } else {
                foreach (i, ref child; tree.children) {
                    if (!visited[i] && expected.matches.length && shortName(child.name) == expected.matches[0]) {
                        found = i;
                        break;
                    }
                }
            }
            if (found == size_t.max || !compare(tree.children[found], expected, arena))
                return false;
            visited[found] = true;
        }
    }
    foreach (flag; visited)
        if (!flag)
            return false;
    return true;
}

@nogc nothrow unittest {
    Arena arena;
    ParseTree actual, pattern;
    assert(!compare(actual, pattern, arena));
    pattern.name = "TesterGrammar.Node";
    assert(!compare(actual, pattern, arena));
    string[1] names = ["A"];
    pattern.matches = names[];
    actual.name = "B";
    assert(!compare(actual, pattern, arena));
    actual.name = "A";
    ParseTree[1] children;
    actual.children = children[];
    arena.limit = 0;
    assert(!compare(actual, pattern, arena));
}

/// Move-only tester. Diagnostic text is borrowed until reset or the next assertion.
struct GrammarTester(alias grammar, string startSymbol) {
    bool soft;
    private size_t count, errors;
    private Buffer!char diagnostics;
    @disable this(this);
    @disable this(ref GrammarTester);
    @property size_t testCount() const @nogc nothrow {
        return count;
    }

    @property size_t errorCount() const @nogc nothrow {
        return errors;
    }

    @property const(char)[] errorText() const return @nogc nothrow {
        return diagnostics.data;
    }

    @property const(char)[] latestDiffText() const return @nogc nothrow {
        return diagnostics.data;
    }

    void reset() @nogc nothrow {
        count = 0;
        errors = 0;
        diagnostics.clear();
    }

    private bool run(string input, string expected, bool invert) @nogc nothrow {
        ParseContext context;
        auto actual = mixin("grammar." ~ startSymbol ~ "(context, input)");
        auto pattern = TesterGrammar(context, expected);
        Arena scratch;
        const(ParseTree)* actualNode = &actual.tree;
        if (actual.children.length == 1 && actual.children[0].name == actual.name)
            actualNode = &actual.children[0];
        if (pattern.successful)
            assert(pattern.children.length == 1 && pattern.children[0].children.length == 1);
        bool matches = actual.successful && pattern.successful && compare(*actualNode,
                pattern.children[0].children[0], scratch);
        bool pass = invert ? !matches && actual.successful && pattern.successful : matches;
        ++count;
        diagnostics.clear();
        if (!pass) {
            ++errors;
            diagnostics.put("Tree pattern comparison failed\n");
            auto text = actual.toString;
            diagnostics.put(text.data);
            diagnostics.put("Expected:\n");
            diagnostics.put(expected);
            if (!soft)
                assert(pass);
        }
        return pass;
    }

    bool assertSimilar(string file = __FILE__, size_t line = __LINE__)(string input, string expected) @nogc nothrow {
        return run(input, expected, false);
    }

    bool assertDifferent(string file = __FILE__, size_t line = __LINE__)(string input, string expected) @nogc nothrow {
        return run(input, expected, true);
    }
}

version (unittest) mixin(grammar("TesterExample: Root <- Child eoi Child <- 'a'"));
@nogc nothrow unittest {
    GrammarTester!(TesterExample, "Root") tester;
    assert(tester.assertSimilar("a", "Root->Child"));
    assert(tester.assertDifferent("a", "Wrong"));
    tester.soft = true;
    assert(!tester.assertSimilar("a", "Wrong"));
    assert(tester.errorCount == 1 && tester.testCount == 3 && tester.errorText.length);
    tester.reset();
    assert(tester.testCount == 0 && tester.errorText.length == 0);
}

version (unittest) mixin(grammar("Branches: Root <- A B eoi A <- 'a' B <- 'b'"));
@nogc nothrow unittest {
    GrammarTester!(Branches, "Root") tester;
    tester.soft = true;
    assert(tester.assertSimilar("ab", "Root->{A B}"));
    assert(tester.assertSimilar("ab", "Root~>{B A}"));
    assert(tester.assertSimilar("ab", "Root->{..}"));
    assert(!tester.assertSimilar("ab", "Root~>{B A C}"));
    assert(!tester.assertSimilar("ab", "Root->{B A}"));
    assert(!tester.assertSimilar("ab", "Root->{A B C}"));
    assert(!tester.assertSimilar("ab", "Root->{A}"));
    assert(!tester.assertSimilar("ab", "Root->A ~>B"));
    assert(!tester.assertSimilar("ab", "Root->{"));
    assert(!tester.assertSimilar("x", "Root"));
    assert(!tester.assertDifferent("ab", "Root->{..}"));
    assert(tester.latestDiffText.length);
}

version (unittest) private ParseTree hideMatches(ParseTree tree) @nogc nothrow {
    tree.matches = null;
    return tree;
}

version (unittest) mixin(grammar("EmptyRoot: Root <- '' eoi"));
version (unittest) mixin(grammar("EmptyParent: Root <- (Child Child){hideMatches} Child <- 'a'"));
@nogc nothrow unittest {
    GrammarTester!(Branches, "Root") tester;
    tester.soft = true;
    assert(tester.assertSimilar("ab", "Root~>{A B}"));
    assert(tester.assertSimilar("ab", "Root->{A} ->{B}"));
    assert(!tester.assertSimilar("ab", "Root->{A} ~>{B}"));
    assert(!tester.assertDifferent("x", "Root"));
    assert(!tester.assertDifferent("ab", "Root->{"));
    GrammarTester!(EmptyRoot, "Root") empty;
    assert(empty.assertSimilar("", "Root"));
    GrammarTester!(EmptyParent, "Root") parent;
    assert(parent.assertSimilar("aa", "Root->{Child Child}"));
}
