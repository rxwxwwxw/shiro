// The conversation on screen: standing figures of the two speakers behind a dialogue box (the
// one talking lit, the listener dimmed), the speaker's portrait in the box, the name, the line
// typed out, and the choices as buttons (also keys 1..6). Art is optional and loaded on first
// use from assets/portraits/<portrait>_<expr>.png and assets/figures/<figure>.png. View layer;
// reads the VillageWorld and queues commands, never changes the Model directly.
module gui.dialogue_ui;

import bindings.nuklear.nuklear;
import bindings.sdl3.sdl;
import core.stdc.stdio : snprintf;
import gfx.sdl_handles : Texture;
import gui.nuklear_ui : NuklearContext;
import story.dialogue;
import village.world;

/// Bytes of text revealed per second while a line types out.
private enum float typeRate = 70;
private enum int artSlots = 48;

/// Portraits and figures by file name, each tried once (a missing file stays missing).
private struct ArtCache {
    private char[96][artSlots] keys;
    private ubyte[artSlots] keyLen;
    private Texture[artSlots] tex;
    private int count;

    @disable this(this);

    /// Texture for assets/<dir>/<name><suffix>.png, or null.
    SDL_Texture* get(SDL_Renderer* r, const(char)* dir, const(char)[] name, const(char)[] suffix) @nogc nothrow @trusted {
        if (name.length == 0)
            return null;
        char[96] key = void;
        immutable n = snprintf(key.ptr, key.length, "%s/%.*s%.*s", dir, cast(int)name.length,
                name.ptr, cast(int)suffix.length, suffix.ptr);
        if (n <= 0 || n >= key.length)
            return null;
        foreach (i; 0 .. count)
            if (keys[i][0 .. keyLen[i]] == key[0 .. n])
                return tex[i].handle;
        if (count == artSlots)
            return null;
        immutable slot = count++;
        keys[slot][0 .. n] = key[0 .. n];
        keyLen[slot] = cast(ubyte)n;
        char[1200] path = void;
        snprintf(path.ptr, path.length, "assets/%.*s.png", n, key.ptr);
        if (tex[slot].tryOpenImage(r, path.ptr) != 0) {
            const(char)* base = SDL_GetBasePath();
            if (base !is null) {
                snprintf(path.ptr, path.length, "%s../assets/%.*s.png", base, n, key.ptr);
                tex[slot].tryOpenImage(r, path.ptr);
            }
        }
        return tex[slot].handle;
    }
}

/// Where the box sits this frame (screen units).
private struct BoxLayout {
    float x, y, w, h;
    float portrait;
    float textX, textW;
}

struct DialogueUi {
    private ArtCache art;
    private int lastNode = -1;
    private float shown = 0;

    @disable this(this);

    /// True while the line on screen is still typing out.
    bool typing(ref const VillageWorld w) const @nogc nothrow @trusted {
        return w.talking && shown < w.talk.line.text.length;
    }

    /// Shows the rest of the line at once.
    void skipTyping(ref const VillageWorld w) @nogc nothrow @trusted {
        if (w.talking)
            shown = w.talk.line.text.length;
    }

    /// Advances the typewriter by `dt` seconds (call once a frame).
    void update(ref const VillageWorld w, float dt) @nogc nothrow @trusted {
        if (!w.talking) {
            lastNode = -1;
            return;
        }
        if (w.talk.nodeIndex != lastNode) {
            lastNode = w.talk.nodeIndex;
            shown = 0;
        }
        shown += dt * typeRate;
        if (shown > w.talk.line.text.length)
            shown = w.talk.line.text.length;
    }

    private BoxLayout layout(ref const VillageWorld w, float viewW, float viewH) const @nogc nothrow @trusted {
        BoxLayout b;
        immutable choices = typing(w) ? 0 : w.talk.choiceCount;
        b.w = viewW - 48 < 1100 ? viewW - 48 : 1100;
        b.h = 170 + choices * 38;
        b.x = (viewW - b.w) * 0.5f;
        b.y = viewH - b.h - 20;
        b.portrait = w.talk.speaker !is null ? 140 : 0;
        b.textX = b.x + (b.portrait > 0 ? b.portrait + 30 : 14);
        b.textW = b.x + b.w - 14 - b.textX;
        return b;
    }

    /// Figures, the box and the portrait (SDL, under the Nuklear text). Call before the UI renders.
    void drawScene(SDL_Renderer* r, ref const VillageWorld w, ref const DialogueDb db, float viewW, float viewH) @nogc nothrow @trusted {
        if (!w.talking)
            return;
        const line = &w.talk.line();
        const spk = w.talk.speaker;
        immutable b = layout(w, viewW, viewH);
        // The two in the scene: the player on the left, the villager (or whoever speaks) on the right.
        const(Speaker)* other = spk;
        if (w.talkNpc >= 0)
            other = &db.speakers[w.npcs[w.talkNpc].speaker];
        if (other !is null && other.id == "player")
            other = null;
        immutable pi = db.findSpeaker("player");
        const(Speaker)* me = pi >= 0 ? &db.speakers[pi] : null;
        immutable figH = viewH * 0.6f < 540 ? viewH * 0.6f : 540;
        void figure(const(Speaker)* s, bool right) {
            if (s is null)
                return;
            auto t = art.get(r, "figures", s.figure, "");
            if (t is null)
                return;
            float tw, th;
            SDL_GetTextureSize(t, &tw, &th);
            immutable fw = figH * tw / th;
            auto dst = SDL_FRect(right ? b.x + b.w - fw - 30 : b.x + 30, b.y + 60 - figH, fw, figH);
            immutable lit = spk is s || (spk is null && !right);
            immutable k = lit ? 1.0f : 0.45f;
            SDL_SetTextureColorModFloat(t, k, k, k * 1.05f);
            SDL_RenderTexture(r, t, null, &dst);
            SDL_SetTextureColorModFloat(t, 1, 1, 1);
        }

        if (spk !is null || w.talkNpc >= 0) {
            figure(me, false);
            figure(other, true);
        }

        // Box: dark lacquer with a gold rim.
        SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
        auto box = SDL_FRect(b.x, b.y, b.w, b.h);
        SDL_SetRenderDrawColor(r, 34, 20, 16, 232);
        SDL_RenderFillRect(r, &box);
        SDL_SetRenderDrawColor(r, 206, 160, 84, 255);
        SDL_RenderRect(r, &box);
        auto inner = SDL_FRect(b.x + 4, b.y + 4, b.w - 8, b.h - 8);
        SDL_SetRenderDrawColor(r, 120, 46, 32, 255);
        SDL_RenderRect(r, &inner);
        if (spk is null)
            return;
        auto frame = SDL_FRect(b.x + 16, b.y + 16, b.portrait, b.portrait);
        SDL_SetRenderDrawColor(r, 60, 38, 28, 255);
        SDL_RenderFillRect(r, &frame);
        const(char)[] expr = line.expr.length ? line.expr : "neutral";
        char[40] suffix = void;
        immutable sn = snprintf(suffix.ptr, suffix.length, "_%.*s", cast(int)expr.length, expr.ptr);
        auto t = art.get(r, "portraits", spk.portrait, suffix[0 .. sn > 0 ? sn : 0]);
        if (t is null)
            t = art.get(r, "portraits", spk.portrait, "_neutral");
        if (t is null)
            t = art.get(r, "portraits", spk.portrait, "");
        if (t !is null)
            SDL_RenderTexture(r, t, null, &frame);
        else {
            // No portrait: the speaker's initial on the frame.
            SDL_SetRenderDrawColor(r, 230, 200, 140, 255);
            char[2] initial = [spk.name.length ? spk.name[0] : '?', 0];
            float sx, sy;
            SDL_GetRenderScale(r, &sx, &sy);
            SDL_SetRenderScale(r, sx * 6, sy * 6);
            SDL_RenderDebugText(r, (frame.x + b.portrait * 0.5f - 24) / 6,
                    (frame.y + b.portrait * 0.5f - 24) / 6, initial.ptr);
            SDL_SetRenderScale(r, sx, sy);
        }
        SDL_SetRenderDrawColor(r, 206, 160, 84, 255);
        SDL_RenderRect(r, &frame);
    }

    /// Name, text and choices (Nuklear); clicks queue choose commands.
    void drawUi(ref NuklearContext ui, ref const VillageWorld w, ref const DialogueDb db, ref VillageQueue q,
            float viewW, float viewH) @nogc nothrow @trusted {
        if (!w.talking)
            return;
        auto ctx = ui.ctx;
        const line = &w.talk.line();
        const spk = w.talk.speaker;
        immutable b = layout(w, viewW, viewH);
        shiro_nk_dialogue_style(ctx, 1);
        scope (exit) {
            shiro_nk_dialogue_style(ctx, 0);
            shiro_nk_use_font(ctx, 0);
        }
        scope (exit)
            nk_end(ctx);
        if (!nk_begin(ctx, "dialogue", nk_rect(b.textX, b.y + 6, b.textW, b.h - 12), NK_WINDOW_NO_SCROLLBAR))
            return;
        if (spk !is null) {
            shiro_nk_use_font(ctx, 2);
            nk_layout_row_dynamic(ctx, 30, 1);
            nk_text_colored(ctx, spk.name.ptr, cast(int)spk.name.length, NK_TEXT_LEFT, nk_color(255, 205, 110, 255));
        }
        shiro_nk_use_font(ctx, 1);
        // Reveal whole UTF-8 characters only.
        size_t n = cast(size_t)shown;
        while (n < line.text.length && (line.text[n] & 0xC0) == 0x80)
            n++;
        nk_layout_row_dynamic(ctx, spk !is null ? 86 : 116, 1);
        nk_text_wrap(ctx, line.text.ptr, cast(int)n);
        if (typing(w))
            return;
        immutable choices = w.talk.choiceCount;
        foreach (i; 0 .. choices) {
            const c = &w.talk.choice(i);
            char[320] label = void;
            immutable len = snprintf(label.ptr, label.length, "%d.  %.*s", i + 1, cast(int)c.text.length, c.text.ptr);
            nk_layout_row_dynamic(ctx, 32, 1);
            if (nk_button_text(ctx, label.ptr, len < label.length ? len : cast(int)label.length - 1))
                q.push(VillageCommand(VillageCmd.choose, 0, 0, cast(ubyte)i));
        }
        if (choices == 0) {
            shiro_nk_use_font(ctx, 0);
            nk_layout_row_dynamic(ctx, 18, 1);
            nk_label_colored(ctx, "[Space] continue    [Esc] leave", NK_TEXT_LEFT, nk_color(200, 170, 120, 255));
        }
    }
}
