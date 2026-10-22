// Zoomed-out view of the whole map as one image, a pixel pair per cell (the odd-row stagger is
// exact), so a 2M-cell map costs one textured quad per frame and ~16 MB instead of any geometry.
// Huge maps with extreme aspect ratios are sampled down to fit the texture limit. View layer.
module gfx.overview;

import bindings.sdl3.sdl;
import core.stdc.stdlib : free, malloc;
import gfx.camera;
import gfx.hex_mesh : edgeColor, heightShade, Rgb;
import gfx.iso;
import wfc.decorations : DecoKind;
import wfc.hex;
import wfc.map_session : MapSession;
import wfc.tile_data;

private enum int maxDim = 4096;

struct Overview {
    private SDL_Texture* tex;
    private int w, h, kx = 1, ky = 1;
    private float worldH;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        if (tex !is null)
            SDL_DestroyTexture(tex);
    }

    bool ready() const @nogc nothrow pure @safe {
        return tex !is null;
    }

    private static ubyte ch(float v) @nogc nothrow pure @safe {
        immutable x = cast(int)(v * 255.0f + 0.5f);
        return cast(ubyte)(x < 0 ? 0 : (x > 255 ? 255 : x));
    }

    /// Renders the session's map into the image. Returns false if memory or the texture failed.
    bool build(SDL_Renderer* r, ref const MapSession s) @nogc nothrow @trusted {
        if (tex !is null) {
            SDL_DestroyTexture(tex);
            tex = null;
        }
        immutable cols = s.tiles().rect.cols, rows = s.tiles().rect.rows;
        kx = (2 * cols + maxDim - 1) / maxDim;
        ky = (rows + maxDim - 1) / maxDim;
        kx = kx < 1 ? 1 : kx;
        ky = ky < 1 ? 1 : ky;
        w = (2 * cols + kx - 1) / kx;
        h = (rows + ky - 1) / ky;
        auto px = cast(ubyte*)malloc(cast(size_t)w * h * 4);
        if (px is null)
            return false;
        scope (exit)
            free(px);
        foreach (y; 0 .. h) {
            immutable row = (y * ky + ky / 2) < rows ? y * ky + ky / 2 : rows - 1;
            foreach (x; 0 .. w) {
                immutable pxl = x * kx + kx / 2;
                immutable cx = (pxl - (row & 1)) >> 1;
                auto o = px + (cast(size_t)y * w + x) * 4;
                o[0] = o[1] = o[2] = o[3] = 0;
                if (pxl - (row & 1) < 0 || cx >= cols)
                    continue;
                immutable c = offsetToCube(cx, row);
                if (!s.inMap(c))
                    continue;
                immutable col = cellColor(s, c);
                o[0] = ch(col.r);
                o[1] = ch(col.g);
                o[2] = ch(col.b);
                o[3] = 255;
            }
        }
        tex = SDL_CreateTexture(r, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, w, h);
        if (tex is null)
            return false;
        SDL_UpdateTexture(tex, null, px, w * 4);
        SDL_SetTextureScaleMode(tex, SDL_SCALEMODE_LINEAR);
        SDL_SetTextureBlendMode(tex, SDL_BLENDMODE_BLEND);
        return true;
    }

    private static Rgb cellColor(ref const MapSession s, CubeCoord c) @nogc nothrow @trusted {
        immutable id = s.tiles().get(c);
        if (id < 0)
            return Rgb(0.65f, 0.12f, 0.12f);
        const st = &s.rules.states[id];
        const edges = &s.rules.stateEdges[id];
        int[numEdgeTypes] count;
        bool river, road;
        foreach (d; 0 .. 6) {
            immutable t = (*edges)[d].type;
            river |= t == EdgeType.river;
            road |= t == EdgeType.road;
            count[t == EdgeType.road || t == EdgeType.river ? EdgeType.grass : t]++;
        }
        EdgeType best = EdgeType.grass;
        foreach (t; 0 .. numEdgeTypes)
            if (count[t] > count[best])
                best = cast(EdgeType)t;
        Rgb col = edgeColor[river ? EdgeType.river : (road ? EdgeType.road : best)];
        float level = st.level + tileList[st.tile].levelIncrement * 0.5f;
        switch (s.decorations.get(c).kind) {
        case DecoKind.tree:
            col = Rgb(0.20f, 0.46f, 0.26f);
            break;
        case DecoKind.building, DecoKind.windmill:
            col = Rgb(0.78f, 0.40f, 0.28f);
            break;
        case DecoKind.mountain:
            col = Rgb(0.62f, 0.60f, 0.58f);
            level += 2;
            break;
        default:
            break;
        }
        immutable sh = heightShade(level);
        return Rgb(col.r * sh, col.g * sh, col.b * sh);
    }

    /// Draws the part of the image inside the viewport. Clipping here rather than leaving it to SDL
    /// matters: zoomed in, the full destination rectangle is tens of thousands of pixels wide, which
    /// a software renderer would try to materialize.
    void draw(SDL_Renderer* r, ref const Camera cam) const @nogc nothrow @trusted {
        if (tex is null)
            return;
        immutable top = rowPitch * squash * -0.5f;
        immutable a = cam.toScreen(-1.0f, top);
        immutable b = cam.toScreen(-1.0f + w * kx, top + h * ky * rowPitch * squash);
        immutable fw = b.x - a.x, fh = b.y - a.y;
        if (fw <= 0 || fh <= 0)
            return;
        immutable vx0 = cam.x0, vx1 = cam.x0 + cam.width, vy0 = 0.0f, vy1 = cam.height;
        immutable cx0 = a.x > vx0 ? a.x : vx0, cx1 = b.x < vx1 ? b.x : vx1;
        immutable cy0 = a.y > vy0 ? a.y : vy0, cy1 = b.y < vy1 ? b.y : vy1;
        if (cx1 <= cx0 || cy1 <= cy0)
            return;
        immutable src = SDL_FRect((cx0 - a.x) / fw * w, (cy0 - a.y) / fh * h, (cx1 - cx0) / fw * w, (cy1 - cy0) / fh * h);
        immutable dst = SDL_FRect(cx0, cy0, cx1 - cx0, cy1 - cy0);
        SDL_RenderTexture(r, cast(SDL_Texture*)tex, &src, &dst);
    }
}
