// Draws a MapMesh through SDL_RenderGeometry. Only the chunks that can reach the viewport are
// expanded into SDL_Vertex, and consecutive chunks are batched into one call until the scratch
// buffers fill. Zoomed far out the prebuilt overview image is drawn instead. View layer; the
// per-frame path is @nogc and allocation-free once the scratch buffers have grown to fit.
module gfx.renderer;

import bindings.sdl3.sdl;
import core.stdc.math : sinf;
import core.stdc.stdlib : free, realloc;
import gfx.camera;
import gfx.hex_mesh;
import gfx.iso;
import gfx.overview;

struct MapRenderer {
    private SDL_Vertex* sv;
    private int* si;
    private SDL_Texture* tex;
    private size_t capV, capI, nV, nI;
    /// Vertices drawn last frame (for the stats readout).
    size_t drawnVerts;
    /// True if last frame drew any water sparkle (so an animated drift needs redraws).
    bool sparkleVisible;

    enum size_t batchVerts = 1 << 15;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(sv);
        free(si);
    }

    /// Grows the scratch buffers to hold `v` more vertices / `i` more indices; false if memory ran out.
    private bool reserve(size_t v, size_t i) @nogc nothrow @trusted {
        immutable wantV = nV + v > batchVerts ? nV + v : batchVerts;
        immutable wantI = nI + i > 2 * wantV ? nI + i : 2 * wantV;
        if (wantV > capV) {
            auto p = cast(SDL_Vertex*)realloc(sv, wantV * SDL_Vertex.sizeof);
            if (p is null)
                return false;
            sv = p;
            capV = wantV;
        }
        if (wantI > capI) {
            auto p = cast(int*)realloc(si, wantI * int.sizeof);
            if (p is null)
                return false;
            si = p;
            capI = wantI;
        }
        return true;
    }

    private void flush(SDL_Renderer* r) @nogc nothrow @trusted {
        if (nI > 0)
            SDL_RenderGeometry(r, tex, sv, cast(int)nV, si, cast(int)nI);
        drawnVerts += nV;
        nV = nI = 0;
    }

    /// Expands one layer into the scratch buffers, after the current contents.
    private void expand(const(MeshVert)[] v, const(int)[] idx, float z, float ox, float oy, float du = 0,
            float wave = float.nan) @nogc nothrow @trusted {
        enum float inv = 1.0f / 255.0f;
        immutable base = cast(int)nV;
        foreach (ref m; v) {
            auto o = &sv[nV++];
            o.position = SDL_FPoint(m.x * z + ox, m.y * z + oy);
            float alpha = (m.rgba >> 24) * inv;
            // Foam (the opaque-ish overlay vertices) pulses in bands travelling across the map.
            if (wave == wave && alpha > 0.6f)
                alpha *= 0.62f + 0.38f * sinf(wave + (m.x + m.y) * 1.7f);
            o.color = SDL_FColor((m.rgba & 0xFF) * inv, (m.rgba >> 8 & 0xFF) * inv, (m.rgba >> 16 & 0xFF) * inv, alpha);
            o.tex_coord = SDL_FPoint(m.u + du, m.v);
        }
        foreach (i; idx)
            si[nI++] = i + base;
    }

    /// `texture` is the model atlas (model level of detail), `caustic` the tiled water sparkle.
    void draw(SDL_Renderer* r, SDL_Texture* texture, SDL_Texture* caustic,
            ref const Overview overview, ref MapMesh mesh, ref const Camera cam, float sparkleShift = 0,
            float wave = float.nan) @nogc nothrow @trusted {
        drawnVerts = 0;
        sparkleVisible = false;
        nV = nI = 0;
        if (mesh.rows == 0)
            return;
        immutable lod = mesh.pick(cam);
        if (lod == Lod.overview) {
            overview.draw(r, cam);
            return;
        }
        tex = lod == Lod.model ? texture : null;
        mesh.beginFrame();
        immutable top = cam.toWorld(0, 0).y, bottom = cam.toWorld(0, cam.height).y;
        immutable left = cam.toWorld(cam.x0, 0).x, right = cam.toWorld(cam.x0 + cam.width, 0).x;
        immutable pitch = MapMesh.rowY(1);
        int r0 = cast(int)((top - mesh.rowBelow) / pitch) - 1;
        int r1 = cast(int)((bottom + mesh.rowAbove) / pitch) + 1;
        r0 = r0 < 0 ? 0 : r0;
        r1 = r1 >= mesh.rows ? mesh.rows - 1 : r1;
        // Cell centers sit at x = 2 col + (row & 1); models reach about 2.5 units past them.
        int b0 = cast(int)((left - 3.5f) / (2.0f * blockCols));
        int b1 = cast(int)((right + 3.5f) / (2.0f * blockCols));
        b0 = left < 3.5f ? 0 : (b0 < 0 ? 0 : b0);
        b1 = b1 >= mesh.blocks ? mesh.blocks - 1 : b1;

        immutable z = cam.zoom, ox = cam.x0 + cam.width * 0.5f - cam.cx * z;
        immutable oy = cam.height * 0.5f - cam.cy * z;
        foreach (row; r0 .. r1 + 1)
            foreach (block; b0 .. b1 + 1) {
                const(MeshVert)[] v, ov;
                const(int)[] idx, oidx;
                if (!mesh.chunk(row, block, v, idx, ov, oidx))
                    continue;
                if (idx.length != 0) {
                    if ((nV + v.length > capV || nI + idx.length > capI) && nV > 0)
                        flush(r);
                    if (reserve(v.length, idx.length))
                        expand(v, idx, z, ox, oy);
                }
                // Water sparkle goes over this chunk's tiles with its own (wrapped) texture.
                if (oidx.length != 0 && caustic !is null && lod == Lod.model) {
                    flush(r);
                    if (reserve(ov.length, oidx.length)) {
                        expand(ov, oidx, z, ox, oy, sparkleShift, wave);
                        sparkleVisible = true;
                        tex = caustic;
                        SDL_SetRenderTextureAddressMode(r, SDL_TEXTURE_ADDRESS_WRAP, SDL_TEXTURE_ADDRESS_WRAP);
                        flush(r);
                        SDL_SetRenderTextureAddressMode(r, SDL_TEXTURE_ADDRESS_AUTO, SDL_TEXTURE_ADDRESS_AUTO);
                        tex = texture;
                    }
                }
            }
        flush(r);
        mesh.endFrame();
    }
}
