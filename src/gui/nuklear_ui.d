// Nuklear side panel for the map viewer: generation parameters, view toggles and stats. The
// panel edits ViewerState and enqueues commands; it never touches the Model directly.
module gui.nuklear_ui;

import bindings.nuklear.nuklear;
import bindings.sdl3.sdl : SDL_Event, SDL_Renderer, SDL_Window;
import core.result : EngineError;
import core.stdc.stdio : snprintf;
import gfx.hex_mesh : MapMesh;
import viewer.commands;
import wfc.grid_connector : MapRect;
import wfc.map_session;

enum float panelWidth = 280;

struct NuklearContext {
    nk_context* ctx;

    @disable this(this);

    EngineError open(SDL_Window* win, SDL_Renderer* renderer, float scale) @nogc nothrow @trusted {
        ctx = shiro_nk_init(win, renderer, scale);
        return ctx is null ? EngineError.InitializationFailed : EngineError.None;
    }

    ~this() @nogc nothrow @trusted {
        if (ctx !is null)
            shiro_nk_shutdown(ctx);
    }

    void handle(SDL_Renderer* renderer, SDL_Event* e) @nogc nothrow @trusted {
        shiro_nk_handle_event(ctx, renderer, e);
    }

    /// True while the pointer is over the panel or a widget is being dragged / edited.
    bool capturing() const @nogc nothrow @trusted {
        return nk_window_is_any_hovered(ctx) || nk_item_is_any_active(ctx);
    }

    void render() @nogc nothrow @trusted {
        shiro_nk_render(ctx);
    }
}

private void labelf(Args...)(nk_context* ctx, const(char)* fmt, Args args) @nogc nothrow @trusted {
    char[128] buf = void;
    snprintf(buf.ptr, buf.length, fmt, args);
    nk_label(ctx, buf.ptr, NK_TEXT_LEFT);
}

private void sliderRow(nk_context* ctx, const(char)* name, float lo, float* v, float hi, float step) @nogc nothrow @trusted {
    nk_layout_row_dynamic(ctx, 20, 2);
    labelf(ctx, "%s %.2f", name, *v);
    nk_slider_float(ctx, lo, v, hi, step);
}

private bool checkbox(nk_context* ctx, const(char)* label, ref bool v) @nogc nothrow @trusted {
    immutable before = v;
    nk_checkbox_label(ctx, label, &v);
    return v != before;
}

/// Draws the panel. Call between nk_input_end (done here) and NuklearContext.render.
void drawPanel(ref NuklearContext ui, ref ViewerState st, ref CommandQueue q, ref const MapSession session,
        ref const MapMesh mesh, float viewHeight) @nogc nothrow @trusted {
    auto ctx = ui.ctx;
    nk_input_end(ctx);
    if (!st.showPanel)
        return;
    scope (exit)
        nk_end(ctx);
    if (!nk_begin(ctx, "Hex Map WFC", nk_rect(0, 0, panelWidth, viewHeight), NK_WINDOW_BORDER | NK_WINDOW_TITLE))
        return;
    auto p = &st.params;

    nk_layout_row_dynamic(ctx, 18, 1);
    nk_label(ctx, "Layout", NK_TEXT_LEFT);
    nk_layout_row_dynamic(ctx, 22, 2);
    if (nk_option_label(ctx, "Rectangle", p.layout == Layout.rect))
        p.layout = Layout.rect;
    if (nk_option_label(ctx, "Island", p.layout == Layout.island))
        p.layout = Layout.island;

    nk_layout_row_dynamic(ctx, 24, 1);
    if (p.layout == Layout.rect) {
        nk_property_int(ctx, "Cols:", 4, &p.cols, 1000, 1, 0.5f);
        nk_property_int(ctx, "Rows:", 4, &p.rows, 1000, 1, 0.5f);
        nk_layout_row_dynamic(ctx, 24, 2);
        nk_property_int(ctx, "#Cells:", 64, &st.targetCells, cast(int)maxSessionCells, 500, 50);
        if (nk_button_label(ctx, "Set 16:9")) {
            immutable r = MapRect.withAspect(st.targetCells, 16, 9);
            p.cols = r.cols;
            p.rows = r.rows;
        }
    } else
        nk_property_int(ctx, "Rings:", 0, &p.rings, maxIslandRings, 1, 0.1f);

    nk_layout_row_dynamic(ctx, 24, 1);
    nk_property_int(ctx, "Grid radius:", minGridRadius, &p.radius, maxGridRadius, 1, 0.1f);
    int seed = cast(int)(p.seed & int.max);
    nk_property_int(ctx, "Seed:", 0, &seed, int.max, 1, 1);
    p.seed = seed;
    nk_property_int(ctx, "Ocean spacing:", 0, &p.gen.oceanSpacing, 32, 1, 0.1f);
    nk_layout_row_dynamic(ctx, 22, 1);
    checkbox(ctx, "Grass seed at center", p.gen.centerGrass);

    nk_layout_row_dynamic(ctx, 28, 2);
    if (nk_button_label(ctx, "Random seed")) {
        p.seed = p.seed * 1664525u + 1013904223u;
        q.push(CommandKind.regenerate);
    }
    if (nk_button_label(ctx, "Regenerate"))
        q.push(CommandKind.regenerate);

    nk_layout_row_dynamic(ctx, 8, 1);
    nk_layout_row_dynamic(ctx, 18, 1);
    nk_label(ctx, "Decoration (applies on regenerate)", NK_TEXT_LEFT);
    sliderRow(ctx, "Tree freq", 0.01f, &p.deco.treeFrequency, 0.2f, 0.01f);
    sliderRow(ctx, "Tree thresh", 0.0f, &p.deco.treeThreshold, 1.0f, 0.05f);
    sliderRow(ctx, "Bldg freq", 0.01f, &p.deco.buildingFrequency, 0.2f, 0.01f);
    sliderRow(ctx, "Bldg thresh", 0.0f, &p.deco.buildingThreshold, 1.0f, 0.01f);

    nk_layout_row_dynamic(ctx, 8, 1);
    nk_layout_row_dynamic(ctx, 18, 1);
    nk_label(ctx, "View", NK_TEXT_LEFT);
    nk_layout_row_dynamic(ctx, 22, 1);
    bool meshChanged = checkbox(ctx, "Decorations", st.mesh.decorations);
    meshChanged |= checkbox(ctx, "Cell outlines", st.mesh.outlines);
    meshChanged |= checkbox(ctx, "Level colors", st.mesh.levelColors);
    if (meshChanged)
        q.push(CommandKind.rebuildMesh);
    nk_layout_row_dynamic(ctx, 28, 2);
    if (nk_button_label(ctx, "Fit view"))
        q.push(CommandKind.fitView);
    if (nk_button_label(ctx, "Save BMP"))
        q.push(CommandKind.screenshot);

    nk_layout_row_dynamic(ctx, 8, 1);
    nk_layout_row_dynamic(ctx, 16, 1);
    const map = &session.tiles();
    const s = &session.stats;
    labelf(ctx, "Map %d x %d, %zu cells", map.rect.cols, map.rect.rows, map.countSolved);
    labelf(ctx, "Grids solved %zu, failed %zu", s.gridsSolved, s.gridsFailed);
    labelf(ctx, "Unsolved %zu, mountains %zu", s.cellsUnsolved, map.countMountains);
    labelf(ctx, "Generated in %.1f ms", session.genMillis);
    labelf(ctx, "Mesh %zu verts, %.1f MB", mesh.vertexCount, mesh.bytes / (1024.0 * 1024.0));
    labelf(ctx, "%.0f fps, %zu verts drawn", st.fps, st.drawnVerts);
    nk_layout_row_dynamic(ctx, 8, 1);
    nk_layout_row_dynamic(ctx, 16, 1);
    nk_label(ctx, "Drag: pan   Wheel: zoom", NK_TEXT_LEFT);
    nk_label(ctx, "R: new seed  F: fit  O: outlines", NK_TEXT_LEFT);
    nk_label(ctx, "Tab: toggle panel  Esc: quit", NK_TEXT_LEFT);
}
