/** RAII storage for npegged, a derivative of Philippe Sigaud's Pegged (Boost 1.0). */
module npegged.storage;

import core.stdc.stdlib : malloc, free;
import core.stdc.string : memcpy;

enum Status {
    ok,
    mismatch,
    outOfMemory,
    resourceLimit,
    invalidInput,
    ioError
}

/// Checked geometric capacity, also usable during CTFE.
size_t growthCapacity(size_t current, size_t required, size_t minimum) @nogc nothrow pure {
    if (current > size_t.max / 2)
        return required;
    size_t next = current * 2;
    if (next < required)
        next = required;
    return next < minimum ? minimum : next;
}

@nogc nothrow unittest {
    assert(growthCapacity(0, 1, 32) == 32);
    assert(growthCapacity(32, 33, 32) == 64);
    assert(growthCapacity(32, 100, 32) == 100);
    assert(growthCapacity(size_t.max, size_t.max, 32) == size_t.max);
}

/// Noncopyable arena. Allocation never moves existing objects.
struct Arena {
    private struct Block {
        Block* next;
        size_t bytes;
    }

    private Block* head;
    private ubyte* cursor;
    private size_t available;
    private enum slabBytes = 4096;
    size_t limit = 256 * 1024 * 1024;
    /// Cumulative successful allocator bytes, including block/alignment overhead.
    size_t used;
    /// Actual allocator invocations, including an invocation that returns null.
    size_t allocationCalls;
    /// Cumulative payload bytes from successful allocations (excludes overhead).
    size_t requestedBytes;
    Status status;
    private static void* systemAllocate(size_t bytes) @nogc nothrow {
        return malloc(bytes);
    }

    /// Custom allocation must return malloc-compatible memory, or null.
    void* function(size_t) @nogc nothrow allocator = &systemAllocate;
    @disable this(this);
    @disable this(ref Arena);
    pragma(inline, true) ~this() @nogc nothrow {
        while (head !is null) {
            auto next = head.next;
            free(head);
            head = next;
        }
    }

    T[] allocate(T)(size_t count) @nogc nothrow if (__traits(isPOD, T)) {
        if (!count)
            return null;
        if (status != Status.ok)
            return null;
        enum alignment = T.alignof > Block.alignof ? T.alignof : Block.alignof;
        enum overhead = Block.sizeof + alignment - 1;
        if (count > (size_t.max - overhead) / T.sizeof) {
            status = Status.resourceLimit;
            return null;
        }
        size_t payload = count * T.sizeof;
        if (used > limit) {
            status = Status.resourceLimit;
            return null;
        }
        size_t padding = (alignment - (cast(size_t)cursor & (alignment - 1))) & (alignment - 1);
        T* data;
        if (cursor !is null && padding <= available && payload <= available - padding) {
            data = cast(T*)(cursor + padding);
            cursor += padding + payload;
            available -= padding + payload;
        } else {
            size_t minimum = payload + overhead;
            if (minimum > limit - used) {
                status = Status.resourceLimit;
                return null;
            }
            size_t bytes = minimum < slabBytes ? slabBytes : minimum;
            if (bytes > limit - used)
                bytes = limit - used;
            ++allocationCalls;
            auto block = cast(Block*)allocator(bytes);
            if (block is null) {
                status = Status.outOfMemory;
                return null;
            }
            block.next = head;
            block.bytes = bytes;
            head = block;
            used += bytes;
            auto start = cast(ubyte*)(block + 1);
            padding = (alignment - (cast(size_t)start & (alignment - 1))) & (alignment - 1);
            data = cast(T*)(start + padding);
            // Dedicated oversized blocks must not displace a partially used slab.
            if (minimum <= slabBytes) {
                cursor = cast(ubyte*)(data + count);
                available = bytes - Block.sizeof - padding - payload;
            }
        }
        requestedBytes += payload;
        foreach (i; 0 .. count)
            data[i] = T.init;
        return data[0 .. count];
    }

    T[] copy(T)(scope const(T)[] input) @nogc nothrow if (__traits(isPOD, T)) {
        auto result = allocate!T(input.length);
        if (result.length)
            memcpy(result.ptr, input.ptr, input.length * T.sizeof);
        return result;
    }
}

@nogc nothrow unittest {
    static assert(!__traits(compiles, { Arena memory; auto invalid = memory.allocate!Arena(1); }));
    static assert(!__traits(compiles, { Buffer!Arena invalid; }));
    Arena arena;
    assert(arena.allocate!int(0).length == 0);
    assert(arena.allocationCalls == 0 && arena.requestedBytes == 0 && arena.used == 0);
    auto first = arena.allocate!int(2);
    assert(arena.allocationCalls == 1 && arena.requestedBytes == 2 * int.sizeof);
    assert(arena.used > arena.requestedBytes);
    assert(first == [0, 0]);
    first[0] = 42;
    auto second = arena.copy!int(first);
    assert(second == [42, 0]);
    assert(first.ptr != second.ptr);
    assert(arena.allocationCalls == 1 && arena.requestedBytes == 4 * int.sizeof);
    arena.limit = arena.used;
    assert(arena.allocate!ubyte(arena.available + 1).length == 0);
    assert(arena.status == Status.resourceLimit);
    assert(arena.allocationCalls == 1 && arena.requestedBytes == 4 * int.sizeof);
    Arena failed;
    failed.allocator = (size_t bytes) @nogc nothrow => cast(void*)null;
    assert(failed.allocate!int(1).length == 0 && failed.status == Status.outOfMemory);
    assert(failed.allocate!int(1).length == 0);
    assert(failed.allocationCalls == 1 && failed.requestedBytes == 0 && failed.used == 0);
    Arena overflow;
    assert(overflow.allocate!ulong(size_t.max).length == 0);
    assert(overflow.status == Status.resourceLimit);
    assert(overflow.allocationCalls == 0 && overflow.requestedBytes == 0 && overflow.used == 0);
}

@nogc nothrow unittest {
    struct Aligned {
        align(64) ulong value = 17;
    }

    Arena arena;
    auto prefix = arena.allocate!ubyte(1);
    prefix[0] = 93;
    auto aligned = arena.allocate!Aligned(2);
    assert(cast(size_t)aligned.ptr % Aligned.alignof == 0);
    assert(aligned[0].value == 17 && aligned[1].value == 17);
    auto calls = arena.allocationCalls;
    auto large = arena.allocate!ubyte(8192);
    assert(large.length == 8192 && arena.allocationCalls == calls + 1);
    auto tail = arena.allocate!ubyte(1);
    assert(tail.length == 1 && arena.allocationCalls == calls + 1);
    assert(prefix[0] == 93 && aligned[0].value == 17);
    Arena bounded;
    bounded.limit = 64;
    assert(bounded.allocate!ubyte(8).length == 8);
    assert(bounded.used == 64);
    auto remaining = bounded.available;
    assert(bounded.allocate!ubyte(remaining).length == remaining);
    assert(bounded.allocate!ubyte(1).length == 0);
    assert(bounded.status == Status.resourceLimit);
    Arena independent;
    auto other = independent.allocate!ubyte(1);
    other[0] = 12;
    assert(prefix[0] == 93 && other[0] == 12);
}

/// A growable, move-only buffer for utilities outside the parser.
struct Buffer(T) if (__traits(isPOD, T)) {
    private Arena arena;
    private T[] storage;
    private size_t length;
    private Status failure;
    @disable this(this);
    @disable this(ref Buffer);
    @property T[] data() return @nogc nothrow {
        return storage[0 .. length];
    }

    @property const(T)[] data() const return @nogc nothrow {
        return storage[0 .. length];
    }

    @property Status status() const @nogc nothrow {
        return failure != Status.ok ? failure : arena.status;
    }

    @property void memoryLimit(size_t bytes) @nogc nothrow {
        arena.limit = bytes;
    }

    bool put(scope const(T)[] values) @nogc nothrow {
        if (values.length > size_t.max - length) {
            failure = Status.resourceLimit;
            return false;
        }
        auto required = length + values.length;
        if (required > storage.length) {
            size_t capacity = growthCapacity(storage.length, required, 32);
            auto replacement = arena.allocate!T(capacity);
            if (!replacement.length)
                return false;
            replacement[0 .. length] = storage[0 .. length];
            storage = replacement;
        }
        storage[length .. required] = values[];
        length = required;
        return true;
    }

    bool put(T value) @nogc nothrow {
        return put((&value)[0 .. 1]);
    }

    void clear() @nogc nothrow {
        length = 0;
    }
}

@nogc nothrow unittest {
    Buffer!char text;
    assert(text.put("hello"));
    assert(text.put('!'));
    assert(text.data == "hello!");
    assert(text.put("0123456789012345678901234567890123456789"));
    assert(text.data.length == 46);
    text.clear();
    assert(text.data.length == 0);
    assert(text.status == Status.ok);
}

@nogc nothrow unittest {
    Buffer!char buffer;
    buffer.memoryLimit = 0;
    assert(!buffer.put("data") && buffer.status == Status.resourceLimit);
}

@nogc nothrow unittest {
    Arena arena;
    assert(arena.allocate!char(1).length == 1);
    arena.limit = 0;
    assert(arena.allocate!char(1).length == 0);
    Buffer!char overflow;
    overflow.length = size_t.max;
    assert(!overflow.put('x') && overflow.status == Status.resourceLimit);
}
