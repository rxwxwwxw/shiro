/** Tree text and HTML output, derived from Pegged (Boost 1.0). */
module npegged.formatting;
import npegged.peg : ParseTree;
import npegged.storage : Buffer, Status;

struct Text {
    Buffer!char buffer;
    @disable this(this);
    @disable this(ref Text);
    @property const(char)[] data() const return @nogc nothrow {
        return buffer.data;
    }

    alias data this;
    @property Status status() const @nogc nothrow {
        return buffer.status;
    }
}

void putNumber(ref Buffer!char output, size_t value) @nogc nothrow {
    char[32] storage;
    size_t pos = storage.length;
    do {
        storage[--pos] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value);
    output.put(storage[pos .. $]);
}

@nogc nothrow unittest {
    Buffer!char buffer;
    putNumber(buffer, 0);
    putNumber(buffer, 123);
    assert(buffer.data == "0123");
}

void putQuoted(ref Buffer!char output, scope const(char)[] text) @nogc nothrow {
    output.put('"');
    foreach (c; text) {
        switch (c) {
        case '"':
            output.put("\\\"");
            break;
        case '\\':
            output.put("\\\\");
            break;
        case '\n':
            output.put("\\n");
            break;
        case '\r':
            output.put("\\r");
            break;
        case '\t':
            output.put("\\t");
            break;
        default:
            output.put(c);
            break;
        }
    }
    output.put('"');
}

@nogc nothrow unittest {
    Buffer!char buffer;
    putQuoted(buffer, "\"\\\n\r\tx");
    assert(buffer.data == "\"\\\"\\\\\\n\\r\\tx\"");
}

private void node(ref Buffer!char output, scope const ref ParseTree tree, scope const(char)[] prefix, size_t depth) @nogc nothrow {
    if (depth > 128) {
        output.put("[depth limit]\n");
        return;
    }
    output.put(tree.name);
    output.put('[');
    putNumber(output, tree.begin);
    output.put(", ");
    putNumber(output, tree.end);
    output.put("][");
    foreach (i, match; tree.matches) {
        if (i)
            output.put(", ");
        putQuoted(output, match);
    }
    output.put("]\n");
    foreach (i, ref child; tree.children) {
        output.put(prefix);
        output.put(" +-");
        Buffer!char nested;
        nested.put(prefix);
        nested.put(i + 1 < tree.children.length ? " | " : "   ");
        node(output, child, nested.data, depth + 1);
    }
}

Text formatTree(scope const ref ParseTree tree) @nogc nothrow {
    Text result;
    node(result.buffer, tree, null, 0);
    return result;
}

@nogc nothrow unittest {
    ParseTree tree;
    tree.name = "root";
    tree.successful = true;
    auto text = formatTree(tree);
    assert(text.data == "root[0, 0][]\n");
    ParseTree[1] children;
    children[0].name = "child";
    tree.children = children[];
    auto nested = formatTree(tree);
    assert(nested.data == "root[0, 0][]\n +-child[0, 0][]\n");
}

/// Human-readable diagnostic; the returned text owns its storage.
Text failureMessage(scope const ref ParseTree tree) @nogc nothrow {
    import npegged.peg : position;

    Text result;
    if (tree.successful) {
        result.buffer.put("Success");
        return result;
    }
    const(ParseTree)* failure = &tree;
    size_t depth;
    while (failure.failedChild.length && depth++ < 128)
        failure = &failure.failedChild[0];
    size_t offset = failure.failEnd <= failure.input.length ? failure.failEnd : failure.input.length;
    auto location = position(failure.input[0 .. offset]);
    result.buffer.put("Failure at line ");
    putNumber(result.buffer, location.line);
    result.buffer.put(", col ");
    putNumber(result.buffer, location.col);
    if (offset) {
        result.buffer.put(", after ");
        putQuoted(result.buffer, failure.input[offset > 10 ? offset - 10 : 0 .. offset]);
    }
    result.buffer.put(" expected ");
    putQuoted(result.buffer, failure.matches.length ? failure.matches[$ - 1] : "NO MATCH");
    result.buffer.put(", but got ");
    putQuoted(result.buffer, failure.input[offset .. failure.input.length - offset > 10
        ? offset + 10 : failure.input.length]);
    return result;
}

@nogc nothrow unittest {
    import npegged.peg;

    ParseContext context;
    auto tree = parse!(and!(literal!"a", literal!"b"))(context, "ax");
    auto message = failureMessage(tree.tree);
    assert(message.data == "Failure at line 0, col 1, after \"a\" expected \"b\", but got \"x\"");
    auto success = parse!(literal!"a")(context, "a");
    auto good = failureMessage(success.tree);
    assert(good.data == "Success");
    auto empty = parse!(literal!"a")(context, "");
    auto bad = failureMessage(empty.tree);
    assert(bad.data.length);
}

@nogc nothrow unittest {
    import npegged.peg;

    ParseContext context;
    auto tree = parse!(and!(literal!"abcdefghijkl", literal!"X"))(context, "abcdefghijklmnopqrstuvwx");
    auto message = failureMessage(tree.tree);
    assert(message.data == "Failure at line 0, col 12, after \"cdefghijkl\" expected \"X\", but got \"mnopqrstuv\"");
    ParseTree[1] nodes;
    nodes[0].children = nodes[];
    auto text = formatTree(nodes[0]);
    assert(text.data.length > 0);
}
