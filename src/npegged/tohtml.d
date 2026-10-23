/** HTML tree rendering derived from Pegged (Boost Software License 1.0). */
module npegged.tohtml;
import npegged.peg;
import npegged.formatting : Text, putNumber;
import npegged.storage : Buffer;
import npegged.io : File;

enum Expand {
    no,
    yes,
    ifMatch,
    ifNotMatch
}

private void escaped(ref Buffer!char output, scope string text) @nogc nothrow {
    foreach (c; text) {
        switch (c) {
        case '<':
            output.put("&lt;");
            break;
        case '>':
            output.put("&gt;");
            break;
        case '&':
            output.put("&amp;");
            break;
        case '"':
            output.put("&quot;");
            break;
        default:
            output.put(c);
            break;
        }
    }
}

@nogc nothrow unittest {
    Buffer!char output;
    escaped(output, "<&>\"x");
    assert(output.data == "&lt;&amp;&gt;&quot;x");
}

private bool expanded(string name, Expand mode, scope const(string)[] filters) @nogc nothrow pure {
    if (mode == Expand.no)
        return false;
    if (mode == Expand.yes || !filters.length)
        return true;
    bool matched;
    foreach (filter; filters) {
        if (filter.length > name.length)
            continue;
        foreach (i; 0 .. name.length - filter.length + 1)
            if (name[i .. i + filter.length] == filter) {
                matched = true;
                break;
            }
        if (matched)
            break;
    }
    return mode == Expand.ifMatch ? matched : !matched;
}

@nogc nothrow unittest {
    string[1] filters = ["Root"];
    assert(!expanded("Root", Expand.no, filters[]));
    assert(expanded("Root", Expand.yes, filters[]));
    assert(expanded("Root", Expand.ifMatch, null));
    assert(expanded("Grammar.Root", Expand.ifMatch, filters[]));
    assert(!expanded("Other", Expand.ifMatch, filters[]));
    assert(expanded("Other", Expand.ifNotMatch, filters[]));
    assert(!expanded("Grammar.Root", Expand.ifNotMatch, filters[]));
    string[2] many = ["TooLongToMatch", "Root"];
    assert(expanded("Root", Expand.ifMatch, many[]));
}

private void node(ref Buffer!char output, scope const ref ParseTree tree, Expand expand,
        scope const(string)[] filters, size_t depth) @nogc nothrow {
    if (depth > 128) {
        output.put("<p>depth limit</p>");
        return;
    }
    output.put(expanded(tree.name, expand, filters) ? "<details open><summary>" : "<details><summary>");
    escaped(output, tree.name);
    output.put(" [");
    putNumber(output, tree.begin);
    output.put(", ");
    putNumber(output, tree.end);
    output.put("]</summary><pre>");
    foreach (match; tree.matches) {
        escaped(output, match);
        output.put('\n');
    }
    output.put("</pre>");
    foreach (ref child; tree.children)
        node(output, child, expand, filters, depth + 1);
    output.put("</details>");
}

Text toHTML(scope const ref ParseTree tree, Expand expand = Expand.no, scope const(string)[] filters = null) @nogc nothrow {
    Text result;
    result.buffer.put("<!doctype html><html><head><meta charset=\"utf-8\"><title>Parse tree</title></head><body>");
    node(result.buffer, tree, expand, filters, 0);
    result.buffer.put("</body></html>\n");
    return result;
}

@nogc nothrow unittest {
    ParseTree tree;
    tree.name = "<root>";
    auto output = toHTML(tree);
    assert(output.status == Status.ok);
    assert(output.data[0 .. 15] == "<!doctype html>");
    auto expanded = toHTML(tree, Expand.yes);
    assert(expanded.data.length > output.data.length);
}

Status toHTML(scope const ref ParseTree tree, string filename, Expand expand = Expand.no,
        scope const(string)[] filters = null) @nogc nothrow {
    auto text = toHTML(tree, expand, filters);
    if (text.status != Status.ok)
        return text.status;
    auto file = File.open(filename, true);
    return file.write(text.data);
}

@nogc nothrow unittest {
    ParseTree tree;
    tree.name = "<node>";
    ParseTree[1] children;
    children[0].name = "child";
    tree.children = children[];
    auto text = toHTML(tree);
    assert(text.status == Status.ok);
    assert(toHTML(tree, "/dev/null", Expand.yes) == Status.ok);
    assert(toHTML(tree, "/nonexistent/npegged/output") == Status.ioError);
    children[0].children = children[];
    auto bounded = toHTML(children[0]);
    assert(bounded.data.length > 0);
}

/// Template convenience for the original selective-expansion calling style.
Status toHTML(Expand mode = Expand.no, Details...)(scope const ref ParseTree tree, ref File file) @nogc nothrow {
    static immutable string[] filters = [Details];
    auto text = toHTML(tree, mode, filters);
    if (text.status != Status.ok)
        return text.status;
    return file.write(text.data);
}

@nogc nothrow unittest {
    ParseTree tree;
    tree.name = "Root";
    auto file = File.open("/dev/null", true);
    assert(toHTML!(Expand.ifMatch, "Root")(tree, file) == Status.ok);
    string[1] filters = ["Root"];
    auto text = toHTML(tree, Expand.ifMatch, filters[]);
    assert(text.status == Status.ok);
}
