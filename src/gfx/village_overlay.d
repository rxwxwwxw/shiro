// The village's moving parts drawn over the map each frame: the player and villagers (sprites
// from assets/sprites/villagers.png, or simple figures without it), their shadows, a talk prompt
// over whoever is in reach, and the west gate's sign. Positions are interpolated between the
// last two village ticks. View layer; reads the VillageWorld, never changes it.
module gfx.village_overlay;

import bindings.sdl3.sdl;
import gfx.camera;
import gfx.hex_mesh : MapMesh;
import gfx.iso : IsoPoint;
import gfx.sprites;
import gfx.td_overlay : isoPerX, isoPerY, worldToScreen;
import story.program : StoryProgram;
import td.defs : cellWorld;
import village.world;
import wfc.hex;

/// Fallback body colors per sprite row (player, elder, priestess, smith, child, guard).
private immutable SDL_FColor[6] bodyColor = [
    SDL_FColor(0.25f, 0.45f, 0.85f, 1), SDL_FColor(0.55f, 0.30f, 0.62f, 1),
    SDL_FColor(0.15f, 0.62f, 0.58f, 1), SDL_FColor(0.50f, 0.34f, 0.20f, 1),
    SDL_FColor(0.92f, 0.76f, 0.25f, 1), SDL_FColor(0.78f, 0.22f, 0.18f, 1)
];

struct VillageOverlay {
    private SpriteBatch batch;
    /// Villager atlas (borrowed), or null for the fallback figures.
    private SDL_Texture* atlas;
    private float atlasW = 1, atlasH = 1;

    @disable this(this);

    void setSprites(SDL_Texture* tex) @nogc nothrow @trusted {
        atlas = tex;
        if (tex !is null)
            SDL_GetTextureSize(tex, &atlasW, &atlasH);
    }

    private static struct Item {
        float sy;
        int who; // -1 = player, else NPC index
    }

    /// Draws everyone; `alpha` (0..1) is the fraction of a tick since the last one.
    void draw(SDL_Renderer* r, ref const VillageWorld w, ref const StoryProgram db, ref const Camera cam,
            ref const MapMesh mesh, float alpha, float time) @nogc nothrow @trusted {
        immutable zoom = cam.zoom;
        Item[maxNpcs + 1] items;
        int n = 0;
        IsoPoint ground(ref const Walker b) {
            immutable x = b.px + (b.x - b.px) * alpha, y = b.py + (b.y - b.py) * alpha;
            return worldToScreen(cam, mesh, x, y, 0);
        }

        items[n++] = Item(ground(w.player).y, -1);
        foreach (i, ref npc; w.npcs)
            items[n++] = Item(ground(npc.body).y, cast(int)i);
        // Back to front (a handful of walkers: insertion sort).
        foreach (i; 1 .. n) {
            auto it = items[i];
            int j = i;
            for (; j > 0 && items[j - 1].sy > it.sy; j--)
                items[j] = items[j - 1];
            items[j] = it;
        }
        foreach (ref it; items[0 .. n]) {
            const b = it.who < 0 ? &w.player : &w.npcs[it.who].body;
            immutable row = it.who < 0 ? 0 : db.speakers[w.npcs[it.who].speaker].sprite;
            drawWalker(*b, ground(*b), row < 0 ? 0 : row, zoom, time, it.who);
        }
        batch.flush(r, atlas);

        // Prompts in SDL's built-in 8 px font (ASCII; names live in the dialogue box).
        if (!w.talking) {
            immutable near = w.npcInReach();
            immutable door = w.doorInReach();
            if (door >= 0) {
                int dx, dy;
                cellWorld(w.plan.spot[door], dx, dy);
                immutable d = worldToScreen(cam, mesh, dx, dy, 0);
                label(r, d.x, d.y - spriteSpan * zoom * spriteAnchor - 14, "[E] Enter", SDL_FColor(1, 0.95f, 0.7f, 1));
            } else if (near >= 0) {
                immutable g = ground(w.npcs[near].body);
                label(r, g.x, g.y - spriteSpan * zoom * spriteAnchor - 14, "[E] Talk", SDL_FColor(1, 0.95f, 0.7f, 1));
            }
            int gx, gy;
            cellWorld(offsetToCube(1, w.plan.gateRow), gx, gy);
            immutable gs = worldToScreen(cam, mesh, gx, gy, 2.2f);
            immutable pc = worldToScreen(cam, mesh, w.player.x, w.player.y, 0);
            immutable dx = pc.x - gs.x, dy = pc.y - gs.y;
            if (dx * dx + dy * dy < (6 * zoom) * (6 * zoom))
                label(r, gs.x, gs.y, "<- West gate", SDL_FColor(1, 0.85f, 0.55f, 1));
        }
    }

    private void drawWalker(ref const Walker b, IsoPoint g, int row, float zoom, float time, int who) @nogc nothrow @trusted {
        immutable size = spriteSpan * zoom;
        batch.disc(g.x, g.y, size * 0.18f, size * 0.07f, SDL_FColor(0, 0, 0, 0.35f), SDL_FColor(0, 0, 0, 0), 12);
        immutable facing = spriteFacing(b.faceX * isoPerX, -b.faceY * isoPerY);
        // Each walker steps on its own beat.
        immutable frame = b.moving ? cast(int)(time * 8 + (who + 1) * 0.37f) % spriteFrames : 0;
        if (atlas !is null) {
            immutable i = spriteIndex(row, facing, frame);
            immutable u0 = (i % spriteCols) * spriteCell / atlasW, v0 = (i / spriteCols) * spriteCell / atlasH;
            batch.quad(g.x - size * 0.5f, g.y - size * spriteAnchor, size, size, u0, v0,
                    u0 + spriteCell / atlasW, v0 + spriteCell / atlasH, SDL_FColor(1, 1, 1, 1));
            return;
        }
        // No atlas: a robed body and a head, bobbing while walking.
        immutable c = bodyColor[row % bodyColor.length];
        immutable bob = b.moving ? (frame & 1) * size * 0.02f : 0;
        immutable dark = SDL_FColor(c.r * 0.55f, c.g * 0.55f, c.b * 0.55f, 1);
        batch.disc(g.x, g.y - size * 0.17f - bob, size * 0.11f, size * 0.17f, c, dark, 12);
        batch.disc(g.x, g.y - size * 0.40f - bob, size * 0.075f, size * 0.075f, SDL_FColor(0.95f, 0.80f,
                0.65f, 1), SDL_FColor(0.75f, 0.58f, 0.45f, 1), 10);
    }
}

/// Centered 8 px text with a dark backing, at screen (x, y).
private void label(SDL_Renderer* r, float x, float y, const(char)* text, SDL_FColor c) @nogc nothrow @trusted {
    import core.stdc.string : strlen;

    immutable w = strlen(text) * 8.0f;
    auto box = SDL_FRect(x - w * 0.5f - 4, y - 4, w + 8, 16);
    SDL_SetRenderDrawBlendMode(r, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(r, 20, 14, 10, 170);
    SDL_RenderFillRect(r, &box);
    SDL_SetRenderDrawColor(r, cast(ubyte)(c.r * 255), cast(ubyte)(c.g * 255), cast(ubyte)(c.b * 255), 255);
    SDL_RenderDebugText(r, x - w * 0.5f, y, text);
}
