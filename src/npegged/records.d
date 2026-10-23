/** Result-owned compact rule records and transactional output (Boost 1.0). */
module npegged.records;
import npegged.storage : Arena, Status, growthCapacity;

/// Preorder record. Kind tags are supplied by the caller's rule selector.
struct CompactNode {
    uint kind;
    size_t begin, end;
    size_t parent = size_t.max;
}

/// Frozen records retain their original base for parent-index rebasing on replay.
struct RecordSnapshot {
    CompactNode[] nodes;
    size_t base;
    version (NPeggedSharedOutput) {
        // Typed node slices are aligned. An odd empty-slice pointer encodes an
        // internal shared handle without growing this value or any memo entry.
        // The tagged pointer is never dereferenced as a CompactNode. Only the
        // enabled internal parser buffer decodes this protocol; generic public
        // snapshot APIs keep treating every empty slice as empty.
        private @property SharedRecordSnapshot fragments() const @nogc nothrow {
            if (!nodes.length && (cast(size_t)nodes.ptr & 1))
                return SharedRecordSnapshot(cast(const(RecordFragment)*)(cast(size_t)nodes.ptr & ~cast(size_t)1));
            return SharedRecordSnapshot.init;
        }

        private static RecordSnapshot fromShared(size_t base, SharedRecordSnapshot saved) @nogc nothrow {
            if (!saved.length)
                return RecordSnapshot(null, base);
            static assert(CompactNode.alignof > 1 && RecordFragment.alignof > 1);
            assert(!(cast(size_t)saved.root & 1));
            auto tagged = cast(CompactNode*)(cast(size_t)saved.root | 1);
            return RecordSnapshot(tagged[0 .. 0], base);
        }
    }
}

@nogc nothrow unittest {
    static assert(RecordSnapshot.sizeof == 3 * size_t.sizeof);
    version (NPeggedSharedOutput) {
        RecordSnapshot empty;
        assert(!empty.fragments.length);
        assert(!RecordSnapshot.fromShared(7, SharedRecordSnapshot.init).fragments.length);
        CompactNode[1] nodes;
        auto flat = RecordSnapshot(nodes[], 0);
        assert(!flat.fragments.length);
        auto tail = RecordSnapshot(nodes[$ .. $], size_t.max);
        assert(!tail.fragments.length);
    }
}

@nogc nothrow unittest {
    align(16) ubyte[64] bytes = 1;
    auto empty = (cast(CompactNode*)(bytes.ptr + 1))[0 .. 0];
    Arena owner;
    RecordBuffer buffer;
    buffer.arena = &owner;
    assert(buffer.restore(RecordSnapshot(empty, size_t.max)) && buffer.length == 0 && owner.used == 0);
    SharedRecordStore store;
    store.arena = &owner;
    assert(!store.freeze(RecordSnapshot(empty, size_t.max)).length && owner.used == 0);
}

version (NPeggedMetrics) {
    /// Actual output work, including appends subsequently rolled back on failure.
    struct RecordMetrics {
        ulong restoreCalls, restoreNodes, restoreBytes, growthCopyBytes;
        ulong snapshotCalls, snapshotNodes, snapshotBytes;
        version (NPeggedSharedOutput) ulong sharedSnapshots, sharedReusedNodes, sharedFrozenNodes, sharedReplays;
    }

    @nogc nothrow unittest {
        RecordMetrics metrics;
        assert(metrics.restoreCalls == 0 && metrics.restoreNodes == 0);
        assert(metrics.snapshotCalls == 0 && metrics.snapshotNodes == 0 && metrics.snapshotBytes == 0);
        assert(metrics.restoreBytes == 0 && metrics.growthCopyBytes == 0);
    }
}

/// Non-owning builder: both live storage and snapshots belong to explicit arenas.
struct RecordBuffer {
    Arena* arena;
    version (NPeggedMetrics) RecordMetrics* metrics;
    uint function(string) @nogc nothrow pure selector;
    private CompactNode[] storage;
    private size_t _length;
    size_t parent = size_t.max;
    bool suppressed;
    private Status failure;

    version (NPeggedSharedOutput) {
        private SharedRecordStore* sharedStore;
        private Arena* sharedArena;
        private RecordReplayFrame[] replayFrames;
        private struct ReplaySpan {
            size_t begin, end, parent;
            SharedRecordSnapshot saved;
        }

        private ReplaySpan[] spans;
        private size_t spanCount;

        package(npegged) @property bool sharingEnabled() const @nogc nothrow {
            return sharedStore !is null;
        }

        /// Internal parse policy: both arenas and the store must outlive this builder.
        package(npegged) bool enableSharedOutput(ref SharedRecordStore store, ref Arena scratch) @nogc nothrow {
            if (status != Status.ok)
                return false;
            if (store.arena !is &scratch) {
                failure = Status.invalidInput;
                return false;
            }
            if (store.status != Status.ok) {
                failure = store.status;
                return false;
            }
            sharedStore = &store;
            sharedArena = &scratch;
            return true;
        }

        pragma(inline, false) private bool restoreShared(SharedRecordSnapshot saved) @nogc nothrow {
            const base = _length;
            auto restored = sharedStore.restoreUsing(this, saved, *sharedArena, replayFrames, true);
            if (restored)
                restored = rememberShared(base, saved);
            if (!restored)
                rollback(base);
            version (NPeggedMetrics)
                if (metrics !is null)
                    ++metrics.sharedReplays;
            return restored;
        }

        private bool rememberShared(size_t begin, SharedRecordSnapshot saved) @nogc nothrow {
            if (!saved.length)
                return true;
            if (spanCount == spans.length) {
                auto replacement = sharedArena.allocate!ReplaySpan(growthCapacity(spanCount, spanCount + 1, 8));
                if (!replacement.length) {
                    failure = sharedArena.status;
                    return false;
                }
                replacement[0 .. spanCount] = spans[0 .. spanCount];
                spans = replacement;
            }
            assert(!spanCount || spans[spanCount - 1].end <= begin);
            spans[spanCount++] = ReplaySpan(begin, _length, parent, saved);
            return true;
        }

        private size_t coveringSpan(size_t index) const @nogc nothrow {
            if (!spanCount || index < spans[0].begin || index >= spans[spanCount - 1].end)
                return size_t.max;
            size_t low, high = spanCount;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (spans[middle].begin <= index)
                    low = middle + 1;
                else
                    high = middle;
            }
            return low && index < spans[low - 1].end ? low - 1 : size_t.max;
        }

        pragma(inline, false) private void invalidateShared(size_t index) @nogc nothrow {
            const span = coveringSpan(index);
            if (span != size_t.max)
                spans[span].saved = SharedRecordSnapshot.init;
        }

        pragma(inline, false) private RecordSnapshot sharedSnapshot(size_t checkpoint) @nogc nothrow {
            version (NPeggedMetrics) {
                const copiedBefore = sharedStore.frozenBytes;
                scope (exit)
                    if (metrics !is null) {
                        auto copied = sharedStore.frozenBytes - copiedBefore;
                        ++metrics.snapshotCalls;
                        metrics.snapshotBytes += copied;
                        metrics.snapshotNodes += copied / CompactNode.sizeof;
                        metrics.sharedFrozenNodes += copied / CompactNode.sizeof;
                    }
            }
            if (status != Status.ok)
                return RecordSnapshot.init;
            SharedRecordSnapshot saved;
            size_t cursor = checkpoint;
            size_t low, high = spanCount;
            while (low < high) {
                auto middle = low + (high - low) / 2;
                if (spans[middle].begin < checkpoint)
                    low = middle + 1;
                else
                    high = middle;
            }
            auto span = low;
            while (cursor < _length) {
                SharedRecordSnapshot piece;
                size_t attachment;
                bool reused;
                while (span < spanCount && (spans[span].begin < cursor || !spans[span].saved.length))
                    ++span;
                if (span < spanCount && spans[span].begin == cursor) {
                    assert(spans[span].end <= _length);
                    piece = spans[span].saved;
                    attachment = spans[span].parent;
                    cursor = spans[span++].end;
                    reused = true;
                } else {
                    // A dense leaf may have internal parents, but all of its
                    // external roots must share one attachment to the prefix.
                    const limit = span < spanCount ? spans[span].begin : _length;
                    attachment = storage[cursor].parent;
                    const canonical = attachment == size_t.max || attachment < checkpoint
                        ? size_t.max : attachment - checkpoint;
                    auto end = cursor + 1;
                    while (end < limit) {
                        const parentIndex = storage[end].parent;
                        if (parentIndex == size_t.max || parentIndex < cursor) {
                            const outside = parentIndex == size_t.max || parentIndex < checkpoint
                                ? size_t.max : parentIndex - checkpoint;
                            if (outside != canonical)
                                break;
                        }
                        ++end;
                    }
                    piece = sharedStore.freeze(RecordSnapshot(storage[cursor .. end], cursor));
                    cursor = end;
                }
                attachment = attachment == size_t.max || attachment < checkpoint ? size_t.max : attachment - checkpoint;
                saved = sharedStore.join(saved, piece, attachment);
                if (sharedStore.status != Status.ok) {
                    if (status == Status.ok)
                        failure = sharedStore.status;
                    return RecordSnapshot.init;
                }
                version (NPeggedMetrics)
                    if (metrics !is null && reused)
                        metrics.sharedReusedNodes += piece.length;
            }
            version (NPeggedMetrics)
                if (metrics !is null)
                    ++metrics.sharedSnapshots;
            return RecordSnapshot.fromShared(checkpoint, saved);
        }
    }

    @property size_t length() const @nogc nothrow {
        return _length;
    }

    @property Status status() const @nogc nothrow {
        return failure != Status.ok ? failure : arena is null ? Status.invalidInput : arena.status;
    }

    @property CompactNode[] nodes() return @nogc nothrow {
        version (NPeggedSharedOutput) {
            version (NPeggedFlatSpecialization) {
                if (sharedStore !is null)
                    spanCount = 0;
            } else {
                spanCount = 0;
            }
        }
        return storage[0 .. _length];
    }

    size_t put(CompactNode node) @nogc nothrow {
        if (status != Status.ok)
            return size_t.max;
        if (_length == size_t.max) {
            failure = Status.resourceLimit;
            return size_t.max;
        }
        if (node.parent != size_t.max && node.parent >= _length) {
            failure = Status.invalidInput;
            return size_t.max;
        }
        if (_length == storage.length && !grow())
            return size_t.max;
        storage[_length] = node;
        return _length++;
    }

    /// One more slot of capacity; false when the arena refuses (its status then reports why).
    private bool grow() @nogc nothrow {
        auto replacement = arena.allocate!CompactNode(growthCapacity(_length, _length + 1, 32));
        if (!replacement.length)
            return false;
        replacement[0 .. _length] = storage[0 .. _length];
        version (NPeggedMetrics)
            if (metrics !is null)
                metrics.growthCopyBytes += _length * CompactNode.sizeof;
        storage = replacement;
        return true;
    }

    /// O3: append a finished leaf record for a compiled leaf rule (`kind != uint.max`, no descendants). The status
    /// is not tested up front: the caller synchronizes it right after and rolls the record back when it is not ok,
    /// which is what the failed `put` of the open/finish pair amounted to. The parent is valid by construction
    /// (rollbacks never cut below an open ancestor) and `_length` cannot reach `size_t.max` before memory is gone.
    package(npegged) pragma(inline, true) void putLeaf(uint kind, size_t begin, size_t end) @nogc nothrow {
        if (suppressed)
            return;
        assert(kind != uint.max);
        assert(parent == size_t.max || parent < _length);
        if (_length == storage.length && !grow())
            return;
        version (NPeggedSharedOutput)
            assert(coveringSpan(_length) == size_t.max);
        storage[_length++] = CompactNode(kind, begin, end, parent);
    }

    size_t open(string name, size_t begin) @nogc nothrow {
        if (suppressed)
            return size_t.max;
        if (selector is null) {
            failure = Status.invalidInput;
            return size_t.max;
        }
        return openKind(selector(name), begin);
    }

    size_t openKind(uint kind, size_t begin) @nogc nothrow {
        if (suppressed || kind == uint.max)
            return size_t.max;
        auto index = put(CompactNode(kind, begin, begin, parent));
        if (index != size_t.max)
            parent = index;
        return index;
    }

    /// Capture wrappers finish the node they opened, outside every replay span.
    /// Debug builds verify this invariant; arbitrary edits use finish instead.
    package(npegged) pragma(inline, true) void finishFresh(size_t index, size_t end) @nogc nothrow {
        if (index != size_t.max) {
            assert(index < _length);
            version (NPeggedSharedOutput)
                assert(coveringSpan(index) == size_t.max);
            storage[index].end = end;
        }
    }

    pragma(inline, true) void finish(size_t index, size_t end) @nogc nothrow {
        if (index != size_t.max) {
            assert(index < _length);
            version (NPeggedSharedOutput) {
                version (NPeggedFlatSpecialization) {
                    if (sharedStore !is null && spanCount)
                        invalidateShared(index);
                } else {
                    if (spanCount)
                        invalidateShared(index);
                }
            }
            storage[index].end = end;
        }
    }

    void rollback(size_t checkpoint) @nogc nothrow {
        assert(checkpoint <= _length);
        _length = checkpoint;
        version (NPeggedSharedOutput) {
            version (NPeggedFlatSpecialization) {
                if (sharedStore !is null) {
                    while (spanCount && spans[spanCount - 1].end > checkpoint)
                        --spanCount;
                }
            } else {
                while (spanCount && spans[spanCount - 1].end > checkpoint)
                    --spanCount;
            }
        }
    }

    RecordSnapshot snapshot(ref Arena owner, size_t checkpoint) @nogc nothrow {
        assert(checkpoint <= _length);
        version (NPeggedSharedOutput)
            if (sharedStore !is null && sharedStore.arena is &owner && _length - checkpoint >= 4096 / CompactNode
                    .sizeof)
                return sharedSnapshot(checkpoint);
        auto frozen = owner.copy!CompactNode(storage[checkpoint .. _length]);
        version (NPeggedMetrics)
            if (metrics !is null) {
                ++metrics.snapshotCalls;
                metrics.snapshotNodes += frozen.length;
                metrics.snapshotBytes += frozen.length * CompactNode.sizeof;
            }
        return RecordSnapshot(frozen, checkpoint);
    }

    bool restore(RecordSnapshot saved) @nogc nothrow {
        version (NPeggedMetrics)
            if (metrics !is null)
                ++metrics.restoreCalls;
        if (!saved.nodes.length) {
            version (NPeggedSharedOutput)
                if (sharedStore !is null && saved.fragments.length)
                    return restoreShared(saved.fragments);
            return true;
        }
        const base = _length;
        bool complete;
        scope (exit)
            if (!complete)
                _length = base;
        foreach (i, original; saved.nodes) {
            auto node = original;
            if (node.parent == size_t.max || node.parent < saved.base)
                node.parent = parent;
            else {
                auto offset = node.parent - saved.base;
                if (offset >= i) {
                    failure = Status.invalidInput;
                    return false;
                }
                // offset names an already appended node, so this sum cannot wrap.
                node.parent = base + offset;
            }
            if (put(node) == size_t.max)
                return false;
            version (NPeggedMetrics)
                if (metrics !is null) {
                    ++metrics.restoreNodes;
                    metrics.restoreBytes += CompactNode.sizeof;
                }
        }
        complete = true;
        return true;
    }
}

version (NPeggedSharedOutput) @nogc nothrow unittest {
    Arena live, owner, destination;
    SharedRecordStore store;
    store.arena = &owner;
    RecordBuffer buffer, copy;
    buffer.arena = &live;
    copy.arena = &destination;
    assert(buffer.enableSharedOutput(store, owner));
    assert(copy.enableSharedOutput(store, owner));
    CompactNode[3] prefix = [
        CompactNode(0, 0, 200), CompactNode(1, 0, 50, 0), CompactNode(2, 0, 1, 1)
    ];
    auto saved = store.freeze(RecordSnapshot(prefix[], 0));
    assert(buffer.restore(RecordSnapshot.fromShared(0, saved)));
    assert(buffer.put(CompactNode(3, 2, 3, 1)) == 3);
    foreach (i; 4 .. 140)
        assert(buffer.put(CompactNode(cast(uint)i, i, i + 1, 0)) == i);
    auto frozen = buffer.snapshot(owner, 0);
    assert(copy.restore(frozen));
    assert(copy.storage[0 .. copy.length] == buffer.storage[0 .. buffer.length]);
    assert(copy.storage[3].parent == 1 && copy.storage[4].parent == 0);
}

version (NPeggedSharedOutput) @nogc nothrow unittest {
    Arena live, owner;
    SharedRecordStore store;
    store.arena = &owner;
    RecordBuffer buffer;
    buffer.arena = &live;
    assert(buffer.enableSharedOutput(store, owner));
    foreach (i; 0 .. 200)
        assert(buffer.put(CompactNode(cast(uint)i, i, i + 1, i ? 0 : size_t.max)) == i);
    auto first = buffer.snapshot(owner, 0);
    assert(first.fragments.length == 200 && !first.nodes.length);
    buffer.rollback(0);
    assert(buffer.restore(first) && buffer.spanCount == 1);
    auto again = buffer.snapshot(owner, 0);
    assert(again.fragments.root is first.fragments.root);
    buffer.finish(1, 999);
    assert(!buffer.spans[0].saved.length);
    auto changed = buffer.snapshot(owner, 0);
    Arena targetArena;
    RecordBuffer copy;
    copy.arena = &targetArena;
    assert(copy.enableSharedOutput(store, owner));
    assert(copy.restore(changed));
    assert(copy.nodes[1].end == 999);
    buffer.rollback(0);
    assert(buffer.restore(first));
    auto mutableView = buffer.nodes;
    mutableView[2].kind = 999;
    assert(buffer.spanCount == 0);
    auto exposed = buffer.snapshot(owner, 0);
    copy.rollback(0);
    assert(copy.restore(exposed) && copy.nodes[2].kind == 999);
    buffer.rollback(0);
    assert(buffer.restore(first));
    buffer.rollback(75);
    assert(buffer.spanCount == 0);
    foreach (i; 75 .. 200)
        assert(buffer.put(CompactNode(99, i, i + 1, 0)) == i);
    auto replacement = buffer.snapshot(owner, 0);
    copy.rollback(0);
    assert(copy.restore(replacement));
    assert(copy.nodes[74].kind == 74 && copy.nodes[75].kind == 99);
    // Partial checkpoint starts inside a replay: no partial span is inferred.
    buffer.rollback(0);
    assert(buffer.restore(first));
    auto tail = buffer.snapshot(owner, 1);
    copy.rollback(0);
    assert(copy.restore(tail) && copy.nodes.length == 199 && copy.nodes[0].parent == size_t.max);
    Arena separate;
    auto flat = buffer.snapshot(separate, 0);
    assert(flat.nodes.length == 200 && !flat.fragments.length);
    buffer.failure = Status.outOfMemory;
    const retained = owner.used;
    assert(!buffer.snapshot(owner, 0).fragments.length);
    assert(buffer.status == Status.outOfMemory && owner.used == retained);
}

version (NPeggedSharedOutput) @nogc nothrow unittest {
    Arena live, owner;
    SharedRecordStore store;
    store.arena = &owner;
    RecordBuffer buffer;
    buffer.arena = &live;
    assert(buffer.enableSharedOutput(store, owner));
    assert(buffer.put(CompactNode(10, 0, 100)) == 0);
    buffer.parent = 0;
    CompactNode[1] node = [CompactNode(1, 0, 1)];
    auto leaf = store.freeze(RecordSnapshot(node[], 0));
    auto single = RecordSnapshot.fromShared(0, leaf);
    foreach (i; 1 .. 10)
        assert(buffer.restore(single));
    assert(buffer.spanCount == 9 && buffer.replayFrames.length == 1);
    assert(buffer.coveringSpan(0) == size_t.max && buffer.coveringSpan(5) == 4);
    buffer.finishFresh(0, 101);
    buffer.finish(0, 101); // Outside the span interval.
    buffer.finish(5, 102); // Binary search into the middle of the span list.
    assert(!buffer.spans[4].saved.length && buffer.spans[3].saved.length == 1);
    assert(buffer.put(CompactNode(11, 0, 1, 0)) == 10);
    buffer.finish(10, 2); // Past the last replay span.
    buffer.rollback(5);
    assert(buffer.spanCount == 4);
    buffer.rollback(0);
    assert(buffer.rememberShared(0, SharedRecordSnapshot.init) && buffer.spanCount == 0);
    buffer.parent = size_t.max;
    foreach (i; 0 .. 200)
        assert(buffer.put(CompactNode(cast(uint)i, 0, 1, i ? 0 : size_t.max)) == i);
    auto saved = buffer.snapshot(owner, 0);
    buffer.rollback(0);
    assert(buffer.put(CompactNode(123, 0, 100)) == 0);
    buffer.parent = 0;
    assert(buffer.restore(saved));
    auto rebased = buffer.snapshot(owner, 0);
    Arena targetArena;
    RecordBuffer copy;
    copy.arena = &targetArena;
    assert(copy.enableSharedOutput(store, owner));
    assert(copy.restore(rebased));
    assert(copy.nodes.length == 201 && copy.nodes[1].parent == 0 && copy.nodes[2].parent == 1);
    auto sharedBefore = buffer.snapshot(owner, 1);
    assert(sharedBefore.fragments.root is saved.fragments.root);
}

version (NPeggedSharedOutput) @nogc nothrow unittest {
    Arena live, owner, other;
    SharedRecordStore store;
    store.arena = &owner;
    RecordBuffer missing;
    assert(!missing.enableSharedOutput(store, owner));
    RecordBuffer wrong;
    wrong.arena = &live;
    assert(!wrong.enableSharedOutput(store, other) && wrong.status == Status.invalidInput);
    owner.status = Status.outOfMemory;
    RecordBuffer failed;
    failed.arena = &live;
    assert(!failed.enableSharedOutput(store, owner) && failed.status == Status.outOfMemory);
    // Force span registration to fail after a successful one-node replay.
    Arena source, exhausted, output;
    exhausted.limit = 4096;
    SharedRecordStore sourceStore, limited;
    sourceStore.arena = &source;
    limited.arena = &exhausted;
    CompactNode[1] node;
    auto leaf = sourceStore.freeze(RecordSnapshot(node[], 0));
    RecordBuffer partial;
    partial.arena = &output;
    assert(partial.enableSharedOutput(limited, exhausted));
    partial.replayFrames = exhausted.allocate!RecordReplayFrame(1);
    enum filler = 4096 - 2 * size_t.sizeof - RecordReplayFrame.sizeof - 8 * RecordBuffer.ReplaySpan.sizeof + 1;
    assert(exhausted.allocate!ubyte(filler).length == filler);
    assert(!partial.restore(RecordSnapshot.fromShared(0, leaf)));
    assert(partial.status == Status.resourceLimit && partial.length == 0);
}

version (NPeggedMetrics) @nogc nothrow unittest {
    Arena owner;
    RecordMetrics metrics;
    RecordBuffer records;
    records.arena = &owner;
    records.metrics = &metrics;
    CompactNode[33] nodes;
    assert(records.restore(RecordSnapshot(nodes[], 0)));
    assert(metrics.restoreCalls == 1 && metrics.restoreNodes == 33);
    assert(metrics.restoreBytes == 33 * CompactNode.sizeof);
    assert(metrics.growthCopyBytes == 32 * CompactNode.sizeof);
    assert(records.restore(RecordSnapshot.init));
    assert(metrics.restoreCalls == 2 && metrics.restoreNodes == 33);
    Arena snapshots;
    auto frozen = records.snapshot(snapshots, 1);
    assert(frozen.nodes.length == 32);
    assert(metrics.snapshotCalls == 1 && metrics.snapshotNodes == 32);
    assert(metrics.snapshotBytes == 32 * CompactNode.sizeof);
    assert(records.snapshot(snapshots, records.length).nodes.length == 0);
    assert(metrics.snapshotCalls == 2 && metrics.snapshotNodes == 32);
    Arena noSnapshot;
    noSnapshot.limit = 0;
    assert(records.snapshot(noSnapshot, 0).nodes.length == 0);
    assert(metrics.snapshotCalls == 3 && metrics.snapshotNodes == 32);
    CompactNode[2] corrupt = [CompactNode.init, CompactNode(0, 0, 0, 1)];
    assert(!records.restore(RecordSnapshot(corrupt[], 0)));
    assert(metrics.restoreCalls == 3 && metrics.restoreNodes == 34);
    assert(metrics.restoreBytes == 34 * CompactNode.sizeof && records.length == 33);
    Arena exhausted;
    exhausted.limit = 0;
    RecordBuffer failed;
    failed.arena = &exhausted;
    failed.metrics = &metrics;
    assert(!failed.restore(RecordSnapshot(nodes[0 .. 1], 0)));
    assert(metrics.restoreCalls == 4 && metrics.restoreNodes == 34);
}

@nogc nothrow unittest {
    Arena owner, snapshots;
    RecordBuffer records;
    records.arena = &owner;
    records.selector = (string name) @nogc nothrow => name == "skip" ? uint.max : 7;
    assert(records.open("skip", 0) == size_t.max && records.length == 0);
    auto root = records.open("root", 0);
    assert(root == 0 && records.parent == 0);
    auto child = records.open("child", 1);
    records.finish(child, 2);
    records.parent = root;
    records.finish(root, 3);
    assert(records.nodes[1].parent == 0 && records.nodes[0].end == 3);
    auto saved = records.snapshot(snapshots, 1);
    records.rollback(1);
    records.parent = size_t.max;
    auto other = records.open("other", 4);
    assert(other == 1);
    assert(records.restore(saved));
    assert(records.nodes[2].parent == 1 && records.nodes[2].begin == 1);
    foreach (i; 0 .. 70)
        assert(records.put(CompactNode(8, i, i + 1, 1)) != size_t.max);
    assert(records.nodes.length == 73 && saved.nodes[0].begin == 1);
    auto nested = records.snapshot(snapshots, 1);
    records.rollback(1);
    records.parent = 0;
    assert(records.restore(nested));
    assert(records.nodes[1].parent == 0 && records.nodes[2].parent == 1);
    records.suppressed = true;
    assert(records.open("ignored", 99) == size_t.max && records.length == 73);
    records.finish(size_t.max, 99);
    assert(records.openKind(8, 99) == size_t.max);
    records.suppressed = false;
    assert(records.openKind(uint.max, 99) == size_t.max);
    assert(records.status == Status.ok);
    Arena limited;
    limited.limit = 0;
    RecordBuffer failed;
    failed.arena = &limited;
    assert(failed.put(CompactNode.init) == size_t.max && failed.status == Status.resourceLimit);
    assert(!failed.restore(saved));
    RecordBuffer invalid;
    assert(invalid.status == Status.invalidInput && invalid.put(CompactNode.init) == size_t.max);
    invalid.arena = &owner;
    assert(invalid.open("x", 0) == size_t.max && invalid.status == Status.invalidInput);
    RecordBuffer overflow;
    overflow.arena = &owner;
    overflow._length = size_t.max;
    assert(overflow.put(CompactNode.init) == size_t.max && overflow.status == Status.resourceLimit);
    CompactNode[2] corrupt = [CompactNode(0, 0, 1), CompactNode(0, 1, 2, 1)];
    records.parent = 0;
    auto originalLength = records.length;
    assert(!records.restore(RecordSnapshot(corrupt[], 0)) && records.status == Status.invalidInput);
    assert(records.length == originalLength);
    RecordBuffer badParent;
    badParent.arena = &owner;
    assert(badParent.put(CompactNode(0, 0, 1, 0)) == size_t.max);
    assert(badParent.status == Status.invalidInput && badParent.length == 0);
}

/// Experimental immutable record composition. Handles borrow their component arenas.
/// Only explicit fragment composition shares storage; arbitrary flat input is copied.
struct SharedRecordSnapshot {
    private const(RecordFragment)* root;
    @property size_t length() const @nogc nothrow {
        return root is null ? 0 : root.length;
    }
}

@nogc nothrow unittest {
    SharedRecordSnapshot empty;
    assert(empty.length == 0);
}

private struct RecordFragment {
    const(RecordFragment)* left, right;
    const(CompactNode)[] nodes;
    size_t length, height;
    size_t attachment = size_t.max;
}

private struct RecordReplayFrame {
    const(RecordFragment)* fragment;
    size_t base, parent;
}

/// Non-owning experimental store. Every component arena must outlive its handles and replay.
/// Callers must prove composition or import a full flat copy; parser use is an opt-in policy.
struct SharedRecordStore {
    Arena* arena;
    private Status failure;
    /// Cumulative diagnostic work; linking existing fragments never increases frozenBytes.
    version (NPeggedMetrics) ulong frozenBytes, replayBytes, fragmentCount;

    @property Status status() const @nogc nothrow {
        return failure != Status.ok ? failure : arena is null ? Status.invalidInput : arena.status;
    }

    /// Conservative fallback: validate, copy and normalize all parent indices.
    SharedRecordSnapshot freeze(RecordSnapshot saved) @nogc nothrow {
        if (status != Status.ok || !saved.nodes.length)
            return SharedRecordSnapshot.init;
        foreach (i, node; saved.nodes)
            if (node.parent != size_t.max && node.parent >= saved.base && node.parent - saved.base >= i) {
                failure = Status.invalidInput;
                return SharedRecordSnapshot.init;
            }
        auto fragment = arena.allocate!RecordFragment(1);
        if (!fragment.length)
            return SharedRecordSnapshot.init;
        auto copy = arena.copy!CompactNode(saved.nodes);
        if (!copy.length)
            return SharedRecordSnapshot.init;
        foreach (ref node; copy)
            node.parent = node.parent == size_t.max || node.parent < saved.base ? size_t.max : node.parent - saved.base;
        fragment[0].nodes = copy;
        fragment[0].length = copy.length;
        fragment[0].height = 1;
        version (NPeggedMetrics) {
            frozenBytes += copy.length * CompactNode.sizeof;
            ++fragmentCount;
        }
        return SharedRecordSnapshot(&fragment[0]);
    }

    /// Right external roots attach to an earlier left node or to the replay parent.
    /// Internal parent references in both operands remain unchanged.
    SharedRecordSnapshot join(SharedRecordSnapshot left, SharedRecordSnapshot right, size_t attachment = size_t.max) @nogc nothrow {
        if (status != Status.ok)
            return SharedRecordSnapshot.init;
        if (attachment != size_t.max && attachment >= left.length) {
            failure = Status.invalidInput;
            return SharedRecordSnapshot.init;
        }
        if (left.length > size_t.max - right.length) {
            failure = Status.resourceLimit;
            return SharedRecordSnapshot.init;
        }
        if (!right.length)
            return left;
        if (!left.length)
            return right;
        auto height = left.root.height > right.root.height ? left.root.height : right.root.height;
        if (height == size_t.max) {
            failure = Status.resourceLimit;
            return SharedRecordSnapshot.init;
        }
        auto fragment = arena.allocate!RecordFragment(1);
        if (!fragment.length)
            return SharedRecordSnapshot.init;
        fragment[0].left = left.root;
        fragment[0].right = right.root;
        fragment[0].attachment = attachment;
        fragment[0].length = left.length + right.length;
        fragment[0].height = height + 1;
        version (NPeggedMetrics)
            ++fragmentCount;
        return SharedRecordSnapshot(&fragment[0]);
    }

    /// Iterative replay uses bounded scratch arena space; failure rolls output length back.
    bool restore(ref RecordBuffer output, SharedRecordSnapshot saved, ref Arena scratch) @nogc nothrow {
        RecordReplayFrame[] frames;
        return restoreUsing(output, saved, scratch, frames, false);
    }

    private bool restoreUsing(ref RecordBuffer output, SharedRecordSnapshot saved, ref Arena scratch,
            ref RecordReplayFrame[] stack, bool accountMetrics) @nogc nothrow {
        if (output.status != Status.ok)
            return false;
        if (status != Status.ok) {
            output.failure = status;
            return false;
        }
        if (!saved.length)
            return true;
        const checkpoint = output.length;
        if (saved.length > size_t.max - checkpoint) {
            output.failure = Status.resourceLimit;
            return false;
        }
        // Reuse is internal: the builder's scratch arena outlives all its replays.
        if (saved.root.height > stack.length) {
            auto replacement = scratch.allocate!RecordReplayFrame(growthCapacity(stack.length, saved.root.height, 0));
            if (!replacement.length) {
                output.failure = scratch.status;
                return false;
            }
            stack = replacement;
        }
        bool complete;
        scope (exit)
            if (!complete)
                output.rollback(checkpoint);
        size_t count = 1;
        stack[0] = RecordReplayFrame(saved.root, checkpoint, output.parent);
        // The checked total length bounds every descendant base/parent addition.
        while (count) {
            auto frame = stack[--count];
            auto fragment = frame.fragment;
            if (fragment.left !is null) {
                stack[count++] = RecordReplayFrame(fragment.right, frame.base + fragment.left.length,
                        fragment.attachment == size_t.max ? frame.parent : frame.base + fragment.attachment);
                stack[count++] = RecordReplayFrame(fragment.left, frame.base, frame.parent);
            } else {
                foreach (original; fragment.nodes) {
                    CompactNode node = original;
                    node.parent = node.parent == size_t.max ? frame.parent : frame.base + node.parent;
                    if (output.put(node) == size_t.max)
                        return false;
                    version (NPeggedMetrics) {
                        replayBytes += CompactNode.sizeof;
                        if (accountMetrics && output.metrics !is null) {
                            ++output.metrics.restoreNodes;
                            output.metrics.restoreBytes += CompactNode.sizeof;
                        }
                    }
                }
            }
        }
        complete = true;
        return true;
    }
}

@nogc nothrow unittest {
    version (NPeggedMetrics) {
    } else {
        static assert(!__traits(hasMember, SharedRecordStore, "frozenBytes"));
        static assert(!__traits(hasMember, SharedRecordStore, "replayBytes"));
        static assert(!__traits(hasMember, SharedRecordStore, "fragmentCount"));
    }
    Arena owner, live, scratch;
    SharedRecordStore store;
    store.arena = &owner;
    assert(store.status == Status.ok);
    assert(!store.freeze(RecordSnapshot.init).length && owner.used == 0);
    CompactNode[2] input = [CompactNode(1, 3, 8, 5), CompactNode(2, 4, 6, 7)];
    auto leaf = store.freeze(RecordSnapshot(input[], 7));
    assert(leaf.length == 2);
    version (NPeggedMetrics)
        assert(store.frozenBytes == 2 * CompactNode.sizeof);
    input[0].kind = 99;
    CompactNode[1] root = [CompactNode(3, 0, 9)];
    auto outer = store.freeze(RecordSnapshot(root[], 0));
    auto nested = store.join(outer, leaf, 0);
    auto sibling = store.join(nested, leaf);
    assert(sibling.length == 5);
    version (NPeggedMetrics)
        assert(store.frozenBytes == 3 * CompactNode.sizeof && store.fragmentCount == 4);
    assert(store.join(SharedRecordSnapshot.init, leaf).length == 2);
    assert(store.join(leaf, SharedRecordSnapshot.init).length == 2);
    RecordBuffer output;
    output.arena = &live;
    assert(output.put(CompactNode(9, 0, 10)) == 0);
    output.parent = 0;
    assert(store.restore(output, sibling, scratch));
    assert(output.nodes[1] == CompactNode(3, 0, 9, 0));
    assert(output.nodes[2] == CompactNode(1, 3, 8, 1));
    assert(output.nodes[3] == CompactNode(2, 4, 6, 2));
    assert(output.nodes[4] == CompactNode(1, 3, 8, 0));
    assert(output.nodes[5] == CompactNode(2, 4, 6, 4));
    output.rollback(1);
    assert(store.restore(output, leaf, scratch));
    assert(output.nodes[1] == CompactNode(1, 3, 8, 0));
    assert(output.nodes[2] == CompactNode(2, 4, 6, 1));
    assert(store.restore(output, SharedRecordSnapshot.init, scratch));
    version (NPeggedMetrics)
        assert(store.replayBytes == 7 * CompactNode.sizeof);
}

@nogc nothrow unittest {
    SharedRecordStore missing;
    assert(missing.status == Status.invalidInput);
    assert(!missing.freeze(RecordSnapshot.init).length);
    assert(!missing.join(SharedRecordSnapshot.init, SharedRecordSnapshot.init).length);
    Arena memory, live, scratch;
    RecordBuffer output;
    output.arena = &live;
    assert(!missing.restore(output, SharedRecordSnapshot.init, scratch));
    assert(output.status == Status.invalidInput);
    SharedRecordStore invalid;
    invalid.arena = &memory;
    CompactNode[1] corrupt = [CompactNode(0, 0, 1, 0)];
    assert(!invalid.freeze(RecordSnapshot(corrupt[], 0)).length);
    assert(invalid.status == Status.invalidInput && memory.used == 0);
    assert(!invalid.freeze(RecordSnapshot.init).length);
    SharedRecordStore attachment;
    attachment.arena = &memory;
    assert(!attachment.join(SharedRecordSnapshot.init, SharedRecordSnapshot.init, 0).length);
    assert(attachment.status == Status.invalidInput);
    SharedRecordStore overflow;
    overflow.arena = &memory;
    RecordFragment huge, small;
    huge.length = size_t.max;
    small.length = 1;
    assert(!overflow.join(SharedRecordSnapshot(&huge), SharedRecordSnapshot(&small)).length);
    assert(overflow.status == Status.resourceLimit);
    SharedRecordStore depth;
    depth.arena = &memory;
    huge.length = 1;
    huge.height = size_t.max;
    assert(!depth.join(SharedRecordSnapshot(&huge), SharedRecordSnapshot(&small)).length);
    assert(depth.status == Status.resourceLimit);
}

@nogc nothrow unittest {
    CompactNode[1] node;
    Arena frozen;
    SharedRecordStore store;
    store.arena = &frozen;
    auto saved = store.freeze(RecordSnapshot(node[], 0));
    assert(saved.length == 1);
    Arena unavailable, live;
    unavailable.limit = 0;
    RecordBuffer output;
    output.arena = &live;
    assert(!store.restore(output, saved, unavailable));
    assert(output.length == 0 && output.status == Status.resourceLimit);
    RecordBuffer noOutput;
    assert(!store.restore(noOutput, saved, live));
    Arena limited, scratch;
    limited.limit = 0;
    RecordBuffer failed;
    failed.arena = &limited;
    assert(!store.restore(failed, saved, scratch));
    assert(failed.length == 0 && failed.status == Status.resourceLimit);
    Arena empty;
    empty.limit = 0;
    SharedRecordStore cannotFreeze;
    cannotFreeze.arena = &empty;
    assert(!cannotFreeze.freeze(RecordSnapshot(node[], 0)).length);
    assert(cannotFreeze.status == Status.resourceLimit);
    // Fragment allocation fits, but the larger leaf copy must fail.
    Arena tight;
    tight.limit = 4096;
    SharedRecordStore partial;
    partial.arena = &tight;
    CompactNode[200] many;
    assert(!partial.freeze(RecordSnapshot(many[], 0)).length);
    assert(partial.status == Status.resourceLimit);
    version (NPeggedMetrics)
        assert(partial.frozenBytes == 0);
}

@nogc nothrow unittest {
    Arena owner;
    SharedRecordStore store;
    store.arena = &owner;
    CompactNode[100] many;
    auto saved = store.freeze(RecordSnapshot(many[], 0));
    Arena limited, scratch;
    limited.limit = 4096;
    RecordBuffer output;
    output.arena = &limited;
    assert(output.put(CompactNode(9, 0, 1)) == 0);
    output.parent = 0;
    assert(!store.restore(output, saved, scratch));
    assert(output.length == 1 && output.nodes[0].kind == 9);
    assert(output.status == Status.resourceLimit);
    version (NPeggedMetrics)
        assert(store.replayBytes > 0);
    Arena unavailable;
    unavailable.limit = 0;
    SharedRecordStore cannotJoin;
    cannotJoin.arena = &unavailable;
    assert(!cannotJoin.join(saved, saved).length);
    assert(cannotJoin.status == Status.resourceLimit);
    // Replay size overflow is checked before appending.
    RecordFragment huge;
    huge.length = size_t.max;
    huge.height = 1;
    Arena live, work;
    RecordBuffer overflow;
    overflow.arena = &live;
    assert(overflow.put(CompactNode.init) == 0);
    assert(!store.restore(overflow, SharedRecordSnapshot(&huge), work));
    assert(overflow.length == 1 && overflow.status == Status.resourceLimit && work.used == 0);
}

@nogc nothrow unittest {
    Arena memory, live, scratch;
    SharedRecordStore store;
    store.arena = &memory;
    CompactNode[1] node;
    auto saved = store.freeze(RecordSnapshot(node[], 0));
    RecordBuffer output;
    output.arena = &live;
    output.parent = 0; // No preceding parent exists in the destination.
    assert(!store.restore(output, saved, scratch));
    assert(output.length == 0 && output.status == Status.invalidInput);
}

@nogc nothrow unittest {
    Arena live, scratch;
    RecordBuffer output;
    output.arena = &live;
    output.failure = Status.resourceLimit;
    SharedRecordStore missing;
    assert(!missing.restore(output, SharedRecordSnapshot.init, scratch));
    assert(output.status == Status.resourceLimit);
}

/// O3: `putLeaf` is `openKind` + `finishFresh` for a childless record, including growth, suppression and failure.
@nogc nothrow unittest {
    Arena owner;
    RecordBuffer fast, reference;
    fast.arena = reference.arena = &owner;
    // Across the first growth steps and with a non-root parent.
    const root = fast.put(CompactNode(1, 0, 100));
    assert(root == reference.put(CompactNode(1, 0, 100)));
    fast.parent = reference.parent = root;
    foreach (i; 0 .. 200) {
        fast.putLeaf(7, i, i + 1);
        const index = reference.openKind(7, i);
        reference.parent = root;
        reference.finishFresh(index, i + 1);
    }
    assert(fast.nodes == reference.nodes && fast.length == 201);
    assert(fast.nodes[200] == CompactNode(7, 199, 200, root));
    // Suppressed output records nothing.
    fast.suppressed = true;
    fast.putLeaf(7, 0, 1);
    assert(fast.length == 201);
    fast.suppressed = false;
    // Rolling back after a leaf restores the previous length.
    const before = fast.length;
    fast.putLeaf(8, 3, 4);
    assert(fast.length == before + 1);
    fast.rollback(before);
    assert(fast.length == before && fast.status == Status.ok);
    // A refused growth leaves the buffer unchanged and reports the arena status.
    Arena tiny;
    tiny.limit = 0;
    RecordBuffer starved;
    starved.arena = &tiny;
    starved.putLeaf(1, 0, 1);
    assert(starved.length == 0 && starved.status != Status.ok);
}
