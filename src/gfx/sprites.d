// Sprite atlases rendered by scripts/blender (td_creeps.py, village_chars.py): per kind, 8
// facings x 4 walk frames of `spriteCell`-pixel squares, `spriteCols` to an atlas row. A square
// spans `spriteSpan` iso units with the walker's ground point centered, `spriteAnchor` of the way
// down. Plus a small batch of textured quads and flat shapes for drawing walkers. View layer.
module gfx.sprites;

import bindings.sdl3.sdl;
import core.stdc.math : atan2f, cosf, sinf;
import core.stdc.stdlib : free, realloc;

enum int spriteCell = 128, spriteCols = 16, spriteFacings = 8, spriteFrames = 4;
enum float spriteSpan = 2.0f, spriteAnchor = 0.75f;

/// Atlas facing for motion (gx, gy) in iso units with y up; 0 = east, counter-clockwise.
int spriteFacing(float gx, float gy) @nogc nothrow @trusted {
    if (gx * gx + gy * gy <= 1e-8f)
        return 0;
    return cast(int)(atan2f(gy, gx) * (spriteFacings / 6.2831853f) + spriteFacings + 0.5f) % spriteFacings;
}

/// Atlas square of `kind` / `facing` / `frame`.
int spriteIndex(int kind, int facing, int frame) @nogc nothrow pure @safe {
    return (kind * spriteFacings + facing) * spriteFrames + frame;
}

/// Growable vertex batches: one textured (the atlas), one untextured (shadows, fallback shapes).
struct SpriteBatch {
    private SDL_Vertex* tv, fv;
    private int* ti, fi;
    private size_t ntv, nti, nfv, nfi, capTV, capTI, capFV, capFI;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(tv);
        free(ti);
        free(fv);
        free(fi);
    }

    void clear() @nogc nothrow pure @safe {
        ntv = nti = nfv = nfi = 0;
    }

    private static bool grow(T)(ref T* p, ref size_t cap, size_t need) @nogc nothrow @trusted {
        if (need <= cap)
            return true;
        immutable n = need * 2 + 256;
        auto q = cast(T*)realloc(p, n * T.sizeof);
        if (q is null)
            return false;
        p = q;
        cap = n;
        return true;
    }

    /// Atlas quad at (x, y) of size (w, h) in screen units, with texture coordinates u0..u1, v0..v1.
    void quad(float x, float y, float w, float h, float u0, float v0, float u1, float v1, SDL_FColor c) @nogc nothrow @trusted {
        if (!grow(tv, capTV, ntv + 4) || !grow(ti, capTI, nti + 6))
            return;
        immutable float[2][4] p = [[x, y], [x + w, y], [x + w, y + h], [x, y + h]];
        immutable float[2][4] uv = [[u0, v0], [u1, v0], [u1, v1], [u0, v1]];
        immutable base = cast(int)ntv;
        foreach (k; 0 .. 4)
            tv[ntv++] = SDL_Vertex(SDL_FPoint(p[k][0], p[k][1]), c, SDL_FPoint(uv[k][0], uv[k][1]));
        foreach (k; [0, 1, 2, 0, 2, 3])
            ti[nti++] = base + k;
    }

    /// Filled ellipse: `center` color in the middle fading to `rim` at the edge.
    void disc(float x, float y, float rx, float ry, SDL_FColor center, SDL_FColor rim, int segments = 14) @nogc nothrow @trusted {
        if (!grow(fv, capFV, nfv + segments + 1) || !grow(fi, capFI, nfi + segments * 3))
            return;
        immutable base = cast(int)nfv;
        fv[nfv++] = SDL_Vertex(SDL_FPoint(x, y), center, SDL_FPoint(0, 0));
        foreach (k; 0 .. segments) {
            immutable a = k * 6.2831853f / segments;
            fv[nfv++] = SDL_Vertex(SDL_FPoint(x + cosf(a) * rx, y + sinf(a) * ry), rim, SDL_FPoint(0, 0));
            fi[nfi++] = base;
            fi[nfi++] = base + 1 + k;
            fi[nfi++] = base + 1 + (k + 1) % segments;
        }
    }

    /// Untextured shapes first (they sit under the sprites), then the atlas quads.
    void flush(SDL_Renderer* r, SDL_Texture* atlas) @nogc nothrow @trusted {
        if (nfi > 0)
            SDL_RenderGeometry(r, null, fv, cast(int)nfv, fi, cast(int)nfi);
        if (nti > 0 && atlas !is null)
            SDL_RenderGeometry(r, atlas, tv, cast(int)ntv, ti, cast(int)nti);
        clear();
    }
}
