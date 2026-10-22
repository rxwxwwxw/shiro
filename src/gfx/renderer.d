// Draws a MapMesh through SDL_RenderGeometry. Only rows that can reach the viewport are expanded
// into SDL_Vertex, and consecutive rows are batched into one call until the scratch buffers fill.
// View layer; the per-frame path is @nogc and allocation-free once the scratch buffers are sized.
module gfx.renderer;

import bindings.sdl3.sdl;
import core.stdc.stdlib : free, realloc;
import gfx.camera;
import gfx.hex_mesh;

struct MapRenderer {
    private SDL_Vertex* sv;
    private int* si;
    private size_t capV, capI, nV, nI;
    /// Vertices drawn last frame (for the stats readout).
    size_t drawnVerts;

    enum size_t batchVerts = 1 << 16;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        free(sv);
        free(si);
    }

    /// Sizes the scratch buffers for a mesh. Cold path; returns false if memory ran out.
    bool prepare(ref const MapMesh mesh) @nogc nothrow @trusted {
        immutable wantV = mesh.maxRowVerts > batchVerts ? mesh.maxRowVerts : batchVerts;
        immutable wantI = mesh.maxRowIdx > 2 * wantV ? mesh.maxRowIdx : 2 * wantV;
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
            SDL_RenderGeometry(r, null, sv, cast(int)nV, si, cast(int)nI);
        drawnVerts += nV;
        nV = nI = 0;
    }

    void draw(SDL_Renderer* r, ref const MapMesh mesh, ref const Camera cam) @nogc nothrow @trusted {
        drawnVerts = 0;
        if (mesh.rows == 0 || capV < mesh.maxRowVerts || capI < mesh.maxRowIdx)
            return;
        immutable top = cam.toWorld(0, 0).y, bottom = cam.toWorld(0, cam.height).y;
        immutable pitch = MapMesh.rowY(1);
        int r0 = cast(int)((top - mesh.rowBelow) / pitch) - 1;
        int r1 = cast(int)((bottom + mesh.rowAbove) / pitch) + 1;
        r0 = r0 < 0 ? 0 : r0;
        r1 = r1 >= mesh.rows ? mesh.rows - 1 : r1;

        immutable z = cam.zoom, ox = cam.x0 + cam.width * 0.5f - cam.cx * z;
        immutable oy = cam.height * 0.5f - cam.cy * z;
        enum float inv = 1.0f / 255.0f;
        foreach (row; r0 .. r1 + 1) {
            const(MeshVert)[] v;
            const(int)[] idx;
            mesh.row(row, v, idx);
            if (nV + v.length > capV || nI + idx.length > capI)
                flush(r);
            immutable base = cast(int)nV;
            foreach (ref m; v) {
                auto o = &sv[nV++];
                o.position = SDL_FPoint(m.x * z + ox, m.y * z + oy);
                o.color = SDL_FColor((m.rgba & 0xFF) * inv, (m.rgba >> 8 & 0xFF) * inv,
                        (m.rgba >> 16 & 0xFF) * inv, (m.rgba >> 24) * inv);
                o.tex_coord = SDL_FPoint(0, 0);
            }
            foreach (i; idx)
                si[nI++] = i + base;
        }
        flush(r);
    }
}
