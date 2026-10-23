// Compiles `.story` files into a StoryProgram. Cold path: runs once at load, allocates only from
// malloc pools, and reports every problem it finds (file:line:col) instead of stopping at the
// first. The controller supplies a loader for imports, so this module never opens files itself.
//
// Passes: (1) read the entry file and its imports depth-first, splitting lines and recording
// indentation; (2) declarations - types, characters, places, labels, variables (emitting the
// initializer code that sets starting values); (3) scene code for labels and triggers; (4) label
// fixups and warnings (unused labels, variables read but never set).
//
// Model layer: no SDL, @nogc nothrow.
module story.compile;

import core.file : FileBytes;
import core.stdc.stdio : snprintf;
import core.stdc.stdlib : strtod;
import story.pool;
import story.program;
import story.state;
import story.syntax;
import story.value;

/// Reads `path` (NUL-terminated just past its length) into `scratch` and returns its text, or
/// null when it cannot. The text must stay valid until compiling ends (tests may return literals).
alias SourceLoader = const(char)[]delegate(const(char)[] path, ref FileBytes scratch) @nogc nothrow;

/// Most source files one story may import.
enum int maxStoryFiles = 64;

/// Compiles `entry` (and everything it imports) into `p`, interning every variable into `st`.
/// Variables already in `st` count as set by the game. Returns the first error class; the full
/// list (with warnings) is in `p.diagnostics`.
StoryError compileStory(ref StoryProgram p, ref StoryState st, const(char)[] entry, scope SourceLoader load) @nogc nothrow @trusted {
    p.clear();
    Compiler c;
    c.p = &p;
    c.st = &st;
    c.load = load;
    c.external = st.length;
    return c.run(entry);
}

/// Compiles one in-memory story (no imports); for tests and tools.
StoryError compileText(ref StoryProgram p, ref StoryState st, const(char)[] text) @nogc nothrow @trusted {
    const(char)[] loader(const(char)[] path, ref FileBytes) @nogc nothrow {
        return path == "inline.story" ? text : null;
    }

    return compileStory(p, st, "inline.story", &loader);
}

private:

enum SlotUse : ubyte {
    read = 1,
    written = 2
}

struct SrcLine {
    ushort file;
    /// 1-based line number in its file.
    uint lineNo;
    uint indent;
    /// Indentation used for block structure (sub-label markers take the next line's).
    uint eff;
    const(char)[] text;
}

struct TypeInfo {
    const(char)[] name;
    int line;
}

struct DerivedInfo {
    const(char)[] path, scope_;
    int line;
}

struct ConstInfo {
    const(char)[] path;
    Value value;
}

struct Fixup {
    /// Code index, or -1 - trigger index for a trigger entry.
    int at;
    /// Which field of the instruction: 0 = a, 1 = b, 2 = c.
    ubyte field;
    const(char)[] label;
    int line;
}

/// A label's name and the line declaring it (for "unused" warnings).
struct LabelInfo {
    const(char)[] name;
    int line;
    bool used;
}

struct Builtins {
    const(char)[] name;
    Builtin id;
    ubyte minArgs, maxArgs;
}

immutable Builtins[] builtinTable = [
    Builtins("min", Builtin.min, 1, 16), Builtins("max", Builtin.max, 1, 16),
    Builtins("abs", Builtin.abs, 1, 1), Builtins("floor", Builtin.floor, 1, 1),
    Builtins("ceil", Builtin.ceil, 1, 1), Builtins("round", Builtin.round, 1, 1),
    Builtins("clamp", Builtin.clamp, 3, 3), Builtins("rand", Builtin.rand, 0, 2),
    Builtins("len", Builtin.len, 1, 1), Builtins("str", Builtin.str, 1, 1),
    Builtins("append", Builtin.append, 2, 2), Builtins("remove", Builtin.remove, 2, 2),
    Builtins("keys", Builtin.keys, 1, 1), Builtins("has", Builtin.has, 2, 2),
    Builtins("range", Builtin.range, 1, 2),
];

/// Statement kinds that own an indented body.
bool hasBody(const(char)[] rule) @nogc nothrow pure @safe {
    foreach (r; [
            "TypeDecl", "CharDecl", "PlaceDecl", "LabelDecl", "Option", "If", "Elif", "Else", "For"
        ])
        if (r == rule)
            return true;
    return false;
}

/// Source text of a node.
const(char)[] src(ref const ParseTree t) @nogc nothrow pure @safe {
    return t.input[t.begin .. t.end];
}

/// Inside of a String node (without the quotes).
const(char)[] strBody(ref const ParseTree t) @nogc nothrow pure @safe {
    return t.input[t.begin + 1 .. t.end - 1];
}

/// First child named `rule`, or null.
const(ParseTree)* child(return ref const ParseTree t, const(char)[] rule) @nogc nothrow @trusted {
    foreach (ref c; t.children)
        if (ruleName(c) == rule)
            return &c;
    return null;
}

struct Compiler {
@nogc nothrow @trusted:
    StoryProgram* p;
    StoryState* st;
    SourceLoader load;
    /// Slots below this were interned by the game before compiling (written by game code).
    int external;

    FileBytes[maxStoryFiles] files;
    const(char)[][maxStoryFiles] fileNames;
    int fileCount;
    Pool!SrcLine lines;
    Pool!TypeInfo types;
    Pool!DerivedInfo derived;
    Pool!ConstInfo consts;
    Pool!(const(char)[]) records;
    Pool!LabelInfo labels;
    Pool!Fixup fixups;
    Pool!ubyte slotUse;
    TextArena scratch;
    int errors, syntaxErrors;
    bool oom;

    // Expression emission state.
    int depth, maxDepth;
    int derivedDepth;
    const(char)[] scope_;

    // Scene emission state.
    const(char)[] curLabel, curLineId;
    uint forCount;

    StoryError run(const(char)[] entry) {
        if (!loadFile(entry, -1))
            return StoryError.notFound;
        computeEffectiveIndent();
        declare();
        emitScenes();
        resolveFixups();
        warnings();
        if (oom)
            return StoryError.outOfMemory;
        if (syntaxErrors)
            return StoryError.syntax;
        return errors ? StoryError.semantic : StoryError.none;
    }

    // ---- diagnostics ---------------------------------------------------------------------------

    void report(Severity sev, int line, uint col, const(char)[] msg) {
        Diagnostic d;
        d.severity = sev;
        if (line >= 0) {
            const l = lines[line];
            d.file = fileNames[l.file];
            d.line = l.lineNo;
            d.col = col ? col : l.indent + 1;
        }
        d.message = p.text_.copy(msg);
        if (!p.diags_.push(d))
            oom = true;
        if (sev == Severity.error)
            errors++;
    }

    /// printf-style error on `line`.
    void error(Args...)(int line, uint col, const(char)* fmt, Args args) {
        char[320] b;
        immutable n = snprintf(b.ptr, b.length, fmt, args);
        report(Severity.error, line, col, b[0 .. n < 0 ? 0 : (n < b.length ? n : b.length - 1)]);
    }

    void warn(Args...)(int line, const(char)* fmt, Args args) {
        char[320] b;
        immutable n = snprintf(b.ptr, b.length, fmt, args);
        report(Severity.warning, line, 0, b[0 .. n < 0 ? 0 : (n < b.length ? n : b.length - 1)]);
    }

    uint colOf(int line, ref const ParseTree t) {
        return lines[line].indent + cast(uint)t.begin + 1;
    }

    const(char)[] keep(const(char)[] s) {
        if (s.length == 0)
            return "";
        auto c = p.text_.copy(s);
        if (c is null)
            oom = true;
        return c;
    }

    /// `a.b` joined into the scratch arena.
    const(char)[] join(const(char)[] a, const(char)[] b) {
        if (a.length == 0)
            return b;
        auto d = scratch.alloc(a.length + 1 + b.length);
        if (d is null) {
            oom = true;
            return null;
        }
        d[0 .. a.length] = a[];
        d[a.length] = '.';
        d[a.length + 1 .. $] = b[];
        return d;
    }

    /// Parses line `i`; on failure reports a syntax error and returns false.
    bool parseOk(int i, ref ParseResult r) {
        if (r.successful)
            return true;
        auto m = r.tree.failMsg;
        const(char)[] msg = m.data;
        // npegged says "Failure at line 0, col N, after "..." expected X, but got Y".
        foreach (k; 0 .. msg.length)
            if (k + 9 < msg.length && msg[k .. k + 9] == " expected") {
                msg = msg[k + 1 .. $];
                break;
            }
        error(i, lines[i].indent + cast(uint)r.failEnd + 1, "syntax error: %.*s", cast(int)msg.length, msg.ptr);
        syntaxErrors++;
        return false;
    }

    // ---- pass 1: files and lines ---------------------------------------------------------------

    bool loadFile(const(char)[] path, int fromLine) {
        foreach (n; fileNames[0 .. fileCount])
            if (n == path)
                return true;
        if (fileCount == maxStoryFiles) {
            error(fromLine, 0, "more than %d story files", maxStoryFiles);
            return false;
        }
        char[512] z;
        if (path.length + 1 > z.length) {
            error(fromLine, 0, "import path too long");
            return false;
        }
        z[0 .. path.length] = path[];
        z[path.length] = 0;
        immutable f = fileCount++;
        fileNames[f] = keep(path);
        const text = load(z[0 .. path.length], files[f]);
        if (text is null) {
            if (fromLine >= 0)
                error(fromLine, 0, "cannot read \"%.*s\"", cast(int)path.length, path.ptr);
            else
                report(Severity.error, -1, 0, "cannot read the story entry file");
            return false;
        }
        bool ok = true;
        uint lineNo = 0;
        size_t i = 0;
        while (i < text.length) {
            size_t e = i;
            while (e < text.length && text[e] != '\n')
                e++;
            lineNo++;
            auto raw = text[i .. e];
            i = e + 1;
            if (raw.length && raw[$ - 1] == '\r')
                raw = raw[0 .. $ - 1];
            uint indent = 0;
            size_t k = 0;
            while (k < raw.length && (raw[k] == ' ' || raw[k] == '\t')) {
                indent += raw[k] == '\t' ? 4 : 1;
                k++;
            }
            auto content = raw[k .. $];
            while (content.length && (content[$ - 1] == ' ' || content[$ - 1] == '\t'))
                content = content[0 .. $ - 1];
            if (content.length == 0 || content[0] == '#')
                continue;
            if (!lines.push(SrcLine(cast(ushort)f, lineNo, indent, indent, content))) {
                oom = true;
                return false;
            }
            if (indent == 0 && content.length > 7 && content[0 .. 7] == "import ") {
                // The import line stays (later passes skip it) so errors can point at it.
                immutable li = cast(int)lines.length - 1;
                ParseContext ctx;
                auto r = parseLine(ctx, content);
                if (!parseOk(li, r) || ruleName(statementOf(r.tree)) != "Import")
                    continue;
                char[512] buf;
                const rel = strBody(statementOf(r.tree).children[0]);
                size_t dir = path.length;
                while (dir > 0 && path[dir - 1] != '/' && path[dir - 1] != '\\')
                    dir--;
                if (dir + rel.length > buf.length) {
                    error(li, 0, "import path too long");
                    continue;
                }
                buf[0 .. dir] = path[0 .. dir];
                buf[dir .. dir + rel.length] = rel[];
                ok &= loadFile(keep(buf[0 .. dir + rel.length]), li);
            }
        }
        return ok;
    }

    /// Sub-label markers (`.ask:`) may sit at any indentation; they take the next line's.
    void computeEffectiveIndent() {
        uint next = 0;
        foreach_reverse (ref l; lines.slice) {
            if (l.text[0] == '.' && l.text.length > 1 && l.text[$ - 1] == ':')
                l.eff = next;
            next = l.eff;
        }
    }

    /// End (exclusive) of the block whose header is line `i`.
    int blockEnd(int i) {
        immutable base = lines[i].eff;
        int e = i + 1;
        while (e < lines.length && lines[e].eff > base)
            e++;
        return e;
    }

    /// Calls `fn(line, end)` for every direct child of the block `[first, end)`; deeper lines with
    /// no header above them are errors.
    void eachChild(int first, int end, scope void delegate(int, int) @nogc nothrow fn) {
        if (first >= end)
            return;
        immutable ind = lines[first].eff;
        int k = first;
        while (k < end) {
            if (lines[k].eff != ind) {
                error(k, 0, "unexpected indentation");
                k++;
                continue;
            }
            immutable e = blockEnd(k);
            fn(k, e);
            k = e;
        }
    }

    // ---- pass 2: declarations --------------------------------------------------------------------

    void declare() {
        // Types and labels first, so anything may refer to them regardless of file order.
        eachChild(0, cast(int)lines.length, (int i, int end) {
            ParseContext ctx;
            auto r = parseLine(ctx, lines[i].text);
            if (!r.successful)
                return;
            const s = &statementOf(r.tree);
            const kind = ruleName(*s);
            if (kind == "TypeDecl") {
                const n = src(s.children[0]);
                foreach (ref t; types.slice)
                    if (t.name == n)
                        return error(i, 0, "type %.*s declared twice", cast(int)n.length, n.ptr);
                types.push(TypeInfo(keep(n), i));
            } else if (kind == "LabelDecl") {
                const n = keep(src(s.children[0]));
                addLabel(n, i);
                foreach (k; i + 1 .. end)
                    if (lines[k].text[0] == '.') {
                        ParseContext c2;
                        auto r2 = parseLine(c2, lines[k].text);
                        if (r2.successful && ruleName(statementOf(r2.tree)) == "SubLabel")
                            addLabel(keep(join(n, src(statementOf(r2.tree).children[0]))), k);
                    }
            } else if (kind == "CharDecl") {
                Speaker sp;
                sp.id = keep(src(s.children[0]));
                if (p.findSpeaker(sp.id) >= 0)
                    return error(i, 0, "character %.*s declared twice", cast(int)sp.id.length, sp.id.ptr);
                const nm = child(*s, "String");
                sp.name = nm ? unescape(strBody(*nm)) : sp.id;
                sp.portrait = sp.figure = sp.id;
                p.speakers_.push(sp);
            }
        });
        // Everything that creates variables, in file order (the initializer runs in this order).
        p.init_ = cast(int)p.code_.length;
        eachChild(0, cast(int)lines.length, (int i, int end) {
            ParseContext ctx;
            auto r = parseLine(ctx, lines[i].text);
            if (!parseOk(i, r))
                return;
            const s = &statementOf(r.tree);
            const kind = ruleName(*s);
            if (kind == "CharDecl")
                character(i, end, *s);
            else if (kind == "PlaceDecl")
                place(i, end, *s);
            else if (kind == "VarDecl")
                varDecl(i, *s);
            else if (kind == "TypeDecl" || kind == "LabelDecl" || kind == "Import")
                return;
            else if (kind == "On") {
                if (child(*s, "OnBlock") is null && end > i + 1)
                    error(i + 1, 0, "unexpected indented block");
                return;
            } else
                error(i, 0, "%.*s is not allowed at the top level", cast(int)kind.length, kind.ptr);
            if (!hasBody(kind) && end > i + 1)
                error(i + 1, 0, "unexpected indented block");
        });
        emit(Ins(Op.ret));
    }

    void addLabel(const(char)[] name, int line) {
        foreach (ref l; labels.slice)
            if (l.name == name)
                return error(line, 0, "label %.*s declared twice", cast(int)name.length, name.ptr);
        labels.push(LabelInfo(name, line));
        p.labelNames_.push(name);
        p.labelPcs_.push(-1);
    }

    int typeLine(const(char)[] name) {
        foreach (ref t; types.slice)
            if (t.name == name)
                return t.line;
        return -1;
    }

    void character(int i, int end, ref const ParseTree s) {
        immutable spk = p.findSpeaker(src(s.children[0]));
        if (spk < 0)
            return;
        // The display name is a read-only field: {elder.name}.
        const id = p.speakers_[spk].id;
        consts.push(ConstInfo(keep(join(id, "name")), Value.constText(p.speakers_[spk].name)));
        records.push(id);
        eachChild(i + 1, end, (int k, int e) {
            ParseContext ctx;
            auto r = parseLine(ctx, lines[k].text);
            if (!parseOk(k, r))
                return;
            const f = &statementOf(r.tree);
            if (ruleName(*f) != "Prop")
                return field(id, k, e, *f, 0);
            const key = src(f.children[0]);
            auto sp = &p.speakers_[spk];
            const(ParseTree)[] args = f.children[1 .. $];
            const(char)[] word(size_t n) {
                return n < args.length ? (ruleName(args[n].children[0]) == "String"
                    ? unescape(strBody(args[n].children[0])) : keep(src(args[n]))) : null;
            }

            int number(size_t n) {
                return n < args.length && ruleName(args[n].children[0]) == "SignedNumber"
                    ? toInt(parseNumber(src(args[n]))) : int.min;
            }

            if (key == "portrait" && args.length == 1)
                sp.portrait = word(0);
            else if (key == "figure" && args.length == 1)
                sp.figure = word(0);
            else if (key == "sprite" && args.length == 1 && number(0) != int.min)
                sp.sprite = number(0);
            else if (key == "home" && (args.length == 1 || (args.length == 3
                && src(args[1]) == "wander" && number(2) != int.min)))
                p.npcs_.push(NpcSpot(spk, word(0), args.length == 3 ? number(2) : 1));
            else
                error(k, 0, "bad character property: %.*s", cast(int)lines[k].text.length, lines[k].text.ptr);
        });
    }

    /// One field line of a character, type or record var under `prefix`.
    void field(const(char)[] prefix, int k, int e, ref const ParseTree f, int nesting) {
        if (e > k + 1)
            error(k + 1, 0, "unexpected indented block");
        const kind = ruleName(f);
        if (kind == "Assign") {
            const lv = f.children[0];
            const path = lv.children[0];
            if (lv.children.length != 1 || path.children.length != 1 || src(f.children[1]) != "=")
                return error(k, 0, "a field is declared as `name = value`");
            immutable slot = intern(join(prefix, src(path)), k);
            if (slot < 0)
                return;
            markUse(slot, SlotUse.written);
            if (const b = child(f, "Bounds"))
                bounds(slot, k, *b);
            initAssign(slot, k, f.children[2], prefix);
        } else if (kind == "Derived") {
            const full = keep(join(prefix, src(f.children[0])));
            derived.push(DerivedInfo(full, keep(prefix), k));
        } else if (kind == "Say" && child(f, "Mood") is null) {
            // `bond: Bond` - a nested record of a declared type.
            const tname = src(f.children[$ - 1]);
            immutable tl = typeLine(tname);
            if (tl < 0)
                return error(k, 0, "unknown type %.*s", cast(int)tname.length, tname.ptr);
            instantiate(keep(join(prefix, src(f.children[0]))), tl, k, nesting + 1);
        } else
            error(k, 0, "expected a field (`name = value`, `name => expr` or `name: Type`)");
    }

    /// Creates the slots of a record of the type declared on `typeLine` under `prefix`.
    void instantiate(const(char)[] prefix, int typeLine, int at, int nesting) {
        if (nesting > 8)
            return error(at, 0, "record types nest too deeply (recursive type?)");
        records.push(prefix);
        eachChild(typeLine + 1, blockEnd(typeLine), (int k, int e) {
            ParseContext ctx;
            auto r = parseLine(ctx, lines[k].text);
            if (parseOk(k, r))
                field(prefix, k, e, statementOf(r.tree), nesting);
        });
    }

    void bounds(int slot, int k, ref const ParseTree b) {
        immutable lo = parseNumber(src(b.children[0])), hi = parseNumber(src(b.children[1]));
        if (!(lo <= hi))
            return error(k, 0, "empty range %g..%g", lo, hi);
        st.setBounds(slot, lo, hi);
    }

    void initAssign(int slot, int k, ref const ParseTree exprNode, const(char)[] scopePrefix) {
        auto saved = scope_;
        scope_ = scopePrefix;
        immutable x = expression(exprNode, k);
        scope_ = saved;
        emit(Ins(Op.assign, AssignOp.set, slot, x));
    }

    void varDecl(int i, ref const ParseTree s) {
        const name = src(s.children[0]);
        if (const vt = child(s, "VarType")) {
            if (child(s, "Bounds"))
                error(i, 0, "a record var takes no range");
            const tname = src(vt.children[0]);
            immutable tl = typeLine(tname);
            if (tl < 0)
                return error(i, 0, "unknown type %.*s", cast(int)tname.length, tname.ptr);
            return instantiate(keep(name), tl, i, 0);
        }
        immutable slot = intern(name, i);
        if (slot < 0)
            return;
        markUse(slot, SlotUse.written);
        if (const b = child(s, "Bounds"))
            bounds(slot, i, *b);
        initAssign(slot, i, child(s, "VarInit").children[0], null);
    }

    void place(int i, int end, ref const ParseTree s) {
        Place pl;
        pl.id = keep(src(s.children[0]));
        foreach (ref o; p.places_.slice)
            if (o.id == pl.id)
                return error(i, 0, "place %.*s declared twice", cast(int)pl.id.length, pl.id.ptr);
        const t = child(s, "String");
        pl.title = t ? unescape(strBody(*t)) : pl.id;
        pl.wareStart = p.wares_.length;
        pl.topicStart = p.topics_.length;
        eachChild(i + 1, end, (int k, int e) {
            if (e > k + 1)
                error(k + 1, 0, "unexpected indented block");
            ParseContext ctx;
            auto r = parseLine(ctx, lines[k].text);
            if (!parseOk(k, r))
                return;
            const f = &statementOf(r.tree);
            const kind = ruleName(*f);
            if (kind == "Prop" && f.children.length == 2 && src(f.children[0]) == "image")
                pl.image = keep(src(f.children[1]));
            else if (kind == "Prop" && f.children.length == 2 && src(f.children[0]) == "host") {
                const h = src(f.children[1]);
                pl.host = p.findSpeaker(h);
                if (pl.host < 0)
                    error(k, 0, "unknown character %.*s", cast(int)h.length, h.ptr);
            } else if (kind == "Say" && src(f.children[0]) == "look" && child(*f, "Mood") is null)
                pl.look = keep(src(f.children[$ - 1]));
            else if (kind == "Ware") {
                PlaceWare w;
                w.name = unescape(strBody(f.children[0]));
                w.price = toInt(parseNumber(src(f.children[1])));
                w.flag = intern(src(f.children[2]), k);
                if (w.flag >= 0)
                    markUse(w.flag, SlotUse.written);
                w.desc = keep(src(f.children[3]));
                p.wares_.push(w);
            } else if (kind == "Topic")
                p.topics_.push(PlaceTopic(unescape(strBody(f.children[0])), keep(src(f.children[1]))));
            else
                error(k, 0, "expected image, host, look, ware or topic");
        });
        pl.wareLen = p.wares_.length - pl.wareStart;
        pl.topicLen = p.topics_.length - pl.topicStart;
        p.places_.push(pl);
    }

    // ---- variables -------------------------------------------------------------------------------

    int intern(const(char)[] name, int line) {
        immutable id = st.intern(name);
        if (id < 0)
            error(line, 0, "bad variable name %.*s", cast(int)name.length, name.ptr);
        return id;
    }

    void markUse(int slot, int u) {
        while (slotUse.length <= slot)
            if (!slotUse.push(0)) {
                oom = true;
                return;
            }
        slotUse[slot] |= u;
    }

    bool isRecord(const(char)[] path) {
        foreach (r; records.slice)
            if (r == path)
                return true;
        return false;
    }

    // ---- expressions -----------------------------------------------------------------------------

    int emitX(XOp op, int arg = 0, int argc = 0) {
        if (!p.xcode_.push(XIns(op, cast(ubyte)argc, arg)))
            oom = true;
        return cast(int)p.xcode_.length - 1;
    }

    void push(int n) {
        depth += n;
        if (depth > maxDepth)
            maxDepth = depth;
    }

    int constant(Value v) {
        if (!p.consts_.push(v))
            oom = true;
        return cast(int)p.consts_.length - 1;
    }

    /// Compiles the expression rooted at `t` as a stand-alone entry point.
    int expression(ref const ParseTree t, int line) {
        return entryOf(line, () { emitExpr(t, line); });
    }

    /// An expression entry point whose code `body` emits (leaving one value).
    int entryOf(int line, scope void delegate() @nogc nothrow 
            body) {
        immutable entry = cast(int)p.xcode_.length;
        depth = maxDepth = 0;
        body();
        emitX(XOp.ret);
        if (maxDepth > maxExprStack)
            error(line, 0, "expression too deeply nested");
        return entry;
    }

    /// Emits `[...]` / `.name` accessors: each indexes the value below it.
    void emitAccessors(const(ParseTree)[] accs, int line) {
        foreach (ref a; accs) {
            if (ruleName(a) == "Index")
                emitExpr(a.children[0], line);
            else {
                // `.name` (Member) or a further Path segment (Name).
                const name = ruleName(a) == "Name" ? src(a) : src(a.children[0]);
                emitX(XOp.konst, constant(Value.constText(keep(name))));
                push(1);
            }
            emitX(XOp.index);
            push(-1);
        }
    }

    /// Reads the first `segs` names of Path `t` dynamically: the root variable, then each further
    /// name as a map key (`citizen.health.food`).
    void emitDynamicPath(ref const ParseTree t, size_t segs, int line) {
        const root = src(t.children[0]);
        if (!resolveRead(root, line, t)) {
            immutable slot = intern(root, line);
            if (slot >= 0)
                markUse(slot, SlotUse.read);
            emitX(XOp.load, slot);
            push(1);
        }
        emitAccessors(t.children[1 .. segs], line);
    }

    void emitExpr(ref const ParseTree t, int line) {
        const r = ruleName(t);
        switch (r) {
        case "Expr", "Primary", "OptCond", "VarInit":
            return emitExpr(t.children[$ - 1], line);
        case "Or", "And": {
                emitExpr(t.children[0], line);
                if (t.children.length == 1)
                    return;
                int[32] jumps;
                int nj = 0;
                for (size_t k = 2; k < t.children.length; k += 2) {
                    immutable j = emitX(r == "Or" ? XOp.orJump : XOp.andJump);
                    if (nj < jumps.length)
                        jumps[nj++] = j;
                    push(-1);
                    emitExpr(t.children[k], line);
                }
                emitX(XOp.toBool);
                foreach (j; jumps[0 .. nj])
                    p.xcode_[j].arg = cast(int)p.xcode_.length;
                return;
            }
        case "Not":
            if (ruleName(t.children[0]) == "NotOp") {
                emitExpr(t.children[1], line);
                emitX(XOp.not);
            } else
                emitExpr(t.children[0], line);
            return;
        case "Cmp", "Sum", "Term":
            emitExpr(t.children[0], line);
            for (size_t k = 1; k + 1 < t.children.length; k += 2) {
                emitExpr(t.children[k + 1], line);
                emitX(binary(src(t.children[k])));
                push(-1);
            }
            return;
        case "Unary":
            if (ruleName(t.children[0]) == "NegOp") {
                emitExpr(t.children[1], line);
                emitX(XOp.neg);
            } else
                emitExpr(t.children[0], line);
            return;
        case "Paren":
            return emitExpr(t.children[0], line);
        case "Postfix":
            emitExpr(t.children[0], line);
            return emitAccessors(t.children[1 .. $], line);
        case "ListLit":
            foreach (ref e; t.children)
                emitExpr(e, line);
            if (t.children.length > 255)
                error(line, colOf(line, t), "list literal too long");
            emitX(XOp.list, 0, cast(int)t.children.length);
            return push(1 - cast(int)t.children.length);
        case "MapLit":
            foreach (ref pr; t.children) {
                const key = pr.children[0];
                if (ruleName(key) == "String")
                    emitString(key, line);
                else {
                    emitX(XOp.konst, constant(Value.constText(keep(src(key)))));
                    push(1);
                }
                emitExpr(pr.children[1], line);
            }
            if (t.children.length > 255)
                error(line, colOf(line, t), "map literal too long");
            emitX(XOp.map, 0, cast(int)t.children.length);
            return push(1 - 2 * cast(int)t.children.length);
        case "Number":
            emitX(XOp.konst, constant(Value.number(parseNumber(src(t)))));
            return push(1);
        case "Literal": {
                const w = src(t);
                emitX(XOp.konst, constant(w == "true" ? Value.boolean(true) : (w == "false"
                        ? Value.boolean(false) : Value.init)));
                return push(1);
            }
        case "String":
            return emitString(t, line);
        case "CallExpr":
            return emitCall(t, line);
        case "Path":
            return emitPath(t, line);
        default:
            error(line, colOf(line, t), "unsupported expression (%.*s)", cast(int)r.length, r.ptr);
            emitX(XOp.konst, constant(Value.init));
            return push(1);
        }
    }

    static XOp binary(const(char)[] op) @nogc nothrow pure @safe {
        switch (op) {
        case "==":
            return XOp.eq;
        case "!=":
            return XOp.ne;
        case "<":
            return XOp.lt;
        case "<=":
            return XOp.le;
        case ">":
            return XOp.gt;
        case ">=":
            return XOp.ge;
        case "+":
            return XOp.add;
        case "-":
            return XOp.sub;
        case "*":
            return XOp.mul;
        case "/":
            return XOp.div;
        default:
            return XOp.mod;
        }
    }

    void emitCall(ref const ParseTree t, int line) {
        const name = src(t.children[0]);
        immutable argc = cast(int)t.children.length - 1;
        foreach (ref b; builtinTable)
            if (b.name == name) {
                if (argc < b.minArgs || argc > b.maxArgs)
                    error(line, colOf(line, t), "%.*s takes %d to %d arguments",
                            cast(int)name.length, name.ptr, b.minArgs, b.maxArgs);
                foreach (ref a; t.children[1 .. $])
                    emitExpr(a, line);
                emitX(XOp.call, b.id, argc);
                push(1 - argc);
                return;
            }
        error(line, colOf(line, t), "unknown function %.*s", cast(int)name.length, name.ptr);
        emitX(XOp.konst, constant(Value.init));
        push(1);
    }

    /// Dotted path of a Path node, in the scratch arena.
    const(char)[] pathOf(ref const ParseTree t) {
        return src(t);
    }

    void emitPath(ref const ParseTree t, int line) {
        const path = pathOf(t);
        if (scope_.length && resolveRead(join(scope_, path), line, t))
            return;
        if (resolveRead(path, line, t))
            return;
        if (t.children.length == 1) {
            immutable slot = intern(path, line);
            if (slot >= 0)
                markUse(slot, SlotUse.read);
            emitX(XOp.load, slot);
            return push(1);
        }
        if (!recordish(path) && !recordish(src(t.children[0])))
            return emitDynamicPath(t, t.children.length, line);
        if (isRecord(path))
            error(line, colOf(line, t), "%.*s is a record; name one of its fields", cast(int)path.length, path.ptr);
        else
            error(line, colOf(line, t), "unknown field %.*s", cast(int)path.length, path.ptr);
        emitX(XOp.konst, constant(Value.init));
        push(1);
    }

    /// True when `path` is a record or lies inside one (static fields, not map keys).
    bool recordish(const(char)[] path) {
        foreach (r; records.slice)
            if (r.length <= path.length && path[0 .. r.length] == r && (r.length == path.length || path[r.length] == '.'))
                return true;
        return false;
    }

    /// Emits a read of `path` when it names a derived field, a constant or an existing slot.
    bool resolveRead(const(char)[] path, int line, ref const ParseTree at) {
        foreach (ref d; derived.slice)
            if (d.path == path) {
                if (derivedDepth > 16) {
                    error(line, colOf(line, at), "derived field %.*s refers to itself",
                            cast(int)path.length, path.ptr);
                    emitX(XOp.konst, constant(Value.init));
                    push(1);
                    return true;
                }
                ParseContext ctx;
                auto r = parseLine(ctx, lines[d.line].text);
                assert(r.successful);
                auto saved = scope_;
                scope_ = d.scope_;
                derivedDepth++;
                emitExpr(statementOf(r.tree).children[1], d.line);
                derivedDepth--;
                scope_ = saved;
                return true;
            }
        foreach (ref c; consts.slice)
            if (c.path == path) {
                emitX(XOp.konst, constant(c.value));
                push(1);
                return true;
            }
        immutable slot = st.find(path);
        if (slot < 0)
            return false;
        markUse(slot, SlotUse.read);
        emitX(XOp.load, slot);
        push(1);
        return true;
    }

    /// The slot an assignment to `path` writes, or -1 (reported).
    int lvalue(ref const ParseTree t, int line) {
        const path = pathOf(t);
        foreach (ref d; derived.slice)
            if (d.path == path) {
                error(line, colOf(line, t), "%.*s is derived and cannot be assigned", cast(int)path.length, path.ptr);
                return -1;
            }
        foreach (ref c; consts.slice)
            if (c.path == path) {
                error(line, colOf(line, t), "%.*s is read-only", cast(int)path.length, path.ptr);
                return -1;
            }
        immutable found = st.find(path);
        if (found >= 0 || t.children.length == 1) {
            immutable slot = found >= 0 ? found : intern(path, line);
            if (slot >= 0)
                markUse(slot, SlotUse.written);
            return slot;
        }
        if (isRecord(path))
            error(line, colOf(line, t), "%.*s is a record; assign one of its fields", cast(int)path.length, path.ptr);
        else
            error(line, colOf(line, t), "unknown field %.*s", cast(int)path.length, path.ptr);
        return -1;
    }

    /// Splits `text` into literal and `{expression}` pieces, unescaping `{{`, `}}` and (when
    /// `escapes`) backslash escapes. Calls `piece(isExpr, s)`; false on an unbalanced brace.
    bool pieces(const(char)[] text, bool escapes, int line, scope void delegate(bool, const(char)[]) @nogc nothrow piece) {
        char[512] lit;
        size_t n = 0;
        void flush() {
            if (n)
                piece(false, lit[0 .. n]);
            n = 0;
        }

        void put(char c) {
            if (n == lit.length)
                flush();
            lit[n++] = c;
        }

        size_t i = 0;
        while (i < text.length) {
            immutable c = text[i];
            if (escapes && c == '\\' && i + 1 < text.length) {
                immutable e = text[i + 1];
                put(e == 'n' ? '\n' : (e == 't' ? '\t' : e));
                i += 2;
            } else if (c == '{' && i + 1 < text.length && text[i + 1] == '{') {
                put('{');
                i += 2;
            } else if (c == '}' && i + 1 < text.length && text[i + 1] == '}') {
                put('}');
                i += 2;
            } else if (c == '{') {
                size_t e = i + 1;
                char quote = 0;
                int nest = 0;
                while (e < text.length && (quote || nest || text[e] != '}')) {
                    if (text[e] == '"')
                        quote = quote ? 0 : '"';
                    else if (!quote && text[e] == '{')
                        nest++;
                    else if (!quote && text[e] == '}')
                        nest--;
                    e++;
                }
                if (e == text.length) {
                    error(line, 0, "unclosed { in text");
                    return false;
                }
                flush();
                piece(true, text[i + 1 .. e]);
                i = e + 1;
            } else if (c == '}') {
                error(line, 0, "stray } in text (write }} for a brace)");
                return false;
            } else {
                put(c);
                i++;
            }
        }
        flush();
        return true;
    }

    /// Parses the inside of `{...}` and calls `fn` with its Expr tree.
    void withInterpolated(const(char)[] s, int line, scope void delegate(ref const ParseTree) @nogc nothrow fn) {
        while (s.length && (s[0] == ' ' || s[0] == '\t'))
            s = s[1 .. $];
        while (s.length && (s[$ - 1] == ' ' || s[$ - 1] == '\t'))
            s = s[0 .. $ - 1];
        ParseContext ctx;
        auto r = parseExpr(ctx, s);
        if (!r.successful || r.end != s.length) {
            error(line, 0, "bad expression in {%.*s}", cast(int)s.length, s.ptr);
            return;
        }
        fn(r.tree.children[0]);
    }

    void emitString(ref const ParseTree t, int line) {
        int parts = 0;
        bool simple = true;
        // Fast path: constant strings.
        foreach (ch; strBody(t))
            if (ch == '{' || ch == '}')
                simple = false;
        if (simple) {
            emitX(XOp.konst, constant(Value.constText(unescape(strBody(t)))));
            return push(1);
        }
        pieces(strBody(t), true, line, (bool isExpr, const(char)[] s) {
            if (parts == 16)
                return error(line, colOf(line, t), "too many pieces in one string");
            if (isExpr)
                withInterpolated(s, line, (ref const ParseTree e) { emitExpr(e, line); });
            else {
                emitX(XOp.konst, constant(Value.constText(keep(s))));
                push(1);
            }
            parts++;
        });
        if (parts == 0) {
            emitX(XOp.konst, constant(Value.constText("")));
            return push(1);
        }
        emitX(XOp.concat, 0, parts);
        push(1 - parts);
    }

    /// A display template for raw line text (or a quoted caption when `escapes`).
    int textTemplate(const(char)[] text, bool escapes, int line) {
        Template tp;
        tp.start = p.segments_.length;
        pieces(text, escapes, line, (bool isExpr, const(char)[] s) {
            Segment seg;
            if (isExpr)
                withInterpolated(s, line, (ref const ParseTree e) { seg.expr = expression(e, line); });
            else
                seg.lit = keep(s);
            if (!p.segments_.push(seg))
                oom = true;
        });
        tp.len = p.segments_.length - tp.start;
        if (!p.templates_.push(tp))
            oom = true;
        return cast(int)p.templates_.length - 1;
    }

    /// A copy of a quoted string's inside with backslash escapes applied.
    const(char)[] unescape(const(char)[] s) {
        auto d = p.text_.alloc(s.length);
        if (d is null)
            return "";
        size_t o = 0;
        for (size_t i = 0; i < s.length; i++) {
            char c = s[i];
            if (c == '\\' && i + 1 < s.length) {
                immutable e = s[++i];
                c = e == 'n' ? '\n' : (e == 't' ? '\t' : e);
            }
            d[o++] = c;
        }
        return d[0 .. o];
    }

    static double parseNumber(const(char)[] s) @nogc nothrow @trusted {
        char[64] z;
        if (s.length >= z.length)
            return double.nan;
        z[0 .. s.length] = s[];
        z[s.length] = 0;
        return strtod(z.ptr, null);
    }

    // ---- pass 3: scenes --------------------------------------------------------------------------

    int emit(Ins ins) {
        if (!p.code_.push(ins))
            oom = true;
        return cast(int)p.code_.length - 1;
    }

    int here() {
        return cast(int)p.code_.length;
    }

    void fixup(int at, ubyte field, const(char)[] target, int line) {
        const(char)[] full = target;
        if (target.length && target[0] == '.') {
            if (curLabel.length == 0)
                return error(line, 0, "%.*s: local labels need an enclosing label",
                        cast(int)target.length, target.ptr);
            full = join(curLabel, target[1 .. $]);
        }
        fixups.push(Fixup(at, field, keep(full), line));
    }

    void emitScenes() {
        eachChild(0, cast(int)lines.length, (int i, int end) {
            ParseContext ctx;
            auto r = parseLine(ctx, lines[i].text);
            if (!r.successful)
                return;
            const s = &statementOf(r.tree);
            const kind = ruleName(*s);
            if (kind == "LabelDecl") {
                curLabel = curLineId = keep(src(s.children[0]));
                setLabelPc(curLabel, here());
                block(i + 1, end);
                emit(Ins(Op.ret));
            } else if (kind == "On")
                onTrigger(i, end, *s);
        });
        curLabel = curLineId = null;
    }

    void setLabelPc(const(char)[] name, int pc) {
        foreach (k, n; p.labelNames_.slice)
            if (n == name)
                p.labelPcs_[k] = pc;
    }

    void onTrigger(int i, int end, ref const ParseTree s) {
        Trigger t;
        t.entry = -1;
        const kind = src(s.children[0]);
        t.on = kind == "start" ? TriggerKind.start : (kind == "talk" ? TriggerKind.talk : (kind == "enter"
                ? TriggerKind.enter : TriggerKind.returned));
        if (const tg = child(s, "OnTarget"))
            t.target = keep(src(*tg));
        if ((t.on == TriggerKind.talk || t.on == TriggerKind.enter) && t.target.length == 0)
            error(i, 0, "on %.*s needs a target", cast(int)kind.length, kind.ptr);
        if (t.on == TriggerKind.returned && t.target.length && t.target != "won" && t.target != "lost")
            error(i, 0, "on return takes won or lost");
        if (child(s, "Once")) {
            char[24] nb;
            immutable n = snprintf(nb.ptr, nb.length, "once#%u", p.triggers_.length);
            t.onceVar = intern(keep(nb[0 .. n]), i);
            if (t.onceVar >= 0)
                markUse(t.onceVar, SlotUse.written | SlotUse.read);
        }
        if (const e = child(s, "Expr"))
            t.cond = expression(*e, i);
        immutable ti = cast(int)p.triggers_.length;
        if (const g = child(s, "OnGoto")) {
            curLabel = null;
            fixup(-1 - ti, 0, src(g.children[0]), i);
        } else {
            curLabel = curLineId = null;
            t.entry = here();
            block(i + 1, end);
            emit(Ins(Op.ret));
        }
        p.triggers_.push(t);
    }

    /// Emits the statements of the block `[first, end)`.
    void block(int first, int end) {
        int k = first;
        if (first >= end)
            return;
        immutable ind = lines[first].eff;
        // Pending if-chain end jumps (patched when the chain ends).
        int[16] chainEnds;
        int numChainEnds = 0;
        int chainNext = -1; // jumpIfNot of the previous branch, waiting for the next one
        bool inChain = false;

        void closeChain() {
            if (!inChain)
                return;
            if (chainNext >= 0)
                p.code_[chainNext].b = here();
            foreach (j; chainEnds[0 .. numChainEnds])
                p.code_[j].a = here();
            numChainEnds = 0;
            chainNext = -1;
            inChain = false;
        }

        while (k < end) {
            if (lines[k].eff != ind) {
                error(k, 0, "unexpected indentation");
                k++;
                continue;
            }
            immutable e = blockEnd(k);
            ParseContext ctx;
            auto r = parseLine(ctx, lines[k].text);
            if (!parseOk(k, r)) {
                k = e;
                continue;
            }
            const s = &statementOf(r.tree);
            const kind = ruleName(*s);
            if (kind != "Elif" && kind != "Else")
                closeChain();
            if (!hasBody(kind) && e > k + 1)
                error(k + 1, 0, "unexpected indented block");
            if (kind == "Option") {
                k = menu(k, end, ind);
                continue;
            }
            if (kind == "For") {
                forLoop(k, e, *s);
                k = e;
                continue;
            }
            if (kind == "If" || kind == "Elif") {
                if (kind == "Elif" && !inChain) {
                    error(k, 0, "elif without if");
                } else {
                    if (kind == "Elif") {
                        if (numChainEnds < chainEnds.length)
                            chainEnds[numChainEnds++] = emit(Ins(Op.jump));
                        p.code_[chainNext].b = here();
                    }
                    inChain = true;
                    chainNext = emit(Ins(Op.jumpIfNot, 0, expression(s.children[0], k)));
                    block(k + 1, e);
                }
            } else if (kind == "Else") {
                if (!inChain || chainNext < 0)
                    error(k, 0, "else without if");
                else {
                    if (numChainEnds < chainEnds.length)
                        chainEnds[numChainEnds++] = emit(Ins(Op.jump));
                    p.code_[chainNext].b = here();
                    chainNext = -1;
                    block(k + 1, e);
                }
                closeChain();
            } else
                statement(k, *s, kind);
            k = e;
        }
        closeChain();
    }

    /// Emits the menu starting with the option on line `k`; returns the first line after it.
    int menu(int k, int end, uint ind) {
        int[maxChoices] opts;
        int[maxChoices] bodyStart, bodyEnd;
        int n = 0;
        immutable m = emit(Ins(Op.menu, 0, 0));
        int at = k;
        while (at < end && lines[at].eff == ind) {
            ParseContext ctx;
            auto r = parseLine(ctx, lines[at].text);
            if (!r.successful || ruleName(statementOf(r.tree)) != "Option")
                break;
            immutable e = blockEnd(at);
            const o = &statementOf(r.tree);
            if (n == maxChoices) {
                error(at, 0, "more than %d choices in one menu", maxChoices);
                at = e;
                continue;
            }
            const cap = o.children[0].children[0];
            immutable tpl = ruleName(cap) == "String" ? textTemplate(strBody(cap), true, at) : textTemplate(src(cap),
                    false, at);
            const cond = child(*o, "OptCond");
            opts[n] = emit(Ins(Op.option, 0, tpl, cond ? expression(*cond, at) : -1));
            bodyStart[n] = at + 1;
            bodyEnd[n] = e;
            n++;
            at = e;
        }
        p.code_[m].a = n;
        int[maxChoices + 1] ends;
        ends[0] = emit(Ins(Op.jump));
        foreach (i; 0 .. n) {
            p.code_[opts[i]].c = here();
            block(bodyStart[i], bodyEnd[i]);
            ends[i + 1] = emit(Ins(Op.jump));
        }
        foreach (j; ends[0 .. n + 1])
            p.code_[j].a = here();
        return at;
    }

    void statement(int k, ref const ParseTree s, const(char)[] kind) {
        switch (kind) {
        case "Say": {
                SayRec say;
                const name = src(s.children[0]);
                say.speaker = p.findSpeaker(name);
                if (say.speaker < 0)
                    error(k, 0, "unknown speaker %.*s (declare it with `character %.*s`)",
                            cast(int)name.length, name.ptr, cast(int)name.length, name.ptr);
                if (const m = child(s, "Mood"))
                    say.mood = keep(src(m.children[0]));
                say.text = textTemplate(src(s.children[$ - 1]), false, k);
                return addSay(say);
            }
        case "Narrate": {
                SayRec say;
                say.text = textTemplate(src(s.children[0]), false, k);
                return addSay(say);
            }
        case "SubLabel":
            curLineId = keep(join(curLabel, src(s.children[0])));
            setLabelPc(curLineId, here());
            return;
        case "Goto":
            return fixup(emit(Ins(Op.jump)), 0, src(s.children[0]), k);
        case "Call":
            return fixup(emit(Ins(Op.call)), 0, src(s.children[0]), k);
        case "Return":
            emit(Ins(Op.ret));
            return;
        case "End":
            emit(Ins(Op.jump, 0, -1));
            return;
        case "SetStmt": {
                immutable slot = lvalue(s.children[0], k);
                immutable x = s.children.length > 1 ? expression(s.children[1], k) : -1;
                if (slot >= 0)
                    emit(Ins(Op.assign, AssignOp.set, slot, x));
                return;
            }
        case "ClearStmt": {
                immutable slot = lvalue(s.children[0], k);
                if (slot >= 0)
                    emit(Ins(Op.assign, AssignOp.clear, slot));
                return;
            }
        case "Assign": {
                if (child(s, "Bounds"))
                    error(k, 0, "ranges belong in declarations (var, type or character fields)");
                const lv = &s.children[0];
                const path = &lv.children[0];
                const op = src(s.children[1]);
                immutable aop = op == "=" ? AssignOp.set : (op == "+=" ? AssignOp.add : (op == "-="
                        ? AssignOp.sub : (op == "*=" ? AssignOp.mul : (op == "/=" ? AssignOp.div : AssignOp.mod))));
                if (lv.children.length > 1 || (path.children.length > 1 && st.find(src(*path)) < 0
                        && !recordish(src(*path)) && !recordish(src(path.children[0])))) {
                    // A list element or map entry: container[key] op= value.
                    int cont, key;
                    if (lv.children.length > 1) {
                        cont = entryOf(k, () {
                            emitExpr(*path, k);
                            emitAccessors(lv.children[1 .. $ - 1], k);
                        });
                        const last = &lv.children[$ - 1];
                        key = ruleName(*last) == "Index" ? expression(last.children[0], k) : entryOf(k, () {
                            emitX(XOp.konst, constant(Value.constText(keep(src(last.children[0])))));
                            push(1);
                        });
                    } else {
                        cont = entryOf(k, () { emitDynamicPath(*path, path.children.length - 1, k); });
                        key = entryOf(k, () {
                            emitX(XOp.konst, constant(Value.constText(keep(src(path.children[$ - 1])))));
                            push(1);
                        });
                    }
                    emit(Ins(Op.store, aop, cont, key, expression(s.children[2], k)));
                    return;
                }
                immutable slot = lvalue(*path, k);
                immutable x = expression(s.children[2], k);
                if (slot >= 0) {
                    if (aop != AssignOp.set)
                        markUse(slot, SlotUse.read);
                    emit(Ins(Op.assign, aop, slot, x));
                }
                return;
            }
        case "CallStmt":
            emit(Ins(Op.exec, 0, expression(s.children[0], k)));
            return;
        case "EventStmt": {
                immutable id = eventId(src(s.children[0]));
                emit(Ins(Op.event, 0, id, s.children.length > 1 ? expression(s.children[1], k) : -1));
                return;
            }
        case "Show":
            emit(Ins(Op.present, PresentKind.show, str(src(s.children[0])), s.children.length > 1
                    ? str(src(s.children[1])) : -1));
            return;
        case "Hide":
            emit(Ins(Op.present, PresentKind.hide, str(src(s.children[0]))));
            return;
        case "SceneCmd":
            emit(Ins(Op.present, PresentKind.scene, str(src(s.children[0]))));
            return;
        case "Play":
            emit(Ins(Op.present, src(s.children[0]) == "music" ? PresentKind.playMusic
                    : PresentKind.playSound, str(unescape(strBody(s.children[1])))));
            return;
        case "StopCmd":
            emit(Ins(Op.present, src(s.children[0]) == "music" ? PresentKind.stopMusic : PresentKind.stopSound));
            return;
        case "Battle":
            emit(Ins(Op.present, PresentKind.battle, s.children.length ? str(src(s.children[0])) : -1));
            return;
        default:
            error(k, 0, "%.*s is not allowed inside a scene", cast(int)kind.length, kind.ptr);
        }
    }

    /// `for x in xs:` - over list elements or map keys, in order. The collection is evaluated
    /// once; the loop index lives in a hidden variable, so the body may call and jump freely.
    void forLoop(int k, int e, ref const ParseTree s) {
        char[32] nb;
        immutable n = snprintf(nb.ptr, nb.length, "for#%u", forCount++);
        immutable listSlot = intern(keep(join(nb[0 .. n], "list")), k);
        immutable iSlot = intern(keep(join(nb[0 .. n], "i")), k);
        immutable varSlot = intern(src(s.children[0]), k);
        if (listSlot < 0 || iSlot < 0 || varSlot < 0)
            return;
        markUse(listSlot, SlotUse.read | SlotUse.written);
        markUse(iSlot, SlotUse.read | SlotUse.written);
        markUse(varSlot, SlotUse.written);
        emit(Ins(Op.assign, AssignOp.set, listSlot, expression(s.children[1], k)));
        immutable zero = constant(Value.number(0)), one = constant(Value.number(1));
        emit(Ins(Op.assign, AssignOp.set, iSlot, entryOf(k, () { emitX(XOp.konst, zero); push(1); })));
        immutable top = here();
        immutable test = emit(Ins(Op.jumpIfNot, 0, entryOf(k, () {
                    emitX(XOp.load, iSlot);
                    emitX(XOp.load, listSlot);
                    push(2);
                    emitX(XOp.call, Builtin.len, 1);
                    emitX(XOp.lt);
                    push(-1);
                })));
        emit(Ins(Op.assign, AssignOp.set, varSlot, entryOf(k, () {
                    emitX(XOp.load, listSlot);
                    emitX(XOp.load, iSlot);
                    push(2);
                    emitX(XOp.iter);
                    push(-1);
                })));
        block(k + 1, e);
        emit(Ins(Op.assign, AssignOp.add, iSlot, entryOf(k, () { emitX(XOp.konst, one); push(1); })));
        emit(Ins(Op.jump, 0, top));
        p.code_[test].b = here();
    }

    void addSay(SayRec say) {
        say.label = curLineId;
        if (!p.says_.push(say))
            oom = true;
        emit(Ins(Op.say, 0, cast(int)p.says_.length - 1));
    }

    int str(const(char)[] s) {
        if (!p.strings_.push(keep(s)))
            oom = true;
        return cast(int)p.strings_.length - 1;
    }

    int eventId(const(char)[] name) {
        immutable f = p.findEvent(name);
        if (f >= 0)
            return f;
        if (!p.events_.push(keep(name)))
            oom = true;
        return cast(int)p.events_.length - 1;
    }

    // ---- pass 4: fixups and warnings -------------------------------------------------------------

    void resolveFixups() {
        foreach (ref f; fixups.slice) {
            int pc = -1;
            foreach (k, n; p.labelNames_.slice)
                if (n == f.label) {
                    pc = p.labelPcs_[k];
                    labels[k].used = true;
                }
            if (pc < 0) {
                error(f.line, 0, "unknown label %.*s", cast(int)f.label.length, f.label.ptr);
                continue;
            }
            if (f.at < 0) {
                p.triggers_[-1 - f.at].entry = pc;
                continue;
            }
            auto ins = &p.code_[f.at];
            if (f.field == 0)
                ins.a = pc;
            else if (f.field == 1)
                ins.b = pc;
            else
                ins.c = pc;
        }
    }

    void warnings() {
        foreach (ref l; labels.slice) {
            bool sub = false;
            foreach (c; l.name)
                sub |= c == '.';
            if (!l.used && !sub)
                warn(l.line, "label %.*s is never used", cast(int)l.name.length, l.name.ptr);
        }
        foreach (slot; external .. st.length) {
            immutable u = slot < slotUse.length ? slotUse[slot] : 0;
            if ((u & SlotUse.read) && !(u & SlotUse.written)) {
                const n = st.name(slot);
                warn(-1, "%.*s is read but never set", cast(int)n.length, n.ptr);
            }
        }
    }
}
