// Shiro hex map viewer: generates WFC maps (Model) and shows them with SDL3 + Nuklear.
//
//   scripts/build_third_party.sh && scripts/build_viewer.sh
//   bin/shiro_viewer --layout island --radius 8 --rings 2 --seed 7
module app;

import bindings.sdl3.sdl;
import core.result : EngineError;
import core.stdc.stdio : fprintf, printf, snprintf, stderr;
import core.stdc.string : strlen;
import gfx.camera;
import gfx.glb;
import gfx.hex_mesh;
import gfx.highlight;
import gfx.iso : cellCenter, levelStep, squash;
import gfx.pick;
import gfx.overview;
import gfx.particles;
import gfx.renderer;
import gfx.sdl_handles;
import gfx.td_overlay;
import gui.nuklear_ui;
import td.bot;
import td.defs : cellUnits, halfHex, rowUnits, Stage, ticksPerSecond, TowerKind;
import td.game;
import viewer.cli;
import viewer.commands;
import wfc.map_session;

/// Elevation-blended copies of the texture atlas (one per level) and their edge length in pixels.
private enum int blendVariants = 5, blendSize = 512;
/// Palette grading calibrated against pixels of the reference's own screenshot.
private enum float paletteSaturation = 1.0f, paletteExposure = 0.9f;
/// Pixels a press may travel and still count as a click; tallest cell top in levels, for picking.
private enum float clickSlop = 4, maxCellHeight = 8;
private enum string defaultAssets = "third-party/Hex-Map-WFC/public/assets";

private struct Viewer {
    MapSession* session;
    GlbModel glb;
    Texture texture;
    Texture caustic;
    Texture grain;
    MapMesh mesh;
    Overview overview;
    MapRenderer renderer;
    Camera camera;
    ViewerState state;
    CommandQueue queue;
    /// The tower defense game on the current map (inactive when the map has no roads).
    Game game;
    Bot bot;
    GameQueue gameQueue;
    TdOverlay overlay;
    Particles fx;
    /// Real time not yet simulated, in seconds; the overlay interpolates by the leftover.
    double simAcc = 0;
    bool running = true;
    bool dragging;
    int screenshotCount;
    /// Pointer in render units, whether it is over the window, and where the current press began.
    float mouseX = 0, mouseY = 0, downX = 0, downY = 0;
    bool mouseIn, moved, clickPending;

    @disable this(this);

    ~this() @nogc nothrow {
        MapSession.release(session);
    }

    /// Finds the cell under the pointer (not while the panel owns it or a drag pans the map) and
    /// turns a pending click into the selection.
    void updatePicking(bool uiCapturing) @nogc nothrow @trusted {
        state.hoverCol = state.hoverRow = -1;
        if (mouseIn && !uiCapturing && !(dragging && moved) && mouseX >= camera.x0 && mesh.rows > 0) {
            float heightAt(int c, int r) @nogc nothrow {
                float level;
                mesh.cellLevel(c, r, level);
                return level;
            }

            int c, r;
            if (pickCell(camera, mouseX, mouseY, session.tiles.rect.cols, session.tiles.rect.rows,
                    maxCellHeight, &heightAt, c, r)) {
                state.hoverCol = c;
                state.hoverRow = r;
            }
        }
        if (clickPending) {
            if (state.buildKind >= 0 && state.hoverCol >= 0)
                gameQueue.push(GameCommand(CommandType.place, cast(TowerKind)state.buildKind, 0,
                        state.hoverCol, state.hoverRow));
            else {
                state.selCol = state.hoverCol;
                state.selRow = state.hoverRow;
            }
        }
        clickPending = false;
    }

    /// Hover and selection markers over the map.
    void drawMarkers(SDL_Renderer* sdl) @nogc nothrow @trusted {
        void mark(int col, int row, ref const Marker m) {
            float level;
            if (col < 0 || !mesh.cellLevel(col, row, level))
                return;
            float[2][6] pts;
            cellOutline(camera, col, row, level, pts);
            drawHexMarker(sdl, pts, m);
        }

        static immutable Marker hover = Marker(SDL_FColor(1, 1, 1, 0.20f), SDL_FColor(1, 1, 1, 0.85f), 2);
        static immutable Marker selected = Marker(SDL_FColor(1, 0.85f, 0.3f, 0.18f), SDL_FColor(1, 0.8f, 0.2f, 1), 3);
        static immutable Marker canBuild = Marker(SDL_FColor(0.3f, 1, 0.4f, 0.25f), SDL_FColor(0.4f, 1, 0.5f, 1), 3);
        static immutable Marker cannotBuild = Marker(SDL_FColor(1, 0.25f, 0.2f, 0.25f),
                SDL_FColor(1, 0.3f, 0.25f, 1), 3);
        if (state.buildKind >= 0 && game.active)
            mark(state.hoverCol, state.hoverRow, game.canPlace(cast(TowerKind)state.buildKind,
                    state.hoverCol, state.hoverRow) == CommandError.none ? canBuild : cannotBuild);
        else if (state.hoverCol != state.selCol || state.hoverRow != state.selRow)
            mark(state.hoverCol, state.hoverRow, hover);
        mark(state.selCol, state.selRow, selected);
    }

    /// Regenerates the map from state.params; on bad params the old map stays.
    void regenerate(SDL_Renderer* sdl) @nogc nothrow @trusted {
        immutable r = session.regenerate(state.params);
        if (r.isErr) {
            if (r.error == EngineError.PlacementFailed || r.error == EngineError.RoutingFailed)
                fprintf(stderr, "regenerate failed: no room for %d sources / %d sinks with their roads\n",
                        state.params.routes.place.sources, state.params.routes.place.sinks);
            else
                fprintf(stderr, "regenerate rejected (error %d): check sizes / radius / rings\n", r.error);
            return;
        }
        state.selCol = state.selRow = state.hoverCol = state.hoverRow = -1;
        startGame();
        const st = r.value;
        printf("seed %u: %d x %d, %zu grids solved, %zu failed, %zu mountains, %.1f ms\n", state.params.seed,
                session.tiles.rect.cols, session.tiles.rect.rows, st.gridsSolved, st.gridsFailed,
                session.tiles.countMountains, session.genMillis);
        if (state.params.routes.enabled)
            printf(
                    "  %d routes (%d loops), %d/%d sources connected, %d/%d sinks reached, %zu leaks, %s, %d attempt(s)\n",
                    session.network.numRoutes, session.network.numLoops,
                    session.routeReport.sourcesConnected, session.routeReport.sources,
                    session.routeReport.sinksReached,
                    session.routeReport.sinks, session.routeReport.leakCells,
                    session.routeReport.ok ? "valid".ptr : "INVALID".ptr, session.routeAttempts);
        rebuildMesh(sdl);
        fitView();
    }

    /// New game on the current map (none without roads).
    void startGame() @nogc nothrow @trusted {
        simAcc = 0;
        if (state.params.routes.enabled && session.network.allocated) {
            game.start(*session, state.params.seed);
            bot.setup(game);
        } else
            game.stop();
        fx.reset(game);
    }

    /// Reacts to what the last tick or command did: rebuilds the cells whose tower changed.
    void onSimEvents() @nogc nothrow @trusted {
        fx.onEvents(game.events);
        foreach (ref e; game.events) {
            if (e.kind != EventKind.built && e.kind != EventKind.upgraded && e.kind != EventKind.sold)
                continue;
            immutable row = e.y / rowUnits;
            mesh.invalidateCell((e.x / halfHex - (row & 1)) / 2, row);
        }
    }

    /// Applies queued commands from the keyboard, mouse and panel.
    void applyCommands() @nogc nothrow @trusted {
        if (!game.active)
            return;
        game.clearEvents();
        GameCommand c;
        while (gameQueue.pop(c)) {
            immutable err = game.apply(c);
            if (err != CommandError.none) {
                state.lastError = err;
                state.errorTimer = 2.5f;
            }
        }
        onSimEvents();
    }

    /// One simulation tick, the bot's turn, and the View's reaction.
    void stepOnce() @nogc nothrow @trusted {
        game.advance();
        if (state.bot)
            bot.act(game);
        onSimEvents();
    }

    /// Runs the ticks `dt` seconds of play call for at the current speed (at most a few per frame,
    /// so a slow frame does not snowball).
    void stepGame(double dt) @nogc nothrow @trusted {
        if (!game.active || state.speed == 0)
            return;
        enum double tickLen = 1.0 / ticksPerSecond;
        simAcc += dt * state.speed;
        int steps = 0;
        while (simAcc >= tickLen) {
            if (steps++ == 12) {
                simAcc = 0;
                break;
            }
            stepOnce();
            simAcc -= tickLen;
        }
    }

    bool gameRunning() const @nogc nothrow @safe {
        return game.active && state.speed > 0 && (game.status == GameStatus.waiting || game.status == GameStatus.wave);
    }

    void upgradeSelected(int branch) @nogc nothrow @trusted {
        const t = game.towerAt(state.selCol, state.selRow);
        if (t is null)
            return;
        // U only goes to Lv2; Q / E pick the specialization from there.
        if ((branch < 0) != (t.stage == Stage.lv1))
            return;
        gameQueue.push(GameCommand(CommandType.upgrade, t.kind, cast(ubyte)(branch < 0 ? 0 : branch), t.col, t.row));
    }

    bool haveModel() const @nogc nothrow @safe {
        return glb.loaded && texture.handle !is null;
    }

    void rebuildMesh(SDL_Renderer* sdl) @nogc nothrow @trusted {
        if (!mesh.setup(*session, state.mesh, haveModel ? &glb : null, texture.variants))
            fprintf(stderr, "out of memory preparing the map mesh\n");
        mesh.setGame(&game);
        if (!overview.build(sdl, *session))
            fprintf(stderr, "could not build the overview image\n");
    }

    void fitView() @nogc nothrow @safe {
        camera.fit(mesh.minX, mesh.minY, mesh.maxX, mesh.maxY);
    }

    void setViewport(float w, float h) @nogc nothrow @safe {
        immutable x0 = state.showPanel ? panelWidth : 0;
        camera.setViewport(x0, w - x0, h);
    }

    /// Loads hex-terrain.glb and its texture from the assets directory (the --assets flag, else
    /// the repository copy relative to the working directory or the executable). Without them the
    /// viewer still runs, with flat shapes.
    void loadModel(ref Renderer ren, ref const ViewerConfig cfg) @nogc nothrow @trusted {
        char[2048] path = void;
        const(char)* base = SDL_GetBasePath();
        size_t dirLen;
        foreach (attempt; 0 .. 3) {
            if (attempt == 0 && cfg.hasAssets)
                snprintf(path.ptr, path.length, "%s/models/hex-terrain.glb", cfg.assets.ptr);
            else if (attempt == 1 && !cfg.hasAssets)
                snprintf(path.ptr, path.length, "%.*s/models/hex-terrain.glb",
                        cast(int)defaultAssets.length, defaultAssets.ptr);
            else if (attempt == 2 && !cfg.hasAssets && base !is null)
                snprintf(path.ptr, path.length, "%s../%.*s/models/hex-terrain.glb", base,
                        cast(int)defaultAssets.length, defaultAssets.ptr);
            else
                continue;
            if (glb.load(path.ptr) == EngineError.None) {
                dirLen = strlen(path.ptr) - "/models/hex-terrain.glb".length;
                break;
            }
        }
        if (!glb.loaded) {
            fprintf(stderr, "hex-terrain.glb not found (try --assets DIR); using flat shapes\n");
            return;
        }
        char[2048] lo = void, hi = void;
        if (grain.openGrain(ren, 128, 22) != EngineError.None)
            fprintf(stderr, "no film grain texture\n");
        // SDL's own loader reads PNG but not JPEG, so the reference's caustic.jpg ships as a PNG copy
        // in the repository's assets/ directory.
        foreach (attempt; 0 .. 2) {
            if (attempt == 0)
                snprintf(lo.ptr, lo.length, "assets/caustic.png");
            else if (base !is null)
                snprintf(lo.ptr, lo.length, "%s../assets/caustic.png", base);
            else
                break;
            if (caustic.openCaustic(ren, lo.ptr, 0.29f, 17.5f, 0.40f) == EngineError.None)
                break;
        }
        // The reference blends its moody atlas into the winter one by elevation.
        snprintf(lo.ptr, lo.length, "%.*s/textures/moody.png", cast(int)dirLen, path.ptr);
        snprintf(hi.ptr, hi.length, "%.*s/textures/winter.png", cast(int)dirLen, path.ptr);
        if (texture.openBlend(ren, lo.ptr, hi.ptr, blendVariants, blendSize, paletteSaturation,
                paletteExposure) == EngineError.None)
            printf("loaded %zu meshes and the blended texture atlas\n", glb.meshCount);
        else if (texture.openPng(ren, glb.image) != EngineError.None)
            fprintf(stderr, "could not decode the model texture; using flat shapes\n");
        else
            printf("loaded %zu meshes from hex-terrain.glb (single texture)\n", glb.meshCount);
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
            downX = e.button.x;
            downY = e.button.y;
            moved = false;
            break;
        case SDL_EVENT_MOUSE_BUTTON_UP:
            // A press that never travelled is a click, not a pan; a right click cancels building.
            clickPending = dragging && !moved && e.button.button == SDL_BUTTON_LEFT;
            if (dragging && !moved && e.button.button == SDL_BUTTON_RIGHT)
                state.buildKind = -1;
            dragging = false;
            break;
        case SDL_EVENT_MOUSE_MOTION:
            mouseX = e.motion.x;
            mouseY = e.motion.y;
            mouseIn = true;
            if (dragging) {
                camera.pan(e.motion.xrel, e.motion.yrel);
                immutable dx = mouseX - downX, dy = mouseY - downY;
                moved = moved || dx * dx + dy * dy > clickSlop * clickSlop;
            }
            break;
        case SDL_EVENT_WINDOW_MOUSE_LEAVE:
            mouseIn = false;
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
                // Back out one step at a time: building, then the selection, then the viewer.
                if (state.buildKind >= 0)
                    state.buildKind = -1;
                else if (state.selCol >= 0)
                    state.selCol = state.selRow = -1;
                else
                    queue.push(CommandKind.quit);
                break;
            case SDLK_1, SDLK_2, SDLK_3, SDLK_4, SDLK_5, SDLK_6:
                immutable k = cast(int)(e.key.key - SDLK_1);
                state.buildKind = state.buildKind == k ? -1 : k;
                break;
            case SDLK_U:
                upgradeSelected(-1);
                break;
            case SDLK_Q:
                upgradeSelected(0);
                break;
            case SDLK_E:
                upgradeSelected(1);
                break;
            case SDLK_DELETE, SDLK_BACKSPACE:
                if (game.towerAt(state.selCol,
                        state.selRow) !is null)
                    gameQueue.push(GameCommand(CommandType.sell, TowerKind.arrow, 0, state.selCol, state.selRow));
                break;
            case SDLK_T:
                if (const t = game.towerAt(state.selCol, state.selRow))
                    gameQueue.push(GameCommand(CommandType.setTargeting, t.kind,
                            cast(ubyte)((t.targeting + 1) % 3), t.col, t.row));
                break;
            case SDLK_SPACE:
                gameQueue.push(GameCommand(CommandType.startWave));
                break;
            case SDLK_P:
                state.speed = state.speed == 0 ? 1 : 0;
                break;
            case SDLK_COMMA:
                state.speed = state.speed > 1 ? state.speed - 1 : 1;
                break;
            case SDLK_PERIOD:
                state.speed = state.speed < 3 ? state.speed + 1 : 3;
                break;
            case SDLK_B:
                state.bot = !state.bot;
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

/// The reference's water drift, in texture units per second (speed 0.3 * 0.015).
private enum double sparkleDrift = 0.0045;

/// Film grain over the map area: the grain tile wrapped across the viewport at an offset that
/// changes every frame, so it shimmers whenever the view redraws.
private void drawGrain(SDL_Renderer* r, SDL_Texture* tex, ref const Camera cam, ulong seed) @nogc nothrow @trusted {
    enum float tile = 128;
    immutable h = cast(uint)(seed * 2654435761UL >> 7);
    immutable ou = (h & 0xFF) / 255.0f, ov = (h >> 8 & 0xFF) / 255.0f;
    immutable x0 = cam.x0, y0 = 0.0f, x1 = cam.x0 + cam.width, y1 = cam.height;
    immutable us = cam.width / tile, vs = cam.height / tile;
    SDL_Vertex[4] v;
    immutable float[2][4] p = [[x0, y0], [x1, y0], [x1, y1], [x0, y1]];
    immutable float[2][4] uv = [[ou, ov], [ou + us, ov], [ou + us, ov + vs], [ou, ov + vs]];
    foreach (i; 0 .. 4) {
        v[i].position = SDL_FPoint(p[i][0], p[i][1]);
        v[i].color = SDL_FColor(1, 1, 1, 1);
        v[i].tex_coord = SDL_FPoint(uv[i][0], uv[i][1]);
    }
    static immutable int[6] idx = [0, 1, 2, 0, 2, 3];
    SDL_SetRenderTextureAddressMode(r, SDL_TEXTURE_ADDRESS_WRAP, SDL_TEXTURE_ADDRESS_WRAP);
    SDL_RenderGeometry(r, tex, v.ptr, 4, idx.ptr, 6);
    SDL_SetRenderTextureAddressMode(r, SDL_TEXTURE_ADDRESS_AUTO, SDL_TEXTURE_ADDRESS_AUTO);
}

/// Darkens the corners of the map area: a fan of black triangles whose alpha rises from nothing at
/// the center to the edges, like the reference's vignette pass. No texture, eight triangles.
private void drawVignette(SDL_Renderer* r, ref const Camera cam) @nogc nothrow @trusted {
    immutable x0 = cam.x0, y0 = 0.0f, x1 = cam.x0 + cam.width, y1 = cam.height;
    immutable xm = (x0 + x1) * 0.5f, ym = (y0 + y1) * 0.5f;
    // Center, then the ring clockwise from the top-left corner: corners darkest, edge midpoints lighter.
    static immutable float[9] alpha = [0, 0.42f, 0.10f, 0.42f, 0.10f, 0.42f, 0.10f, 0.42f, 0.10f];
    immutable float[2][9] pos = [
        [xm, ym], [x0, y0], [xm, y0], [x1, y0], [x1, ym], [x1, y1], [xm, y1], [x0, y1], [x0, ym]
    ];
    SDL_Vertex[9] v;
    foreach (i; 0 .. 9) {
        v[i].position = SDL_FPoint(pos[i][0], pos[i][1]);
        v[i].color = SDL_FColor(0.04f, 0.05f, 0.09f, alpha[i]);
        v[i].tex_coord = SDL_FPoint(0, 0);
    }
    static immutable int[24] idx = [
        0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 5, 0, 5, 6, 0, 6, 7, 0, 7, 8, 0, 8, 1
    ];
    SDL_RenderGeometry(r, null, v.ptr, 9, idx.ptr, 24);
}

/// Frame-time benchmark (--bench N): N frames standing still, then N frames panning so new chunks
/// are built each frame. Vsync is off and each frame ends with a pixel readback so the GPU's
/// work is included. Prints the average, median, 95th percentile and worst frame in ms.
private int bench(ref Renderer ren, ref Viewer v, int frames, float slow) @nogc nothrow @trusted {
    SDL_SetRenderVSync(ren.handle, 0);
    enum int cap = 2000;
    immutable n = frames < cap ? frames : cap;
    static float[cap] ms, cpu;
    immutable freq = cast(double)SDL_GetPerformanceFrequency();
    foreach (phase; 0 .. 2) {
        foreach (i; 0 .. n) {
            if (phase == 1)
                v.camera.pan(-9, -3);
            immutable t0 = SDL_GetPerformanceCounter();
            SDL_SetRenderDrawColor(ren.handle, 128, 134, 153, 255);
            SDL_RenderClear(ren.handle);
            v.renderer.draw(ren.handle, v.texture.handle, v.caustic.handle, v.overview, v.mesh, v.camera);
            cpu[i] = cast(float)((SDL_GetPerformanceCounter() - t0) / freq * 1000.0);
            SDL_RenderPresent(ren.handle);
            int[4] px = [0, 0, 1, 1];
            auto surf = SDL_RenderReadPixels(ren.handle, px.ptr);
            if (surf !is null)
                SDL_DestroySurface(surf);
            ms[i] = cast(float)((SDL_GetPerformanceCounter() - t0) / freq * 1000.0);
            v.mesh.adapt(cpu[i] * slow, ms[i] * slow);
        }
        float sum = 0, csum = 0;
        foreach (i; 0 .. n)
            csum += cpu[i];
        foreach (i; 0 .. n) {
            sum += ms[i];
            // Insertion sort in place: n is small.
            immutable x = ms[i];
            size_t j = i;
            for (; j > 0 && ms[j - 1] > x; j--)
                ms[j] = ms[j - 1];
            ms[j] = x;
        }
        // Sorting ms above scrambled the pairing with cpu, so cpu gets its own sort.
        foreach (i; 1 .. n) {
            immutable x = cpu[i];
            size_t j = i;
            for (; j > 0 && cpu[j - 1] > x; j--)
                cpu[j] = cpu[j - 1];
            cpu[j] = x;
        }
        printf("%s: CPU draw avg %.2f ms, p95 %.2f, worst %.2f\n", phase == 0 ? "still  ".ptr
                : "panning".ptr, csum / n, cpu[cast(size_t)(n * 0.95f)], cpu[n - 1]);
        printf("%s: %d frames, avg %.2f ms, median %.2f, p95 %.2f, worst %.2f | detail %d (quality %.0f%%), %zu verts drawn, cache %.1f MB\n",
                phase == 0 ? "still  ".ptr : "panning".ptr, n, sum / n, ms[n / 2],
                ms[cast(size_t)(n * 0.95f)], ms[n - 1], cast(int)v.mesh.lod, v.mesh.quality * 100,
                v.renderer.drawnVerts, v.mesh.bytes / (1024.0 * 1024.0));
    }
    return 0;
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
    if (ren.open(window, !cfg.classic) != EngineError.None)
        return 1;
    // Render in window points; the high-density backbuffer keeps it sharp.
    immutable scale = SDL_GetWindowDisplayScale(window.handle) > 0 ? SDL_GetWindowDisplayScale(window.handle) : 1.0f;
    SDL_SetRenderScale(ren.handle, scale, scale);
    NuklearContext ui;
    if (ui.open(window.handle, ren.handle, scale) != EngineError.None)
        return 1;

    Viewer v;
    if (ren.gpu) {
        if (v.renderer.gpu.open(ren.handle))
            printf("GPU renderer: %s\n", SDL_GetGPUDeviceDriver(SDL_GetGPURendererDevice(ren.handle)));
        else
            fprintf(stderr, "GPU mesh path unavailable (%s); drawing geometry on the CPU\n", SDL_GetError());
    }
    v.loadModel(ren, cfg);
    v.state.mesh.textured = !cfg.flat;

    auto created = MapSession.create();
    if (created.isErr)
        return 1;
    v.session = created.value;
    v.state.params = cfg.params;
    v.state.showPanel = !cfg.hasScreenshot;
    v.state.bot = cfg.bot;

    float viewW = 0, viewH = 0;
    void updateViewport() {
        int pw, ph;
        SDL_GetCurrentRenderOutputSize(ren.handle, &pw, &ph);
        viewW = pw / scale;
        viewH = ph / scale;
        v.setViewport(viewW, viewH);
    }

    updateViewport();
    v.regenerate(ren.handle);
    if (v.session.tiles.rect.cols == 0)
        return 1; // the initial parameters were rejected
    if (!v.fx.open(ren.handle))
        fprintf(stderr, "particle effects unavailable\n");
    v.fx.reset(v.game);
    foreach (t; 0 .. cfg.ticks) {
        v.stepOnce();
        // Keep effects in step so a --screenshot after --ticks shows them mid-flight.
        v.fx.ambient(v.game, 1.0f / ticksPerSecond, 0);
        v.fx.update(1.0f / ticksPerSecond);
    }
    if (cfg.bench > 0) {
        if (cfg.zoom > 0) {
            v.camera.zoom = cfg.zoom;
            v.camera.cx = (v.mesh.minX + v.mesh.maxX) * 0.5f;
            v.camera.cy = (v.mesh.minY + v.mesh.maxY) * 0.5f;
        }
        return bench(ren, v, cfg.bench, cfg.slow);
    }
    if (cfg.zoom > 0) {
        v.camera.zoom = cfg.zoom;
        v.camera.cx = (v.mesh.minX + v.mesh.maxX) * 0.5f;
        v.camera.cy = (v.mesh.minY + v.mesh.maxY) * 0.5f;
    }
    if (cfg.selCol >= 0 && cfg.selCol < v.session.tiles.rect.cols && cfg.selRow < v.session.tiles.rect.rows) {
        v.state.selCol = cfg.selCol;
        v.state.selRow = cfg.selRow;
        if (cfg.zoom > 0) {
            float x, z, level;
            v.mesh.cellLevel(cfg.selCol, cfg.selRow, level);
            cellCenter(cfg.selCol, cfg.selRow, x, z);
            v.camera.cx = x;
            v.camera.cy = z * squash - level * levelStep;
        }
    }

    immutable freq = cast(double)SDL_GetPerformanceFrequency();
    ulong last = SDL_GetPerformanceCounter();
    bool firstFrame = true;
    bool animating;
    ulong simLast = SDL_GetPerformanceCounter();
    while (v.running) {
        SDL_Event e;
        immutable capturing = ui.capturing();
        // Idle frames cost nothing: sleep until an event arrives (a screenshot run never waits).
        // While the game runs, frames come as fast as vsync allows.
        bool got = cfg.hasScreenshot || v.gameRunning ? SDL_PollEvent(&e) : SDL_WaitEventTimeout(&e,
                animating ? 120 : 500);
        immutable woke = got || firstFrame || animating;
        firstFrame = false;
        if (!woke)
            continue;
        while (got) {
            ui.handle(ren.handle, &e); // also converts e to render coordinates
            v.onEvent(e, capturing);
            got = SDL_PollEvent(&e);
        }
        immutable wasPanel = v.state.showPanel;
        v.updatePicking(capturing);
        drawPanel(ui, v.state, v.queue, v.gameQueue, v.game, *v.session, v.mesh, v.haveModel, viewH);

        bool screenshot = cfg.hasScreenshot;
        CommandKind cmd;
        while (v.queue.pop(cmd)) {
            final switch (cmd) {
            case CommandKind.regenerate:
                v.regenerate(ren.handle);
                break;
            case CommandKind.rebuildMesh:
                v.rebuildMesh(ren.handle);
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
        {
            immutable now = SDL_GetPerformanceCounter();
            double sdt = (now - simLast) / freq;
            simLast = now;
            sdt = sdt > 0.25 ? 0.25 : sdt;
            v.applyCommands();
            v.stepGame(cfg.hasScreenshot ? 0 : sdt);
            v.state.errorTimer -= cast(float)sdt;
            v.fx.density = v.mesh.quality;
            if (v.state.speed > 0) {
                v.fx.ambient(v.game, cast(float)sdt, 0);
                v.fx.update(cast(float)sdt);
            }
        }

        SDL_SetRenderDrawColor(ren.handle, 128, 134, 153, 255);
        SDL_RenderClear(ren.handle);
        immutable drawStart = SDL_GetPerformanceCounter();
        immutable shift = v.state.animateWater ? cast(float)(drawStart / freq * sparkleDrift) : 0.0f;
        immutable wave = v.state.animateWater ? cast(float)(drawStart / freq * 2.2) : float.nan;
        v.renderer.draw(ren.handle, v.texture.handle, v.caustic.handle, v.overview, v.mesh, v.camera, shift, wave);
        immutable drawMs = cast(float)((SDL_GetPerformanceCounter() - drawStart) / freq * 1000.0);
        v.drawMarkers(ren.handle);
        {
            OverlayInput inp;
            inp.selCol = v.state.selCol;
            inp.selRow = v.state.selRow;
            inp.buildKind = v.state.buildKind;
            inp.hoverCol = v.state.hoverCol;
            inp.hoverRow = v.state.hoverRow;
            inp.time = cast(float)(drawStart / freq);
            v.overlay.draw(ren.handle, v.game, v.camera, v.mesh, cast(float)(v.simAcc * ticksPerSecond), inp);
            v.fx.draw(ren.handle, v.camera, v.mesh);
        }
        v.state.drawnVerts = v.renderer.drawnVerts;
        // Full-screen blending is the one cost that scales with pixels, so it goes first when the
        // frame budget is tight.
        if (v.state.vignette && v.mesh.quality > 0.5f)
            drawVignette(ren.handle, v.camera);
        if (v.state.grain && v.mesh.quality > 0.5f && v.grain.handle !is null)
            drawGrain(ren.handle, v.grain.handle, v.camera, drawStart);
        animating = (v.state.animateWater && v.renderer.sparkleVisible) || v.gameRunning || v.fx.busy;
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
        v.mesh.adapt(drawMs * cfg.slow, cast(float)((SDL_GetPerformanceCounter() - drawStart) / freq * 1000.0)
                * cfg.slow);

        immutable now = SDL_GetPerformanceCounter();
        immutable dt = (now - last) / freq;
        last = now;
        if (dt > 0 && dt < 0.25)
            v.state.fps = v.state.fps * 0.9f + cast(float)(1.0 / dt) * 0.1f;
    }
    return 0;
}
