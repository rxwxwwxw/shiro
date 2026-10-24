// Viewer commands: SDL input and the GUI panel both enqueue these; the main loop drains them,
// so there is one place where the Model is told to change (AGENTS.md §1.2).
module viewer.commands;

import gfx.hex_mesh : MeshOptions;
import td.game : GameCommand;
import wfc.map_session : GenParams;

enum CommandKind : ubyte {
    /// Generate a new map from ViewerState.params.
    regenerate,
    /// Rebuild the mesh only (view options changed).
    rebuildMesh,
    fitView,
    screenshot,
    quit,
    /// Leave tower defense for the village (the run counts as lost unless it was won).
    returnToVillage,
    /// Main menu: the story from the start (or a quick battle without one).
    newGame,
    /// A tower defense map with no story attached.
    quickBattle,
    /// The developer view: a tower defense map with the generation and debug panel.
    debugMap,
    /// Back to the main menu (the current run is dropped).
    mainMenu,
    /// Fullscreen / vsync changed in the settings.
    applyDisplay
}

/// Full-screen menus over the game. While one is up the game is paused and takes no input.
enum Screen : ubyte {
    none,
    mainMenu,
    pause,
    settings
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

/// Game commands from the keyboard, mouse and panel, applied by the main loop between ticks.
struct GameQueue {
    enum size_t capacity = 32;
    private GameCommand[capacity] items;
    private size_t head, count;

    bool push(const GameCommand c) @nogc nothrow pure @safe {
        if (count == capacity)
            return false;
        items[(head + count) % capacity] = c;
        count++;
        return true;
    }

    bool pop(out GameCommand c) @nogc nothrow pure @safe {
        if (count == 0)
            return false;
        c = items[head];
        head = (head + 1) % capacity;
        count--;
        return true;
    }
}

@nogc nothrow pure @safe unittest {
    import td.game : CommandType;

    GameQueue q;
    GameCommand c;
    assert(!q.pop(c));
    foreach (i; 0 .. GameQueue.capacity)
        assert(q.push(GameCommand(CommandType.place, cast(typeof(c.kind))0, 0, cast(int)i, 0)));
    assert(!q.push(GameCommand(CommandType.startWave)));
    foreach (i; 0 .. GameQueue.capacity)
        assert(q.pop(c) && c.col == i);
    assert(!q.pop(c));
}

/// Everything the panel edits and displays. Generation parameters take effect on `regenerate`.
struct ViewerState {
    GenParams params;
    MeshOptions mesh;
    /// Panel helper: target cell count for the 16:9 button.
    int targetCells = 5000;
    bool showPanel = true;
    /// Drift the water sparkle (needs a few redraws a second while water is visible).
    bool animateWater = true;
    /// Darken the screen edges like the reference's post-processing vignette.
    bool vignette = true;
    /// Animated film grain over the map (the reference's noise pass); off by default, it reads as a dirty window.
    bool grain = false;
    /// Cell under the pointer and the clicked cell (column, row); -1 when none.
    int hoverCol = -1, hoverRow = -1, selCol = -1, selRow = -1;
    /// Tower kind being placed (a td.defs.TowerKind), or -1.
    int buildKind = -1;
    /// Game speed: 0 = paused, else ticks run at this multiple of real time.
    int speed = 1;
    /// The scripted bot plays.
    bool bot;
    /// Last command's refusal (td.game.CommandError), shown in the panel briefly.
    int lastError;
    float errorTimer = 0;
    float fps = 0;
    size_t drawnVerts;
    /// A village story is running: tower defense runs start from and return to it.
    bool story;
    /// A story file loaded, so New game can start it.
    bool storyAvailable;
    /// Villagers who can man towers this visit: their crew ids (story speaker indexes) and names.
    ubyte[32] crewIds;
    const(char)[][32] crewNames;
    int numCrew;
    /// Name of crew id `id` ("nobody" for none).
    const(char)[] crewName(int id) const @nogc nothrow pure @safe {
        foreach (i; 0 .. numCrew)
            if (crewIds[i] == id)
                return crewNames[i];
        return "nobody";
    }

    /// Menu on screen, where Back from the settings returns to, and the open settings tab.
    Screen screen;
    Screen settingsFrom;
    int settingsTab;
    /// Developer view: the side panel with generation, tile and stats sections.
    bool debugView;
    bool fullscreen;
    bool vsync = true;
    /// Audio is not implemented; the settings show these disabled.
    float masterVolume = 0.8f, musicVolume = 0.6f, effectsVolume = 0.8f;
}
