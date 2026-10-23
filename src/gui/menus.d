// Full-screen menus: the title screen, the in-game pause menu and the settings. They only edit
// ViewerState and push viewer commands; the main loop does the rest (AGENTS.md §1.2). Features
// that do not exist yet are shown disabled with a tooltip saying so. View layer, no unit tests.
module gui.menus;

import bindings.nuklear.nuklear;
import gui.nuklear_ui : NuklearContext;
import viewer.commands;

private enum float menuWidth = 300, rowH = 34;

private immutable char* notYet = "Not implemented yet";

/// A button, disabled (with `tip` on hover) when `enabled` is false; true when clicked.
private bool menuButton(nk_context* ctx, const(char)* label, bool enabled = true, const(char)* tip = null) @nogc nothrow @trusted {
    if (tip !is null && nk_widget_is_hovered(ctx))
        nk_tooltip(ctx, tip);
    if (!enabled)
        nk_widget_disable_begin(ctx);
    immutable hit = nk_button_label(ctx, label);
    if (!enabled)
        nk_widget_disable_end(ctx);
    return hit && enabled;
}

private bool check(nk_context* ctx, const(char)* label, ref bool v, bool enabled = true) @nogc nothrow @trusted {
    if (!enabled) {
        if (nk_widget_is_hovered(ctx))
            nk_tooltip(ctx, notYet);
        nk_widget_disable_begin(ctx);
    }
    bool b = v;
    immutable changed = nk_checkbox_label(ctx, label, &b) && enabled;
    if (!enabled)
        nk_widget_disable_end(ctx);
    if (changed)
        v = b;
    return changed;
}

private void slider(nk_context* ctx, const(char)* label, ref float v, bool enabled) @nogc nothrow @trusted {
    nk_layout_row_dynamic(ctx, 24, 2);
    nk_label(ctx, label, NK_TEXT_LEFT);
    if (!enabled)
        nk_widget_disable_begin(ctx);
    float f = v;
    nk_slider_float(ctx, 0, &f, 1, 0.05f);
    if (!enabled)
        nk_widget_disable_end(ctx);
    else
        v = f;
}

/// A centered window of `w` x `h`; false (and nothing to end) if it is not drawn.
private bool centered(nk_context* ctx, const(char)* name, float viewW, float viewH, float w, float h) @nogc nothrow @trusted {
    immutable r = nk_rect((viewW - w) * 0.5f, (viewH - h) * 0.5f, w, h);
    nk_window_set_bounds(ctx, name, r);
    if (nk_begin(ctx, name, r, NK_WINDOW_BORDER | NK_WINDOW_NO_SCROLLBAR))
        return true;
    nk_end(ctx);
    return false;
}

private void title(nk_context* ctx, const(char)* text, float h, int font = 2) @nogc nothrow @trusted {
    shiro_nk_use_font(ctx, font);
    nk_layout_row_dynamic(ctx, h, 1);
    nk_label(ctx, text, NK_TEXT_CENTERED);
    shiro_nk_use_font(ctx, 0);
}

/// Draws whichever menu `st.screen` asks for. `villageScene`: the pause menu is over the village
/// (no debug panel there, and no run to retreat from).
void drawMenus(ref NuklearContext ui, ref ViewerState st, ref CommandQueue q, bool villageScene,
        bool haveModel, float viewW, float viewH) @nogc nothrow @trusted {
    auto ctx = ui.ctx;
    if (st.screen == Screen.none)
        return;
    shiro_nk_game_style(ctx, 1);
    scope (exit)
        shiro_nk_game_style(ctx, 0);
    final switch (st.screen) {
    case Screen.none:
        return;
    case Screen.mainMenu:
        mainMenu(ctx, st, q, viewW, viewH);
        return;
    case Screen.pause:
        pauseMenu(ctx, st, q, villageScene, viewW, viewH);
        return;
    case Screen.settings:
        settings(ctx, st, q, haveModel, viewW, viewH);
        return;
    }
}

private void mainMenu(nk_context* ctx, ref ViewerState st, ref CommandQueue q, float viewW, float viewH) @nogc nothrow @trusted {
    if (!centered(ctx, "main_menu", viewW, viewH, menuWidth, 440))
        return;
    scope (exit)
        nk_end(ctx);
    title(ctx, "SHIRO", 60, 3);
    nk_layout_row_dynamic(ctx, 18, 1);
    nk_label(ctx, "Hold the west road", NK_TEXT_CENTERED);
    nk_layout_row_dynamic(ctx, 10, 1);
    nk_spacing(ctx, 1);
    nk_layout_row_dynamic(ctx, rowH, 1);
    menuButton(ctx, "Continue", false, "Saving is not implemented yet");
    if (menuButton(ctx, "New game", true, st.storyAvailable ? null : "No story file: starts a quick battle".ptr))
        q.push(CommandKind.newGame);
    menuButton(ctx, "Load game", false, "Saving is not implemented yet");
    if (menuButton(ctx, "Quick battle", true, "A tower defense map, no story"))
        q.push(CommandKind.quickBattle);
    if (menuButton(ctx, "Settings")) {
        st.settingsFrom = Screen.mainMenu;
        st.screen = Screen.settings;
    }
    if (menuButton(ctx, "Map debugger", true, "Developer view: map generation and debug panels"))
        q.push(CommandKind.debugMap);
    if (menuButton(ctx, "Quit"))
        q.push(CommandKind.quit);
}

private void pauseMenu(nk_context* ctx, ref ViewerState st, ref CommandQueue q, bool villageScene,
        float viewW, float viewH) @nogc nothrow @trusted {
    immutable retreat = st.story && !villageScene;
    if (!centered(ctx, "pause_menu", viewW, viewH, menuWidth, retreat ? 370 : 330))
        return;
    scope (exit)
        nk_end(ctx);
    title(ctx, "Paused", 40);
    nk_layout_row_dynamic(ctx, rowH, 1);
    if (menuButton(ctx, "Resume (Esc)"))
        st.screen = Screen.none;
    if (retreat && menuButton(ctx, "Retreat to the village")) {
        st.screen = Screen.none;
        q.push(CommandKind.returnToVillage);
    }
    menuButton(ctx, "Save game", false, "Saving is not implemented yet");
    if (menuButton(ctx, "Settings")) {
        st.settingsFrom = Screen.pause;
        st.screen = Screen.settings;
    }
    if (!villageScene) {
        nk_layout_row_dynamic(ctx, 26, 1);
        check(ctx, "Debug panel (Tab)", st.debugView);
        nk_layout_row_dynamic(ctx, rowH, 1);
    }
    if (menuButton(ctx, "Main menu"))
        q.push(CommandKind.mainMenu);
    if (menuButton(ctx, "Quit to desktop"))
        q.push(CommandKind.quit);
}

private void settings(nk_context* ctx, ref ViewerState st, ref CommandQueue q, bool haveModel, float viewW, float viewH) @nogc nothrow @trusted {
    immutable w = viewW - 40 < 460 ? viewW - 40 : 460;
    if (!centered(ctx, "settings", viewW, viewH, w, 470))
        return;
    scope (exit)
        nk_end(ctx);
    title(ctx, "Settings", 40);
    static immutable char*[4] tabs = ["Graphics", "Audio", "Controls", "Gameplay"];
    nk_layout_row_dynamic(ctx, 28, 4);
    foreach (i, t; tabs)
        if (nk_option_label(ctx, t, st.settingsTab == i))
            st.settingsTab = cast(int)i;
    nk_layout_row_dynamic(ctx, 8, 1);
    nk_spacing(ctx, 1);

    switch (st.settingsTab) {
    case 0: {
            nk_layout_row_dynamic(ctx, 24, 1);
            bool display = check(ctx, "Fullscreen", st.fullscreen);
            display |= check(ctx, "Vertical sync", st.vsync);
            if (display)
                q.push(CommandKind.applyDisplay);
            bool mesh = check(ctx, "Detailed terrain models", st.mesh.textured, haveModel);
            mesh |= check(ctx, "Trees and decorations", st.mesh.decorations);
            if (mesh)
                q.push(CommandKind.rebuildMesh);
            check(ctx, "Animated water", st.animateWater);
            check(ctx, "Vignette", st.vignette);
            check(ctx, "Film grain", st.grain);
            bool shadows = true, aa;
            check(ctx, "Soft shadows", shadows, false);
            check(ctx, "Anti-aliasing", aa, false);
            nk_layout_row_dynamic(ctx, 18, 1);
            nk_label(ctx, "Detail adjusts itself to keep the frame rate up.", NK_TEXT_LEFT);
            break;
        }
    case 1:
        nk_layout_row_dynamic(ctx, 20, 1);
        nk_label_colored(ctx, "Sound is not implemented yet.", NK_TEXT_LEFT, nk_color(230, 200, 120, 255));
        slider(ctx, "Master volume", st.masterVolume, false);
        slider(ctx, "Music", st.musicVolume, false);
        slider(ctx, "Effects", st.effectsVolume, false);
        nk_layout_row_dynamic(ctx, 24, 1);
        bool mute;
        check(ctx, "Mute when in the background", mute, false);
        break;
    case 2: {
            static immutable char*[2][11] keys = [
                ["Pan the map", "Drag / WASD / arrows"], ["Zoom", "Wheel / + -"],
                ["Build tower", "1 - 6, right click cancels"], [
                    "Upgrade", "U (Q / E pick a branch)"
                ], ["Sell", "Del"], ["Targeting", "T"], ["Next wave", "Space"],
                ["Pause / speed", "P, comma, period"], ["Fit the view", "F"],
                ["Walk (village)", "WASD / arrows, E talks"], ["Menu", "Esc"]
            ];
            foreach (ref k; keys) {
                nk_layout_row_dynamic(ctx, 20, 2);
                nk_label(ctx, k[0], NK_TEXT_LEFT);
                nk_label(ctx, k[1], NK_TEXT_LEFT);
            }
            nk_layout_row_dynamic(ctx, 28, 1);
            menuButton(ctx, "Rebind keys", false, notYet);
            break;
        }
    default: {
            nk_layout_row_dynamic(ctx, 24, 1);
            bool mesh = check(ctx, "Show cell outlines", st.mesh.outlines);
            if (mesh)
                q.push(CommandKind.rebuildMesh);
            bool edge, damage = true;
            check(ctx, "Scroll at the screen edge", edge, false);
            check(ctx, "Floating damage numbers", damage, false);
            nk_layout_row_dynamic(ctx, 28, 1);
            menuButton(ctx, "Language: English", false, notYet);
            break;
        }
    }

    nk_layout_row_dynamic(ctx, 10, 1);
    nk_spacing(ctx, 1);
    nk_layout_row_dynamic(ctx, rowH, 1);
    if (menuButton(ctx, "Back (Esc)"))
        st.screen = st.settingsFrom;
}
