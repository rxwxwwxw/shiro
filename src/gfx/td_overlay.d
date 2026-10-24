// Moving parts of a tower defense game, drawn over the map each frame: creeps (shadow, body,
// status tint, health bar), projectiles in flight, burning ground, and tower range rings. Positions
// are interpolated between the last two simulation ticks. Everything is built into one vertex
// batch and drawn with a single SDL_RenderGeometry call. View layer; reads the Game, never
// changes it. Allocation-free once the batch buffers have grown.
module gfx.td_overlay;

import bindings.sdl3.sdl;
import core.stdc.math : atan2f, cosf, sinf, sqrtf;
import core.stdc.stdlib : free, qsort, realloc;
import gfx.camera;
import gfx.hex_mesh : MapMesh;
import gfx.iso : IsoPoint, levelStep, rowPitch, squash;
import gfx.sprites : spriteAnchor, spriteCell, spriteCols, spriteFacing, spriteFrames, spriteIndex, spriteSpan;
import td.catalog : Catalog;
import td.defs;
import td.game;
import wfc.hex : CubeCoord, cubeToOffset, HexDir;
import wfc.passability : unreachable;

/// World units (td.defs) to iso units.
enum float isoPerX = 1.0f / halfHex;
enum float isoPerY = rowPitch / rowUnits;
/// Height of a tower's muzzle above its tile, in iso units.
enum float towerTop = 1.15f;

/// Screen position of a world point `lift` iso units above the ground there.
IsoPoint worldToScreen(ref const Camera cam, ref const MapMesh mesh, float wx, float wy, float lift) @nogc nothrow @trusted {
    float level;
    immutable row = cast(int)(wy / rowUnits + 0.5f);
    immutable col = cast(int)((wx / halfHex - (row & 1)) * 0.5f + 0.5f);
    mesh.cellLevel(col, row, level);
    return cam.toScreen(wx * isoPerX, wy * isoPerY * squash - level * levelStep - lift);
}

private struct Key {
    float y;
    uint id;
}

private extern (C) int cmpKey(const(void)* a, const(void)* b) @nogc nothrow pure @trusted {
    immutable x = (cast(const(Key)*)a).y, y = (cast(const(Key)*)b).y;
    return x < y ? -1 : (x > y ? 1 : 0);
}

struct CreepLook {
    float radius;
    SDL_FColor body, rim;
}

immutable CreepLook[numCreepKinds] creepLooks = [
    CreepLook(0.30f, SDL_FColor(0.62f, 0.82f, 0.40f, 1), SDL_FColor(0.25f, 0.42f, 0.16f, 1)), // grunt
    CreepLook(0.24f, SDL_FColor(1.00f, 0.84f, 0.35f, 1), SDL_FColor(0.62f, 0.40f, 0.08f, 1)), // runner
    CreepLook(0.42f, SDL_FColor(0.62f, 0.52f, 0.46f, 1), SDL_FColor(0.28f, 0.24f, 0.24f, 1)), // brute
    CreepLook(0.17f, SDL_FColor(0.86f, 0.50f, 0.95f, 1), SDL_FColor(0.42f, 0.16f, 0.50f, 1)), // swarm
    CreepLook(0.72f, SDL_FColor(0.92f, 0.28f, 0.30f, 1), SDL_FColor(0.38f, 0.06f, 0.10f, 1)) // boss
];

// assets/sprites/creeps.png follows the shared atlas layout of gfx.sprites (per creep kind).

/// What the overlay should highlight besides the game itself.
struct OverlayInput {
    /// Cell whose tower range is shown (the selected tower), or -1.
    int selCol = -1, selRow = -1;
    /// Build ghost: kind (-1 = none) and the hovered cell.
    int buildKind = -1;
    int hoverCol = -1, hoverRow = -1;
    /// Seconds, for animation.
    float time = 0;
}

struct TdOverlay {
    private SDL_Vertex* v;
    private int* idx;
    private size_t nv, ni, capV, capI;
    private Key* keys;
    private size_t capKeys;
    private float zoom = 1;
    /// Creep sprite atlas (borrowed), or null to draw creeps as shapes.
    private SDL_Texture* sprites;
    private float atlasW = 1, atlasH = 1;
    // Textured quads for the sprites, a second batch drawn between the shadows and the bars.
    private SDL_Vertex* sv;
    private int* si;
    private size_t nsv, nsi, capSV, capSI;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(v);
        free(idx);
        free(keys);
        free(sv);
        free(si);
    }

    /// Draws creeps from the sprite atlas `tex` (owned by the caller; null: flat shapes).
    void setSprites(SDL_Texture* tex) @nogc nothrow @trusted {
        sprites = tex;
        if (tex !is null)
            SDL_GetTextureSize(tex, &atlasW, &atlasH);
    }

    private void spriteQuad(float x, float y, float w, float h, float u0, float v0, float u1, float v1, SDL_FColor c) @nogc nothrow @trusted {
        if (nsv + 4 > capSV) {
            immutable cap = (nsv + 4) * 2 + 1024;
            auto p = cast(SDL_Vertex*)realloc(sv, cap * SDL_Vertex.sizeof);
            if (p is null)
                return;
            sv = p;
            capSV = cap;
        }
        if (nsi + 6 > capSI) {
            immutable cap = (nsi + 6) * 2 + 1536;
            auto p = cast(int*)realloc(si, cap * int.sizeof);
            if (p is null)
                return;
            si = p;
            capSI = cap;
        }
        immutable a = cast(int)nsv;
        sv[nsv++] = SDL_Vertex(SDL_FPoint(x, y), c, SDL_FPoint(u0, v0));
        sv[nsv++] = SDL_Vertex(SDL_FPoint(x + w, y), c, SDL_FPoint(u1, v0));
        sv[nsv++] = SDL_Vertex(SDL_FPoint(x + w, y + h), c, SDL_FPoint(u1, v1));
        sv[nsv++] = SDL_Vertex(SDL_FPoint(x, y + h), c, SDL_FPoint(u0, v1));
        static immutable int[6] corners = [0, 1, 2, 0, 2, 3];
        foreach (k; corners)
            si[nsi++] = a + k;
    }

    private bool reserve(size_t addV, size_t addI) @nogc nothrow @trusted {
        if (nv + addV > capV) {
            immutable cap = (nv + addV) * 2 + 4096;
            auto p = cast(SDL_Vertex*)realloc(v, cap * SDL_Vertex.sizeof);
            if (p is null)
                return false;
            v = p;
            capV = cap;
        }
        if (ni + addI > capI) {
            immutable cap = (ni + addI) * 2 + 8192;
            auto p = cast(int*)realloc(idx, cap * int.sizeof);
            if (p is null)
                return false;
            idx = p;
            capI = cap;
        }
        return true;
    }

    private int put(float x, float y, SDL_FColor c) @nogc nothrow @trusted {
        v[nv] = SDL_Vertex(SDL_FPoint(x, y), c, SDL_FPoint(0, 0));
        return cast(int)nv++;
    }

    private void tri(int a, int b, int c) @nogc nothrow @trusted {
        idx[ni++] = a;
        idx[ni++] = b;
        idx[ni++] = c;
    }

    /// Filled ellipse, `center` color in the middle fading to `rim` at the edge.
    void disc(float x, float y, float rx, float ry, SDL_FColor center, SDL_FColor rim, int sides = 12) @nogc nothrow @trusted {
        if (!reserve(sides + 1, sides * 3))
            return;
        immutable c = put(x, y, center);
        foreach (k; 0 .. sides) {
            immutable a = k * (6.2831853f / sides);
            put(x + cosf(a) * rx, y + sinf(a) * ry, rim);
        }
        foreach (k; 0 .. sides)
            tri(c, c + 1 + k, c + 1 + (k + 1) % sides);
    }

    /// Ellipse outline of thickness `w` (screen units).
    void ring(float x, float y, float rx, float ry, float w, SDL_FColor col, int sides = 48) @nogc nothrow @trusted {
        if (!reserve(sides * 2, sides * 6))
            return;
        immutable base = cast(int)nv;
        foreach (k; 0 .. sides) {
            immutable a = k * (6.2831853f / sides);
            immutable cx = cosf(a), sy = sinf(a);
            put(x + cx * rx, y + sy * ry, col);
            put(x + cx * (rx - w), y + sy * (ry - w * ry / (rx > 0 ? rx : 1)), col);
        }
        foreach (k; 0 .. sides) {
            immutable a = base + 2 * k, b = base + 2 * ((k + 1) % sides);
            tri(a, b, b + 1);
            tri(a, b + 1, a + 1);
        }
    }

    /// Thick segment with a color ramp from `c0` to `c1`.
    void line(float x0, float y0, float x1, float y1, float w, SDL_FColor c0, SDL_FColor c1) @nogc nothrow @trusted {
        immutable dx = x1 - x0, dy = y1 - y0;
        immutable len = sqrtf(dx * dx + dy * dy);
        if (len < 1e-3f || !reserve(4, 6))
            return;
        immutable nx = -dy / len * w * 0.5f, ny = dx / len * w * 0.5f;
        immutable a = put(x0 + nx, y0 + ny, c0), b = put(x1 + nx, y1 + ny, c1);
        immutable c = put(x1 - nx, y1 - ny, c1), d = put(x0 - nx, y0 - ny, c0);
        tri(a, b, c);
        tri(a, c, d);
    }

    void rect(float x, float y, float w, float h, SDL_FColor col) @nogc nothrow @trusted {
        if (!reserve(4, 6))
            return;
        immutable a = put(x, y, col), b = put(x + w, y, col), c = put(x + w, y + h, col), d = put(x, y + h, col);
        tri(a, b, c);
        tri(a, c, d);
    }

    private void flush(SDL_Renderer* r) @nogc nothrow @trusted {
        if (ni > 0)
            SDL_RenderGeometry(r, null, v, cast(int)nv, idx, cast(int)ni);
        nv = ni = 0;
    }

    /// Range of a tower (or a would-be tower) at a cell, as a ring on the ground.
    private void rangeRing(ref const Camera cam, ref const MapMesh mesh, int col, int row, int range,
            SDL_FColor fill, SDL_FColor line_) @nogc nothrow @trusted {
        int wx, wy;
        cellWorld(col, row, wx, wy);
        immutable p = worldToScreen(cam, mesh, wx, wy, 0);
        immutable rx = range * isoPerX * zoom, ry = range * isoPerY * squash * zoom;
        disc(p.x, p.y, rx, ry, fill, fill, 40);
        ring(p.x, p.y, rx, ry, 2, line_);
    }

    void draw(SDL_Renderer* r, ref const Game g, ref const Camera cam, ref const MapMesh mesh, float alpha,
            ref const OverlayInput inp) @nogc nothrow @trusted {
        if (!g.active)
            return;
        nv = ni = 0;
        zoom = cam.zoom;
        immutable t = inp.time;

        // Burning ground under everything else.
        foreach (ref p; g.patches) {
            if (!p.alive)
                continue;
            immutable s = worldToScreen(cam, mesh, p.x, p.y, 0);
            immutable flick = 0.8f + 0.2f * sinf(t * 13 + p.x * 0.01f);
            immutable rx = p.radius * isoPerX * zoom, ry = p.radius * isoPerY * squash * zoom;
            immutable fade = p.ticks < 30 ? p.ticks / 30.0f : 1.0f;
            disc(s.x, s.y, rx, ry, SDL_FColor(1.0f, 0.45f, 0.1f, 0.45f * flick * fade),
                    SDL_FColor(0.8f, 0.15f, 0.0f, 0), 16);
        }

        drawEndpoints(g, cam, mesh, t);

        // Range rings: the selected tower, and the tower about to be built.
        if (const sel = g.towerAt(inp.selCol, inp.selRow))
            if (g.catalog.fights(sel.kind))
                rangeRing(cam, mesh, sel.col, sel.row, g.rangeOf(*sel), SDL_FColor(1, 1, 1,
                        0.06f), SDL_FColor(1, 0.95f, 0.6f, 0.75f));
        if (inp.buildKind >= 0 && inp.buildKind < g.catalog.numTowers
                && g.catalog.fights(cast(TowerKind)inp.buildKind) && inp.hoverCol >= 0) {
            immutable ok = g.canPlace(cast(TowerKind)inp.buildKind, inp.hoverCol, inp.hoverRow) == CommandError.none;
            immutable i = cast(size_t)inp.hoverRow * g.board.rect.cols + inp.hoverCol;
            immutable bonus = g.board.inside(inp.hoverCol, inp.hoverRow) ? g.board.highGroundPct(i) : 0;
            immutable range = g.catalog.tower(cast(TowerKind)inp.buildKind, Stage.lv1).range * (100 + bonus) / 100;
            rangeRing(cam, mesh, inp.hoverCol, inp.hoverRow, range, SDL_FColor(ok ? 0.4f : 1, ok
                    ? 1 : 0.3f, 0.4f, 0.07f), ok ? SDL_FColor(0.5f, 1, 0.5f, 0.8f) : SDL_FColor(1, 0.35f, 0.3f, 0.8f));
        }

        // Creeps back to front.
        const creeps = g.creeps;
        if (capKeys < creeps.length) {
            auto k = cast(Key*)realloc(keys, creeps.length * Key.sizeof);
            if (k is null)
                return;
            keys = k;
            capKeys = creeps.length;
        }
        size_t nk = 0;
        foreach (i, ref c; creeps)
            if (c.alive)
                keys[nk++] = Key(c.py + (c.y - c.py) * alpha, cast(uint)i);
        qsort(keys, nk, Key.sizeof, &cmpKey);
        nsv = nsi = 0;
        foreach (k; 0 .. nk)
            drawCreep(cam, mesh, g.catalog, creeps[keys[k].id], alpha, t, false);
        if (nsi > 0) {
            // Shadows (and anything before them) go under the sprites.
            flush(r);
            SDL_RenderGeometry(r, sprites, sv, cast(int)nsv, si, cast(int)nsi);
        }
        foreach (k; 0 .. nk)
            drawCreep(cam, mesh, g.catalog, creeps[keys[k].id], alpha, t, true);

        foreach (ref p; g.projectiles)
            if (p.alive)
                drawProjectile(cam, mesh, p, alpha);
        flush(r);
    }

    /// Where creeps come from and where they go: a red portal at each source with chevrons
    /// marching down the first steps of its route, and a blue beacon over each sink. Brighter
    /// between waves, while the player is still building.
    private void drawEndpoints(ref const Game g, ref const Camera cam, ref const MapMesh mesh, float t) @nogc nothrow @trusted {
        const b = &g.board();
        immutable idle = g.status == GameStatus.waiting;
        immutable boost = idle ? 1.0f : 0.6f;
        immutable cellRx = halfHex * isoPerX * zoom, cellRy = halfHex * isoPerY * squash * zoom;

        foreach (k; 0 .. b.numSinks) {
            immutable o = cubeToOffset(b.sinks[k]);
            int wx, wy;
            cellWorld(o.col, o.row, wx, wy);
            immutable p = worldToScreen(cam, mesh, wx, wy, 0);
            immutable pulse = 0.5f + 0.5f * sinf(t * 3);
            disc(p.x, p.y, cellRx * 1.1f, cellRy * 1.1f, SDL_FColor(0.05f, 0.2f, 0.55f, 0.6f * boost),
                    SDL_FColor(0.2f, 0.5f, 1, 0), 24);
            ring(p.x, p.y, cellRx * (0.9f + 0.15f * pulse), cellRy * (0.9f + 0.15f * pulse), 3,
                    SDL_FColor(0.55f, 0.85f, 1, 0.9f * boost));
            ring(p.x, p.y, cellRx * 0.6f, cellRy * 0.6f, 2, SDL_FColor(1, 0.9f, 0.5f, 0.8f * boost));
            // Light pillar so the sink reads from across the map.
            immutable top = p.y - 3.0f * zoom;
            line(p.x, p.y, p.x, top, 0.35f * zoom, SDL_FColor(0.6f, 0.9f, 1, 0.55f * boost),
                    SDL_FColor(0.6f, 0.9f, 1, 0));
            // Shield diamond hovering in it.
            immutable hy = p.y - (1.9f + 0.12f * sinf(t * 2)) * zoom, hs = 0.28f * zoom;
            if (reserve(4, 6)) {
                immutable c = SDL_FColor(0.55f, 0.85f, 1, 0.95f), e = SDL_FColor(1, 0.95f, 0.6f, 0.95f);
                immutable q0 = put(p.x, hy - hs, e), q1 = put(p.x + hs * 0.7f, hy, c);
                immutable q2 = put(p.x, hy + hs, e), q3 = put(p.x - hs * 0.7f, hy, c);
                tri(q0, q1, q2);
                tri(q0, q2, q3);
            }
        }

        foreach (k; 0 .. b.numSources) {
            immutable o = cubeToOffset(b.sources[k]);
            int wx, wy;
            cellWorld(o.col, o.row, wx, wy);
            immutable p = worldToScreen(cam, mesh, wx, wy, 0);
            // Swirling portal on the ground.
            disc(p.x, p.y, cellRx * 1.05f, cellRy * 1.05f, SDL_FColor(0.25f, 0.0f, 0.05f,
                    0.55f * boost), SDL_FColor(1, 0.2f, 0.15f, 0.25f * boost), 24);
            foreach (r; 0 .. 3) {
                immutable f = ((t * 0.7f + r / 3.0f) % 1.0f);
                ring(p.x, p.y, cellRx * (1.0f - 0.7f * f), cellRy * (1.0f - 0.7f * f), 2.5f,
                        SDL_FColor(1, 0.3f + 0.4f * f, 0.2f, (1 - f) * 0.9f * boost));
            }
            immutable top = p.y - 2.4f * zoom;
            line(p.x, p.y, p.x, top, 0.3f * zoom, SDL_FColor(1, 0.3f, 0.2f, 0.5f * boost),
                    SDL_FColor(1, 0.3f, 0.2f, 0));

            // Chevrons down the distance field: the way the creeps will walk.
            CubeCoord c = b.sources[k];
            float px = p.x, py = p.y;
            foreach (step; 0 .. 7) {
                immutable i = b.rect.index(c);
                immutable d = b.distAt(i);
                if (d == 0 || d == unreachable)
                    break;
                bool found;
                CubeCoord next;
                foreach (dir; 0 .. 6) {
                    immutable n = c.neighbor(cast(HexDir)dir);
                    immutable no = cubeToOffset(n);
                    if (!b.inside(no.col, no.row))
                        continue;
                    if (b.distAt(b.rect.index(n)) < d) {
                        next = n;
                        found = true;
                        break;
                    }
                }
                if (!found)
                    break;
                immutable no = cubeToOffset(next);
                cellWorld(no.col, no.row, wx, wy);
                immutable q = worldToScreen(cam, mesh, wx, wy, 0.05f);
                immutable dx = q.x - px, dy = q.y - py;
                immutable len = sqrtf(dx * dx + dy * dy);
                if (len > 1) {
                    immutable ux = dx / len, uy = dy / len;
                    // Two chevrons per step, sliding forward; they fade out along the route.
                    foreach (h; 0 .. 2) {
                        immutable f = (h * 0.5f + t * 0.8f) % 1.0f;
                        immutable cx = px + dx * f, cy = py + dy * f;
                        immutable a = (1 - step / 7.0f) * boost * (0.4f + 0.6f * sinf(f * 3.14159f));
                        immutable sz = 0.34f * zoom;
                        immutable col = SDL_FColor(1, 0.35f, 0.25f, a);
                        line(cx - ux * sz - uy * sz, cy - uy * sz + ux * sz, cx, cy, 0.13f * zoom, col, col);
                        line(cx - ux * sz + uy * sz, cy - uy * sz - ux * sz, cx, cy, 0.13f * zoom, col, col);
                    }
                }
                px = q.x;
                py = q.y;
                c = next;
            }
        }
    }

    private void drawCreep(ref const Camera cam, ref const MapMesh mesh, ref const Catalog cat,
            ref const Creep c, float alpha, float t, bool barPass) @nogc nothrow @trusted {
        // Modded kinds borrow the looks of a built-in kind.
        immutable kind = cat.creeps[c.kind].look;
        immutable look = &creepLooks[kind];
        immutable x = c.px + (c.x - c.px) * alpha, y = c.py + (c.y - c.py) * alpha;
        immutable rad = look.radius * zoom;
        immutable ground = worldToScreen(cam, mesh, x, y, 0);
        // Hop as it walks (not while stunned).
        immutable hop = c.stunTicks > 0 ? 0.0f : 0.5f + 0.5f * sinf(t * 11 + c.serial * 1.7f);
        immutable lift = look.radius * (1.0f + 0.25f * hop);
        immutable top = worldToScreen(cam, mesh, x, y, lift);
        if (barPass) {
            // Sprites leave the stun stars to this pass, which draws over them.
            if (sprites !is null && c.stunTicks > 0)
                foreach (k; 0 .. 3) {
                    immutable a = t * 6 + k * 2.094f;
                    disc(top.x + cosf(a) * rad * 0.8f, top.y - rad * 1.05f + sinf(a) * rad * 0.25f,
                            rad * 0.12f + 1, rad * 0.12f + 1, SDL_FColor(1, 1, 0.6f, 1),
                            SDL_FColor(1, 0.85f, 0.2f, 1), 5);
                }
            if (c.hp >= c.maxHp)
                return;
            immutable w = rad * 2.2f > 14 ? rad * 2.2f : 14, h = zoom > 30 ? 4.0f : 3.0f;
            immutable bx = top.x - w * 0.5f, by = top.y - rad - h - 4;
            immutable f = c.hp > 0 ? cast(float)c.hp / c.maxHp : 0;
            rect(bx - 1, by - 1, w + 2, h + 2, SDL_FColor(0, 0, 0, 0.65f));
            rect(bx, by, w * f, h, SDL_FColor(1 - f, 0.25f + 0.65f * f, 0.15f, 0.95f));
            return;
        }
        disc(ground.x + rad * 0.2f, ground.y, rad * 0.95f, rad * 0.95f * squash, SDL_FColor(0, 0, 0,
                0.35f), SDL_FColor(0, 0, 0, 0), 10);
        if (sprites !is null) {
            drawSprite(c, kind, ground, x, y, t);
            return;
        }
        SDL_FColor body = look.body, rim = look.rim;
        if (c.slowTicks > 0) {
            body = mixc(body, SDL_FColor(0.6f, 0.85f, 1.0f, 1), 0.5f);
            rim = mixc(rim, SDL_FColor(0.3f, 0.55f, 0.9f, 1), 0.5f);
        }
        if (c.burnTicks > 0) {
            immutable fl = 0.35f + 0.25f * sinf(t * 25 + c.serial);
            body = mixc(body, SDL_FColor(1.0f, 0.5f, 0.1f, 1), fl);
        }
        if (c.chillTicks > 0)
            rim = mixc(rim, SDL_FColor(0.95f, 0.98f, 1.0f, 1), 0.6f);
        // Body: lit from the upper left.
        disc(top.x, top.y, rad, rad, rim, rim, 14);
        disc(top.x - rad * 0.15f, top.y - rad * 0.18f, rad * 0.82f, rad * 0.8f, body, mixc(body, rim, 0.35f), 14);
        disc(top.x - rad * 0.35f, top.y - rad * 0.4f, rad * 0.22f, rad * 0.18f, SDL_FColor(1, 1, 1,
                0.55f), SDL_FColor(1, 1, 1, 0), 8);
        // Eyes look where it walks.
        float dx = c.x - c.px, dy = (c.y - c.py) * squash;
        immutable dl = sqrtf(dx * dx + dy * dy);
        if (dl > 1e-3f) {
            dx /= dl;
            dy /= dl;
        } else {
            dx = 1;
            dy = 0;
        }
        immutable ex = top.x + dx * rad * 0.45f, ey = top.y + dy * rad * 0.25f - rad * 0.1f;
        immutable px = -dy * rad * 0.28f, py = dx * rad * 0.12f;
        immutable er = rad * 0.17f;
        if (rad > 3) {
            disc(ex + px, ey + py, er, er, SDL_FColor(1, 1, 1, 1), SDL_FColor(0.9f, 0.9f, 0.9f, 1), 6);
            disc(ex - px, ey - py, er, er, SDL_FColor(1, 1, 1, 1), SDL_FColor(0.9f, 0.9f, 0.9f, 1), 6);
            disc(ex + px + dx * er * 0.4f, ey + py, er * 0.5f, er * 0.5f, SDL_FColor(0.05f, 0.05f, 0.1f,
                    1), SDL_FColor(0.05f, 0.05f, 0.1f, 1), 5);
            disc(ex - px + dx * er * 0.4f, ey - py, er * 0.5f, er * 0.5f, SDL_FColor(0.05f, 0.05f, 0.1f,
                    1), SDL_FColor(0.05f, 0.05f, 0.1f, 1), 5);
        }
        if (kind == CreepKind.brute)
            ring(top.x, top.y, rad, rad, rad * 0.16f, SDL_FColor(0.75f, 0.75f, 0.8f, 0.9f), 14);
        if (kind == CreepKind.boss) {
            // Crown.
            immutable cy = top.y - rad * 0.95f;
            foreach (k; 0 .. 3) {
                immutable kx = top.x + (k - 1) * rad * 0.3f;
                if (!reserve(3, 3))
                    break;
                tri(put(kx - rad * 0.14f, cy + rad * 0.15f, SDL_FColor(1, 0.8f, 0.2f, 1)),
                        put(kx + rad * 0.14f, cy + rad * 0.15f, SDL_FColor(1, 0.8f, 0.2f, 1)),
                        put(kx, cy - rad * 0.25f, SDL_FColor(1, 0.95f, 0.5f, 1)));
            }
        }
        if (c.stunTicks > 0)
            foreach (k; 0 .. 3) {
                immutable a = t * 6 + k * 2.094f;
                disc(top.x + cosf(a) * rad * 0.8f, top.y - rad * 1.05f + sinf(a) * rad * 0.25f,
                        rad * 0.12f + 1, rad * 0.12f + 1, SDL_FColor(1, 1, 0.6f, 1), SDL_FColor(1, 0.85f, 0.2f, 1), 5);
            }
    }

    /// The creep as a pre-rendered sprite: facing from its motion, walk frame from time, status
    /// effects as a color wash.
    private void drawSprite(ref const Creep c, CreepKind kind, IsoPoint ground, float x, float y, float t) @nogc nothrow @trusted {
        immutable gx = (c.x - c.px) * isoPerX, gy = -(c.y - c.py) * isoPerY;
        immutable facing = spriteFacing(gx, gy);
        int frame = 0;
        if (c.stunTicks == 0) {
            immutable rate = c.slowTicks > 0 ? 8.0f * (100 - c.slowPct) / 100.0f : 8.0f;
            frame = cast(int)(t * rate + c.serial * 0.37f) % spriteFrames;
        }
        immutable i = spriteIndex(kind, facing, frame);
        immutable u0 = (i % spriteCols) * spriteCell / atlasW, v0 = (i / spriteCols) * spriteCell / atlasH;
        immutable size = spriteSpan * zoom;
        SDL_FColor tint = SDL_FColor(1, 1, 1, 1);
        if (c.slowTicks > 0)
            tint = mixc(tint, SDL_FColor(0.55f, 0.8f, 1.0f, 1), 0.5f);
        if (c.chillTicks > 0)
            tint = mixc(tint, SDL_FColor(0.85f, 0.95f, 1.0f, 1), 0.4f);
        if (c.burnTicks > 0)
            tint = mixc(tint, SDL_FColor(1.0f, 0.55f, 0.25f, 1), 0.35f + 0.25f * sinf(t * 25 + c.serial));
        spriteQuad(ground.x - size * 0.5f, ground.y - size * spriteAnchor, size, size, u0, v0,
                u0 + spriteCell / atlasW, v0 + spriteCell / atlasH, tint);
    }

    private void drawProjectile(ref const Camera cam, ref const MapMesh mesh, ref const Projectile p, float alpha) @nogc nothrow @trusted {
        immutable x = p.px + (p.x - p.px) * alpha, y = p.py + (p.y - p.py) * alpha;
        float f = (p.age - 1 + alpha) / (p.flight > 0 ? p.flight : 1);
        f = f < 0 ? 0 : (f > 1 ? 1 : f);
        final switch (p.kind) {
        case ProjKind.arrow:
            immutable lift = towerTop + (0.35f - towerTop) * f;
            immutable head = worldToScreen(cam, mesh, x, y, lift);
            float dx = p.tx - p.sx, dy = (p.ty - p.sy) * squash * isoPerY / isoPerX;
            immutable dl = sqrtf(dx * dx + dy * dy);
            if (dl < 1)
                return;
            dx /= dl;
            dy /= dl;
            immutable len = 0.5f * zoom;
            line(head.x - dx * len, head.y - dy * len, head.x, head.y, zoom * 0.06f + 1,
                    SDL_FColor(0.45f, 0.30f, 0.15f, 0.9f), SDL_FColor(1, 0.97f, 0.85f, 1));
            break;
        case ProjKind.shell:
        case ProjKind.bomblet:
            immutable big = p.kind == ProjKind.shell;
            immutable arc = (big ? 2.4f : 0.9f) * 4 * f * (1 - f);
            immutable start = big ? towerTop : 0.2f;
            immutable lift = start + (0.15f - start) * f + arc;
            immutable s = worldToScreen(cam, mesh, x, y, lift), gnd = worldToScreen(cam, mesh, x, y, 0);
            immutable rr = (big ? 0.17f : 0.09f) * zoom + 1;
            disc(gnd.x, gnd.y, rr, rr * squash, SDL_FColor(0, 0, 0, 0.3f), SDL_FColor(0, 0, 0, 0), 8);
            disc(s.x, s.y, rr, rr, SDL_FColor(0.35f, 0.33f, 0.32f, 1), SDL_FColor(0.08f, 0.08f, 0.1f, 1), 10);
            disc(s.x - rr * 0.3f, s.y - rr * 0.3f, rr * 0.3f, rr * 0.3f, SDL_FColor(1, 1, 1, 0.6f),
                    SDL_FColor(1, 1, 1, 0), 6);
            if (big)
                disc(s.x + rr * 0.5f, s.y - rr * 0.8f, rr * 0.35f, rr * 0.35f, SDL_FColor(1, 0.8f,
                        0.3f, 1), SDL_FColor(1, 0.3f, 0.0f, 0), 6); // lit fuse
            break;
        case ProjKind.shard:
            immutable lift = towerTop + (0.35f - towerTop) * f;
            immutable s = worldToScreen(cam, mesh, x, y, lift);
            immutable rr = 0.14f * zoom + 1;
            disc(s.x, s.y, rr * 1.9f, rr * 1.9f, SDL_FColor(0.6f, 0.9f, 1, 0.35f), SDL_FColor(0.6f, 0.9f, 1, 0), 10);
            disc(s.x, s.y, rr * 0.7f, rr * 1.2f, SDL_FColor(1, 1, 1, 1), SDL_FColor(0.55f, 0.85f, 1, 1), 4);
            break;
        }
    }
}

private SDL_FColor mixc(SDL_FColor a, SDL_FColor b, float t) @nogc nothrow pure @safe {
    return SDL_FColor(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t);
}
