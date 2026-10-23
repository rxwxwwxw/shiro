// Nuklear side panel for the map viewer: generation parameters, view toggles and stats. The
// panel edits ViewerState and enqueues commands; it never touches the Model directly.
module gui.nuklear_ui;

import bindings.nuklear.nuklear;
import bindings.sdl3.sdl : SDL_Event, SDL_Renderer, SDL_Window;
import core.result : EngineError;
import core.stdc.stdio : snprintf;
import gfx.hex_mesh : Lod, MapMesh;
import td.defs;
import td.game;
import viewer.commands;
import wfc.decorations : buildingDefs, DecoKind;
import wfc.grid_connector : MapRect;
import wfc.hex : HexDir, offsetToCube;
import wfc.passability : NavFlag;
import wfc.tile_data : tileList;
import wfc.map_session;
import wfc.placement : maxSinks, maxSources;
import wfc.reveal : maxStages;

enum float panelWidth = 280;

struct NuklearContext {
    nk_context* ctx;

    @disable this(this);

    /// `textFont`: a TTF for the dialogue text (null: the default font everywhere).
    EngineError open(SDL_Window* win, SDL_Renderer* renderer, float scale, const(char)* textFont = null) @nogc nothrow @trusted {
        ctx = shiro_nk_init(win, renderer, scale, textFont);
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

/// Collapsible section; `id` keeps its open state apart from other sections.
private bool section(nk_context* ctx, const(char)* title, int id, bool open) @nogc nothrow @trusted {
    return nk_tree_push_hashed(ctx, nk_tree_type.NK_TREE_TAB, title, open
            ? nk_collapse_states.NK_MAXIMIZED : nk_collapse_states.NK_MINIMIZED, title, 0, id);
}

private immutable char*[12] errorText = [
    "", "Outside the map", "Can't build there", "Already a tower there",
    "Mines go on gold veins only", "Not enough gold",
    "No tower there", "Fully upgraded", "Not now", "Too many towers", "Still in the fog",
    "Not unlocked yet"
];

private immutable char*[3] targetingNames = ["First", "Strong", "Close"];

private void statsLine(nk_context* ctx, ref const Game g, ref const Tower t) @nogc nothrow @trusted {
    const st = &towerStats(t.kind, t.stage);
    if (t.kind == TowerKind.mine) {
        labelf(ctx, "Income +%d gold per wave", st.income);
        return;
    }
    immutable dmg = st.damage * (t.ley ? 100 + leyDamagePct : 100) / 100;
    labelf(ctx, "Damage %d, range %.1f, %.1f/s", dmg, g.rangeOf(t) / cast(float)cellUnits,
            cast(float)ticksPerSecond / st.cooldown);
    labelf(ctx, "Kills %d, damage dealt %lld", t.kills, t.dealt);
    if (t.ley || t.rangePct > 0)
        labelf(ctx, "%s%s", t.ley ? "Ley stone +25%% dmg  ".ptr : "".ptr, t.rangePct > 0 ? "High ground".ptr : "".ptr);
}

/// Gold, lives, waves, building and the selected tower.
private void gamePanel(nk_context* ctx, ref ViewerState st, ref CommandQueue q, ref GameQueue gq, ref const Game g) @nogc nothrow @trusted {
    if (!g.active) {
        nk_layout_row_dynamic(ctx, 16, 1);
        nk_label(ctx, "Turn on roads to play", NK_TEXT_LEFT);
        return;
    }
    nk_layout_row_dynamic(ctx, 18, 2);
    labelf(ctx, "Gold %d", g.gold);
    labelf(ctx, "Lives %d", g.lives);
    nk_layout_row_dynamic(ctx, 18, 1);
    if (g.board.plan.enabled)
        labelf(ctx, "Stage %d/%d: next reveal after wave %d", g.board.stage + 1, g.board.numStages,
                (g.board.stage + 1) * g.wavesPerStage);
    final switch (g.status) {
    case GameStatus.waiting:
        labelf(ctx, "Wave %d/%d next in %d s", g.waveNo + 1, g.waveLimit,
                (g.countdown + ticksPerSecond - 1) / ticksPerSecond);
        break;
    case GameStatus.wave:
        labelf(ctx, "Wave %d/%d: %d creeps left", g.waveNo, g.waveLimit,
                g.creepsAlive + g.pendingSpawns);
        break;
    case GameStatus.lost:
        nk_label_colored(ctx, st.story
                ? "Defeat! The road is lost" : "Defeat! Press R for a new map", NK_TEXT_LEFT,
                nk_color(255, 90, 80, 255));
        break;
    case GameStatus.won:
        nk_label_colored(ctx, "Victory! All waves held", NK_TEXT_LEFT, nk_color(120, 230, 120, 255));
        break;
    }
    if (st.story) {
        immutable over = g.status == GameStatus.lost || g.status == GameStatus.won;
        nk_layout_row_dynamic(ctx, 26, 1);
        if (nk_button_label(ctx, over ? "Return to the village (Enter)" : "Retreat to the village"))
            q.push(CommandKind.returnToVillage);
    }
    nk_layout_row_dynamic(ctx, 24, 2);
    if (g.status != GameStatus.waiting)
        nk_widget_disable_begin(ctx);
    if (nk_button_label(ctx, "Next wave (Space)"))
        gq.push(GameCommand(CommandType.startWave));
    if (g.status != GameStatus.waiting)
        nk_widget_disable_end(ctx);
    if (nk_button_label(ctx, st.speed == 0 ? "Resume (P)" : "Pause (P)"))
        st.speed = st.speed == 0 ? 1 : 0;
    nk_layout_row_dynamic(ctx, 20, 4);
    nk_label(ctx, "Speed", NK_TEXT_LEFT);
    foreach (s; 1 .. 4) {
        static immutable char*[3] speedNames = ["1x", "2x", "3x"];
        if (nk_option_label(ctx, speedNames[s - 1], st.speed == s))
            st.speed = s;
    }
    nk_layout_row_dynamic(ctx, 20, 1);
    checkbox(ctx, "Bot plays (B)", st.bot);

    nk_layout_row_dynamic(ctx, 18, 1);
    nk_label(ctx, "Build (1-6, right click cancels)", NK_TEXT_LEFT);
    nk_layout_row_dynamic(ctx, 24, 2);
    foreach (k; 0 .. numTowerKinds) {
        const def = &towerStats(cast(TowerKind)k, Stage.lv1);
        char[48] buf = void;
        snprintf(buf.ptr, buf.length, st.buildKind == k ? "> %d %.*s %d <" : "%d %.*s %d", k + 1,
                cast(int)def.name.length, def.name.ptr, def.cost);
        immutable poor = g.gold < def.cost;
        if (poor)
            nk_widget_disable_begin(ctx);
        if (nk_button_label(ctx, buf.ptr))
            st.buildKind = st.buildKind == k ? -1 : k;
        if (poor)
            nk_widget_disable_end(ctx);
    }
    if (st.errorTimer > 0 && st.lastError > 0 && st.lastError < errorText.length) {
        nk_layout_row_dynamic(ctx, 16, 1);
        nk_label_colored(ctx, errorText[st.lastError], NK_TEXT_LEFT, nk_color(255, 120, 100, 255));
    }

    const t = g.towerAt(st.selCol, st.selRow);
    if (t is null) {
        immutable sp = g.board.special(st.selCol, st.selRow);
        nk_layout_row_dynamic(ctx, 16, 1);
        if (sp == SpecialKind.goldVein)
            nk_label(ctx, "Gold vein: build a Mine (6) here", NK_TEXT_LEFT);
        else if (sp == SpecialKind.leyStone)
            nk_label(ctx, "Ley stone: towers here deal +25%", NK_TEXT_LEFT);
        nk_layout_row_dynamic(ctx, 6, 1);
        return;
    }
    const cur = &towerStats(t.kind, t.stage);
    nk_layout_row_dynamic(ctx, 18, 1);
    labelf(ctx, "%.*s  Lv %d/%d  (%.*s)", cast(int)cur.name.length, cur.name.ptr, tierOf(t.stage),
            maxTier, cast(int)cur.blurb.length, cur.blurb.ptr);
    nk_layout_row_dynamic(ctx, 16, 1);
    statsLine(ctx, g, *t);
    if (t.kind != TowerKind.mine) {
        nk_layout_row_dynamic(ctx, 20, 4);
        nk_label(ctx, "Target", NK_TEXT_LEFT);
        foreach (m; 0 .. 3)
            if (nk_option_label(ctx, targetingNames[m], t.targeting == m) && t.targeting != m)
                gq.push(GameCommand(CommandType.setTargeting, t.kind, cast(ubyte)m, t.col, t.row));
    }
    void upgradeButton(int branch, Stage next) {
        const ns = &towerStats(t.kind, next);
        char[64] buf = void;
        snprintf(buf.ptr, buf.length, "%s %.*s (%d)", !isBranchPoint(t.kind, t.stage)
                ? "Upgrade U:".ptr : (branch == 0 ? "Q:".ptr : "E:".ptr), cast(int)ns.name.length, ns.name.ptr, ns.cost);
        immutable poor = g.gold < ns.cost;
        if (poor)
            nk_widget_disable_begin(ctx);
        if (nk_button_label(ctx, buf.ptr))
            gq.push(GameCommand(CommandType.upgrade, t.kind, cast(ubyte)branch, t.col, t.row));
        if (poor)
            nk_widget_disable_end(ctx);
    }

    Stage next;
    if (nextStage(t.kind, t.stage, 0, next)) {
        if (!isBranchPoint(t.kind, t.stage)) {
            nk_layout_row_dynamic(ctx, 24, 1);
            upgradeButton(0, next);
        } else {
            foreach (b; 0 .. 2) {
                nextStage(t.kind, t.stage, b, next);
                nk_layout_row_dynamic(ctx, 24, 1);
                upgradeButton(b, next);
                const ns = &towerStats(t.kind, next);
                nk_layout_row_dynamic(ctx, 14, 1);
                labelf(ctx, "   %.*s", cast(int)ns.blurb.length, ns.blurb.ptr);
            }
        }
    }
    nk_layout_row_dynamic(ctx, 24, 1);
    char[40] sell = void;
    snprintf(sell.ptr, sell.length, "Sell for %d (Del)", t.invested * sellPercent / 100);
    if (nk_button_label(ctx, sell.ptr))
        gq.push(GameCommand(CommandType.sell, t.kind, 0, t.col, t.row));
    nk_layout_row_dynamic(ctx, 6, 1);
}

private immutable char*[5] edgeNames = ["grass", "water", "road", "river", "coast"];
private immutable char*[6] dirNames = ["NE", "E", "SE", "SW", "W", "NW"];

/// Properties of the clicked cell (and a line for the hovered one).
private void tileInfo(nk_context* ctx, ref const ViewerState st, ref const MapSession session) @nogc nothrow @trusted {
    nk_layout_row_dynamic(ctx, 18, 1);
    nk_label(ctx, "Tile", NK_TEXT_LEFT);
    nk_layout_row_dynamic(ctx, 16, 1);
    if (st.hoverCol >= 0)
        labelf(ctx, "Hover: col %d, row %d", st.hoverCol, st.hoverRow);
    if (st.selCol < 0) {
        nk_label(ctx, "Click a tile to inspect it", NK_TEXT_LEFT);
        nk_layout_row_dynamic(ctx, 8, 1);
        return;
    }
    immutable c = offsetToCube(st.selCol, st.selRow);
    labelf(ctx, "Cell col %d, row %d", st.selCol, st.selRow);
    labelf(ctx, "Cube q %d, r %d, s %d", c.q, c.r, c.s);
    immutable id = session.tiles.get(c);
    if (id < 0) {
        nk_label(ctx, "Unsolved cell", NK_TEXT_LEFT);
        nk_layout_row_dynamic(ctx, 8, 1);
        return;
    }
    const rules = session.rules;
    immutable ts = rules.states[id];
    const def = &tileList[ts.tile];
    labelf(ctx, "Tile %.*s (state %d)", cast(int)def.name.length, def.name.ptr, cast(int)id);
    labelf(ctx, "Rotation %d (%d deg), level %d", ts.rotation, ts.rotation * 60, ts.level);
    if (def.levelIncrement != 0)
        labelf(ctx, "Slope: rises %d level(s)", def.levelIncrement);
    foreach (half; 0 .. 2) {
        const e = &rules.stateEdges[id];
        labelf(ctx, "%s %s %d  %s %s %d  %s %s %d", dirNames[3 * half],
                edgeNames[(*e)[3 * half].type], (*e)[3 * half].level, dirNames[3 * half + 1],
                edgeNames[(*e)[3 * half + 1].type], (*e)[3 * half + 1].level, dirNames[3 * half + 2],
                edgeNames[(*e)[3 * half + 2].type], (*e)[3 * half + 2].level);
    }
    const deco = session.decorations.get(c);
    final switch (deco.kind) {
    case DecoKind.none:
        nk_label(ctx, "Decoration: none", NK_TEXT_LEFT);
        break;
    case DecoKind.tree:
        labelf(ctx, "Tree %c, density %d/3", 'A' + (deco.variant & 1), deco.extra & 3);
        break;
    case DecoKind.building:
        labelf(ctx, "Building %.*s",
                cast(int)buildingDefs[deco.variant].name.length, buildingDefs[deco.variant].name.ptr);
        break;
    case DecoKind.windmill:
        nk_label(ctx, "Windmill", NK_TEXT_LEFT);
        break;
    case DecoKind.bridge:
        nk_label(ctx, "Bridge", NK_TEXT_LEFT);
        break;
    case DecoKind.mountain:
        nk_label(ctx, "Mountain (blocks movement)", NK_TEXT_LEFT);
        break;
    case DecoKind.source:
        nk_label(ctx, "Creep source", NK_TEXT_LEFT);
        break;
    case DecoKind.sink:
        nk_label(ctx, "Creep sink (goal)", NK_TEXT_LEFT);
        break;
    case DecoKind.rock:
        nk_label(ctx, "Rock wall", NK_TEXT_LEFT);
        break;
    case DecoKind.village:
        nk_label(ctx, "Village building", NK_TEXT_LEFT);
        break;
    }
    immutable nav = session.nav.get(c);
    labelf(ctx, "Ground %s, water %s", (nav & NavFlag.ground) ? "yes".ptr : "no".ptr,
            (nav & NavFlag.water) ? "yes".ptr : "no".ptr);
    if (nav & NavFlag.road) {
        immutable dirs = session.network.roadDirs(c);
        char[32] buf = 0;
        size_t n;
        foreach (d; 0 .. 6)
            if (dirs & (1 << d))
                n += snprintf(buf.ptr + n, buf.length - n, "%s ", dirNames[d]);
        labelf(ctx, "Road exits: %s", buf.ptr);
    }
    nk_layout_row_dynamic(ctx, 8, 1);
}

/// Draws the panel. Call between nk_input_end (done here) and NuklearContext.render.
void drawPanel(ref NuklearContext ui, ref ViewerState st, ref CommandQueue q, ref GameQueue gq,
        ref const Game game, ref const MapSession session, ref const MapMesh mesh, bool haveModel, float viewHeight) @nogc nothrow @trusted {
    auto ctx = ui.ctx;
    nk_input_end(ctx);
    if (!st.showPanel)
        return;
    scope (exit)
        nk_end(ctx);
    if (!nk_begin(ctx, "Shiro Tower Defense", nk_rect(0, 0, panelWidth, viewHeight),
            NK_WINDOW_BORDER | NK_WINDOW_TITLE))
        return;
    auto p = &st.params;

    if (section(ctx, "Game", 1, true)) {
        gamePanel(ctx, st, q, gq, game);
        nk_tree_pop(ctx);
    }
    if (section(ctx, "Tile", 2, false)) {
        tileInfo(ctx, st, session);
        nk_tree_pop(ctx);
    }
    if (section(ctx, "Map generation", 3, false)) {
        generationPanel(ctx, st, q);
        nk_tree_pop(ctx);
    }
    if (section(ctx, "View", 4, false)) {
        viewPanel(ctx, st, q, haveModel);
        nk_tree_pop(ctx);
    }
    if (section(ctx, "Stats", 5, false)) {
        statsPanel(ctx, st, session, mesh);
        nk_tree_pop(ctx);
    }
    nk_layout_row_dynamic(ctx, 16, 1);
    nk_label(ctx, "Drag: pan   Wheel: zoom   Click: select", NK_TEXT_LEFT);
    nk_label(ctx, "U upgrade  Q/E branch  Del sell  T target", NK_TEXT_LEFT);
    nk_label(ctx, "R: new map  F: fit  Tab: panel  Esc: cancel/quit", NK_TEXT_LEFT);
    cast(void)p;
}

private void generationPanel(nk_context* ctx, ref ViewerState st, ref CommandQueue q) @nogc nothrow @trusted {
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
    nk_label(ctx, "Tower defense (applies on regenerate)", NK_TEXT_LEFT);
    nk_layout_row_dynamic(ctx, 22, 1);
    checkbox(ctx, "Roads, sources & sinks", p.routes.enabled);
    if (p.routes.enabled) {
        nk_layout_row_dynamic(ctx, 24, 2);
        // 0 = picked from the map size.
        nk_property_int(ctx, "Sources (0 auto):", 0, &p.routes.place.sources, maxSources, 1, 0.1f);
        nk_property_int(ctx, "Sinks (0 auto):", 0, &p.routes.place.sinks, maxSinks, 1, 0.1f);
        nk_property_int(ctx, "Loops:", 0, &p.routes.loops, 8, 1, 0.1f);
        nk_property_int(ctx, "Waypoints:", 0, &p.routes.waypoints, 4, 1, 0.1f);
        nk_property_int(ctx, "Bendiness:", 0, &p.routes.bendiness, 1000, 10, 2);
        nk_property_int(ctx, "Affinity:", 0, &p.routes.affinity, 300, 5, 1);
        nk_property_int(ctx, "Wall depth:", 0, &p.routes.wallDepth, 4, 1, 0.1f);
        nk_property_int(ctx, "Edge margin:", 1, &p.routes.place.edgeMargin, 20, 1, 0.1f);
        nk_layout_row_dynamic(ctx, 22, 1);
        checkbox(ctx, "Terrain walls (cliff, river, coast)", p.routes.flankTerrain);
        checkbox(ctx, "Sources left, sinks right", p.routes.place.sides);
        checkbox(ctx, "Reveal the map in stages (rect)", p.reveal.enabled);
        if (p.reveal.enabled) {
            nk_layout_row_dynamic(ctx, 24, 2);
            nk_property_int(ctx, "Stages:", 2, &p.reveal.stages, maxStages, 1, 0.1f);
            nk_property_int(ctx, "Waves/stage:", 1, &p.reveal.wavesPerStage, 30, 1, 0.1f);
            nk_property_int(ctx, "Start cols:", 0, &p.reveal.startCols, 400, 1, 0.5f);
            nk_property_int(ctx, "Start rows:", 0, &p.reveal.startRows, 400, 1, 0.5f);
            nk_property_int(ctx, "Defense path:", 4, &p.reveal.minDefensePath, 80, 1, 0.2f);
        }
    }

}

private void viewPanel(nk_context* ctx, ref ViewerState st, ref CommandQueue q, bool haveModel) @nogc nothrow @trusted {
    nk_layout_row_dynamic(ctx, 22, 1);
    bool meshChanged = checkbox(ctx, "Decorations", st.mesh.decorations);
    if (haveModel)
        meshChanged |= checkbox(ctx, "Hex-Map-WFC models", st.mesh.textured);
    meshChanged |= checkbox(ctx, "Cell outlines", st.mesh.outlines);
    if (haveModel)
        meshChanged |= checkbox(ctx, "Tile edges", st.mesh.tileEdges);
    meshChanged |= checkbox(ctx, "Level colors", st.mesh.levelColors);
    checkbox(ctx, "Animate water", st.animateWater);
    checkbox(ctx, "Vignette", st.vignette);
    checkbox(ctx, "Film grain", st.grain);
    if (meshChanged)
        q.push(CommandKind.rebuildMesh);
    nk_layout_row_dynamic(ctx, 28, 2);
    if (nk_button_label(ctx, "Fit view"))
        q.push(CommandKind.fitView);
    if (nk_button_label(ctx, "Save BMP"))
        q.push(CommandKind.screenshot);
}

private void statsPanel(nk_context* ctx, ref const ViewerState st, ref const MapSession session, ref const MapMesh mesh) @nogc nothrow @trusted {
    nk_layout_row_dynamic(ctx, 16, 1);
    const map = &session.tiles();
    const s = &session.stats;
    labelf(ctx, "Map %d x %d, %zu cells", map.rect.cols, map.rect.rows, map.countSolved);
    labelf(ctx, "Grids solved %zu, failed %zu", s.gridsSolved, s.gridsFailed);
    labelf(ctx, "Unsolved %zu, mountains %zu", s.cellsUnsolved, map.countMountains);
    labelf(ctx, "Generated in %.1f ms", session.genMillis);
    if (session.params.routes.enabled) {
        const rr = &session.routeReport;
        const net = &session.network();
        labelf(ctx, "Routes %d (%d loops), %zu road cells", net.numRoutes, net.numLoops, net.roadCellCount);
        labelf(ctx, "Sources %d/%d to sink, sinks %d/%d reached", rr.sourcesConnected, rr.sources,
                rr.sinksReached, rr.sinks);
        labelf(ctx, "%s after %d attempt(s), leaks %zu", rr.ok ? "Valid".ptr : "INVALID".ptr,
                session.routeAttempts, rr.leakCells);
    }
    static immutable char*[4] lodNames = [
        "overview image", "plain shapes", "flat shapes", "terrain models"
    ];
    labelf(ctx, "Detail: %s (quality %.0f%%)", lodNames[mesh.lod], mesh.quality * 100);
    labelf(ctx, "Cached %zu verts, %.1f MB", mesh.vertexCount, mesh.bytes / (1024.0 * 1024.0));
    labelf(ctx, "%.0f fps, %zu verts drawn", st.fps, st.drawnVerts);
}
