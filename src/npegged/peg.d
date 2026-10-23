/** Parsing engine derived from Philippe Sigaud's Pegged. Boost Software License 1.0. */
module npegged.peg;
public import npegged.storage : Arena, Status;
import npegged.storage : growthCapacity;
public import npegged.records : CompactNode;
import npegged.records : RecordBuffer, RecordSnapshot;

version (NPeggedSharedOutput) import npegged.records : SharedRecordStore;

/// Non-owning node. Runtime slices belong to the enclosing ParseResult.
struct ParseTree {
    string name;
    bool successful;
    string[] matches;
    string input;
    size_t begin, end;
    ParseTree[] children;
    size_t failEnd;
    ParseTree[] failedChild;
    @property auto toString() const @nogc nothrow {
        import npegged.formatting : formatTree;

        return formatTree(this);
    }

    @property auto failMsg() const @nogc nothrow {
        import npegged.formatting : failureMessage;

        return failureMessage(this);
    }

    ref inout(ParseTree) opIndex(size_t i) inout return @nogc nothrow {
        return children[i];
    }

    inout(ParseTree)[] opIndex() inout return @nogc nothrow {
        return children;
    }

    size_t opDollar() const @nogc nothrow {
        return children.length;
    }

    inout(ParseTree)[] opSlice(size_t a, size_t b) inout return @nogc nothrow {
        return children[a .. b];
    }
}

@nogc nothrow unittest {
    ParseTree[2] children;
    children[0].name = "a";
    ParseTree tree;
    tree.children = children[];
    assert(tree[0].name == "a");
    assert(tree[].length == 2);
    assert(tree[0 .. $].length == 2);
    auto text = tree.toString;
    assert(text.status == Status.ok && text.data.length);
    auto failure = tree.failMsg;
    assert(failure.status == Status.ok && failure.data.length);
}

/// Internal recognition value: no input views, names, output or diagnostic arrays.
struct RecognitionNode {
    size_t begin, end, failEnd;
    bool successful;
}

@nogc nothrow unittest {
    static assert(RecognitionNode.sizeof < ParseTree.sizeof);
    RecognitionNode node;
    assert(!node.successful && node.begin == 0 && node.end == 0 && node.failEnd == 0);
}

/// Limits are per parse; contexts can be reused or used independently by threads.
// Diagnostic builds only: timed builds contain neither counters nor branches.
version (NPeggedMetrics) {
    struct ParseMetrics {
        ulong memoCalls, memoHits, seedGrowths, invalidationVisits, invalidatedEntries;
        ulong snapshotBytes, outputSnapshotCount;
        version (NPeggedPureIslands) ulong pureIslandEntries, pureIslandFallbacks;
        ulong memoBucketVisits, memoUnlinkVisits, memoRehashes, memoRehashedEntries;
        import npegged.records : RecordMetrics;

        RecordMetrics output;
    }

    @nogc nothrow unittest {
        ParseMetrics metrics;
        assert(metrics.memoCalls == 0 && metrics.snapshotBytes == 0);
    }
}

version (NPeggedDependencyTrace) {
    /// Diagnostic events only; IDs are monotonically assigned within one trace.
    enum MemoTraceKind {
        created,
        iteration,
        activeHit,
        cachedHit,
        growth,
        retired,
        completed
    }

    struct MemoTraceEvent {
        MemoTraceKind kind;
        size_t caller, entry, position, end;
        bool successful;
        string rule;
    }

    /// Non-owning bounded sink. Its caller must retain storage for the entire parse.
    /// Truncation never changes parser status and invalidates dependency conclusions.
    struct MemoTrace {
        private MemoTraceEvent[] storage;
        private size_t length;
        private size_t nextID = 1;
        bool truncated;

        this(MemoTraceEvent[] storage) @nogc nothrow {
            this.storage = storage;
        }

        const(MemoTraceEvent)[] events() const return @nogc nothrow {
            return storage[0 .. length];
        }

        private size_t issueID() @nogc nothrow {
            if (truncated)
                return 0;
            if (nextID == size_t.max) {
                truncated = true;
                return 0;
            }
            return nextID++;
        }

        private void record(MemoTraceEvent event) @nogc nothrow {
            if (truncated)
                return;
            if (length == storage.length) {
                truncated = true;
                return;
            }
            storage[length++] = event;
        }
    }

    @nogc nothrow unittest {
        MemoTraceEvent[2] storage;
        MemoTrace trace = MemoTrace(storage[]);
        assert(trace.issueID() == 1 && trace.issueID() == 2);
        trace.record(MemoTraceEvent(MemoTraceKind.created, 0, 1, 0, 0, false, "test"));
        trace.record(MemoTraceEvent(MemoTraceKind.completed, 0, 1));
        assert(trace.events.length == 2 && !trace.truncated);
        trace.record(MemoTraceEvent.init);
        assert(trace.events.length == 2 && trace.truncated && trace.issueID() == 0);
        MemoTrace overflow = MemoTrace(storage[]);
        overflow.nextID = size_t.max;
        assert(overflow.issueID() == 0 && overflow.truncated);
    }
}

version (NPeggedScannerMetrics) {
    enum ScannerReason {
        none,
        tree,
        innerRecords,
        invalidTable,
        state,
        position,
        steps,
        trace,
        depth,
        budgetEdge,
        failureDiagnostic,
        primitiveScan,
        recordLowering,
        count
    }

    /// Frontier spans exclude an inspected stopping byte at the frontier itself.
    struct ScannerEvent {
        string rule;
        ScannerReason reason;
        bool eligible, attempted, scanAccepted, fastSuccess, fastFailure, original;
        size_t examinedBytes, originalBytes, replayedBytes;
    }

    struct ScannerStats {
        string rule;
        ulong calls, eligible, scanCalls, scanSuccess, scanFailure, fastSuccess, fastFailure;
        ulong originalCalls, replays, examinedBytes, originalBytes, replayedBytes;
        ulong[ScannerReason.count] reasons;

        void add(scope const ref ScannerEvent event) @nogc nothrow {
            ++calls;
            eligible += event.eligible;
            scanCalls += event.attempted;
            scanSuccess += event.attempted && event.scanAccepted;
            scanFailure += event.attempted && !event.scanAccepted;
            fastSuccess += event.fastSuccess;
            fastFailure += event.fastFailure;
            originalCalls += event.original;
            replays += event.attempted && event.original;
            examinedBytes += event.examinedBytes;
            originalBytes += event.originalBytes;
            replayedBytes += event.replayedBytes;
            ++reasons[event.reason];
        }
    }

    @nogc nothrow unittest {
        ScannerStats stats;
        ScannerEvent event;
        event.eligible = event.attempted = event.scanAccepted = event.fastSuccess = true;
        event.examinedBytes = 3;
        stats.add(event);
        event.scanAccepted = event.fastSuccess = false;
        event.original = event.fastFailure = true;
        event.originalBytes = 5;
        event.replayedBytes = 3;
        event.reason = ScannerReason.budgetEdge;
        stats.add(event);
        assert(stats.calls == 2 && stats.eligible == 2 && stats.scanCalls == 2);
        assert(stats.scanSuccess == 1 && stats.scanFailure == 1 && stats.fastSuccess == 1);
        assert(stats.fastFailure == 1 && stats.originalCalls == 1 && stats.replays == 1);
        assert(stats.examinedBytes == 6 && stats.originalBytes == 5 && stats.replayedBytes == 3);
        assert(stats.reasons[ScannerReason.none] == 1 && stats.reasons[ScannerReason.budgetEdge] == 1);
    }

    /// Borrowed fixed-capacity storage; totals remain complete when rows truncate.
    struct ScannerReport {
        ScannerStats total;
        ScannerStats[] rows;
        size_t length;
        bool truncated;

        void record(scope const ref ScannerEvent event) @nogc nothrow {
            total.add(event);
            foreach (i; 0 .. length)
                if (rows[i].rule == event.rule) {
                    rows[i].add(event);
                    return;
                }
            if (length == rows.length) {
                truncated = true;
                return;
            }
            rows[length] = ScannerStats.init;
            rows[length].rule = event.rule;
            rows[length++].add(event);
        }
    }

    @nogc nothrow unittest {
        ScannerReport empty;
        ScannerEvent event;
        event.rule = "A";
        empty.record(event);
        assert(empty.truncated && empty.length == 0 && empty.total.calls == 1);
        ScannerStats[2] fullRows;
        ScannerReport full;
        full.rows = fullRows[];
        full.record(event);
        event.rule = "B";
        event.examinedBytes = 4;
        full.record(event);
        assert(!full.truncated && full.length == 2);
        assert(full.rows[0].calls + full.rows[1].calls == full.total.calls);
        assert(full.rows[0].examinedBytes + full.rows[1].examinedBytes == full.total.examinedBytes);
        ScannerStats[1] rows;
        ScannerReport report;
        report.rows = rows[];
        event.rule = "A";
        report.record(event);
        report.record(event);
        event.rule = "B";
        report.record(event);
        event.rule = "A";
        report.record(event);
        assert(report.length == 1 && report.truncated && report.total.calls == 4);
        assert(rows[0].rule == "A" && rows[0].calls == 3);
    }
}

// Per-rule instrumentation build only (-version=NPeggedRuleMetrics): counts are never in timed builds.
version (NPeggedRuleMetrics) {
    struct RuleStats {
        string rule;
        ulong calls, successes, failures, memoHits;
    }

    /// Borrowed fixed-capacity rows; `total` stays complete when rows truncate.
    struct RuleReport {
        RuleStats total;
        RuleStats[] rows;
        size_t length;
        bool truncated;

        void record(string rule, bool successful, bool memoHit = false) @nogc nothrow {
            ++total.calls;
            successful ? ++total.successes : ++total.failures;
            total.memoHits += memoHit;
            foreach (i; 0 .. length)
                if (rows[i].rule == rule) {
                    ++rows[i].calls;
                    successful ? ++rows[i].successes : ++rows[i].failures;
                    rows[i].memoHits += memoHit;
                    return;
                }
            if (length == rows.length) {
                truncated = true;
                return;
            }
            rows[length] = RuleStats(rule, 1, successful, !successful, memoHit);
            ++length;
        }

        /// Deterministic JSON for the instrumented run.
        string json() const nothrow {
            string number(ulong value) nothrow {
                char[20] digits;
                size_t count;
                do {
                    digits[count++] = cast(char)('0' + value % 10);
                    value /= 10;
                }
                while (value);
                string text;
                while (count)
                    text ~= digits[--count];
                return text;
            }

            string row(const RuleStats stats) nothrow {
                return "\"calls\":" ~ number(stats.calls) ~ ",\"successes\":" ~ number(
                        stats.successes) ~ ",\"failures\":" ~ number(
                        stats.failures) ~ ",\"memoHits\":" ~ number(stats.memoHits);
            }

            string text = "{\"truncated\":" ~ (truncated ? "true" : "false") ~ ",\"total\":{" ~ row(
                    total) ~ "},\"rules\":[";
            foreach (i; 0 .. length)
                text ~= (i ? "," : "") ~ "{\"rule\":\"" ~ rows[i].rule ~ "\"," ~ row(rows[i]) ~ "}";
            return text ~ "]}";
        }
    }

    @nogc nothrow unittest {
        RuleStats[2] storage;
        RuleReport report;
        report.rows = storage[];
        report.record("A", true);
        report.record("A", false, true);
        report.record("B", true);
        report.record("C", true); // truncated row, still totalled
        assert(report.length == 2 && report.truncated && report.total.calls == 4);
        assert(storage[0].calls == 2 && storage[0].failures == 1 && storage[0].memoHits == 1);
    }

    nothrow unittest {
        RuleStats[1] storage;
        RuleReport report;
        report.rows = storage[];
        report.record("A", true);
        assert(report.json() == `{"truncated":false,"total":{"calls":1,"successes":1,"failures":0,"memoHits":0},"rules":[{"rule":"A","calls":1,"successes":1,"failures":0,"memoHits":0}]}`);
    }
}

struct ParseContext {
    version (NPeggedRuleMetrics) RuleReport* ruleReport;
    version (NPeggedScannerMetrics) ScannerReport* scannerReport;
    version (NPeggedSharedOutput) bool sharedOutput;
    version (NPeggedDependencyTrace) MemoTrace* memoTrace;
    version (NPeggedMetrics) ParseMetrics* metrics;
    size_t memoryLimit = 256 * 1024 * 1024;
    size_t stepLimit = 10_000_000;
    size_t depthLimit = 1024;
    void* userData;
    void function(string, size_t, bool, void*) @nogc nothrow trace;
}

@nogc nothrow unittest {
    version (NPeggedScannerMetrics)
        static assert(__traits(hasMember, ParseContext, "scannerReport"));
    else
        static assert(!__traits(hasMember, ParseContext, "scannerReport"));
}

/// Owns input and all runtime tree storage. Views expire when this owner is destroyed.
struct ParseResult {
    Arena arena;
    ParseTree tree;
    Status status = Status.invalidInput;
    alias tree this;
    @disable this(this);
    @disable this(ref ParseResult);
}

/// One invocation's storage and rule state. CTFE instantiations use compiler storage.
struct State(bool CT, int Check = 0) {
    static if (Check)
        alias Node = RecognitionNode;
    else
        alias Node = ParseTree;
    Arena* arena;
    string input;
    ParseContext context;
    Status status;
    size_t steps, depth;
    version (NPeggedRuleMetrics) bool memoHitPending;
    static if (Check == 2)
        private RecordBuffer* records;
    static if (Check == 2) {
        /// The attached record builder, for the tagged scanners of `npegged.dfa`.
        package(npegged) @property ref RecordBuffer output() return @nogc nothrow {
            return *records;
        }

        /// Non-owning backend setup; the builder and its arenas must outlive this state.
        void attachRecords(ref RecordBuffer output) @nogc nothrow {
            records = &output;
            version (NPeggedMetrics)
                output.metrics = context.metrics is null ? null : &context.metrics.output;
        }
    }
    version (NPeggedPureIslands) {
        private bool pureIslandsEnabled;

        /// An enclosing API entry, not an arbitrary leaf call, must carry proof.
        pragma(inline, true) bool pureIslandAllowed() @nogc nothrow {
            static if (CT || Check == 0)
                return false;
            else {
                if (!pureIslandsEnabled || status != Status.ok) {
                    version (NPeggedMetrics)
                        if (context.metrics !is null)
                            ++context.metrics.pureIslandFallbacks;
                    return false;
                }
                bool allowed = context.trace is null && context.stepLimit == size_t.max
                    && context.depthLimit == size_t.max && context.memoryLimit == size_t.max
                    && arena !is null && arena.limit == size_t.max && arena.status == Status.ok
                    && arena.allocator is Arena.init.allocator;
                static if (Check == 2)
                    allowed = allowed && records !is null && records.arena !is null
                        && records.arena.limit == size_t.max && records.status == Status.ok
                        && records.arena.allocator is Arena.init.allocator;
                version (NPeggedMetrics)
                    if (context.metrics !is null) {
                        if (allowed)
                            ++context.metrics.pureIslandEntries;
                        else
                            ++context.metrics.pureIslandFallbacks;
                    }
                return allowed;
            }
        }

        @nogc nothrow unittest {
            State!(CT, Check) state;
            version (NPeggedMetrics) {
                ParseMetrics metrics;
                state.context.metrics = &metrics;
            }
            assert(!state.pureIslandAllowed());
            static if (!CT && Check != 0) {
                state.pureIslandsEnabled = true;
                assert(!state.pureIslandAllowed());
                Arena owner, output;
                owner.limit = output.limit = size_t.max;
                state.arena = &owner;
                state.context.memoryLimit = state.context.depthLimit = state.context.stepLimit = size_t.max;
                state.arena = null;
                assert(!state.pureIslandAllowed());
                state.arena = &owner;
                RecordBuffer buffer;
                buffer.arena = &output;
                static if (Check == 2) {
                    assert(!state.pureIslandAllowed());
                    state.attachRecords(buffer);
                }
                assert(state.pureIslandAllowed());
                static foreach (field; ["stepLimit", "depthLimit", "memoryLimit"]) {
                    __traits(getMember, state.context, field) = 0;
                    assert(!state.pureIslandAllowed());
                    __traits(getMember, state.context, field) = size_t.max;
                }
                state.context.trace = (string, size_t, bool, void*) @nogc nothrow{};
                assert(!state.pureIslandAllowed());
                state.context.trace = null;
                owner.limit = 0;
                assert(!state.pureIslandAllowed());
                owner.limit = size_t.max;
                owner.allocator = (size_t) @nogc nothrow => cast(void*)null;
                assert(!state.pureIslandAllowed());
                owner.allocator = Arena.init.allocator;
                owner.status = Status.outOfMemory;
                assert(!state.pureIslandAllowed());
                owner.status = Status.ok;
                state.status = Status.resourceLimit;
                assert(!state.pureIslandAllowed());
                state.status = Status.ok;
                static if (Check == 2) {
                    output.limit = 0;
                    assert(!state.pureIslandAllowed());
                    output.limit = size_t.max;
                    output.allocator = (size_t) @nogc nothrow => cast(void*)null;
                    assert(!state.pureIslandAllowed());
                    output.allocator = Arena.init.allocator;
                    output.status = Status.outOfMemory;
                    assert(!state.pureIslandAllowed());
                    output.status = Status.ok;
                }
                assert(state.pureIslandAllowed());
                version (NPeggedMetrics)
                    assert(metrics.pureIslandEntries > 0 && metrics.pureIslandFallbacks > 0);
            }
        }
    }

    version (NPeggedDependencyTrace) private Entry* currentMemo;
    private Entry* entries;
    private Entry*[] buckets;
    private size_t entryCount;
    static if (Check != 1)
        private string captureInput;
    static if (Check) {
        // Recognition only exposes the furthest offset. Saving lookahead state
        // must not copy unused begin/end/success fields on every probe.
        private struct FailureOffset {
            size_t failEnd;
        }

        private FailureOffset furthestFailure;
    } else
        private Node furthestFailure;
    private bool hasFailure;
    /// `accept` mode (Check 1): the caller wants a yes/no answer, so generated cursors may skip failure diagnostics.
    bool acceptOnly;
    private alias ParserIdentity = Node function(ref State!(CT, Check), size_t) nothrow;
    private struct Entry {
        version (NPeggedDependencyTrace) size_t traceID;
        ParserIdentity identity;
        size_t position, hash;
        Node seed;
        bool active, recursive, valid;
        static if (Check == 2) {
            RecordSnapshot output;
            bool suppressed;
        }
        Entry* next;
        Entry* bucketNext;
    }

    private static size_t keyHash(string key) @nogc nothrow pure {
        size_t hash = 2166136261;
        foreach (c; key)
            hash = (hash ^ cast(ubyte)c) * 16777619;
        return hash;
    }
    /// Local builder owns its capacity until its final snapshot is returned.
    struct Builder(T) {
        State* owner;
        T[] storage;
        size_t length;
        bool put(T[] values) nothrow {
            if (values.length > size_t.max - length) {
                owner.status = Status.resourceLimit;
                return false;
            }
            size_t required = length + values.length;
            if (required > storage.length) {
                size_t capacity = growthCapacity(storage.length, required, 4);
                auto replacement = owner.allocate!T(capacity);
                if (!replacement.length)
                    return false;
                replacement[0 .. length] = storage[0 .. length];
                storage = replacement;
            }
            storage[length .. required] = values[];
            length = required;
            return true;
        }

        T[] data() nothrow {
            return storage[0 .. length];
        }
    }

    /// Isolated tree execution preserves action-visible captures and memo seeds.
    Node treeFallback(alias parser)(size_t pos) nothrow {
        State!(CT, false) outputState;
        outputState.arena = arena;
        outputState.input = input;
        static if (Check != 1)
            outputState.captureInput = captureInput;
        outputState.context = context;
        outputState.steps = steps;
        outputState.depth = depth;
        outputState.status = status;
        auto result = parser(outputState, pos);
        steps = outputState.steps;
        depth = outputState.depth;
        status = outputState.status;
        input = outputState.input;
        context = outputState.context;
        if (outputState.hasFailure) {
            auto failed = node(outputState.furthestFailure.begin, outputState.furthestFailure.end, false);
            failed.failEnd = outputState.furthestFailure.failEnd;
            recordFailure(failed);
        }
        static if (Check == 2)
            if (result.successful && status == Status.ok)
                projectRecords(result);
        auto recognized = node(result.begin, result.end, result.successful);
        recognized.failEnd = result.failEnd;
        return recognized;
    }

    private void projectRecords(ParseTree tree) nothrow {
        static if (Check == 2) {
            if (records.suppressed || !tree.successful || !tick())
                return;
            if (depth >= context.depthLimit) {
                status = Status.resourceLimit;
                return;
            }
            ++depth;
            scope (exit)
                --depth;
            // defined() retains an inner node with the same public rule boundary.
            while (tree.children.length == 1 && tree.children[0].name == tree.name
                    && tree.children[0].begin == tree.begin && tree.children[0].end == tree.end) {
                if (!tick())
                    return;
                tree = tree.children[0];
            }
            const parent = records.parent;
            auto index = records.open(tree.name, tree.begin);
            syncOutput();
            scope (exit)
                records.parent = parent;
            foreach (child; tree.children)
                projectRecords(child);
            records.finishFresh(index, tree.end);
        }
    }

    static if (!Check) {
        /// Only root-owned, contiguous slices can replace a fused byte copy.
        private bool contiguousView(string[] matches, out string view) nothrow {
            static if (CT)
                if (__ctfe)
                    return false;
            bool started;
            size_t start, cursor;
            const base = cast(size_t)captureInput.ptr;
            foreach (match; matches) {
                if (!match.length)
                    continue;
                auto address = cast(size_t)match.ptr;
                if (address < base || address - base > captureInput.length)
                    return false;
                auto offset = address - base;
                if (match.length > captureInput.length - offset)
                    return false;
                if (!started) {
                    start = cursor = offset;
                    started = true;
                }
                if (offset != cursor)
                    return false;
                cursor += match.length;
            }
            view = started ? captureInput[start .. cursor] : null;
            return true;
        }

        private string retainCapture(string data) nothrow {
            static if (CT) {
                if (!__ctfe) {
                    if (ownsCapture(data))
                        return data;
                }
            } else if (ownsCapture(data))
                return data;
            auto bytes = allocate!char(data.length);
            if (bytes.length)
                bytes[] = data[];
            return cast(string)bytes;
        }

        private bool ownsCapture(string data) nothrow {
            auto address = cast(size_t)data.ptr;
            auto base = cast(size_t)captureInput.ptr;
            return address >= base && address - base <= captureInput.length
                && data.length <= captureInput.length - (address - base);
        }
    }

    T[] allocate(T)(size_t n) nothrow {
        static if (CT) {
            if (__ctfe)
                return new T[n];
        }
        auto data = arena.allocate!T(n);
        if (arena.status != Status.ok)
            status = arena.status;
        return data;
    }

    T[] append(T)(T[] a, T[] b) nothrow {
        if (!b.length)
            return a;
        if (a.length > size_t.max - b.length) {
            status = Status.resourceLimit;
            return null;
        }
        auto data = allocate!T(a.length + b.length);
        if (data.length) {
            data[0 .. a.length] = a[];
            data[a.length .. $] = b[];
        }
        return data;
    }

    T[] single(T)(T value) nothrow {
        static if (Check && (is(T == string) || is(T == ParseTree)))
            return null;
        auto data = allocate!T(1);
        if (data.length)
            data[0] = value;
        return data;
    }

    /// Work-unit model v2 (docs/WORK_UNITS.md): fine-grained nodes only observe the status; rule calls, repetition
    /// attempts and scanners count units with `tick`.
    pragma(inline, true) bool alive() const nothrow {
        return status == Status.ok;
    }

    pragma(inline, true) bool tick() nothrow {
        if (status != Status.ok)
            return false;
        if (steps >= context.stepLimit) {
            status = Status.resourceLimit;
            return false;
        }
        ++steps;
        return true;
    }

    pragma(inline, true) Node node(size_t start, size_t end, bool success = true) nothrow {
        Node result;
        static if (!Check)
            result.input = input;
        result.begin = start;
        result.end = end;
        result.failEnd = end;
        result.successful = success && status == Status.ok;
        return result;
    }

    Node failure(size_t pos, string expected) nothrow {
        auto result = node(pos, pos, false);
        static if (!Check)
            result.matches = single(expected);
        recordFailure(result);
        return result;
    }

    pragma(inline, true) void recordFailure(Node candidate) nothrow {
        static if (!Check)
            while (candidate.failedChild.length && tick())
                candidate = candidate.failedChild[0];
        if (candidate.end > candidate.failEnd)
            candidate.failEnd = candidate.end;
        if (!hasFailure || candidate.failEnd >= furthestFailure.failEnd) {
            static if (Check)
                furthestFailure.failEnd = candidate.failEnd;
            else
                furthestFailure = candidate;
            hasFailure = true;
        }
    }

    pragma(inline, true) Node finish(Node tree) nothrow {
        if (tree.end > tree.failEnd)
            tree.failEnd = tree.end;
        if (hasFailure && furthestFailure.failEnd >= tree.failEnd && (!tree.successful
                || furthestFailure.failEnd > tree.end)) {
            tree.failEnd = furthestFailure.failEnd;
            static if (!Check)
                tree.failedChild = single(furthestFailure);
        }
        return tree;
    }

    nothrow unittest {
        // No-failure entries still normalize end; remembered failures must not
        // erase a farther frontier or attach a child to an accepted prefix.
        State state;
        Arena owner;
        state.arena = &owner;
        auto accepted = state.node(0, 3);
        accepted.failEnd = 1;
        auto normalized = state.finish(accepted);
        assert(normalized.successful && normalized.end == 3 && normalized.failEnd == 3);
        auto failure = state.node(0, 2, false);
        state.recordFailure(failure);
        assert(state.finish(accepted).failEnd == 3);
        failure.end = failure.failEnd = 4;
        state.recordFailure(failure);
        auto merged = state.finish(accepted);
        assert(merged.successful && merged.end == 3 && merged.failEnd == 4);
        static if (!Check)
            assert(merged.failedChild.length == 1 && merged.failedChild[0].end == 4);
        accepted.successful = false;
        accepted.failEnd = 5;
        assert(state.finish(accepted).failEnd == 5);
        accepted.failEnd = 4;
        assert(state.finish(accepted).failEnd == 4);
    }

    size_t outputCheckpoint() const nothrow {
        static if (Check == 2)
            return records.length;
        else
            return 0;
    }

    void rollbackOutput(size_t checkpoint) nothrow {
        static if (Check == 2)
            records.rollback(checkpoint);
    }

    package(npegged) void syncOutput() nothrow {
        static if (Check == 2)
            if (status == Status.ok && records.status != Status.ok)
                status = records.status;
    }

    private RecordSnapshot snapshotOutput(size_t checkpoint) nothrow {
        static if (Check == 2) {
            version (NPeggedMetrics)
                if (context.metrics !is null) {
                    ++context.metrics.outputSnapshotCount;
                    version (NPeggedSharedOutput) {
                    } else
                        context.metrics.snapshotBytes += (records.length - checkpoint) * CompactNode.sizeof;
                }
            version (NPeggedSharedOutput) version (NPeggedMetrics) const copiedBefore = context.metrics is null
                ? 0 : context.metrics.output.snapshotBytes;
            auto result = records.snapshot(*arena, checkpoint);
            version (NPeggedSharedOutput) {
                version (NPeggedMetrics)
                    if (context.metrics !is null)
                        context.metrics.snapshotBytes += context.metrics.output.snapshotBytes - copiedBefore;
                if (records.sharingEnabled)
                    syncOutput();
            }
            if (arena.status != Status.ok)
                status = arena.status;
            return result;
        } else
            return RecordSnapshot.init;
    }

    private void restoreOutput(RecordSnapshot saved) nothrow {
        static if (Check == 2) {
            if (!records.suppressed)
                records.restore(saved);
            version (NPeggedFlatSpecialization) {
                if (records.sharingEnabled)
                    syncOutput();
            } else {
                syncOutput();
            }
        }
    }

    version (NPeggedMetrics) @nogc nothrow unittest {
        Arena owner, outputOwner;
        ParseMetrics metrics;
        RecordBuffer records;
        records.arena = &outputOwner;
        State!(false, 2) state;
        state.arena = &owner;
        state.context.metrics = &metrics;
        state.attachRecords(records);
        assert(records.put(CompactNode(1, 0, 1)) == 0);
        auto saved = state.snapshotOutput(0);
        state.rollbackOutput(0);
        state.restoreOutput(saved);
        assert(metrics.outputSnapshotCount == 1 && metrics.snapshotBytes == CompactNode.sizeof);
        assert(metrics.output.restoreCalls == 1 && metrics.output.restoreNodes == 1);
        assert(metrics.output.restoreBytes == CompactNode.sizeof && records.length == 1);
    }

    pragma(inline, true) private Node capturedRule(alias body, string name, bool memoize, long RecordKind)(size_t pos) nothrow {
        const checkpoint = records.length;
        const parent = records.parent;
        scope (exit)
            records.parent = parent;
        static if (RecordKind >= 0 && (RecordKind & (1L << 32))) {
            assert(records.selector(name) == cast(uint)RecordKind);
            static if (memoize)
                auto result = memoizedRule!(body, name)(pos);
            else
                auto result = ruleBody!(body, name)(pos);
            if (result.successful && status == Status.ok) {
                assert(records.length == checkpoint, "A compiled leaf emitted a selected descendant");
                auto index = records.openKind(cast(uint)RecordKind, pos);
                syncOutput();
                if (status == Status.ok)
                    records.finishFresh(index, result.end);
                else
                    records.rollback(checkpoint);
            } else
                records.rollback(checkpoint);
            return result;
        } else {
            static if (RecordKind == -1)
                const index = records.open(name, pos);
            else {
                assert(records.selector(name) == (RecordKind == -2 ? uint.max : cast(uint)RecordKind),
                        "Composed compact grammars must share their selector mapping");
                static if (RecordKind == -2)
                    const index = size_t.max;
                else
                    const index = records.openKind(cast(uint)RecordKind, pos);
            }
            syncOutput();
            static if (memoize)
                auto result = memoizedRule!(body, name)(pos);
            else
                auto result = ruleBody!(body, name)(pos);
            syncOutput();
            if (result.successful && status == Status.ok)
                records.finishFresh(index, result.end);
            else
                records.rollback(checkpoint);
            // Status controls public success; preserve a stored seed's recognition value.
            return result;
        }
    }

    pragma(inline, true) Node rule(alias body, string name, bool memoize = true, long RecordKind = -1)(size_t pos) nothrow
            if (!memoize) {
        static if (Check == 2 && RecordKind != -3)
            auto result = capturedRule!(body, name, false, RecordKind)(pos);
        else
            auto result = ruleBody!(body, name)(pos);
        version (NPeggedRuleMetrics)
            if (context.ruleReport !is null)
                context.ruleReport.record(name, result.successful);
        return result;
    }

    Node rule(alias body, string name, bool memoize = true, long RecordKind = -1)(size_t pos) nothrow
            if (memoize) {
        static if (Check == 2 && RecordKind != -3)
            auto result = capturedRule!(body, name, true, RecordKind)(pos);
        else
            auto result = memoizedRule!(body, name)(pos);
        version (NPeggedRuleMetrics) {
            if (context.ruleReport !is null)
                context.ruleReport.record(name, result.successful, memoHitPending);
            memoHitPending = false;
        }
        return result;
    }

    /// Inline non-memoized calls so tiny lexical rules do not pass nodes through stack frames.
    pragma(inline, true) private Node ruleBody(alias body, string name)(size_t pos) nothrow {
        if (!tick())
            return node(pos, pos, false);
        if (depth >= context.depthLimit) {
            status = Status.resourceLimit;
            return node(pos, pos, false);
        }
        // Direct cursors keep their own depth in a register and may leave `depth` stale: restore, never decrement.
        const savedDepth = depth;
        ++depth;
        auto candidate = body(this, pos);
        depth = savedDepth;
        static if (!Check)
            candidate.name = name;
        if (context.trace !is null)
            context.trace(name, pos, candidate.successful, context.userData);
        return candidate;
    }

    /// Prototype recursive ascent for action-free direct left recursion: E <- E Suffix / Base
    Node directLeftAscent(alias Base, alias Suffix, string name)(size_t pos) nothrow {
        if (!tick())
            return node(pos, pos, false);
        if (depth >= context.depthLimit) {
            status = Status.resourceLimit;
            return node(pos, pos, false);
        }
        const savedDepth = depth;
        ++depth;
        scope (exit)
            depth = savedDepth;

        auto current = Base(this, pos);
        if (!current.successful) {
            recordFailure(current);
            return current;
        }

        static if (!Check) {
            auto acc = node(pos, current.end, true);
            acc.name = name;
            acc.children = current.children.length ? current.children : single(current);
            acc.matches = current.matches;
            acc.failEnd = current.failEnd;
        } else {
            auto acc = current;
        }

        while (acc.end < input.length) {
            if (!tick())
                break;
            const stepPos = acc.end;
            auto tail = Suffix(this, stepPos);
            if (!tail.successful) {
                recordFailure(tail);
                if (tail.failEnd > acc.failEnd)
                    acc.failEnd = tail.failEnd;
                break;
            }
            if (tail.end <= stepPos)
                break;
            static if (!Check) {
                auto nextAcc = node(pos, tail.end, true);
                nextAcc.name = name;
                ParseTree[] stepChildren;
                if (tail.name.length)
                    stepChildren = append(single(acc), single(tail));
                else if (tail.children.length)
                    stepChildren = append(single(acc), tail.children);
                else
                    stepChildren = single(acc);
                nextAcc.children = stepChildren;
                nextAcc.matches = append(acc.matches, tail.matches);
                nextAcc.failEnd = tail.failEnd;
                acc = nextAcc;
            } else {
                acc.end = tail.end;
                acc.successful = true;
                acc.failEnd = tail.failEnd;
            }
        }

        return acc;
    }

    @nogc nothrow unittest {
        static if (!CT && !Check) {
            Arena owner;
            State state;
            state.arena = &owner;

            // 1. Successful ascent with anonymous literals
            state.input = "1+1+1";
            alias baseRule = literal!"1";
            alias suffixRule = and!(literal!"+", literal!"1");
            auto res = state.directLeftAscent!(baseRule, suffixRule, "Expr")(0);
            assert(res.successful && res.end == 5);
            assert(res.children.length == 1);
            assert(res.children[0].name == "Expr");
            assert(res.matches == ["1", "+", "1", "+", "1"]);

            // 2. Base with existing children
            alias baseWithChild = defined!(literal!"1", "Num");
            state.input = "1+1";
            auto resChildBase = state.directLeftAscent!(baseWithChild, suffixRule, "Expr")(0);
            assert(resChildBase.successful && resChildBase.end == 3);

            // 3. Suffix with named rule
            state.input = "1+1";
            alias namedSuffix = defined!(and!(literal!"+", literal!"1"), "Step");
            auto resNamed = state.directLeftAscent!(baseRule, namedSuffix, "Expr")(0);
            assert(resNamed.successful && resNamed.end == 3);
            assert(resNamed.children.length == 2);
            assert(resNamed.children[1].name == "Step");

            // 4. Suffix with children array without top-level name
            alias nestedSuffix = and!(literal!"+", defined!(literal!"1", "Item"));
            auto resNested = state.directLeftAscent!(baseRule, nestedSuffix, "Expr")(0);
            assert(resNested.successful && resNested.end == 3);

            // 5. Base failure
            state.input = "+1";
            auto resBaseFail = state.directLeftAscent!(baseRule, suffixRule, "Expr")(0);
            assert(!resBaseFail.successful && resBaseFail.end == 0);

            // 6. Suffix partial failure with higher failEnd
            state.input = "1+";
            auto resSuffixFail = state.directLeftAscent!(baseRule, suffixRule, "Expr")(0);
            assert(resSuffixFail.successful && resSuffixFail.end == 1 && resSuffixFail.failEnd == 2);

            // 7. Suffix partial failure with tail.failEnd <= acc.failEnd
            state.input = "1x";
            auto resSuffFailLow = state.directLeftAscent!(baseRule, suffixRule, "Expr")(0);
            assert(resSuffFailLow.successful && resSuffFailLow.end == 1 && resSuffFailLow.failEnd == 1);

            // 8. Zero-width suffix guard with remaining input
            state.input = "1remaining";
            alias zeroSuffix = eps;
            auto resZero = state.directLeftAscent!(baseRule, zeroSuffix, "Expr")(0);
            assert(resZero.successful && resZero.end == 1);

            // 9. Depth limit
            state.context.depthLimit = 0;
            auto resDepth = state.directLeftAscent!(baseRule, suffixRule, "Expr")(0);
            assert(!resDepth.successful && state.status == Status.resourceLimit);

            // 10. Step limit
            state.context.depthLimit = size_t.max;
            state.status = Status.ok;
            state.context.stepLimit = 0;
            auto resStep = state.directLeftAscent!(baseRule, suffixRule, "Expr")(0);
            assert(!resStep.successful && state.status == Status.resourceLimit);

            // 11. Step limit during loop
            state.status = Status.ok;
            state.context.stepLimit = 2;
            state.steps = 0;
            state.input = "1+1+1";
            auto resStepLoop = state.directLeftAscent!(baseRule, suffixRule, "Expr")(0);
            assert(resStepLoop.successful && resStepLoop.end < 5);
        } else static if (!CT && Check == 1) {
            State state;
            state.input = "1+1+1";
            alias baseRule = literal!"1";
            alias suffixRule = and!(literal!"+", literal!"1");
            auto res = state.directLeftAscent!(baseRule, suffixRule, "Expr")(0);
            assert(res.successful && res.end == 5);

            // Base fail in recognition
            state.input = "+1";
            auto resFail = state.directLeftAscent!(baseRule, suffixRule, "Expr")(0);
            assert(!resFail.successful);

            // Suffix fail in recognition (higher failEnd)
            state.input = "1+";
            auto resSuffFail = state.directLeftAscent!(baseRule, suffixRule, "Expr")(0);
            assert(resSuffFail.successful && resSuffFail.end == 1);

            // Suffix fail in recognition (low failEnd)
            state.input = "1x";
            auto resSuffFailLow = state.directLeftAscent!(baseRule, suffixRule, "Expr")(0);
            assert(resSuffFailLow.successful && resSuffFailLow.end == 1);

            // Zero-width suffix in recognition with remaining input
            state.input = "1remaining";
            alias zeroSuffix = eps;
            auto resZero = state.directLeftAscent!(baseRule, zeroSuffix, "Expr")(0);
            assert(resZero.successful && resZero.end == 1);
        }
    }

    static if (Check == 1 || Check == 2) {
        /// A value checkpoint for recognition predicates; no output or ownership escapes.
        struct FailureCheckpoint {
            size_t failEnd;
            bool present;
            static if (Check == 2) {
                size_t recordLength;
                bool suppressed;
            }
        }

        FailureCheckpoint checkpointFailure() const @nogc nothrow {
            static assert(Check == 1 || Check == 2);
            return FailureCheckpoint(furthestFailure.failEnd, hasFailure);
        }

        @nogc nothrow unittest {
            static if (!CT && Check == 1) {
                State state;
                assert(!state.checkpointFailure().present);
                state.recordFailure(state.node(0, 3, false));
                auto saved = state.checkpointFailure();
                assert(saved.present && saved.failEnd == 3);
            }
        }

        /// Restore the outer diagnostic scope and return the nested predicate failure.
        FailureCheckpoint restoreFailure(FailureCheckpoint saved) @nogc nothrow {
            static assert(Check == 1 || Check == 2);
            auto nested = checkpointFailure();
            furthestFailure.failEnd = saved.failEnd;
            hasFailure = saved.present;
            return nested;
        }

        @nogc nothrow unittest {
            static if (!CT && Check == 1) {
                State state;
                auto saved = state.checkpointFailure();
                state.recordFailure(state.node(0, 4, false));
                auto nested = state.restoreFailure(saved);
                assert(nested.present && nested.failEnd == 4);
                assert(!state.checkpointFailure().present);
                assert(!state.restoreFailure(nested).present);
                assert(state.checkpointFailure().failEnd == 4);
            }
        }

        /// Suppress speculative records while retaining the outer diagnostic scope.
        pragma(inline, true) FailureCheckpoint beginProbe() @nogc nothrow {
            auto saved = checkpointFailure();
            static if (Check == 2) {
                saved.recordLength = records.length;
                saved.suppressed = records.suppressed;
                records.suppressed = true;
            }
            return saved;
        }

        @nogc nothrow unittest {
            static if (!CT && Check == 1) {
                State state;
                assert(!state.beginProbe().present);
            }
        }

        /// End a predicate, discarding its output and restoring diagnostics.
        pragma(inline, true) FailureCheckpoint finishProbe(FailureCheckpoint saved) @nogc nothrow {
            auto nested = restoreFailure(saved);
            static if (Check == 2) {
                records.rollback(saved.recordLength);
                records.suppressed = saved.suppressed;
            }
            return nested;
        }

        @nogc nothrow unittest {
            static if (!CT && Check == 1) {
                State state;
                auto saved = state.beginProbe();
                state.recordFailure(state.node(0, 4, false));
                assert(state.finishProbe(saved).failEnd == 4);
                assert(!state.checkpointFailure().present);
            } else static if (!CT && Check == 2) {
                Arena owner;
                RecordBuffer output;
                output.arena = &owner;
                State state;
                state.attachRecords(output);
                const root = output.openKind(1, 0);
                const length = output.length;
                auto saved = state.beginProbe();
                assert(output.openKind(2, 1) == size_t.max && output.length == length);
                auto inner = state.beginProbe();
                state.finishProbe(inner);
                assert(output.suppressed);
                state.recordFailure(state.node(0, 4, false));
                assert(state.finishProbe(saved).failEnd == 4);
                assert(!output.suppressed && output.length == length && output.parent == root);
            }
        }

    }

    /// `recognizeRule` for callers that already took the work unit from their own register-resident counter:
    /// generated cursors tick locally, then synchronize `steps` and call this. Everything else is identical.
    pragma(inline, true) bool recognizeRuleTicked(alias body, string name, bool Trace = true)(ref size_t end,
            ref size_t failEnd) nothrow {
        static assert(Check == 1 || Check == 2);
        const pos = end;
        if (depth >= context.depthLimit) {
            status = Status.resourceLimit;
            failEnd = pos;
            return false;
        }
        const savedDepth = depth;
        ++depth;
        const successful = body(this, end, failEnd, depth);
        depth = savedDepth;
        static if (Trace)
            if (context.trace !is null)
                context.trace(name, pos, successful, context.userData);
        return successful;
    }

    /// Recognition rule boundary with scalar results; memoized rules keep Node seeds.
    pragma(inline, true) bool recognizeRule(alias body, string name, bool Trace = true)(ref size_t end,
            ref size_t failEnd) nothrow {
        static assert(Check == 1 || Check == 2);
        const pos = end;
        if (!tick()) {
            failEnd = pos;
            return false;
        }
        if (depth >= context.depthLimit) {
            status = Status.resourceLimit;
            failEnd = pos;
            return false;
        }
        const savedDepth = depth;
        ++depth;
        const successful = body(this, end, failEnd, depth);
        depth = savedDepth;
        version (NPeggedRuleMetrics)
            if (context.ruleReport !is null)
                context.ruleReport.record(name, successful);
        static if (Trace)
            if (context.trace !is null)
                context.trace(name, pos, successful, context.userData);
        return successful;
    }

    @nogc nothrow unittest {
        static if (!CT && Check == 1) {
            static bool advance(ref State state, ref size_t end, ref size_t failure, size_t depth) @nogc nothrow {
                ++end;
                failure = end;
                return true;
            }

            static void trace(string name, size_t pos, bool success, void* data) @nogc nothrow {
                assert(name == "test" && pos == 0 && success);
                ++*cast(size_t*)data;
            }

            State state;
            size_t end, failure, calls;
            state.context.trace = &trace;
            state.context.userData = &calls;
            assert(state.recognizeRule!(advance, "test")(end, failure));
            assert(end == 1 && failure == 1 && state.depth == 0 && calls == 1);
            // Cursors keep depth in a register and may leave `depth` stale: the boundary must restore, not decrement.
            static bool leavesStaleDepth(ref State s, ref size_t at, ref size_t fail, size_t depth) @nogc nothrow {
                assert(depth == s.depth);
                s.depth = 99;
                ++at;
                fail = at;
                return true;
            }

            end = failure = 0;
            state.context.trace = null;
            const before = state.depth;
            assert(state.recognizeRule!(leavesStaleDepth, "stale")(end, failure) && state.depth == before);
            end = failure = 0;
            state.steps = 0;
            assert(state.recognizeRuleTicked!(leavesStaleDepth, "stale", false)(end, failure) && state.depth == before);
            state.context.trace = &trace;
            state.context.userData = &calls;
            end = failure = 0;
            state.context.depthLimit = 0;
            assert(!state.recognizeRule!(advance, "test")(end, failure));
            assert(state.status == Status.resourceLimit && end == 0 && failure == 0);
            assert(!state.recognizeRule!(advance, "test")(end, failure));
            state.status = Status.ok;
            state.context.stepLimit = 0;
            assert(!state.recognizeRule!(advance, "test")(end, failure));
        }
    }

    /// Non-memoized compact rule entry with scalar recognition and transactional capture.
    pragma(inline, true) bool recognizeRecordedRule(alias body, string name, long RecordKind = -1, bool Ticked = false)(
            ref size_t end, ref size_t failEnd) nothrow {
        static assert(Check == 2);
        // `Ticked`: the caller already took the rule's work unit from its register counter (see recognizeRuleTicked).
        static if (Ticked)
            alias boundary = recognizeRuleTicked!(body, name, false);
        else
            alias boundary = recognizeRule!(body, name, false);
        static if (RecordKind == -3)
            return boundary(end, failEnd);
        else static if (RecordKind == -2) {
            // No record of its own: nothing to open or finish, and the descendants restore the parent themselves.
            const checkpoint = records.length;
            const successful = boundary(end, failEnd);
            syncOutput();
            if (!successful || status != Status.ok)
                records.rollback(checkpoint);
            return successful;
        } else {
            const pos = end;
            const checkpoint = records.length;
            const parent = records.parent;
            scope (exit)
                records.parent = parent;
            static if (RecordKind >= 0 && (RecordKind & (1L << 32))) {
                assert(records.selector(name) == cast(uint)RecordKind);
                const successful = boundary(end, failEnd);
                if (successful && status == Status.ok) {
                    assert(records.length == checkpoint, "A compiled leaf emitted a selected descendant");
                    records.putLeaf(cast(uint)RecordKind, pos, end);
                    syncOutput();
                    if (status != Status.ok)
                        records.rollback(checkpoint);
                } else
                    records.rollback(checkpoint);
                return successful;
            } else {
                static if (RecordKind == -1)
                    const index = records.open(name, pos);
                else {
                    assert(records.selector(name) == (RecordKind == -2 ? uint.max : cast(uint)RecordKind));
                    static if (RecordKind == -2)
                        const index = size_t.max;
                    else
                        const index = records.openKind(cast(uint)RecordKind, pos);
                }
                syncOutput();
                const successful = boundary(end, failEnd);
                syncOutput();
                if (successful && status == Status.ok)
                    records.finishFresh(index, end);
                else
                    records.rollback(checkpoint);
                return successful;
            }
        }
    }

    @nogc nothrow unittest {
        static if (!CT && Check == 2) {
            static bool advance(ref State state, ref size_t end, ref size_t failure, size_t depth) @nogc nothrow {
                ++end;
                failure = end;
                return true;
            }

            static uint select(string name) @nogc nothrow pure {
                return name == "leaf" ? 7 : uint.max;
            }

            Arena owner;
            RecordBuffer output;
            output.arena = &owner;
            output.selector = &select;
            State state;
            state.attachRecords(output);
            state.input = "abcd";
            size_t end, failure;
            assert(state.recognizeRecordedRule!(advance, "leaf", (1L << 32) | 7)(end, failure));
            assert(output.nodes.length == 1 && output.nodes[0] == CompactNode(7, 0, 1, size_t.max));
            assert(state.recognizeRecordedRule!(advance, "skip", -2)(end, failure));
            assert(state.recognizeRecordedRule!(advance, "leaf")(end, failure));
            assert(state.recognizeRecordedRule!(advance, "skip", -3)(end, failure));
            assert(output.nodes.length == 2 && output.parent == size_t.max && state.depth == 0);
            Arena exhausted;
            exhausted.limit = 0;
            RecordBuffer limited;
            limited.arena = &exhausted;
            limited.selector = &select;
            state.attachRecords(limited);
            end = failure = 0;
            assert(state.recognizeRecordedRule!(advance, "leaf", (1L << 32) | 7)(end, failure));
            assert(state.status == Status.resourceLimit && limited.nodes.length == 0);
            assert(!state.recognizeRecordedRule!(advance, "leaf", 7)(end, failure));

            // A rule without a record of its own rolls back what its body emitted when it fails, and the
            // `Ticked` entry (work unit taken by the caller) is the same transaction without its own tick.
            static bool emitThenFail(ref State inner, ref size_t at, ref size_t fail, size_t depth) @nogc nothrow {
                inner.records.put(CompactNode(9, at, at + 1, inner.records.parent));
                fail = at + 1;
                return false;
            }

            static bool emitThenAdvance(ref State inner, ref size_t at, ref size_t fail, size_t depth) @nogc nothrow {
                inner.records.put(CompactNode(9, at, at + 1, inner.records.parent));
                ++at;
                fail = at;
                return true;
            }

            Arena roomy;
            RecordBuffer wide;
            wide.arena = &roomy;
            wide.selector = &select;
            State second;
            second.attachRecords(wide);
            second.input = "abcd";
            end = failure = 0;
            assert(!second.recognizeRecordedRule!(emitThenFail, "skip", -2)(end, failure));
            assert(wide.nodes.length == 0 && wide.parent == size_t.max);
            assert(second.recognizeRecordedRule!(emitThenAdvance, "skip", -2)(end, failure));
            assert(wide.nodes.length == 1 && end == 1);
            end = failure = 0;
            const before = second.steps;
            assert(second.recognizeRecordedRule!(advance, "skip", -2, true)(end, failure));
            assert(second.steps == before && end == 1);
            assert(second.recognizeRecordedRule!(advance, "leaf", (1L << 32) | 7, true)(end, failure));
            assert(second.steps == before && wide.nodes.length == 2 && end == 2);
            second.context.stepLimit = 0;
            end = failure = 0;
            assert(!second.recognizeRecordedRule!(advance, "skip", -2)(end, failure));
            assert(second.status == Status.resourceLimit && wide.nodes.length == 2);
        }
    }

    version (NPeggedDependencyTrace) private void traceMemo(MemoTraceKind kind, Entry* entry, string rule = "") @nogc nothrow {
        auto trace = context.memoTrace;
        if (trace is null)
            return;
        if (entry.traceID == 0) {
            trace.truncated = true; // Tracing enabled after entries were already created.
            return;
        }
        trace.record(MemoTraceEvent(kind, currentMemo is null ? 0 : currentMemo.traceID, entry.traceID,
                entry.position, entry.seed.end, entry.seed.successful, rule));
    }

    version (NPeggedDependencyTrace) @nogc nothrow unittest {
        State!(false, 1) state;
        typeof(state).Entry entry, caller;
        state.traceMemo(MemoTraceKind.created, &entry);
        MemoTraceEvent[4] storage;
        MemoTrace trace = MemoTrace(storage[]);
        state.context.memoTrace = &trace;
        state.traceMemo(MemoTraceKind.created, &entry);
        assert(trace.truncated && trace.events.length == 0);
        MemoTrace valid = MemoTrace(storage[]);
        state.context.memoTrace = &valid;
        entry.traceID = 7;
        entry.position = 3;
        caller.traceID = 5;
        state.currentMemo = &caller;
        state.traceMemo(MemoTraceKind.activeHit, &entry, "leaf");
        assert(!valid.truncated && valid.events.length == 1);
        auto event = valid.events[0];
        assert(event.caller == 5 && event.entry == 7 && event.position == 3 && event.rule == "leaf");
    }

    // Retired entries stay arena-owned, but must not be revisited by later
    // seed growth or hash lookup. Active seeds remain reachable.
    // Only entries at `pos` can have read the seed that just grew: rules are applied at or after the
    // current position, so an entry at a later position never saw an entry at `pos`. Entries created
    // since the last growth sit in front of `until` in the list, so the walk stops there.
    private void invalidateMemo(size_t pos, Entry* until) nothrow {
        Entry* previous;
        auto current = entries;
        while (current !is null && current !is until) {
            auto next = current.next;
            version (NPeggedMetrics)
                if (context.metrics !is null)
                    ++context.metrics.invalidationVisits;
            if (!current.active && current.position == pos) {
                version (NPeggedDependencyTrace)
                    traceMemo(MemoTraceKind.retired, current);
                version (NPeggedMetrics)
                    if (context.metrics !is null)
                        ++context.metrics.invalidatedEntries;
                current.valid = false;
                auto link = &buckets[current.hash & (buckets.length - 1)];
                while (true) {
                    version (NPeggedMetrics)
                        if (context.metrics !is null)
                            ++context.metrics.memoUnlinkVisits;
                    if (*link is current)
                        break;
                    link = &(*link).bucketNext;
                }
                *link = current.bucketNext;
                --entryCount;
                if (previous is null)
                    entries = next;
                else
                    previous.next = next;
            } else
                previous = current;
            current = next;
        }
    }

    @nogc nothrow unittest {
        Arena owner;
        State!(false, 1) state;
        state.arena = &owner;
        version (NPeggedMetrics) {
            ParseMetrics metrics;
            state.context.metrics = &metrics;
        }
        auto nodes = state.allocate!(typeof(state).Entry)(5);
        assert(nodes.length == 5);
        foreach (i, ref entry; nodes) {
            entry.valid = true;
            entry.position = i;
            entry.next = i + 1 < nodes.length ? &nodes[i + 1] : null;
        }
        state.buckets = state.allocate!(typeof(state).Entry*)(1);
        state.buckets[0] = &nodes[0];
        foreach (i, ref entry; nodes)
            entry.bucketNext = i + 1 < nodes.length ? &nodes[i + 1] : null;
        nodes[2].active = true;
        state.entries = &nodes[0];
        state.entryCount = nodes.length;
        state.invalidateMemo(3, &nodes[4]);
        assert(state.entryCount == 4 && !nodes[3].valid && nodes[4].valid);
        assert(nodes[2].next == &nodes[4] && nodes[2].bucketNext == &nodes[4]);
        state.invalidateMemo(2, null);
        assert(state.entryCount == 4 && nodes[2].valid);
        nodes[2].active = false;
        state.invalidateMemo(2, null);
        assert(state.entryCount == 3 && !nodes[2].valid && nodes[1].next == &nodes[4]);
        state.invalidateMemo(0, null);
        state.invalidateMemo(1, null);
        assert(state.entries == &nodes[4] && state.entryCount == 1);
        state.invalidateMemo(4, null);
        assert(state.entries is null && state.entryCount == 0 && state.buckets[0] is null);
        version (NPeggedMetrics) {
            assert(metrics.invalidationVisits == 18 && metrics.invalidatedEntries == 5);
            assert(metrics.memoUnlinkVisits == 10);
        }
    }

    /// Seed growth, with dependent memo entries invalidated whenever a seed grows.
    private Node memoizedRule(alias body, string name)(size_t pos) nothrow {
        version (NPeggedMetrics)
            if (context.metrics !is null)
                ++context.metrics.memoCalls;
        if (!tick())
            return node(pos, pos, false);
        enum baseHash = keyHash(body.mangleof);
        size_t hash = baseHash ^ (pos * cast(size_t)0x9E3779B1);
        const outputBase = outputCheckpoint();
        if (!buckets.length || entryCount > buckets.length * 3 / 4) {
            auto replacement = allocate!(Entry*)(buckets.length ? buckets.length * 2 : 64);
            if (!replacement.length)
                return node(pos, pos, false);
            version (NPeggedMetrics)
                if (context.metrics !is null)
                    ++context.metrics.memoRehashes;
            entryCount = 0;
            for (auto existing = entries; existing !is null; existing = existing.next) {
                if (!existing.valid)
                    continue;
                version (NPeggedMetrics)
                    if (context.metrics !is null)
                        ++context.metrics.memoRehashedEntries;
                auto slot = existing.hash & (replacement.length - 1);
                existing.bucketNext = replacement[slot];
                replacement[slot] = existing;
                ++entryCount;
            }
            buckets = replacement;
        }
        auto slot = hash & (buckets.length - 1);
        for (auto entry = buckets[slot]; entry !is null; entry = entry.bucketNext) {
            version (NPeggedMetrics)
                if (context.metrics !is null)
                    ++context.metrics.memoBucketVisits;
            if (entry.valid && entry.identity == &body && entry.position == pos) {
                static if (Check == 2)
                    if (!entry.active && entry.suppressed != records.suppressed)
                        continue;
                static if (CT) {
                    if (__ctfe)
                        assert(!entry.active, "Left-recursive input parsing is supported only at runtime");
                }
                version (NPeggedMetrics)
                    if (context.metrics !is null)
                        ++context.metrics.memoHits;
                version (NPeggedRuleMetrics)
                    memoHitPending = true;
                version (NPeggedDependencyTrace)
                    traceMemo(entry.active ? MemoTraceKind.activeHit : MemoTraceKind.cachedHit, entry);
                if (entry.active)
                    entry.recursive = true;
                else if (!entry.seed.successful)
                    recordFailure(entry.seed);
                static if (Check == 2)
                    restoreOutput(entry.output);
                return entry.seed;
            }
        }
        if (depth >= context.depthLimit) {
            status = Status.resourceLimit;
            return node(pos, pos, false);
        }
        auto storage = allocate!Entry(1);
        if (!storage.length)
            return node(pos, pos, false);
        auto entry = &storage[0];
        entry.identity = &body;
        static if (Check == 2)
            entry.suppressed = records.suppressed;
        entry.hash = hash;
        entry.valid = true;
        entry.bucketNext = buckets[slot];
        buckets[slot] = entry;
        ++entryCount;
        entry.position = pos;
        entry.seed = node(pos, pos, false);
        entry.active = true;
        entry.next = entries;
        entries = entry;
        version (NPeggedDependencyTrace) {
            auto previousMemo = currentMemo;
            if (context.memoTrace !is null) {
                entry.traceID = context.memoTrace.issueID();
                traceMemo(MemoTraceKind.created, entry, name);
            }
            currentMemo = entry;
        }
        version (NPeggedDependencyTrace)
            scope (exit)
                currentMemo = previousMemo;
        const savedDepth = depth;
        ++depth;
        scope (exit)
            depth = savedDepth;
        // Entries older than `mark` were either invalidated after an earlier iteration or cannot have read this seed.
        auto mark = entry;
        do {
            version (NPeggedDependencyTrace)
                traceMemo(MemoTraceKind.iteration, entry);
            rollbackOutput(outputBase);
            auto candidate = body(this, pos);
            static if (!Check)
                candidate.name = name;
            if (!candidate.successful || (entry.seed.successful && candidate.end <= entry.seed.end)) {
                if (!entry.seed.successful)
                    entry.seed = candidate;
                break;
            }
            version (NPeggedMetrics)
                if (context.metrics !is null)
                    ++context.metrics.seedGrowths;
            entry.seed = candidate;
            version (NPeggedDependencyTrace)
                traceMemo(MemoTraceKind.growth, entry);
            static if (Check == 2)
                entry.output = snapshotOutput(outputBase);
            if (!entry.recursive)
                break;
            invalidateMemo(pos, mark);
            mark = entries;
        }
        while (tick());
        rollbackOutput(outputBase);
        static if (Check == 2)
            restoreOutput(entry.output);
        entry.active = false;
        version (NPeggedDependencyTrace) {
            traceMemo(MemoTraceKind.completed, entry);
            currentMemo = previousMemo;
        }
        if (context.trace !is null)
            context.trace(name, pos, entry.seed.successful, context.userData);
        return entry.seed;
    }

    version (NPeggedDependencyTrace) @nogc nothrow unittest {
        static RecognitionNode body(ref State!(false, 1) state, size_t pos) @nogc nothrow {
            return state.node(pos, pos + 1, true);
        }

        MemoTraceEvent[32] events;
        MemoTrace trace = MemoTrace(events[]);
        Arena owner;
        State!(false, 1) state;
        state.arena = &owner;
        state.context.memoTrace = &trace;
        assert(state.memoizedRule!(body, "leaf")(0).successful);
        assert(state.memoizedRule!(body, "leaf")(0).successful);
        assert(trace.events.length == 5 && !trace.truncated);
        assert(trace.events[0].kind == MemoTraceKind.created && trace.events[0].entry == 1);
        assert(trace.events[0].caller == 0 && trace.events[0].rule == "leaf");
        assert(trace.events[1].kind == MemoTraceKind.iteration);
        assert(trace.events[2].kind == MemoTraceKind.growth);
        assert(trace.events[3].kind == MemoTraceKind.completed);
        assert(trace.events[4].kind == MemoTraceKind.cachedHit && trace.events[4].entry == 1);
        assert(state.currentMemo is null);
        MemoTraceEvent[1] shortStorage;
        MemoTrace shortTrace = MemoTrace(shortStorage[]);
        State!(false, 1) limited;
        limited.arena = &owner;
        limited.context.memoTrace = &shortTrace;
        assert(limited.memoizedRule!(body, "leaf")(0).successful);
        assert(shortTrace.truncated && shortTrace.events.length == 1 && limited.status == Status.ok);
        state.context.memoTrace = &shortTrace;
        assert(state.memoizedRule!(body, "leaf")(0).successful);
        state.context.memoTrace = null;
        assert(state.memoizedRule!(body, "leaf")(0).successful);
    }

    version (NPeggedMetrics) @nogc nothrow unittest {
        static RecognitionNode body(ref State!(false, 1) state, size_t pos) @nogc nothrow {
            return state.node(pos, pos + 1, true);
        }

        Arena owner;
        ParseMetrics metrics;
        State!(false, 1) state;
        state.arena = &owner;
        state.context.metrics = &metrics;
        assert(state.memoizedRule!(body, "metric")(0).successful);
        assert(state.memoizedRule!(body, "metric")(0).successful);
        assert(metrics.memoCalls == 2 && metrics.memoHits == 1 && metrics.seedGrowths == 1);
        assert(metrics.memoBucketVisits == 1 && metrics.memoRehashes == 1 && metrics.memoRehashedEntries == 0);
        state.entryCount = 49; // Force the same rehash boundary without unrelated parser work.
        assert(state.memoizedRule!(body, "metric")(0).successful);
        assert(metrics.memoCalls == 3 && metrics.memoHits == 2 && metrics.seedGrowths == 1);
        assert(metrics.memoBucketVisits == 2 && metrics.memoRehashes == 2 && metrics.memoRehashedEntries == 1);
        assert(metrics.snapshotBytes == 0 && metrics.outputSnapshotCount == 0);
    }

}

/// Bounded phrase cache for ordinary (non-left-recursive) rules.
/// Separated from mandatory recursion state and seed-growth tables.
struct PhraseCache(size_t Capacity = 1) {
    static assert(Capacity == 0 || Capacity == 1 || Capacity == 2 || Capacity == 4 || Capacity == 8,
            "PhraseCache capacity must be 0, 1, 2, 4, or 8");

    static if (Capacity == 0) {
        ulong lookups, hits, stores, evictions;

        void clear() @nogc nothrow pure {
        }

        bool lookup(size_t pos, out size_t end, out size_t fail, out bool ok) @nogc nothrow {
            ++lookups;
            return false;
        }

        void store(size_t pos, size_t end, size_t fail, bool ok) @nogc nothrow {
            ++stores;
        }
    } else static if (Capacity == 1) {
        ulong lookups, hits, stores, evictions;
        private size_t _pos = size_t.max;
        private size_t _end;
        private size_t _fail;
        private bool _ok;
        private bool _valid;

        void clear() @nogc nothrow pure {
            _valid = false;
            _pos = size_t.max;
        }

        bool lookup(size_t pos, out size_t end, out size_t fail, out bool ok) @nogc nothrow {
            ++lookups;
            if (_valid && _pos == pos) {
                ++hits;
                end = _end;
                fail = _fail;
                ok = _ok;
                return true;
            }
            return false;
        }

        void store(size_t pos, size_t end, size_t fail, bool ok) @nogc nothrow {
            ++stores;
            if (_valid && _pos != pos)
                ++evictions;
            _pos = pos;
            _end = end;
            _fail = fail;
            _ok = ok;
            _valid = true;
        }
    } else {
        ulong lookups, hits, stores, evictions;

        static struct Entry {
            size_t pos = size_t.max;
            size_t end;
            size_t fail;
            bool ok;
            bool valid;
        }

        private Entry[Capacity] _slots;
        private size_t _cursor;

        void clear() @nogc nothrow pure {
            _cursor = 0;
            foreach (ref e; _slots) {
                e.valid = false;
                e.pos = size_t.max;
            }
        }

        bool lookup(size_t pos, out size_t end, out size_t fail, out bool ok) @nogc nothrow {
            ++lookups;
            foreach (ref e; _slots) {
                if (e.valid && e.pos == pos) {
                    ++hits;
                    end = e.end;
                    fail = e.fail;
                    ok = e.ok;
                    return true;
                }
            }
            return false;
        }

        void store(size_t pos, size_t end, size_t fail, bool ok) @nogc nothrow {
            ++stores;
            foreach (ref e; _slots) {
                if (e.valid && e.pos == pos) {
                    e.end = end;
                    e.fail = fail;
                    e.ok = ok;
                    return;
                }
            }
            size_t target = size_t.max;
            foreach (i, ref e; _slots) {
                if (!e.valid) {
                    target = i;
                    break;
                }
            }
            if (target == size_t.max) {
                target = _cursor;
                _cursor = (_cursor + 1) & (Capacity - 1);
                ++evictions;
            }
            _slots[target].pos = pos;
            _slots[target].end = end;
            _slots[target].fail = fail;
            _slots[target].ok = ok;
            _slots[target].valid = true;
        }
    }
}

@nogc nothrow unittest {
    static foreach (C; [0, 1, 2, 4, 8]) {
        {
            PhraseCache!C cache;
            size_t end, fail;
            bool ok;
            assert(!cache.lookup(0, end, fail, ok));
            cache.store(0, 10, 0, true);
            static if (C > 0) {
                assert(cache.lookup(0, end, fail, ok));
                assert(end == 10 && ok);
                assert(cache.hits == 1);
                // Miss on different pos
                assert(!cache.lookup(5, end, fail, ok));
                // Eviction / replacement test
                cache.store(C > 1 ? C : 1, 20, 0, true);
                assert(cache.stores == 2);
            } else {
                assert(!cache.lookup(0, end, fail, ok));
                assert(cache.hits == 0);
            }
            cache.clear();
            assert(!cache.lookup(0, end, fail, ok));
        }
    }
}

@nogc nothrow unittest {
    Arena arena;
    State!false state;
    state.arena = &arena;
    state.input = "abc";
    auto data = state.single(42);
    assert(data == [42]);
    assert(state.append(data, data) == [42, 42]);
    assert(state.append(data, cast(int[])null) == [42]);
    assert(state.failure(1, "x").matches == ["x"]);
    state.context.stepLimit = 0;
    assert(!state.tick());
    assert(state.status == Status.resourceLimit);

    assert(State!false.keyHash("") == 2166136261);

    state.status = Status.ok;
    State!false.Builder!int b = {owner: &state, length: size_t.max};
    int[1] val = [1];
    assert(!b.put(val[]));
    assert(state.status == Status.resourceLimit);

    state.status = Status.ok;
    state.captureInput = "abc";
    assert(state.ownsCapture(state.captureInput[0 .. 2]));
    assert(!state.ownsCapture("foreign"));
    assert(!state.ownsCapture(state.captureInput.ptr[0 .. 100]));
    assert(state.retainCapture(state.captureInput[0 .. 1]) == "a");
    assert(state.retainCapture("foreign") == "foreign");

    string view;
    string[1] foreignArr = ["foreign"];
    assert(!state.contiguousView(foreignArr[], view));
    string[2] mixedArr = ["", state.captureInput[0 .. 1]];
    assert(state.contiguousView(mixedArr[], view));
    assert(view == "a");

    int[1] arr = [1];
    assert(state.append(arr.ptr[0 .. size_t.max], arr[]) is null);
}

ParseResult parse(alias parser)(ref ParseContext context, scope string input) @nogc nothrow {
    ParseResult result;
    result.arena.limit = context.memoryLimit;
    auto owned = result.arena.copy!char(input);
    if (result.arena.status != Status.ok) {
        result.status = result.arena.status;
        return result;
    }
    State!false state;
    state.arena = &result.arena;
    state.context = context;
    state.input = cast(string)owned;
    state.captureInput = state.input;
    result.tree = state.finish(parser(state, 0));
    result.status = state.status != Status.ok ? state.status : (result.tree.successful ? Status.ok : Status.mismatch);
    if (state.status != Status.ok)
        result.tree.successful = false;
    return result;
}

/// Synchronous recognition borrows input only for the duration of this call.
/// Memo storage and conservative action fallbacks remain owned by this result.
struct CheckResult {
    Arena arena;
    Status status = Status.invalidInput;
    bool successful;
    size_t end, failEnd;
    @disable this(this);
    @disable this(ref CheckResult);
}

version (NPeggedPureIslands) private template pureIslandEntry(alias parser, bool Records = false) {
    private bool detect() @nogc nothrow pure {
        static if (is(parser == struct)) {
            alias Owner = parser;
            enum name = "opCall";
        } else {
            alias Owner = __traits(parent, parser);
            enum name = __traits(identifier, parser);
        }
        enum marker = Records ? "npeggedPureIslandRecordEntries" : "npeggedPureIslandEntries";
        static if (__traits(hasMember, Owner, marker))
            static foreach (entry; __traits(getMember, Owner, marker))
                static if (entry == name)
                    return true;
        return false;
    }

    enum pureIslandEntry = detect();
}

version (NPeggedPureIslands) private bool pureIslandProjection(alias parser, alias selector)() @nogc nothrow pure {
    static if (pureIslandEntry!(parser, true)) {
        static if (is(parser == struct))
            alias Owner = parser;
        else
            alias Owner = __traits(parent, parser);
        if (selector("") != uint.max)
            return false;
        static foreach (i, name; Owner.compactRuleNames)
            if (selector(name) != Owner.compactRuleKinds[i])
                return false;
        return true;
    } else
        return false;
}

version (NPeggedPureIslands) @nogc nothrow unittest {
    struct Proof {
        enum string[] npeggedPureIslandRecordEntries = ["entry"];
        enum string[] compactRuleNames = ["Proof.entry"];
        enum uint[] compactRuleKinds = [1];
        static RecognitionNode entry(ref State!(false, 2) state, size_t pos) @nogc nothrow {
            return RecognitionNode(pos, pos, pos, true);
        }
    }

    static uint matching(string name) @nogc nothrow pure {
        return name.length ? 1 : uint.max;
    }

    static uint anonymous(string name) @nogc nothrow pure {
        return 1;
    }

    static uint different(string name) @nogc nothrow pure {
        return name.length ? 2 : uint.max;
    }

    assert(pureIslandProjection!(Proof.entry, matching)());
    assert(!pureIslandProjection!(Proof.entry, anonymous)());
    assert(!pureIslandProjection!(Proof.entry, different)());
    assert(!pureIslandProjection!(literal!"x", matching)());
}

pragma(inline, true) CheckResult check(alias parser)(ref ParseContext context, scope string input) @nogc nothrow {
    CheckResult result;
    static if (is(parser == struct)) {
        alias EntryOwner = parser;
        enum entryName = "opCall";
    } else {
        alias EntryOwner = __traits(parent, parser);
        enum entryName = __traits(identifier, parser);
    }
    static if (__traits(compiles, EntryOwner.npeggedTryCheck!entryName(context, input, result)))
        if (EntryOwner.npeggedTryCheck!entryName(context, input, result))
            return result;
    result.arena.limit = context.memoryLimit;
    State!(false, true) state;
    state.arena = &result.arena;
    state.input = input;
    state.context = context;
    version (NPeggedPureIslands) {
        static if (pureIslandEntry!parser)
            state.pureIslandsEnabled = context.trace is null && context.stepLimit == size_t.max
                && context.depthLimit == size_t.max && context.memoryLimit == size_t.max
                && result.arena.limit == size_t.max;
    }
    auto tree = state.finish(parser(state, 0));
    result.status = state.status != Status.ok ? state.status : (tree.successful ? Status.ok : Status.mismatch);
    result.successful = result.status == Status.ok;
    result.end = tree.end;
    result.failEnd = tree.failEnd;
    return result;
}

@nogc nothrow unittest {
    ParseContext context;
    auto good = check!(and!(literal!"ab", eoi))(context, "ab");
    assert(good.successful && good.end == 2 && good.arena.allocationCalls == 0);
    auto bad = check!(and!(literal!"ab", eoi))(context, "ax");
    assert(bad.status == Status.mismatch && bad.failEnd == 1 && bad.arena.used == 0);
    context.stepLimit = 0;
    // Terminals charge nothing; a repetition attempt does.
    assert(check!(literal!"a")(context, "a").successful);
    auto limited = check!(oneOrMore!(literal!"a"))(context, "a");
    assert(limited.status == Status.resourceLimit && !limited.successful);
}

/// Result of `accept`: whole-input acceptance and, when not accepted, why (`mismatch` or a resource limit).
struct AcceptResult {
    bool accepted;
    Status status = Status.invalidInput;
}

/// Yes/no recognition (decision D3). Equivalent to `check!parser(...).successful && end == input.length`, with the
/// same status and the same work-unit accounting, but it reports no `failEnd` and no arena counters, so generated
/// parsers may skip failure recording and diagnostics.
pragma(inline, true) AcceptResult accept(alias parser)(ref ParseContext context, scope string input) @nogc nothrow {
    Arena arena;
    arena.limit = context.memoryLimit;
    State!(false, true) state;
    state.arena = &arena;
    state.input = input;
    state.context = context;
    state.acceptOnly = true;
    version (NPeggedPureIslands) {
        static if (pureIslandEntry!parser)
            state.pureIslandsEnabled = context.trace is null && context.stepLimit == size_t.max
                && context.depthLimit == size_t.max && context.memoryLimit == size_t.max && arena.limit == size_t.max;
    }
    const tree = parser(state, 0);
    AcceptResult result;
    result.status = state.status != Status.ok ? state.status : (tree.successful
            && tree.end == input.length ? Status.ok : Status.mismatch);
    result.accepted = result.status == Status.ok;
    return result;
}

@nogc nothrow unittest {
    ParseContext context;
    alias whole = and!(literal!"ab", eoi);
    foreach (input; ["", "a", "ab", "abc", "x", "aab"]) {
        const expected = check!whole(context, input);
        const actual = accept!whole(context, input);
        assert(actual.accepted == (expected.successful && expected.end == input.length));
        assert(actual.status == expected.status);
    }
    // A prefix match is not an accepted input; limits are reported like `check` does.
    assert(!accept!(literal!"ab")(context, "abc").accepted);
    assert(accept!(literal!"ab")(context, "abc").status == Status.mismatch);
    context.stepLimit = 0;
    assert(accept!(oneOrMore!(literal!"a"))(context, "a").status == Status.resourceLimit);
}

/// Owns copied input, compact preorder output, and parser scratch independently.
struct CompactResult {
    Arena arena;
    Arena outputArena;
    string input;
    CompactNode[] nodes;
    Status status = Status.invalidInput;
    bool successful;
    size_t end, failEnd;
    @disable this(this);
    @disable this(ref CompactResult);
}

/// Selector returns uint.max to omit a rule; other values tag retained intervals.
CompactResult parseRecords(alias parser, alias selector, bool OwnInput = true)(ref ParseContext context,
        scope string input, size_t outputLimit = 256 * 1024 * 1024) @nogc nothrow {
    static if (is(parser == struct))
        alias Owner = parser;
    else
        alias Owner = __traits(parent, parser);
    static if (__traits(hasMember, Owner, "compactRuleNames")) {
        static assert(Owner.compactRuleNames.length == Owner.compactRuleKinds.length);
        static foreach (i, name; Owner.compactRuleNames)
            static assert(selector(name) == Owner.compactRuleKinds[i],
                    "The selector differs from the grammar's compiled compact projection");
    }
    CompactResult result;
    result.arena.limit = context.memoryLimit;
    result.outputArena.limit = outputLimit;
    string parsedInput;
    static if (OwnInput) {
        auto owned = result.arena.copy!char(input);
        if (result.arena.status != Status.ok) {
            result.status = result.arena.status;
            return result;
        }
        result.input = cast(string)owned;
        parsedInput = result.input;
    } else
        parsedInput = input;
    RecordBuffer records;
    records.arena = &result.outputArena;
    records.selector = &selector;
    version (NPeggedSharedOutput) {
        version (NPeggedFlatSpecialization) {
            static if (__traits(hasMember, Owner, "npeggedSharedOutputEligible") && Owner.npeggedSharedOutputEligible) {
                SharedRecordStore sharedStore;
                sharedStore.arena = &result.arena;
                if (context.sharedOutput && context.trace is null && context.stepLimit == size_t.max
                        && context.depthLimit == size_t.max && context.memoryLimit == size_t.max
                        && outputLimit == size_t.max)
                    records.enableSharedOutput(sharedStore, result.arena);
            }
        } else {
            SharedRecordStore sharedStore;
            sharedStore.arena = &result.arena;
            static if (__traits(hasMember, Owner, "npeggedSharedOutputEligible")) {
                static if (Owner.npeggedSharedOutputEligible) {
                    if (context.sharedOutput && context.trace is null && context.stepLimit == size_t.max
                            && context.depthLimit == size_t.max && context.memoryLimit == size_t.max
                            && outputLimit == size_t.max)
                        records.enableSharedOutput(sharedStore, result.arena);
                }
            }
        }
    }
    State!(false, 2) state;
    state.arena = &result.arena;
    state.input = parsedInput;
    static if (OwnInput)
        state.captureInput = parsedInput;
    state.context = context;
    state.attachRecords(records);
    version (NPeggedPureIslands) {
        static if (__traits(hasMember, Owner, "compactRuleNames"))
            if (pureIslandProjection!(parser, selector)())
                state.pureIslandsEnabled = context.trace is null && context.stepLimit == size_t.max
                    && context.depthLimit == size_t.max && context.memoryLimit == size_t.max
                    && result.arena.limit == size_t.max && result.outputArena.limit == size_t.max;
    }
    static if (__traits(compiles, parser(state, 0)))
        auto node = state.finish(parser(state, 0));
    else
        auto node = state.finish(state.treeFallback!parser(0));
    result.status = state.status != Status.ok ? state.status : node.successful ? Status.ok : Status.mismatch;
    result.successful = result.status == Status.ok;
    result.end = node.end;
    result.failEnd = node.failEnd;
    if (result.successful)
        result.nodes = records.nodes;
    return result;
}

version (unittest) private uint omitRecord(string name) @nogc nothrow pure {
    return uint.max;
}

@nogc nothrow unittest {
    static assert(!__traits(compiles, { CompactResult result; auto copy = result; }));
    ParseContext context;
    char[1] input = ['a'];
    auto result = parseRecords!(literal!"a", omitRecord)(context, cast(string)input[]);
    input[0] = 'x';
    assert(result.successful && result.input == "a" && result.nodes.length == 0);
    assert(result.outputArena.allocationCalls == 0);
    auto bad = parseRecords!(literal!"a", omitRecord)(context, "x");
    assert(bad.status == Status.mismatch && bad.nodes.length == 0);
    context.memoryLimit = 0;
    assert(parseRecords!(literal!"a", omitRecord)(context, "a").status == Status.resourceLimit);
    auto borrowed = parseRecords!(literal!"a", omitRecord, false)(context, "a");
    assert(borrowed.successful && borrowed.input is null && borrowed.end == 1);
    assert(borrowed.arena.allocationCalls == 0 && borrowed.outputArena.allocationCalls == 0);
    context = ParseContext.init;
    context.stepLimit = 0;
    assert(parseRecords!(oneOrMore!(literal!"a"), omitRecord)(context, "a").status == Status.resourceLimit);
}

version (unittest) private ParseTree legacyRecordParser(ref State!false state, size_t pos) @nogc nothrow {
    return named!(defined!(literal!"a", "Other"), "Legacy")(state, pos);
}

version (unittest) private uint legacyKind(string name) @nogc nothrow pure {
    return name == "Legacy" ? 4 : uint.max;
}

@nogc nothrow unittest {
    ParseContext context;
    auto output = parseRecords!(legacyRecordParser, legacyKind)(context, "a");
    assert(output.successful && output.nodes.length == 1);
    assert(output.nodes[0] == CompactNode(4, 0, 1));
    auto bad = parseRecords!(legacyRecordParser, legacyKind)(context, "x");
    assert(!bad.successful && bad.status == Status.mismatch && bad.nodes.length == 0);
    auto limited = parseRecords!(legacyRecordParser, legacyKind)(context, "a", 0);
    assert(!limited.successful && limited.status == Status.resourceLimit && limited.nodes.length == 0);
}

/// CTFE entry point. Allocation is confined to compiler-managed storage.
ParseTree parseCT(alias parser)(string input) nothrow {
    assert(__ctfe, "Use parse!(parser)(context, input) at runtime");
    State!true state;
    state.input = input;
    auto tree = state.finish(parser(state, 0));
    assert(state.status == Status.ok, "Compile-time parser resource limit exceeded");
    return tree;
}

State!(CT, Check).Node eps(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
    auto result = s.node(pos, pos);
    static if (!Check)
        result.matches = s.single("");
    return result;
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!eps(context, "");
    assert(result.successful && result.matches == [""]);
}

State!(CT, Check).Node fail(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
    return s.failure(pos, "failure");
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!fail(context, "a");
    assert(result.status == Status.mismatch);
}

State!(CT, Check).Node eoi(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
    return pos == s.input.length ? s.node(pos, pos) : s.failure(pos, "end of input");
}

@nogc nothrow unittest {
    ParseContext context;
    auto empty = parse!eoi(context, "");
    assert(empty.successful);
    auto nonempty = parse!eoi(context, "x");
    assert(!nonempty.successful);
}

alias endOfInput = eoi;
State!(CT, Check).Node any(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
    if (!s.alive() || pos >= s.input.length)
        return s.failure(pos, "any char");
    auto result = s.node(pos, pos + 1);
    static if (!Check)
        result.matches = s.single(s.input[pos .. pos + 1]);
    return result;
}

@nogc nothrow unittest {
    ParseContext context;
    auto character = parse!any(context, "é");
    assert(character.end == 1);
    auto empty = parse!any(context, "");
    assert(!empty.successful);
}

/// Literal matching uses byte offsets, as in the upstream engine.
struct literal(string text) {
    enum byteScanner = text.length == 1;
    static if (byteScanner) {
        static bool byteMatches(ubyte c) @nogc nothrow pure {
            return c == cast(ubyte)text[0];
        }

        static size_t byteSteps(ubyte c) @nogc nothrow pure {
            return 0;
        }
    }
    static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        if (!s.alive())
            return s.node(pos, pos, false);
        static if (text.length == 0) {
            return s.node(pos, pos);
        } else static if (text.length == 1) {
            if (pos < s.input.length && s.input[pos] == text[0]) {
                auto result = s.node(pos, pos + 1);
                static if (!Check)
                    result.matches = s.single(s.input[pos .. pos + 1]);
                return result;
            }
            auto result = s.failure(pos, text);
            result.failEnd = pos;
            s.recordFailure(result);
            return result;
        } else {
            if (pos + text.length <= s.input.length && s.input[pos .. pos + text.length] == text) {
                auto result = s.node(pos, pos + text.length);
                static if (!Check)
                    result.matches = s.single(s.input[pos .. pos + text.length]);
                return result;
            }
            size_t i;
            while (i < text.length && pos + i < s.input.length && s.input[pos + i] == text[i])
                ++i;
            auto result = s.failure(pos, text);
            result.failEnd = pos + i;
            s.recordFailure(result);
            return result;
        }
    }
}

@nogc nothrow unittest {
    ParseContext ctx;
    auto result = parse!(literal!"abc")(ctx, "abcd");
    assert(result.successful && result.end == 3);
    assert(result.matches == ["abc"]);
    auto bad = parse!(literal!"abc")(ctx, "ax");
    assert(bad.status == Status.mismatch && bad.failEnd == 1);
    auto empty = parse!(literal!"")(ctx, "");
    assert(empty.successful && empty.matches.length == 0);
    auto end = parse!eoi(ctx, "x");
    assert(!end.successful);
    auto end2 = parse!eoi(ctx, "");
    assert(end2.successful);
    auto one = parse!any(ctx, "ab");
    assert(one.end == 1);
    auto none = parse!any(ctx, "");
    assert(!none.successful);
    ctx.memoryLimit = 0;
    auto exhausted = parse!any(ctx, "x");
    assert(exhausted.status == Status.resourceLimit);
}

/// Strict UTF-8 scalar decoding for ranges and case-insensitive literals.
bool decode(scope string input, ref size_t pos, out dchar value) @nogc nothrow pure {
    if (pos >= input.length)
        return false;
    auto first = cast(ubyte)input[pos++];
    if (first < 0x80) {
        value = first;
        return true;
    }
    uint count = first >= 0xC2 && first <= 0xDF ? 1 : first >= 0xE0 && first <= 0xEF
        ? 2 : first >= 0xF0 && first <= 0xF4 ? 3 : 0;
    if (!count || count > input.length - pos)
        return false;
    uint scalar = first & ((1u << (6 - count)) - 1);
    foreach (i; 0 .. count) {
        auto next = cast(ubyte)input[pos++];
        if ((next & 0xC0) != 0x80)
            return false;
        scalar = (scalar << 6) | (next & 0x3F);
    }
    if (scalar < (count == 1 ? 0x80 : count == 2 ? 0x800 : 0x10000) || scalar > 0x10FFFF
            || (scalar >= 0xD800 && scalar <= 0xDFFF))
        return false;
    value = cast(dchar)scalar;
    return true;
}

@nogc nothrow unittest {
    foreach (text; ["a", "é", "€", "😀"]) {
        size_t pos;
        dchar value;
        assert(decode(text, pos, value) && pos == text.length);
    }
    foreach (text; [
        "", "\x80", "\xc0\xaf", "\xe0\x80\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xc2x", "\xe2"
    ]) {
        size_t pos;
        dchar value;
        assert(!decode(text, pos, value));
    }
}

struct charRange(dchar low, dchar high) {
    static size_t byteSteps(ubyte c) @nogc nothrow pure {
        return 0;
    }

    enum byteScanner = high < 128;
    enum expectation = "character range";
    static bool byteMatches(ubyte c) @nogc nothrow pure {
        return c >= low && c <= high;
    }

    static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        static if (high < 128) {
            if (!s.alive() || pos >= s.input.length)
                return s.failure(pos, "character range");
            const char c = s.input[pos];
            if (c < low || c > high)
                return s.failure(pos, "character range");
            auto result = s.node(pos, pos + 1);
            static if (!Check)
                result.matches = s.single(s.input[pos .. pos + 1]);
            return result;
        } else {
            size_t end = pos;
            dchar value;
            if (!s.alive() || !decode(s.input, end, value) || value < low || value > high)
                return s.failure(pos, "character range");
            auto result = s.node(pos, end);
            static if (!Check)
                result.matches = s.single(s.input[pos .. end]);
            return result;
        }
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(charRange!('α', 'ω'))(context, "β");
    assert(result.successful && result.end == 2);
    auto bad = parse!(charRange!('a', 'z'))(context, "1");
    assert(!bad.successful);
}

struct CharSetMask {
    ulong[4] bits;

    void addChar(dchar c) @nogc nothrow pure @safe {
        if (c < 256) {
            bits[(cast(uint)c) >> 6] |= (1UL << ((cast(uint)c) & 63));
        }
    }

    void addRange(dchar low, dchar high) @nogc nothrow pure @safe {
        if (low <= high && high < 256) {
            for (uint c = cast(uint)low; c <= cast(uint)high; ++c) {
                bits[c >> 6] |= (1UL << (c & 63));
            }
        }
    }

    static CharSetMask fromRanges(const(char[2])[] ranges...) @nogc nothrow pure @safe {
        CharSetMask mask;
        foreach (range; ranges) {
            mask.addRange(range[0], range[1]);
        }
        return mask;
    }

    static CharSetMask fromChars(const(char)[] chars...) @nogc nothrow pure @safe {
        CharSetMask mask;
        foreach (c; chars) {
            mask.addChar(c);
        }
        return mask;
    }

    bool contains(char c) const @nogc nothrow pure @safe {
        return (bits[(cast(ubyte)c) >> 6] & (1UL << ((cast(ubyte)c) & 63))) != 0;
    }

    bool empty() const @nogc nothrow pure @safe {
        return (bits[0] | bits[1] | bits[2] | bits[3]) == 0;
    }

    bool intersects(CharSetMask other) const @nogc nothrow pure @safe {
        return ((bits[0] & other.bits[0]) | (bits[1] & other.bits[1]) | (bits[2] & other.bits[2]) | (
                bits[3] & other.bits[3])) != 0;
    }

    CharSetMask opBinary(string op : "|")(CharSetMask other) const @nogc nothrow pure @safe {
        CharSetMask res;
        res.bits[0] = bits[0] | other.bits[0];
        res.bits[1] = bits[1] | other.bits[1];
        res.bits[2] = bits[2] | other.bits[2];
        res.bits[3] = bits[3] | other.bits[3];
        return res;
    }

    CharSetMask opBinary(string op : "&")(CharSetMask other) const @nogc nothrow pure @safe {
        CharSetMask res;
        res.bits[0] = bits[0] & other.bits[0];
        res.bits[1] = bits[1] & other.bits[1];
        res.bits[2] = bits[2] & other.bits[2];
        res.bits[3] = bits[3] & other.bits[3];
        return res;
    }

    CharSetMask opUnary(string op : "~")() const @nogc nothrow pure @safe {
        CharSetMask res;
        res.bits[0] = ~bits[0];
        res.bits[1] = ~bits[1];
        res.bits[2] = ~bits[2];
        res.bits[3] = ~bits[3];
        return res;
    }
}

@nogc nothrow unittest {
    CharSetMask mask;
    assert(mask.empty());
    mask.addChar('a');
    mask.addRange('0', '9');
    assert(mask.contains('a'));
    assert(mask.contains('0'));
    assert(mask.contains('9'));
    assert(!mask.contains('b'));
    assert(!mask.empty());

    CharSetMask other = CharSetMask.fromRanges(['b', 'd']);
    assert(!mask.intersects(other));
    auto combined = mask | other;
    assert(combined.contains('c'));
    assert(mask.intersects(combined));
    auto intersected = mask & combined;
    assert(intersected.contains('a'));
    assert(!intersected.contains('b'));
    auto inverted = ~mask;
    assert(!inverted.contains('a'));
    assert(inverted.contains('b'));
}

struct charClass(ulong b0, ulong b1, ulong b2, ulong b3) {
    static size_t byteSteps(ubyte c) @nogc nothrow pure {
        return 0;
    }

    enum byteScanner = true;
    enum expectation = "character class";
    static bool byteMatches(ubyte c) @nogc nothrow pure {
        enum ulong[4] bits = [b0, b1, b2, b3];
        return (bits[c >> 6] & (1UL << (c & 63))) != 0;
    }

    static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        if (!s.alive() || pos >= s.input.length)
            return s.failure(pos, "character class");
        const ubyte c = cast(ubyte)s.input[pos];
        enum ulong[4] bits = [b0, b1, b2, b3];
        if ((bits[c >> 6] & (1UL << (c & 63))) == 0)
            return s.failure(pos, "character class");
        auto result = s.node(pos, pos + 1);
        static if (!Check)
            result.matches = s.single(s.input[pos .. pos + 1]);
        return result;
    }
}

template charClass(CharSetMask mask) {
    alias charClass = charClass!(mask.bits[0], mask.bits[1], mask.bits[2], mask.bits[3]);
}

@nogc nothrow unittest {
    ParseContext context;
    enum mask = CharSetMask.fromRanges(['0', '9'], ['a', 'f']);
    auto valid = parse!(charClass!mask)(context, "a");
    assert(valid.successful && valid.end == 1 && valid.matches == ["a"]);
    auto digit = parse!(charClass!mask)(context, "5");
    assert(digit.successful && digit.end == 1);
    auto bad = parse!(charClass!mask)(context, "z");
    assert(!bad.successful && bad.status == Status.mismatch);
    auto empty = parse!(charClass!mask)(context, "");
    assert(!empty.successful);
}

struct and(rules...) {
    static if (rules.length == 2 && __traits(hasMember, rules[0], "bytePredicate")
            && rules[0].bytePredicate && __traits(isSame, rules[1], npegged.peg.any)) {
        enum byteScanner = true;
        static bool byteMatches(ubyte c) @nogc nothrow pure {
            return rules[0].predicateMatches(c);
        }

        static size_t byteSteps(ubyte c) @nogc nothrow pure {
            // Sequences, any and the predicate charge nothing; the repetition around them pays per attempt.
            return rules[0].predicateSteps(c);
        }
    } else
        enum byteScanner = false;
    static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        static if (Check == 1) {
            pragma(inline, true);
        }
        auto result = s.node(pos, pos);
        static if (!Check) {
            State!(CT, Check).Builder!string matches = {owner: &s};
            State!(CT, Check).Builder!ParseTree children = {owner: &s};
        }
        static foreach (r; rules) {
            {
                if (!s.alive())
                    return s.node(pos, pos, false);
                auto next = r(s, result.end);
                if (!next.successful) {
                    result.successful = false;
                    result.failEnd = next.failEnd;
                    static if (!Check)
                        result.matches = next.matches;
                    static if (!Check)
                        result.failedChild = s.single(next);
                    return result;
                }
                result.end = next.end;
                static if (!Check) {
                    matches.put(next.matches);
                    children.put(next.children);
                }
                static if (!Check)
                    result.matches = matches.data();
                static if (!Check)
                    result.children = children.data();
            }
        }
        return result;
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(and!(literal!"a", literal!"b"))(context, "ab");
    assert(result.end == 2 && result.matches == ["a", "b"]);
    auto bad = parse!(and!(literal!"a", literal!"b"))(context, "ac");
    assert(bad.failEnd == 1 && bad.status == Status.mismatch);
}

struct choice(bool longest, rules...) {
    private static bool canScan() {
        static foreach (rule; rules) {
            static if (!__traits(hasMember, rule, "byteScanner") || !__traits(hasMember, rule,
                    "byteMatches") || !__traits(hasMember, rule, "byteSteps"))
                return false;
            else static if (!rule.byteScanner)
                return false;
        }
        return rules.length > 0;
    }

    enum byteScanner = canScan();
    static if (byteScanner) {
        private static CharSetMask computeByteMask() {
            CharSetMask m;
            foreach (c; 0 .. 256) {
                bool match = false;
                static foreach (rule; rules)
                    if (rule.byteMatches(cast(ubyte)c))
                        match = true;
                if (match)
                    m.addChar(cast(char)c);
            }
            return m;
        }

        enum byteMask = computeByteMask();

        static bool byteMatches(ubyte c) @nogc nothrow pure {
            return (byteMask.bits[c >> 6] & (1UL << (c & 63))) != 0;
        }

        static size_t byteSteps(ubyte c) @nogc nothrow pure {
            size_t steps;
            static foreach (rule; rules) {
                steps += rule.byteSteps(c);
                static if (!longest)
                    if (rule.byteMatches(c))
                        return steps;
            }
            return steps;
        }
    }
    static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        static if (Check == 1) {
            pragma(inline, true);
        }
        auto result = s.node(pos, pos, false);
        const checkpoint = s.outputCheckpoint();
        static if (Check == 2 && longest)
            RecordSnapshot selected;
        static foreach (r; rules) {
            {
                s.rollbackOutput(checkpoint);
                auto candidate = r(s, pos);
                if (candidate.successful) {
                    if (!longest)
                        return candidate;
                    if (!result.successful || candidate.end > result.end) {
                        result = candidate;
                        static if (Check == 2 && longest)
                            selected = s.snapshotOutput(checkpoint);
                    }
                } else if (!result.successful && candidate.failEnd >= result.failEnd)
                    result = candidate;
            }
        }
        s.rollbackOutput(checkpoint);
        static if (Check == 2 && longest)
            if (result.successful)
                s.restoreOutput(selected);
        return result;
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(choice!(true, named!(literal!"a", "first"), named!(literal!"a", "second")))(context, "a");
    assert(result.name == "first");
    alias nullable = choice!(false, literal!"a", option!(literal!"b"));
    static assert(!nullable.byteScanner);
    assert(check!nullable(context, "").successful);
    assert(check!nullable(context, "b").end == 1);
}

template or(rules...) {
    alias or = choice!(false, rules);
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(or!(literal!"x", literal!"a"))(context, "a");
    assert(result.successful);
}

/// Ordered choice of 1-2 byte literals with overlapping FIRST bytes (F4, opt-in via NPeggedFirst2).
/// The winner of an ordered choice is a function of the first two input bytes, so a table picks it.
/// Success reproduces `choice!(false, literal!...)` exactly (literals and choices charge no work units, docs/WORK_UNITS.md);
/// failure, tree mode, compile-time evaluation and a non-ok status all take the original choice.
struct literalChoice2(texts...) {
    import npegged.meta : AliasSeq;

    private template Rules(size_t i = 0) {
        static if (i == texts.length)
            alias Rules = AliasSeq!();
        else
            alias Rules = AliasSeq!(literal!(texts[i]), Rules!(i + 1));
    }

    alias Slow = choice!(false, Rules!());
    enum slots = computeSlots();
    static assert(texts.length >= 2 && texts.length < ubyte.max, "literalChoice2 needs 2..254 alternatives");
    static assert(slots <= 16, "literalChoice2 is limited to 16 distinct first bytes");

    private static size_t computeSlots() {
        bool[256] seen;
        size_t count;
        static foreach (text; texts) {
            static assert(text.length == 1 || text.length == 2, "literalChoice2 takes 1-2 byte literals");
            if (!seen[cast(ubyte)text[0]]) {
                seen[cast(ubyte)text[0]] = true;
                ++count;
            }
        }
        return count;
    }

    private struct Plan {
        ubyte[256] slot; // first byte -> 1-based row, 0 = no alternative starts with it
        ubyte[257][slots] winner; // [row][second byte, 256 = end of input] -> 1-based alternative
        /// [row][second byte] -> 0 when the winner is the first alternative, else 1 + the furthest offset (0 or 1) at which
        /// an earlier alternative failed. The ordered choice records those failures; the table replays the furthest one
        /// because it is visible in `failEnd` whenever a limit ends the parse early.
        ubyte[257][slots] skip;
    }

    private static Plan computePlan() {
        Plan plan;
        size_t rows;
        static foreach (text; texts)
            if (!plan.slot[cast(ubyte)text[0]])
                plan.slot[cast(ubyte)text[0]] = cast(ubyte)++rows;
        foreach (first; 0 .. 256) {
            if (!plan.slot[first])
                continue;
            foreach (second; 0 .. 257) {
                static foreach (i, text; texts)
                    if (!plan.winner[plan.slot[first] - 1][second] && cast(ubyte)text[0] == first
                            && (text.length == 1 || (second != 256 && cast(ubyte)text[1] == second)))
                        plan.winner[plan.slot[first] - 1][second] = cast(ubyte)(i + 1);
                // Earlier alternatives failed: after one matched byte when they start with `first`, else at once.
                static foreach (i, text; texts)
                    if (plan.winner[plan.slot[first] - 1][second] > i + 1) {
                        const reach = cast(ubyte)text[0] == first ? 2 : 1;
                        if (plan.skip[plan.slot[first] - 1][second] < reach)
                            plan.skip[plan.slot[first] - 1][second] = cast(ubyte)reach;
                    }
            }
        }
        return plan;
    }

    static immutable Plan plan = computePlan();

    static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        static if (CT || Check == 0)
            return Slow(s, pos);
        else {
            if (s.status == Status.ok && pos < s.input.length) {
                const row = plan.slot[cast(ubyte)s.input[pos]];
                if (row) {
                    const second = pos + 1 < s.input.length ? cast(ubyte)s.input[pos + 1] : 256;
                    const winner = plan.winner[row - 1][second];
                    // Work-unit model v2: ordered choices of literals charge nothing, so the winner needs no ticks.
                    if (winner) {
                        if (const skipped = plan.skip[row - 1][second])
                            s.recordFailure(s.node(pos, pos + skipped - 1, false));
                        static foreach (i, text; texts)
                            if (winner == i + 1)
                                return s.node(pos, pos + text.length);
                    }
                }
            }
            return Slow(s, pos);
        }
    }
}

/// Ordered choice of 1-4 byte literals (L4): a trie over the alternatives replaces trying them one after another. The winner of
/// an ordered choice is the lowest-index alternative that is a prefix of the input, so the walk follows the input down the
/// trie and keeps the smallest terminal index it passes. Like `literalChoice2`, everything the ordered choice would have
/// recorded is replayed: the skipped earlier alternatives fail after matching the bytes they share with the input, which the
/// walk knows (the deepest node on the path that an earlier alternative passes through); with no winner every alternative failed
/// at the walk's depth.
struct literalChoiceK(texts...) {
    import npegged.meta : AliasSeq;

    private template Rules(size_t i = 0) {
        static if (i == texts.length)
            alias Rules = AliasSeq!();
        else
            alias Rules = AliasSeq!(literal!(texts[i]), Rules!(i + 1));
    }

    alias Slow = choice!(false, Rules!());
    enum maxNodes = 250;
    static assert(texts.length >= 2 && texts.length < ubyte.max, "literalChoiceK needs 2..254 alternatives");

    /// The walk ends at one trie node, and everything `dispatch` reports is a function of the path to it: those facts
    /// are computed once per node. Bytes that no literal contains share class 0, so rows stay small.
    private struct Trie {
        ubyte[256] classOf; // byte -> dense class, 0 = a byte no literal contains
        ubyte[maxNodes + 1][maxNodes + 1] child; // [node][class] -> node, 0 = none (node 0 is the root); classes < maxNodes + 1
        ubyte[maxNodes + 1] terminal; // lowest 1-based alternative ending at the node, 0 = none
        ubyte[maxNodes + 1] lowest; // lowest 1-based alternative passing through (or ending at) the node, 0 = none
        ubyte[maxNodes + 1] parent, depth;
        ubyte[maxNodes + 1] winner, failure, length; // the dispatch outcome when the walk stops at the node
        size_t nodes, classes;
        bool overflow;
    }

    private static Trie computeTrie() {
        Trie trie;
        trie.nodes = 1;
        trie.classes = 1;
        static foreach (i, text; texts) {
            {
                static assert(text.length >= 1 && text.length <= 4, "literalChoiceK takes 1-4 byte literals");
                size_t node = 0;
                foreach (c; text) {
                    if (!trie.classOf[cast(ubyte)c]) {
                        if (trie.classes > maxNodes) {
                            trie.overflow = true;
                            return trie;
                        }
                        trie.classOf[cast(ubyte)c] = cast(ubyte)trie.classes++;
                    }
                    const cls = trie.classOf[cast(ubyte)c];
                    if (!trie.child[node][cls]) {
                        if (trie.nodes > maxNodes) {
                            trie.overflow = true;
                            return trie;
                        }
                        trie.parent[trie.nodes] = cast(ubyte)node;
                        trie.depth[trie.nodes] = cast(ubyte)(trie.depth[node] + 1);
                        trie.child[node][cls] = cast(ubyte)trie.nodes++;
                    }
                    node = trie.child[node][cls];
                    if (!trie.lowest[node])
                        trie.lowest[node] = cast(ubyte)(i + 1);
                }
                if (!trie.terminal[node])
                    trie.terminal[node] = cast(ubyte)(i + 1);
            }
        }
        // The root is passed by every alternative: the lowest index is the first.
        trie.lowest[0] = 1;
        foreach (node; 0 .. trie.nodes) {
            ubyte[5] path;
            size_t at = node;
            const depth = trie.depth[node];
            foreach_reverse (d; 0 .. depth + 1) {
                path[d] = cast(ubyte)at;
                at = trie.parent[at];
            }
            ubyte best;
            foreach (d; 0 .. depth + 1) {
                const t = trie.terminal[path[d]];
                if (t && (!best || t < best)) {
                    best = t;
                    trie.length[node] = cast(ubyte)d;
                }
            }
            trie.winner[node] = best;
            if (!best)
                trie.failure[node] = cast(ubyte)(depth + 1); // every alternative failed after the bytes the walk consumed
            else
                foreach (d; 0 .. depth + 1) // earlier alternatives fail at the deepest path node they still pass through
                    if (trie.lowest[path[d]] && trie.lowest[path[d]] < best)
                        trie.failure[node] = cast(ubyte)(d + 1);
        }
        return trie;
    }

    static immutable Trie trie = computeTrie();
    static assert(!trie.overflow, "literalChoiceK: too many trie nodes or byte classes");

    /// Result of one walk: `winner` is the 1-based alternative (0 = none); `failure` is 0 when no earlier alternative failed,
    /// otherwise 1 + the furthest offset at which an earlier alternative (or, with no winner, any alternative) failed.
    struct Dispatch {
        ubyte winner;
        ubyte failure;
        ubyte length; // bytes the winner consumes
    }

    pragma(inline, true) private static size_t walk(scope const(char)[] input, size_t pos) @nogc nothrow pure {
        size_t node;
        foreach (step; 0 .. 4) {
            if (pos + step >= input.length)
                break;
            const next = trie.child[node][trie.classOf[cast(ubyte)input[pos + step]]];
            if (!next)
                break;
            node = next;
        }
        return node;
    }

    /// Winner and length only, for callers that record no failures (the `accept` clone).
    pragma(inline, true) static Dispatch winnerOnly(scope const(char)[] input, size_t pos) @nogc nothrow pure {
        const node = walk(input, pos);
        return Dispatch(trie.winner[node], 0, trie.length[node]);
    }

    pragma(inline, true) static Dispatch dispatch(scope const(char)[] input, size_t pos) @nogc nothrow pure {
        const node = walk(input, pos);
        return Dispatch(trie.winner[node], trie.failure[node], trie.length[node]);
    }

    static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        static if (CT || Check == 0)
            return Slow(s, pos);
        else {
            if (s.status == Status.ok && pos < s.input.length) {
                const hit = dispatch(s.input, pos);
                if (hit.winner) {
                    if (hit.failure)
                        s.recordFailure(s.node(pos, pos + hit.failure - 1, false));
                    return s.node(pos, pos + hit.length);
                }
            }
            return Slow(s, pos);
        }
    }
}

@nogc nothrow unittest {
    // The trie dispatch is the ordered choice: every short input over a small alphabet, against the combinator choice.
    alias fast = literalChoiceK!("<<=", "<<", "<=", "<", ">>=", ">>", "...", "..", ".", "=>", "=", "!=");
    alias slow = choice!(false, literal!"<<=", literal!"<<", literal!"<=", literal!"<",
            literal!">>=", literal!">>", literal!"...", literal!"..", literal!".",
            literal!"=>", literal!"=", literal!"!=");
    enum alphabet = "<=>.!x";
    char[5] buffer;
    foreach (length; 0 .. 5) {
        size_t combinations = 1;
        foreach (_; 0 .. length)
            combinations *= alphabet.length;
        foreach (code; 0 .. combinations) {
            size_t digit = code;
            foreach (i; 0 .. length) {
                buffer[i] = alphabet[digit % alphabet.length];
                digit /= alphabet.length;
            }
            const input = cast(string)buffer[0 .. length];
            foreach (limit; [0UL, 1, 5, 100]) {
                ParseContext a, b;
                a.stepLimit = b.stepLimit = limit;
                const f = check!fast(a, input);
                const o = check!slow(b, input);
                assert(f.status == o.status && f.successful == o.successful && f.end == o.end && f.failEnd == o.failEnd);
            }
        }
    }
    foreach (probe; [
        "", "<", "<<", "<<=", "<<x", "<=", ">>=x", "...", "..", ".", "=>", "=", "!=", "!", "x", "..x"
    ]) {
        const full = fast.dispatch(probe, 0), lean = fast.winnerOnly(probe, 0);
        assert(full.winner == lean.winner && full.length == lean.length);
    }
    // An earlier longer alternative that fails after sharing bytes is replayed ("<<=" fails at offset 2 on "<<x").
    assert(fast.dispatch("<<x", 0).winner == 2 && fast.dispatch("<<x", 0).failure == 3);
    assert(fast.dispatch("x", 0).winner == 0 && fast.dispatch("x", 0).failure == 1);
    assert(fast.dispatch("<=x", 0).winner == 3 && fast.dispatch("<=x", 0).length == 2);
}

@nogc nothrow unittest {
    alias ordered = literalChoice2!("==", "=", "<=", "<");
    alias reference = choice!(false, literal!"==", literal!"=", literal!"<=", literal!"<");
    static immutable inputs = ["==", "=", "=x", "<=", "<", "<x", "", "x", "<<", "=<", "==="];
    foreach (input; inputs) {
        foreach (limit; [0UL, 1, 2, 3, 4, 100]) {
            ParseContext a, b;
            a.stepLimit = b.stepLimit = limit;
            auto fast = check!ordered(a, input);
            auto slow = check!reference(b, input);
            assert(fast.status == slow.status && fast.successful == slow.successful);
            assert(fast.end == slow.end && fast.failEnd == slow.failEnd);
            ParseContext c, d;
            c.stepLimit = d.stepLimit = limit;
            auto fastRecords = parseRecords!(ordered, omitRecord)(c, input, size_t.max);
            auto slowRecords = parseRecords!(reference, omitRecord)(d, input, size_t.max);
            assert(fastRecords.status == slowRecords.status && fastRecords.successful == slowRecords.successful);
            assert(fastRecords.end == slowRecords.end && fastRecords.failEnd == slowRecords.failEnd);
        }
    }
    // Earlier shorter literal wins over a later longer one, as in ordered choice.
    alias shadowing = literalChoice2!("<", "<=");
    ParseContext c;
    assert(check!shadowing(c, "<=").end == 1);
}

@nogc nothrow unittest {
    // Verify the runtime-built table against the independent ordered PEG path
    // for every two-byte prefix and for EOF after every possible first byte.
    alias Plan = literalChoice2!("ab", "ac", "z", "za");
    alias Reference = choice!(false, literal!"ab", literal!"ac", literal!"z", literal!"za");
    const table = Plan.computePlan();
    assert(Plan.computeSlots() == 2);
    // Skipped earlier alternatives: none for the first winner, an offset-1 failure when an earlier alternative shares the
    // first byte, an offset-0 failure otherwise.
    assert(table.skip[table.slot['a'] - 1]['b'] == 0);
    assert(table.skip[table.slot['a'] - 1]['c'] == 2);
    assert(table.winner[table.slot['z'] - 1]['a'] == 3 && table.skip[table.slot['z'] - 1]['a'] == 1);
    assert(table.skip[table.slot['z'] - 1][256] == 1 && table.winner[table.slot['z'] - 1][256] == 3);
    foreach (first; 0 .. 256)
        foreach (second; 0 .. 257) {
            char[2] bytes = [cast(char)first, cast(char)second];
            State!(false, 1) state;
            state.input = cast(string)bytes[0 .. second == 256 ? 1 : 2];
            const reference = Reference(state, 0);
            const row = table.slot[first];
            const winner = row ? table.winner[row - 1][second] : 0;
            assert((winner != 0) == reference.successful);
            assert(winner != 4); // Earlier 'z' always shadows 'za'.
            if (winner)
                assert(reference.end == (winner == 3 ? 1 : 2));
        }
}

template branch(alias Rule, ulong b0, ulong b1, ulong b2, ulong b3, bool Nullable = false) {
    alias rule = Rule;
    enum CharSetMask mask = CharSetMask([b0, b1, b2, b3]);
    enum nullable = Nullable;
}

template branch(alias Rule, CharSetMask mask, bool Nullable = false) {
    alias branch = branch!(Rule, mask.bits[0], mask.bits[1], mask.bits[2], mask.bits[3], Nullable);
}

struct predictiveChoice(branches...) {
    static assert(branches.length <= ubyte.max, "Predictive choices use byte branch indices");
    private static size_t computeFallback() {
        size_t result;
        static foreach (i, branch; branches)
            static if (branch.nullable) {
                static assert(i + 1 == branches.length, "Only the last alternative may be nullable");
                result = i + 1;
            }
        return result;
    }

    enum fallback = computeFallback();
    private static bool canScan() {
        static foreach (branch; branches) {
            static if (!__traits(hasMember, branch.rule, "byteScanner") || !__traits(hasMember,
                    branch.rule, "byteMatches") || !__traits(hasMember, branch.rule, "byteSteps"))
                return false;
            else static if (!branch.rule.byteScanner)
                return false;
            else static if (branch.nullable)
                return false;
        }
        return branches.length > 0;
    }

    enum byteScanner = canScan();
    static if (byteScanner) {
        static bool byteMatches(ubyte c) @nogc nothrow pure {
            const target = branchTable[c];
            static foreach (i, branch; branches)
                if (target == i + 1)
                    return branch.rule.byteMatches(c);
            return false;
        }

        static size_t byteSteps(ubyte c) @nogc nothrow pure {
            const target = branchTable[c];
            static foreach (i, branch; branches)
                if (target == i + 1)
                    return branch.rule.byteSteps(c);
            return 0;
        }
    }

    private static ubyte[256] computeTable() {
        ubyte[256] table = cast(ubyte)fallback;
        foreach (i, b; branches) {
            foreach (c; 0 .. 256) {
                if (b.mask.contains(cast(char)c)) {
                    table[c] = cast(ubyte)(i + 1);
                }
            }
        }
        return table;
    }

    static immutable ubyte[256] branchTable = computeTable();

    static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        static if (Check == 1) {
            pragma(inline, true);
        }
        if (!s.alive())
            return s.node(pos, pos, false);
        if (pos >= s.input.length) {
            static if (fallback)
                return branches[fallback - 1].rule(s, pos);
            else {
                auto result = s.failure(pos, "choice");
                result.failEnd = pos;
                s.recordFailure(result);
                return result;
            }
        }
        const ubyte b = cast(ubyte)s.input[pos];
        const ubyte target = branchTable[b];
        switch (target) {
            static foreach (i; 0 .. branches.length) {
        case i + 1:
                static if (fallback && i + 1 != fallback) {
                    const checkpoint = s.outputCheckpoint();
                    auto result = branches[i].rule(s, pos);
                    if (result.successful || s.status != Status.ok)
                        return result;
                    s.rollbackOutput(checkpoint);
                    return branches[fallback - 1].rule(s, pos);
                } else
                    return branches[i].rule(s, pos);
            }
        default:
            auto result = s.failure(pos, "choice");
            result.failEnd = pos;
            s.recordFailure(result);
            return result;
        }
    }
}

@nogc nothrow unittest {
    ParseContext context;
    enum maskA = CharSetMask.fromChars('a');
    enum maskB = CharSetMask.fromChars('b');
    alias pred = predictiveChoice!(branch!(literal!"a", maskA), branch!(literal!"b", maskB));
    auto resA = parse!pred(context, "a");
    assert(resA.successful && resA.end == 1);
    auto resB = parse!pred(context, "b");
    assert(resB.successful && resB.end == 1);
    auto resC = parse!pred(context, "c");
    assert(!resC.successful);
    auto resEmpty = parse!pred(context, "");
    assert(!resEmpty.successful);
    alias nullable = predictiveChoice!(branch!(literal!"ab", maskA),
            branch!(zeroOrMore!(literal!"b"), maskB, true));
    static assert(!nullable.byteScanner);
    assert(check!nullable(context, "").successful);
    assert(check!nullable(context, "bbx").end == 2);
    auto rolledBack = check!nullable(context, "aX");
    assert(rolledBack.successful && rolledBack.end == 0 && rolledBack.failEnd == 1);
    assert(check!nullable(context, "x").end == 0);
    assert(check!nullable(context, "ab").end == 2);
    context.stepLimit = 1;
    assert(check!nullable(context, "bb").status == Status.resourceLimit);
}

template longest_match(rules...) {
    alias longest_match = choice!(true, rules);
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(longest_match!(literal!"a", literal!"ab"))(context, "ab");
    assert(result.end == 2);
}

struct repeat(alias r, size_t minimum, size_t maximum = size_t.max) {
    enum byteScanner = __traits(hasMember, r, "byteScanner") && r.byteScanner && __traits(hasMember,
                r, "byteMatches") && __traits(hasMember, r, "byteSteps");
    static if (byteScanner) {
        /// Preserve generic repetition's loop/terminal ticks and stopping mismatch.
        static State!(CT, Check).Node scan(bool Capture, bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
            auto result = s.node(pos, pos);
            size_t count;
            const size_t remainingBytes = s.input.length - result.end;
            const size_t maxSteps = (1 + r.byteSteps(0)) * (remainingBytes + 1);
            if (s.status == Status.ok && s.context.stepLimit > s.steps && s.context.stepLimit - s.steps >= maxSteps) {
                while (count < maximum && result.end < s.input.length) {
                    const c = cast(ubyte)s.input[result.end];
                    if (!r.byteMatches(c))
                        break;
                    s.steps += 1 + r.byteSteps(c);
                    ++result.end;
                    ++count;
                }
            }
            while (count < maximum && s.tick()) {
                if (result.end < s.input.length) {
                    const c = cast(ubyte)s.input[result.end];
                    const cost = r.byteSteps(c);
                    if (r.byteMatches(c) && cost <= s.context.stepLimit - s.steps) {
                        s.steps += cost;
                        ++result.end;
                        ++count;
                        continue;
                    }
                }
                // Preserve exact diagnostics and partial budget behavior at the boundary.
                const checkpoint = s.outputCheckpoint();
                auto next = r(s, result.end);
                if (!next.successful) {
                    s.rollbackOutput(checkpoint);
                    if (count < minimum)
                        return next;
                    break;
                }
                result.end = next.end;
                ++count;
            }
            if (count < minimum || s.status != Status.ok)
                result.successful = false;
            static if (!Check) {
                if (!result.successful) {
                    // Failed transforms retain the unfused child output.
                    static if (!Check)
                        result.matches = s.allocate!string(count);
                    foreach (i; 0 .. result.matches.length)
                        result.matches[i] = s.input[pos + i .. pos + i + 1];
                } else static if (Capture) {
                    if (result.end != pos)
                        static if (!Check)
                            result.matches = s.single(s.retainCapture(s.input[pos .. result.end]));
                }
            }
            return result;
        }
    }
    static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        static if (Check == 1) {
            pragma(inline, true);
        }
        static if (Check && byteScanner)
            return scan!false(s, pos);
        else {
            auto result = s.node(pos, pos);
            static if (!Check) {
                State!(CT, Check).Builder!string matches = {owner: &s};
                State!(CT, Check).Builder!ParseTree children = {owner: &s};
            }
            size_t count;
            while (count < maximum && s.tick()) {
                const checkpoint = s.outputCheckpoint();
                auto next = r(s, result.end);
                if (!next.successful) {
                    s.rollbackOutput(checkpoint);
                    if (count < minimum)
                        return next;
                    break;
                }
                static if (!Check) {
                    matches.put(next.matches);
                    children.put(next.children);
                }
                static if (!Check)
                    result.matches = matches.data();
                static if (!Check)
                    result.children = children.data();
                ++count;
                if (next.end == result.end)
                    break;
                result.end = next.end;
            }
            if (count < minimum || s.status != Status.ok)
                result.successful = false;
            return result;
        }
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(repeat!(digit, 2, 3))(context, "1234");
    assert(result.end == 3);
    auto bad = parse!(repeat!(digit, 2, 3))(context, "1");
    assert(!bad.successful);
}

version (unittest) private State!(CT, Check).Node wrappedDigit(bool CT, int Check = 0)(ref State!(CT,
        Check) state, size_t pos) nothrow {
    return digit(state, pos);
}

@nogc nothrow unittest {
    foreach (input; ["", "x", "1", "12", "1234", "12x"]) {
        foreach (budget; 0 .. 14) {
            ParseContext context;
            context.stepLimit = budget;
            auto specialized = parse!(fuse!(repeat!(digit, 2, 3)))(context, input);
            auto generic = parse!(fuse!(repeat!(wrappedDigit, 2, 3)))(context, input);
            assert(specialized.status == generic.status);
            assert(specialized.successful == generic.successful);
            assert(specialized.end == generic.end && specialized.failEnd == generic.failEnd);
            assert(specialized.matches == generic.matches);
            auto checked = check!(repeat!(digit, 2, 3))(context, input);
            assert(checked.status == generic.status && checked.end == generic.end);
            assert(checked.failEnd == generic.failEnd && checked.arena.allocationCalls == 0);
        }
    }
    ParseContext context;
    auto discarded = parse!(discard!(zeroOrMore!digit))(context, "123x");
    assert(discarded.end == 3 && discarded.matches.length == 0);
    auto unicode = parse!(fuse!(oneOrMore!(charRange!('α', 'ω'))))(context, "αβx");
    assert(unicode.matches == ["αβ"] && unicode.end == 4);
    enum mask = CharSetMask.fromRanges(['0', '9']);
    auto bytes = check!(oneOrMore!(charClass!mask))(context, "12x");
    assert(bytes.successful && bytes.end == 2 && bytes.arena.used == 0);
}

version (unittest) private State!(CT, Check).Node wrappedRun(bool CT, int Check = 0)(ref State!(CT,
        Check) state, size_t pos) nothrow {
    return and!(negLookahead!(or!(doublequote, backslash, charRange!(0, 31))), any)(state, pos);
}

@nogc nothrow unittest {
    alias run = and!(negLookahead!(or!(doublequote, backslash, charRange!(0, 31))), any);
    static assert(run.byteScanner);
    foreach (input; ["", "abc", "a\"", "a\\", "a\x01", "\xffa", "αβ"]) {
        foreach (budget; 0 .. 65) {
            ParseContext context;
            context.stepLimit = budget;
            auto scanned = parse!(fuse!(repeat!(run, 1, 3)))(context, input);
            auto generic = parse!(fuse!(repeat!(wrappedRun, 1, 3)))(context, input);
            assert(scanned.status == generic.status && scanned.successful == generic.successful);
            assert(scanned.end == generic.end && scanned.failEnd == generic.failEnd);
            assert(scanned.matches == generic.matches);
            auto checked = check!(repeat!(run, 1, 3))(context, input);
            auto reference = check!(repeat!(wrappedRun, 1, 3))(context, input);
            assert(checked.status == reference.status && checked.end == reference.end);
            assert(checked.failEnd == reference.failEnd && checked.arena.used == 0);
        }
    }
    alias positive = and!(posLookahead!(or!(literal!"a", literal!"b")), any);
    alias longest = and!(negLookahead!(longest_match!(literal!"a", literal!"b")), any);
    ParseContext context;
    auto yes = check!(oneOrMore!positive)(context, "abba!");
    assert(yes.successful && yes.end == 4);
    auto no = check!(oneOrMore!longest)(context, "cda");
    assert(no.successful && no.end == 2);
}

version (unittest) template unscanned(alias Rule) {
    State!(CT, Check).Node unscanned(bool CT, int Check = 0)(ref State!(CT, Check) state, size_t pos) nothrow {
        return Rule(state, pos);
    }
}

@nogc nothrow unittest {
    enum a = CharSetMask.fromRanges(['a', 'a']);
    enum b = CharSetMask.fromRanges(['b', 'b']);
    alias delimiters = predictiveChoice!(branch!(literal!"a", a), branch!(literal!"b", b));
    assert(delimiters.byteMatches('a') && delimiters.byteMatches('b'));
    assert(!delimiters.byteMatches('c'));
    // Work-unit model v2: terminals and choices are free, so the byte fast paths add nothing per byte.
    assert(delimiters.byteSteps('a') == 0 && delimiters.byteSteps('b') == 0);
    assert(delimiters.byteSteps('c') == 0);
    alias run = and!(negLookahead!delimiters, any);
    static assert(run.byteScanner);
    foreach (input; ["", "a", "b", "c", "cca", "\xffc"]) {
        foreach (budget; 0 .. 25) {
            ParseContext context;
            context.stepLimit = budget;
            auto scanned = parse!(fuse!(repeat!(run, 1, 3)))(context, input);
            auto generic = parse!(fuse!(repeat!(unscanned!run, 1, 3)))(context, input);
            assert(scanned.status == generic.status && scanned.successful == generic.successful);
            assert(scanned.end == generic.end && scanned.failEnd == generic.failEnd);
            assert(scanned.matches == generic.matches);
        }
    }
}

template zeroOrMore(alias r) {
    alias zeroOrMore = repeat!(r, 0);
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(zeroOrMore!digit)(context, "x");
    assert(result.successful && result.end == 0);
}

template oneOrMore(alias r) {
    alias oneOrMore = repeat!(r, 1);
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(oneOrMore!digit)(context, "12x");
    assert(result.end == 2);
}

template option(alias r) {
    alias option = repeat!(r, 0, 1);
}

@nogc nothrow unittest {
    ParseContext context;
    auto absent = parse!(option!digit)(context, "x");
    assert(absent.successful);
    auto present = parse!(option!digit)(context, "1");
    assert(present.end == 1);
}

struct lookahead(alias r, bool positive) {
    enum bytePredicate = __traits(hasMember, r, "byteScanner") && r.byteScanner;
    static if (bytePredicate) {
        static bool predicateMatches(ubyte c) @nogc nothrow pure {
            return r.byteMatches(c) == positive;
        }

        static size_t predicateSteps(ubyte c) @nogc nothrow pure {
            return r.byteSteps(c);
        }
    }
    static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        static if (Check == 1) {
            pragma(inline, true);
        }
        static if (Check == 2) {
            const checkpoint = s.records.length;
            const suppressed = s.records.suppressed;
            s.records.suppressed = true;
            scope (exit) {
                s.records.rollback(checkpoint);
                s.records.suppressed = suppressed;
            }
        }
        auto saved = s.furthestFailure;
        bool hadFailure = s.hasFailure;
        auto next = r(s, pos);
        auto nestedFailure = s.furthestFailure;
        bool nestedHadFailure = s.hasFailure;
        s.furthestFailure = saved;
        s.hasFailure = hadFailure;
        auto result = s.node(pos, pos, next.successful == positive);
        if (!result.successful) {
            static if (positive) {
                static if (!Check)
                    result.matches = next.matches;
                result.failEnd = next.failEnd;
                if (nestedHadFailure) {
                    static if (Check) {
                        auto failure = s.node(pos, pos, false);
                        failure.failEnd = nestedFailure.failEnd;
                        s.recordFailure(failure);
                    } else
                        s.recordFailure(nestedFailure);
                } else
                    s.recordFailure(result);
            } else
                result = s.failure(pos, "negative lookahead");
        }
        return result;
    }
}

@nogc nothrow unittest {
    State!(false, 1) limited;
    limited.input = "a";
    limited.steps = 2;
    limited.context.stepLimit = 1;
    assert(!lookahead!(and!(option!(literal!"a"), literal!"a"), true)(limited, 0).successful);
    assert(limited.status == Status.resourceLimit && limited.steps == 2);

    import npegged.meta : AliasSeq;

    alias bytes = or!(literal!"a", charRange!('0', '9'));
    alias predicted = predictiveChoice!(branch!(literal!"a", CharSetMask.fromChars('a')),
            branch!(literal!"b", CharSetMask.fromChars('b')));
    static foreach (child; AliasSeq!(and!(literal!"ab", literal!"c"), or!(literal!"abcd", literal!"ax"))) {
        static foreach (positive; [false, true]) {
            foreach (input; ["abx", "ab", "ax", "abc", "abcd"]) {
                ParseContext context;
                auto recognized = check!(lookahead!(child, positive))(context, input);
                auto legacy = parse!(lookahead!(child, positive))(context, input);
                assert(recognized.status == legacy.status);
                assert(recognized.end == legacy.end && recognized.failEnd == legacy.failEnd);
            }
        }
    }
    static foreach (child; AliasSeq!(bytes, predicted, literal!"a", charClass!(CharSetMask.fromChars('x')))) {
        static foreach (positive; [false, true]) {
            foreach (input; ["", "a", "b", "1", "x", "!", "\xff"]) {
                foreach (budget; 0 .. 12) {
                    ParseContext context;
                    context.stepLimit = budget;
                    auto fast = check!(lookahead!(child, positive))(context, input);
                    auto generic = check!(lookahead!(unscanned!child, positive))(context, input);
                    assert(fast.status == generic.status && fast.successful == generic.successful);
                    assert(fast.end == generic.end && fast.failEnd == generic.failEnd);
                }
            }
        }
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(lookahead!(digit, false))(context, "1");
    assert(!result.successful && result.end == 0);
}

template posLookahead(alias r) {
    alias posLookahead = lookahead!(r, true);
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(posLookahead!digit)(context, "x");
    assert(!result.successful);
}

/// A pure negative probe cannot match a nonempty input outside its FIRST set.
struct predictiveNot(alias r, ulong b0, ulong b1, ulong b2, ulong b3) {
    enum mask = CharSetMask([b0, b1, b2, b3]);
    enum bytePredicate = __traits(hasMember, r, "byteScanner") && r.byteScanner;
    static if (bytePredicate) {
        static bool predicateMatches(ubyte c) @nogc nothrow pure {
            return !mask.contains(c);
        }

        static size_t predicateSteps(ubyte c) @nogc nothrow pure {
            return r.byteSteps(c);
        }
    }
    static State!(CT, Check).Node opCall(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        static if (Check == 1) {
            pragma(inline, true);
        }
        if (s.context.trace is null && pos < s.input.length && !mask.contains(cast(ubyte)s.input[pos])) {
            if (!s.alive())
                return s.node(pos, pos, false);
            return s.node(pos, pos);
        }
        return negLookahead!r(s, pos);
    }
}

@nogc nothrow unittest {
    enum mask = CharSetMask.fromChars('a');
    alias probe = predictiveNot!(literal!"ab", mask.bits[0], mask.bits[1], mask.bits[2], mask.bits[3]);
    ParseContext context;
    foreach (input; ["", "x", "a", "ab", "ax"]) {
        auto expected = check!(negLookahead!(literal!"ab"))(context, input);
        auto result = check!probe(context, input);
        assert(result.successful == expected.successful && result.end == expected.end);
        assert(result.failEnd == expected.failEnd);
    }
    context.stepLimit = 0;
    // The probe charges nothing (model v2), with or without the FIRST shortcut.
    assert(check!probe(context, "x").successful && check!(negLookahead!(literal!"ab"))(context, "x").successful);
}

template negLookahead(alias r) {
    alias negLookahead = lookahead!(r, false);
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(negLookahead!digit)(context, "1");
    assert(!result.successful);
}

/// Tree transforms keep grammar nodes only; primitive combinators are flattened.
template transform(alias r, char operation) {
    State!(CT, Check).Node transform(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        static if ((operation == '~' || operation == ':') && __traits(hasMember, r, "scan")) {
            return r.scan!(operation == '~')(s, pos);
        } else static if (Check) {
            return r(s, pos);
        } else {
            auto result = r(s, pos);
            if (!result.successful)
                return result;
            static if (operation == '~') {
                string joined;
                if (!s.contiguousView(result.matches, joined)) {
                    size_t length;
                    foreach (match; result.matches) {
                        if (match.length > size_t.max - length) {
                            s.status = Status.resourceLimit;
                            result.successful = false;
                            return result;
                        }
                        length += match.length;
                    }
                    auto bytes = s.allocate!char(length);
                    size_t offset;
                    if (bytes.length == length)
                        foreach (match; result.matches) {
                            bytes[offset .. offset + match.length] = match[];
                            offset += match.length;
                        }
                    joined = cast(string)bytes;
                }
                if (result.matches.length)
                    result.matches = s.single(joined);
                result.children = null;
            } else static if (operation == ':') {
                result.matches = null;
                result.children = null;
            } else static if (operation == ';')
                result.children = null;
            else static if (operation == '%') {
                ParseTree[] children;
                foreach (child; result.children)
                    children = s.append(children, child.children);
                result.children = children;
            } else static if (operation == '^') {
                if (!result.children.length)
                    result.children = s.single(result);
            }
            return result;
        }
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(transform!(oneOrMore!digit, '~'))(context, "123");
    assert(result.matches == ["123"]);
}

@nogc nothrow unittest {
    ParseContext context;
    auto contiguous = parse!(transform!(and!(literal!"a", literal!"b"), '~'))(context, "ab");
    assert(contiguous.matches == ["ab"] && contiguous.matches[0].ptr == contiguous.input.ptr);
    auto spaced = parse!(transform!(wrapAround!(spacing, literal!"a", spacing), '~'))(context, " a ");
    assert(spaced.matches == ["a"] && spaced.matches[0].ptr == spaced.input.ptr + 1);
    auto changed = parse!(transform!(and!(caseInsensitiveLiteral!"a", literal!"b"), '~'))(context, "Ab");
    assert(changed.matches == ["ab"] && changed.matches[0].ptr != changed.input.ptr);
    auto empty = parse!(transform!(eps, '~'))(context, "");
    assert(empty.matches == [""]);
}

template fuse(alias r) {
    alias fuse = transform!(r, '~');
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(fuse!(and!(literal!"a", discard!(literal!"b"), literal!"c")))(context, "abc");
    assert(result.matches == ["ac"]);
}

template discard(alias r) {
    alias discard = transform!(r, ':');
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(and!(literal!"a", discard!(literal!"b")))(context, "ab");
    assert(result.matches == ["a"]);
}

template drop(alias r) {
    alias drop = transform!(r, ';');
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(drop!(defined!(literal!"a", "Node")))(context, "a");
    assert(result.matches == ["a"] && result.children.length == 0);
}

template propagate(alias r) {
    alias propagate = transform!(r, '%');
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(propagate!(defined!(defined!(literal!"a", "Child"), "Parent")))(context, "a");
    assert(result.children[0].name == "Child");
}

template keep(alias r) {
    alias keep = transform!(r, '^');
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(keep!(literal!"a"))(context, "a");
    assert(result.children.length == 1 && result.children[0].matches == ["a"]);
}

template discardChildren(alias r) {
    alias discardChildren = drop!r;
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(discardChildren!(defined!(literal!"a", "Node")))(context, "a");
    assert(result.children.length == 0);
}

template defined(alias r, string name) {
    pragma(inline, true) State!(CT, Check).Node defined(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        auto result = r(s, pos);
        static if (!Check)
            result.name = name;
        static if (!Check)
            if (result.matches.length || !result.successful)
                result.children = s.single(result);
        return result;
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(defined!(literal!"a", "Node"))(context, "a");
    assert(result.name == "Node" && result.children[0].name == "Node");
}

template named(alias r, string name) {
    pragma(inline, true) State!(CT, Check).Node named(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        auto result = r(s, pos);
        static if (!Check)
            result.name = name;
        return result;
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(named!(literal!"a", "Node"))(context, "a");
    assert(result.name == "Node" && result.children.length == 0);
}

template action(alias r, alias act) {
    State!(CT, Check).Node action(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        static if (Check) {
            return s.treeFallback!(npegged.peg.action!(r, act))(pos);
        } else {
            auto result = r(s, pos);
            if (s.status != Status.ok) {
                result.successful = false;
                return result;
            }
            static if (__traits(compiles, act(s, result)))
                result = act(s, result);
            else
                result = act(result);
            if (!result.successful)
                s.recordFailure(result);
            return result;
        }
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(action!(literal!"a", (ParseTree p) @nogc nothrow{ p.name = "acted"; return p; }))(context, "a");
    assert(result.name == "acted");
}

@nogc nothrow unittest {
    ParseContext context;
    alias inspected = action!(literal!"a", (ParseTree tree) @nogc nothrow{
        assert(tree.matches == ["a"]);
        tree.successful = tree.input.length == 1;
        return tree;
    });
    auto good = check!inspected(context, "a");
    assert(good.successful && good.arena.allocationCalls > 0);
    auto bad = check!inspected(context, "ab");
    assert(!bad.successful && bad.status == Status.mismatch);
    context.memoryLimit = 0;
    auto exhausted = check!inspected(context, "a");
    assert(!exhausted.successful && exhausted.status == Status.resourceLimit);
}

template wrapAround(alias before, alias target, alias after) {
    State!(CT, Check).Node wrapAround(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        auto leading = before(s, pos);
        if (!leading.successful)
            return leading;
        auto result = target(s, leading.end);
        if (!result.successful)
            return result;
        auto trailing = after(s, result.end);
        if (!trailing.successful)
            return trailing;
        result.begin = leading.begin;
        result.end = trailing.end;
        static if (!Check)
            if (result.children.length == 1 && result.children[0].name == result.name) {
                auto child = result.children[0];
                child.begin = result.begin;
                child.end = result.end;
                static if (!Check)
                    result.children = s.single(child);
            }
        return result;
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(wrapAround!(literal!"(", literal!"a", literal!")"))(context, "(a)");
    assert(result.end == 3 && result.matches == ["a"]);
    auto bad = parse!(wrapAround!(literal!"(", literal!"a", literal!")"))(context, "(a");
    assert(!bad.successful);
}

/// Combinator for action-free direct left recursion: E <- E Suffix / Base
template directAscent(alias Base, alias Suffix, string name) {
    State!(CT, Check).Node directAscent(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        return s.directLeftAscent!(Base, Suffix, name)(pos);
    }
}

@nogc nothrow unittest {
    ParseContext context;
    alias baseRule = literal!"1";
    alias suffixRule = and!(literal!"+", literal!"1");
    auto result = parse!(directAscent!(baseRule, suffixRule, "Expr"))(context, "1+1+1");
    assert(result.successful && result.end == 5);
    assert(result.children.length == 1);
    assert(result.children[0].name == "Expr");
    assert(result.matches == ["1", "+", "1", "+", "1"]);
}

alias digit = charRange!('0', '9');
alias alpha = charRange!('a', 'z');
alias Alpha = charRange!('A', 'Z');
alias hexDigit = charClass!(CharSetMask.fromRanges(['0', '9'], ['a', 'f'], ['A', 'F']));
alias endOfLine = or!(literal!"\r\n", literal!"\n", literal!"\r");
alias eol = endOfLine;
alias space = or!(literal!" ", literal!"\t", literal!"\v");
alias blank = or!(space, endOfLine);
alias tab = literal!"\t";
alias spaces = fuse!(oneOrMore!space);
alias spacing = discard!(zeroOrMore!blank);
alias digits = fuse!(oneOrMore!digit);
private enum identStartMask = () {
    auto m = CharSetMask.fromRanges(['a', 'z'], ['A', 'Z']);
    m.addChar('_');
    return m;
}();
private enum identCharMask = () {
    auto m = CharSetMask.fromRanges(['a', 'z'], ['A', 'Z'], ['0', '9']);
    m.addChar('_');
    return m;
}();
alias ident = and!(oneOrMore!(charClass!identStartMask), zeroOrMore!(charClass!identCharMask));
alias identifier = named!(fuse!ident, "identifier");
alias qualifiedIdentifier = fuse!(and!(identifier, zeroOrMore!(and!(literal!".", identifier))));
alias slash = literal!"/";
alias backslash = literal!"\\";
alias quote = literal!"'";
alias doublequote = literal!"\"";
alias backquote = literal!"`";
template list(alias element, alias separator) {
    alias list = and!(element, zeroOrMore!(and!(discard!separator, element)));
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(list!(digit, literal!","))(context, "1,2,3");
    assert(result.matches == ["1", "2", "3"]);
}

template list0(alias element, alias separator) {
    alias list0 = option!(list!(element, separator));
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(list0!(digit, literal!","))(context, "");
    assert(result.successful && result.end == 0);
}

@nogc nothrow unittest {
    ParseContext ctx;
    auto seq = parse!(and!(literal!"a", literal!"b"))(ctx, "ab");
    assert(seq.matches == ["a", "b"] && seq.end == 2);
    auto bad = parse!(and!(literal!"a", literal!"b"))(ctx, "ac");
    assert(!bad.successful && bad.failedChild.length == 1);
    auto alternatives = parse!(or!(literal!"x", literal!"ab"))(ctx, "ab");
    assert(alternatives.successful);
    auto longest = parse!(longest_match!(literal!"a", literal!"ab"))(ctx, "ab");
    assert(longest.end == 2);
    auto repeated = parse!(oneOrMore!digit)(ctx, "123x");
    assert(repeated.matches == ["1", "2", "3"]);
    auto none = parse!(oneOrMore!digit)(ctx, "x");
    assert(!none.successful);
    auto nullable = parse!(zeroOrMore!eps)(ctx, "");
    assert(nullable.successful);
    auto optional = parse!(option!digit)(ctx, "x");
    assert(optional.successful);
    auto positive = parse!(posLookahead!digit)(ctx, "1");
    assert(positive.end == 0 && positive.successful);
    auto negative = parse!(negLookahead!digit)(ctx, "x");
    assert(negative.successful);
    auto fused = parse!(fuse!(oneOrMore!digit))(ctx, "123");
    assert(fused.matches == ["123"]);
    auto id = parse!identifier(ctx, "hello_42");
    assert(id.matches == ["hello_42"]);
    auto range = parse!(charRange!('é', 'ê'))(ctx, "é");
    assert(range.end == 2);
}

/// Full Unicode folding, preserving Pegged's fixed byte-length literal consumption.
template caseInsensitiveLiteral(string text) {
    State!(CT, Check).Node caseInsensitiveLiteral(bool CT, int Check = 0)(ref State!(CT, Check) s, size_t pos) nothrow {
        if (!s.alive() || pos > s.input.length || text.length > s.input.length - pos
                || !caseEqual(s.input[pos .. pos + text.length], text))
            return s.failure(pos, text);
        auto result = s.node(pos, pos + text.length);
        static if (!Check)
            result.matches = s.single(text);
        return result;
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(caseInsensitiveLiteral!"Σ")(context, "σ");
    assert(result.successful && result.matches == ["Σ"]);
}

bool caseEqual(scope string a, scope string b) @nogc nothrow pure {
    import npegged.unicode : folded;

    size_t ap, bp;
    string af, bf;
    size_t ai, bi;
    dchar ac, bc;
    bool advance(scope string input, ref size_t pos, ref string expansion, ref size_t i, out dchar value) @nogc nothrow pure {
        if (i < expansion.length)
            return decode(expansion, i, value);
        if (!decode(input, pos, value))
            return false;
        expansion = folded(value);
        i = 0;
        if (expansion.length)
            return decode(expansion, i, value);
        return true;
    }

    while (ap < a.length || ai < af.length) {
        if (!advance(a, ap, af, ai, ac) || !advance(b, bp, bf, bi, bc) || ac != bc)
            return false;
    }
    return bp == b.length && bi == bf.length;
}

@nogc nothrow unittest {
    assert(caseEqual("AbCΣß", "abcσss"));
    assert(!caseEqual("x", "xx"));
    assert(!caseEqual("xy", "x"));
    assert(!caseEqual("\xff", "a"));
    assert(!caseEqual("a", "\xff"));
    ParseContext ctx;
    auto result = parse!(caseInsensitiveLiteral!"Begin")(ctx, "BEGIN");
    assert(result.successful && result.matches == ["Begin"]);
    auto bad = parse!(caseInsensitiveLiteral!"Begin")(ctx, "End");
    assert(!bad.successful);
}

/// Matches a boundary between alphabetic and non-alphabetic input (zero bytes).
State!(CT, Check).Node wordBoundary(bool CT, int Check = 0)(ref State!(CT, Check) state, size_t pos) nothrow {
    import npegged.unicode : isAlphabetic;

    bool left, right;
    dchar value;
    if (pos > 0 && pos <= state.input.length) {
        size_t start = pos - 1;
        while (start && (cast(ubyte)state.input[start] & 0xC0) == 0x80)
            --start;
        size_t end = start;
        left = decode(state.input, end, value) && end == pos && isAlphabetic(value);
    }
    if (pos < state.input.length) {
        size_t end = pos;
        right = decode(state.input, end, value) && isAlphabetic(value);
    }
    return left != right ? state.node(pos, pos) : state.failure(pos, "word boundary");
}

@nogc nothrow unittest {
    ParseContext context;
    auto start = parse!wordBoundary(context, "α");
    assert(start.successful && start.end == 0);
    auto finish = parse!(and!(literal!"α", wordBoundary))(context, "α ");
    assert(finish.successful);
    auto inside = parse!(and!(literal!"α", wordBoundary))(context, "αβ");
    assert(!inside.successful);
    auto empty = parse!wordBoundary(context, "");
    assert(!empty.successful);
}

template keywords(words...) {
    State!(CT, Check).Node keywords(bool CT, int Check = 0)(ref State!(CT, Check) state, size_t pos) nothrow {
        auto best = state.node(pos, pos, false);
        static foreach (word; words) {
            {
                auto candidate = literal!word(state, pos);
                if (candidate.successful)
                    return candidate;
            }
        }
        return best;
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(keywords!("interface", "int", "in"))(context, "interface");
    assert(result.successful && result.end == 9);
    auto bad = parse!(keywords!("in", "int"))(context, "x");
    assert(!bad.successful);
}

template discardMatches(alias parser) {
    State!(CT, Check).Node discardMatches(bool CT, int Check = 0)(ref State!(CT, Check) state, size_t pos) nothrow {
        auto result = parser(state, pos);
        if (result.successful)
            static if (!Check)
                result.matches = null;
        return result;
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(discardMatches!(defined!(literal!"a", "A")))(context, "a");
    assert(result.successful && result.matches.length == 0 && result.children.length == 1);
}

template spaceAnd(alias separator, parsers...) {
    State!(CT, Check).Node spaceAnd(bool CT, int Check = 0)(ref State!(CT, Check) state, size_t pos) nothrow {
        auto result = state.node(pos, pos);
        State!(CT, Check).Builder!string matches = {owner: &state};
        State!(CT, Check).Builder!ParseTree children = {owner: &state};
        static foreach (parser; parsers) {
            {
                auto part = wrapAround!(separator, parser, separator)(state, result.end);
                if (!part.successful)
                    return part;
                result.end = part.end;
                static if (!Check) {
                    matches.put(part.matches);
                    children.put(part.children);
                }
            }
        }
        static if (!Check)
            result.matches = matches.data();
        static if (!Check)
            result.children = children.data();
        return result;
    }
}

@nogc nothrow unittest {
    ParseContext context;
    auto result = parse!(spaceAnd!(spacing, literal!"a", literal!"b"))(context, " a b ");
    assert(result.successful && result.end == 5 && result.matches == ["a", "b"]);
}

struct Position {
    size_t line, col, index;
}

Position position(scope string input) @nogc nothrow pure {
    Position result;
    char previous = 0;
    foreach (c; input) {
        if (c == '\r' || c == '\n' && previous != '\r') {
            ++result.line;
            result.col = 0;
        } else if (c != '\n')
            ++result.col;
        previous = c;
        ++result.index;
    }
    return result;
}

@nogc nothrow unittest {
    assert(position("one\r\ntwo\r\nthree") == Position(2, 5, 15));
    assert(position("") == Position(0, 0, 0));
    assert(position("a\nb") == Position(1, 1, 3));
}

Position position(scope const ref ParseTree tree) @nogc nothrow pure {
    size_t end = tree.end <= tree.input.length ? tree.end : tree.input.length;
    return position(tree.input[0 .. end]);
}

@nogc nothrow unittest {
    ParseTree tree;
    tree.input = "a\nb";
    tree.end = 3;
    assert(position(tree) == Position(1, 1, 3));
}

@nogc nothrow unittest {
    ParseContext context;
    // Fail allocations and work budgets at different points in nested parser execution.
    foreach (budget; 0 .. 80) {
        context = ParseContext.init;
        context.memoryLimit = budget * 128;
        auto result = parse!(and!(defined!(fuse!(oneOrMore!digit), "Number"), literal!"x"))(context,
                "12345678901234567890x");
        assert(result.status == Status.ok || result.status == Status.resourceLimit);
        context = ParseContext.init;
        context.stepLimit = budget;
        auto limited = parse!(action!(oneOrMore!digit, (ParseTree tree) @nogc nothrow => tree))(context, "1234567890");
        assert(limited.status == Status.ok || limited.status == Status.resourceLimit);
    }
    auto leading = parse!(wrapAround!(literal!"(", literal!"a", literal!")"))(context, "a)");
    assert(!leading.successful);
    auto kept = parse!(keep!(defined!(literal!"a", "Child")))(context, "a");
    assert(kept.successful);
    auto failed = parse!(discardMatches!(literal!"a"))(context, "x");
    assert(!failed.successful);
    auto separated = parse!(spaceAnd!(spacing, literal!"a", literal!"b"))(context, " a x ");
    assert(!separated.successful);
    auto equalLength = parse!(caseInsensitiveLiteral!"abc")(context, "xyz");
    assert(!equalLength.successful);
    auto middle = parse!(and!(any, wordBoundary))(context, "α");
    assert(!middle.successful);
    auto word = parse!(and!(literal!"1", wordBoundary))(context, "1x");
    assert(word.successful);
    // Terminals charge nothing but fail as soon as a limit has fired (work-unit model v2).
    context.stepLimit = 0;
    assert(parse!any(context, "a").successful && parse!(charRange!('a', 'z'))(context, "a").successful);
    auto byteLimited = parse!(and!(option!(literal!"z"), any))(context, "a");
    assert(byteLimited.status == Status.resourceLimit);
    State!(false, 1) exhausted;
    exhausted.input = "a";
    exhausted.status = Status.resourceLimit;
    assert(!any(exhausted, 0).successful);
    assert(!caseInsensitiveLiteral!"a"(exhausted, 0).successful);
    assert(!charRange!('a', 'z')(exhausted, 0).successful);
    assert(!literal!"a"(exhausted, 0).successful);
}

@nogc nothrow unittest {
    ParseContext context;
    alias listParser = and!(literal!"[", digit, zeroOrMore!(and!(literal!",", digit)), literal!"]", eoi);
    auto invalid = parse!listParser(context, "[1,]");
    assert(invalid.status == Status.mismatch && invalid.failEnd == 3);
    auto diagnostic = invalid.failMsg;
    assert(diagnostic.data.length);
    auto valid = parse!listParser(context, "[1,2]");
    assert(valid.successful);
    // Failed matches inside a successful negative predicate must not override the real error.
    auto predicate = parse!(and!(negLookahead!(literal!"abc"), literal!"x"))(context, "abz");
    assert(!predicate.successful && predicate.failEnd == 0);
    auto positive = parse!(posLookahead!(literal!"abc"))(context, "abz");
    assert(positive.failEnd == 2);
    auto negative = parse!(negLookahead!(literal!"abc"))(context, "abc");
    assert(!negative.successful);
}
