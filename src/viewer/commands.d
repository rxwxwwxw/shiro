// Viewer commands: SDL input and the GUI panel both enqueue these; the main loop drains them,
// so there is one place where the Model is told to change (AGENTS.md §1.2).
module viewer.commands;

import gfx.hex_mesh : MeshOptions;
import wfc.map_session : GenParams;

enum CommandKind : ubyte {
    /// Generate a new map from ViewerState.params.
    regenerate,
    /// Rebuild the mesh only (view options changed).
    rebuildMesh,
    fitView,
    screenshot,
    quit
}

/// Fixed-capacity FIFO. Duplicate pending commands collapse into one.
struct CommandQueue {
    enum size_t capacity = 16;
    private CommandKind[capacity] items;
    private size_t head, count;

    bool push(CommandKind k) @nogc nothrow pure @safe {
        foreach (i; 0 .. count)
            if (items[(head + i) % capacity] == k)
                return true;
        if (count == capacity)
            return false;
        items[(head + count) % capacity] = k;
        count++;
        return true;
    }

    bool pop(out CommandKind k) @nogc nothrow pure @safe {
        if (count == 0)
            return false;
        k = items[head];
        head = (head + 1) % capacity;
        count--;
        return true;
    }

    bool empty() const @nogc nothrow pure @safe {
        return count == 0;
    }
}

@nogc nothrow pure @safe unittest {
    CommandQueue q;
    CommandKind k;
    assert(q.empty && !q.pop(k));
    assert(q.push(CommandKind.regenerate) && q.push(CommandKind.fitView));
    assert(q.push(CommandKind.regenerate)); // collapsed
    assert(q.pop(k) && k == CommandKind.regenerate);
    assert(q.pop(k) && k == CommandKind.fitView);
    assert(!q.pop(k) && q.empty);
    // Wraps around the ring; distinct kinds only, so it never fills in practice.
    foreach (round; 0 .. 40) {
        assert(q.push(cast(CommandKind)(round % 5)));
        assert(q.pop(k) && k == cast(CommandKind)(round % 5));
    }
}

/// Everything the panel edits and displays. Generation parameters take effect on `regenerate`.
struct ViewerState {
    GenParams params;
    MeshOptions mesh;
    /// Panel helper: target cell count for the 16:9 button.
    int targetCells = 5000;
    bool showPanel = true;
    float fps = 0;
    size_t drawnVerts;
}
