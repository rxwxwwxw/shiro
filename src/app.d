// Shiro hex map viewer: generates WFC maps (Model) and shows them with SDL3 + Nuklear.
//
//   scripts/build_third_party.sh && scripts/build_viewer.sh
//   bin/shiro_viewer --layout island --radius 8 --rings 2 --seed 7
module app;

import bindings.sdl3.sdl;
import core.result : EngineError;
import core.stdc.stdio : fprintf, printf, snprintf, stderr;
import gfx.camera;
import gfx.hex_mesh;
import gfx.renderer;
import gfx.sdl_handles;
import gui.nuklear_ui;
import viewer.cli;
import viewer.commands;
import wfc.map_session;

private struct Viewer {
    MapSession* session;
    MapMesh mesh;
    MapRenderer renderer;
    Camera camera;
    ViewerState state;
    CommandQueue queue;
    bool running = true;
    bool dragging;
    int screenshotCount;

    @disable this(this);

    ~this() @nogc nothrow {
        MapSession.release(session);
    }

    /// Regenerates the map from state.params; on bad params the old map stays.
    void regenerate() @nogc nothrow @trusted {
        immutable r = session.regenerate(state.params);
        if (r.isErr) {
            fprintf(stderr, "regenerate rejected (error %d): check sizes / radius / rings\n", r.error);
            return;
        }
        const st = r.value;
        printf("seed %u: %d x %d, %zu grids solved, %zu failed, %zu mountains, %.1f ms\n", state.params.seed,
                session.tiles.rect.cols, session.tiles.rect.rows, st.gridsSolved, st.gridsFailed,
                session.tiles.countMountains, session.genMillis);
        rebuildMesh();
        fitView();
    }

    void rebuildMesh() @nogc nothrow @trusted {
        if (!mesh.build(*session, state.mesh) || !renderer.prepare(mesh))
            fprintf(stderr, "out of memory building the map mesh\n");
    }

    void fitView() @nogc nothrow @safe {
        camera.fit(mesh.minX, mesh.minY, mesh.maxX, mesh.maxY);
    }

    void setViewport(float w, float h) @nogc nothrow @safe {
        immutable x0 = state.showPanel ? panelWidth : 0;
        camera.setViewport(x0, w - x0, h);
    }

    /// Camera and hotkeys; `uiCapturing` means the panel owns the mouse / keyboard this frame.
    void onEvent(ref const SDL_Event e, bool uiCapturing) @nogc nothrow @trusted {
        switch (e.type) {
        case SDL_EVENT_QUIT:
        case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
            queue.push(CommandKind.quit);
            break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            dragging = !uiCapturing;
            break;
        case SDL_EVENT_MOUSE_BUTTON_UP:
            dragging = false;
            break;
        case SDL_EVENT_MOUSE_MOTION:
            if (dragging)
                camera.pan(e.motion.xrel, e.motion.yrel);
            break;
        case SDL_EVENT_MOUSE_WHEEL:
            if (!uiCapturing) {
                import core.stdc.math : expf;

                camera.zoomAt(expf(e.wheel.y * 0.15f), e.wheel.mouse_x, e.wheel.mouse_y);
            }
            break;
        case SDL_EVENT_KEY_DOWN:
            if (uiCapturing)
                break;
            enum float step = 60;
            switch (e.key.key) {
            case SDLK_ESCAPE:
                queue.push(CommandKind.quit);
                break;
            case SDLK_R:
                state.params.seed = (state.params.seed * 1664525u + 1013904223u) & int.max;
                queue.push(CommandKind.regenerate);
                break;
            case SDLK_F:
                queue.push(CommandKind.fitView);
                break;
            case SDLK_O:
                state.mesh.outlines = !state.mesh.outlines;
                queue.push(CommandKind.rebuildMesh);
                break;
            case SDLK_TAB:
                state.showPanel = !state.showPanel;
                break;
            case SDLK_W, SDLK_UP:
                camera.pan(0, step);
                break;
            case SDLK_S, SDLK_DOWN:
                camera.pan(0, -step);
                break;
            case SDLK_A, SDLK_LEFT:
                camera.pan(step, 0);
                break;
            case SDLK_D, SDLK_RIGHT:
                camera.pan(-step, 0);
                break;
            case SDLK_EQUALS:
                camera.zoomAt(1.25f, camera.x0 + camera.width * 0.5f, camera.height * 0.5f);
                break;
            case SDLK_MINUS:
                camera.zoomAt(0.8f, camera.x0 + camera.width * 0.5f, camera.height * 0.5f);
                break;
            default:
                break;
            }
            break;
        default:
            break;
        }
    }
}

int main(string[] args) {
    auto parsed = parseArgs(args[1 .. $]);
    if (parsed.isErr) {
        if (parsed.error == CliError.help) {
            printf("%.*s", cast(int)usage.length, usage.ptr);
            return 0;
        }
        fprintf(stderr, "invalid arguments (error %d)\n%.*s", parsed.error, cast(int)usage.length, usage.ptr);
        return 2;
    }
    const cfg = parsed.value;
    return run(cfg);
}

private int run(ref const ViewerConfig cfg) @nogc nothrow @trusted {
    SdlVideo video;
    if (video.open() != EngineError.None)
        return 1;
    Window window;
    if (window.open("Shiro - Hex Map WFC", cfg.width, cfg.height,
            SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY) != EngineError.None)
        return 1;
    Renderer ren;
    if (ren.open(window) != EngineError.None)
        return 1;
    // Render in window points; the high-density backbuffer keeps it sharp.
    immutable scale = SDL_GetWindowDisplayScale(window.handle) > 0 ? SDL_GetWindowDisplayScale(window.handle) : 1.0f;
    SDL_SetRenderScale(ren.handle, scale, scale);
    NuklearContext ui;
    if (ui.open(window.handle, ren.handle, scale) != EngineError.None)
        return 1;

    auto created = MapSession.create();
    if (created.isErr)
        return 1;
    Viewer v;
    v.session = created.value;
    v.state.params = cfg.params;
    v.state.showPanel = !cfg.hasScreenshot;

    float viewW = 0, viewH = 0;
    void updateViewport() {
        int pw, ph;
        SDL_GetCurrentRenderOutputSize(ren.handle, &pw, &ph);
        viewW = pw / scale;
        viewH = ph / scale;
        v.setViewport(viewW, viewH);
    }

    updateViewport();
    v.regenerate();
    if (v.session.tiles.rect.cols == 0)
        return 1; // the initial parameters were rejected

    immutable freq = cast(double)SDL_GetPerformanceFrequency();
    ulong last = SDL_GetPerformanceCounter();
    while (v.running) {
        SDL_Event e;
        immutable capturing = ui.capturing();
        while (SDL_PollEvent(&e)) {
            ui.handle(ren.handle, &e); // also converts e to render coordinates
            v.onEvent(e, capturing);
        }
        immutable wasPanel = v.state.showPanel;
        drawPanel(ui, v.state, v.queue, *v.session, v.mesh, viewH);

        bool screenshot = cfg.hasScreenshot;
        CommandKind cmd;
        while (v.queue.pop(cmd)) {
            final switch (cmd) {
            case CommandKind.regenerate:
                v.regenerate();
                break;
            case CommandKind.rebuildMesh:
                v.rebuildMesh();
                break;
            case CommandKind.fitView:
                v.fitView();
                break;
            case CommandKind.screenshot:
                screenshot = true;
                break;
            case CommandKind.quit:
                v.running = false;
                break;
            }
        }
        updateViewport();
        if (wasPanel != v.state.showPanel)
            v.fitView();

        SDL_SetRenderDrawColor(ren.handle, 24, 52, 78, 255);
        SDL_RenderClear(ren.handle);
        v.renderer.draw(ren.handle, v.mesh, v.camera);
        v.state.drawnVerts = v.renderer.drawnVerts;
        ui.render();
        if (screenshot) {
            char[1100] path = void;
            const(char)* out_ = cfg.screenshot.ptr;
            if (!cfg.hasScreenshot) {
                snprintf(path.ptr, path.length, "shiro_seed%u_%d.bmp", v.state.params.seed, v.screenshotCount++);
                out_ = path.ptr;
            }
            if (saveScreenshot(ren.handle, out_) == EngineError.None)
                printf("saved %s\n", out_);
            else if (cfg.hasScreenshot)
                return 1;
            if (cfg.hasScreenshot)
                return 0;
        }
        SDL_RenderPresent(ren.handle);

        immutable now = SDL_GetPerformanceCounter();
        immutable dt = (now - last) / freq;
        last = now;
        if (dt > 0)
            v.state.fps = v.state.fps * 0.9f + cast(float)(1.0 / dt) * 0.1f;
    }
    return 0;
}
