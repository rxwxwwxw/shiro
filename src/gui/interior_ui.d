// Inside a building: the backdrop (assets/interiors/<image>.png, or a plain gradient without it),
// whoever keeps the place standing at the counter, the building's name, and a menu of sections:
// Talk, Ask (topics with answers), Trade (wares for coins), Look (the description) and Leave.
// Tab / Left / Right switch sections, Esc leaves. While a conversation runs the menu steps aside
// for the dialogue box. View layer; reads the VillageWorld and queues commands.
module gui.interior_ui;

import bindings.nuklear.nuklear;
import bindings.sdl3.sdl;
import core.stdc.stdio : snprintf;
import gui.dialogue_ui : ArtCache;
import gui.nuklear_ui : NuklearContext;
import story.dialogue;
import village.interior;
import village.world;

enum Section : ubyte {
    talk,
    ask,
    trade,
    look,
    leave
}

private immutable string[Section.max + 1] sectionNames = ["Talk", "Ask", "Trade", "Look", "Leave"];

/// Menu panel bounds (screen units).
private struct MenuLayout {
    float x, y, w, h;
}

struct InteriorUi {
    private ArtCache art;
    private int lastInside = -1;
    private Section section;
    /// Topic whose answer is showing, or -1.
    private int topic = -1;

    @disable this(this);

    /// Whether section `s` has anything to offer in `it`.
    static bool offers(ref const Interior it, Section s) @nogc nothrow pure @safe {
        final switch (s) {
        case Section.talk:
            return it.host >= 0;
        case Section.ask:
            return it.host >= 0 && it.numTopics > 0;
        case Section.trade:
            return it.numWares > 0;
        case Section.look, Section.leave:
            return true;
        }
    }

    /// Moves to the next (`step` 1) or previous (-1) section on offer.
    void cycle(ref const VillageWorld w, int step) @nogc nothrow @trusted {
        const it = w.interior;
        if (it is null)
            return;
        int s = section;
        foreach (_; 0 .. Section.max + 1) {
            s = (s + step + Section.max + 1) % (Section.max + 1);
            if (offers(*it, cast(Section)s))
                break;
        }
        section = cast(Section)s;
        topic = -1;
    }

    /// Opens on section `s` if the building offers it (screenshots).
    void show(ref const VillageWorld w, Section s) @nogc nothrow @trusted {
        sync(w);
        if (w.interior !is null && offers(*w.interior, s))
            section = s;
    }

    /// Resets the menu when the player walks into a different building (call once a frame).
    void sync(ref const VillageWorld w) @nogc nothrow @trusted {
        if (w.inside == lastInside)
            return;
        lastInside = w.inside;
        topic = -1;
        const it = w.interior;
        section = it !is null && it.host >= 0 ? Section.talk : Section.look;
    }

    private static MenuLayout layout(float viewW, float viewH) @nogc nothrow pure @safe {
        MenuLayout m;
        m.x = 24;
        m.y = 96;
        m.w = viewW * 0.42f < 300 ? 300 : (viewW * 0.42f > 480 ? 480 : viewW * 0.42f);
        m.h = viewH - m.y - 24 < 520 ? viewH - m.y - 24 : 520;
        return m;
    }

    /// Backdrop, the host figure and the menu panel (SDL, under the Nuklear text).
    void drawScene(SDL_Renderer* r, ref const VillageWorld w, ref const DialogueDb db, float viewW, float viewH) @nogc nothrow @trusted {
        const it = w.interior;
        if (it is null)
            return;
        auto bg = art.get(r, "interiors", it.image, "");
        if (bg !is null) {
            // Cover the view, cropping whichever side overflows.
            float tw, th;
            SDL_GetTextureSize(bg, &tw, &th);
            immutable k = viewW / tw > viewH / th ? viewW / tw : viewH / th;
            auto dst = SDL_FRect((viewW - tw * k) * 0.5f, (viewH - th * k) * 0.5f, tw * k, th * k);
            SDL_RenderTexture(r, bg, null, &dst);
        } else {
            immutable SDL_FColor top = SDL_FColor(0.16f, 0.10f, 0.08f, 1), bot = SDL_FColor(0.36f, 0.24f, 0.16f, 1);
            SDL_Vertex[4] v = [
                SDL_Vertex(SDL_FPoint(0, 0), top), SDL_Vertex(SDL_FPoint(viewW, 0), top),
                SDL_Vertex(SDL_FPoint(viewW, viewH), bot), SDL_Vertex(SDL_FPoint(0, viewH), bot)
            ];
            immutable int[6] idx = [0, 1, 2, 0, 2, 3];
            SDL_RenderGeometry(r, null, v.ptr, 4, idx.ptr, 6);
        }
        SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
        // Title strip.
        auto strip = SDL_FRect(0, 18, viewW, 58);
        SDL_SetRenderDrawColor(r, 20, 12, 8, 170);
        SDL_RenderFillRect(r, &strip);
        if (w.talking)
            return; // the dialogue box draws the speakers
        if (it.host >= 0) {
            auto t = art.get(r, "figures", db.speakers[it.host].figure, "");
            if (t !is null) {
                float tw, th;
                SDL_GetTextureSize(t, &tw, &th);
                immutable fh = viewH * 0.78f;
                immutable fw = fh * tw / th;
                auto dst = SDL_FRect(viewW * 0.72f - fw * 0.5f, viewH - fh, fw, fh);
                SDL_RenderTexture(r, t, null, &dst);
            }
        }
        immutable m = layout(viewW, viewH);
        auto box = SDL_FRect(m.x, m.y, m.w, m.h);
        SDL_SetRenderDrawColor(r, 34, 20, 16, 225);
        SDL_RenderFillRect(r, &box);
        SDL_SetRenderDrawColor(r, 206, 160, 84, 255);
        SDL_RenderRect(r, &box);
        auto inner = SDL_FRect(m.x + 4, m.y + 4, m.w - 8, m.h - 8);
        SDL_SetRenderDrawColor(r, 120, 46, 32, 255);
        SDL_RenderRect(r, &inner);
    }

    /// Title, section tabs and the section's contents (Nuklear); clicks queue village commands.
    void drawUi(ref NuklearContext ui, ref const VillageWorld w, ref const DialogueDb db, ref VillageQueue q,
            float viewW, float viewH) @nogc nothrow @trusted {
        sync(w);
        const it = w.interior;
        if (it is null)
            return;
        auto ctx = ui.ctx;
        shiro_nk_dialogue_style(ctx, 1);
        scope (exit) {
            shiro_nk_dialogue_style(ctx, 0);
            shiro_nk_use_font(ctx, 0);
        }
        immutable gold = nk_color(255, 205, 110, 255), dim = nk_color(200, 170, 120, 255);

        // Title and purse.
        if (nk_begin(ctx, "interior_title", nk_rect(16, 20, viewW - 32, 54), NK_WINDOW_NO_SCROLLBAR)) {
            char[64] purse = void;
            immutable pn = snprintf(purse.ptr, purse.length, "%d coins", w.coins);
            nk_layout_row_dynamic(ctx, 36, 2);
            shiro_nk_use_font(ctx, 2);
            nk_text_colored(ctx, it.title.ptr, cast(int)it.title.length, NK_TEXT_LEFT, gold);
            shiro_nk_use_font(ctx, 1);
            nk_text_colored(ctx, purse.ptr, pn, NK_TEXT_RIGHT, gold);
        }
        nk_end(ctx);
        if (w.talking)
            return;

        immutable m = layout(viewW, viewH);
        scope (exit)
            nk_end(ctx);
        if (!nk_begin(ctx, "interior_menu", nk_rect(m.x + 6, m.y + 6, m.w - 12, m.h - 12), 0))
            return;
        // Section tabs: the open one lit, the ones on offer clickable.
        shiro_nk_use_font(ctx, 0);
        int shownTabs = 0;
        foreach (s; 0 .. Section.max + 1)
            shownTabs += offers(*it, cast(Section)s);
        nk_layout_row_dynamic(ctx, 30, shownTabs);
        foreach (s; 0 .. Section.max + 1) {
            if (!offers(*it, cast(Section)s))
                continue;
            immutable open = s == section;
            if (open)
                nk_widget_disable_begin(ctx);
            if (nk_button_label(ctx, sectionNames[s].ptr) && !open) {
                section = cast(Section)s;
                topic = -1;
            }
            if (open)
                nk_widget_disable_end(ctx);
        }
        nk_layout_row_dynamic(ctx, 8, 1);
        nk_spacing(ctx, 1);
        shiro_nk_use_font(ctx, 1);
        const host = it.host >= 0 ? &db.speakers[it.host] : null;

        final switch (section) {
        case Section.talk:
            nk_layout_row_dynamic(ctx, 26, 1);
            nk_text_colored(ctx, host.name.ptr, cast(int)host.name.length, NK_TEXT_LEFT, gold);
            nk_layout_row_dynamic(ctx, 52, 1);
            nk_label_colored(ctx, "Looks up as you come in.", NK_TEXT_LEFT, dim);
            nk_layout_row_dynamic(ctx, 34, 1);
            if (nk_button_label(ctx, "Have a word"))
                q.push(VillageCommand(VillageCmd.talkHost));
            break;
        case Section.ask:
            foreach (i, ref t; it.topicList) {
                nk_layout_row_dynamic(ctx, 32, 1);
                if (nk_button_text(ctx, t.ask.ptr, cast(int)t.ask.length))
                    topic = cast(int)i;
            }
            if (topic >= 0) {
                nk_layout_row_dynamic(ctx, 10, 1);
                nk_spacing(ctx, 1);
                nk_layout_row_dynamic(ctx, 24, 1);
                nk_text_colored(ctx, host.name.ptr, cast(int)host.name.length, NK_TEXT_LEFT, gold);
                const a = it.topics[topic].answer;
                nk_layout_row_dynamic(ctx, 90, 1);
                nk_text_wrap(ctx, a.ptr, cast(int)a.length);
            }
            break;
        case Section.trade:
            foreach (i, ref ware; it.wareList) {
                char[160] label = void;
                immutable ln = snprintf(label.ptr, label.length, "%.*s", cast(int)ware.name.length, ware.name.ptr);
                char[32] price = void;
                immutable owned = w.owns(ware);
                immutable pn = owned ? snprintf(price.ptr, price.length, "Owned") : snprintf(price.ptr,
                        price.length, "Buy  %d", ware.price);
                nk_layout_row_dynamic(ctx, 30, 2);
                nk_text_colored(ctx, label.ptr, ln, NK_TEXT_LEFT, gold);
                immutable cant = owned || w.coins < ware.price;
                if (cant)
                    nk_widget_disable_begin(ctx);
                if (nk_button_text(ctx, price.ptr, pn) && !cant)
                    q.push(VillageCommand(VillageCmd.buy, 0, 0, cast(ubyte)i));
                if (cant)
                    nk_widget_disable_end(ctx);
                if (ware.desc.length) {
                    shiro_nk_use_font(ctx, 0);
                    nk_layout_row_dynamic(ctx, 20, 1);
                    nk_text_colored(ctx, ware.desc.ptr, cast(int)ware.desc.length, NK_TEXT_LEFT, dim);
                    shiro_nk_use_font(ctx, 1);
                }
            }
            immutable(char)* note = null;
            final switch (w.lastBuy) {
            case BuyResult.none:
                break;
            case BuyResult.bought:
                note = "Bought. It is yours.";
                break;
            case BuyResult.tooPoor:
                note = "Not enough coins.";
                break;
            case BuyResult.owned:
                note = "You already have that.";
                break;
            }
            if (note !is null) {
                nk_layout_row_dynamic(ctx, 28, 1);
                nk_label_colored(ctx, note, NK_TEXT_LEFT, gold);
            }
            break;
        case Section.look:
            nk_layout_row_dynamic(ctx, 140, 1);
            nk_text_wrap(ctx, it.look.ptr, cast(int)it.look.length);
            if (host is null) {
                nk_layout_row_dynamic(ctx, 26, 1);
                nk_label_colored(ctx, "Nobody is here.", NK_TEXT_LEFT, dim);
            }
            break;
        case Section.leave:
            nk_layout_row_dynamic(ctx, 34, 1);
            if (nk_button_label(ctx, "Step back outside"))
                q.push(VillageCommand(VillageCmd.leave));
            break;
        }
        shiro_nk_use_font(ctx, 0);
        nk_layout_row_dynamic(ctx, 18, 1);
        nk_label_colored(ctx, "[Tab] section    [E] talk    [Esc] leave", NK_TEXT_LEFT, dim);
    }
}
