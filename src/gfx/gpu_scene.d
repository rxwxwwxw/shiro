// D face of gpu_scene.c: the tile mesh drawn from retained GPU buffers into an offscreen texture
// that the (GPU-backed) SDL_Renderer then composites. View layer.
module gfx.gpu_scene;

import bindings.sdl3.sdl;
import gfx.hex_mesh : MeshVert;

private struct ShiroScene;

private extern (C) @nogc nothrow {
    ShiroScene* shiro_scene_create(SDL_Renderer* r, SDL_Texture* probe);
    void shiro_scene_destroy(ShiroScene* s);
    void* shiro_scene_upload(ShiroScene* s, const(MeshVert)* v, uint nv, const(int)* idx, uint ni,
            const(MeshVert)* ov, uint nov, const(int)* oidx, uint noi);
    void shiro_chunk_free(void* chunk);
    bool shiro_scene_begin(ShiroScene* s, SDL_Texture* target, float r, float g, float b, const(float)* xf);
    void shiro_scene_draw(ShiroScene* s, const(void)* chunk, int layer, uint firstVertex,
            uint firstIndex, uint numIndices, SDL_Texture* texture, bool wrap, float du, float wave);
    void shiro_scene_end(ShiroScene* s);
}

/// The C side reads vertices as x, y, rgba, u, v.
static assert(MeshVert.sizeof == 20);

/// Frees one uploaded chunk; what MapMesh calls when it drops a chunk.
void releaseChunk(void* chunk) @nogc nothrow @trusted {
    shiro_chunk_free(chunk);
}

struct GpuScene {
    private ShiroScene* scene;
    private SDL_Texture* target;
    private int targetW, targetH;
    private SDL_Renderer* ren;

    @disable this(this);

    ~this() @nogc nothrow @trusted {
        if (target !is null)
            SDL_DestroyTexture(target);
        shiro_scene_destroy(scene);
    }

    /// False if `renderer` is not a GPU renderer or the pipeline could not be built.
    bool open(SDL_Renderer* renderer) @nogc nothrow @trusted {
        ren = renderer;
        scene = shiro_scene_create(renderer, null);
        return scene !is null;
    }

    bool ready() const @nogc nothrow pure @safe {
        return scene !is null;
    }

    /// Matches the offscreen target to a viewport of `w` x `h` render units.
    private bool fitTarget(float w, float h) @nogc nothrow @trusted {
        float sx = 1, sy = 1;
        SDL_GetRenderScale(ren, &sx, &sy);
        immutable pw = cast(int)(w * sx + 0.5f), ph = cast(int)(h * sy + 0.5f);
        if (target !is null && pw == targetW && ph == targetH)
            return true;
        if (target !is null)
            SDL_DestroyTexture(target);
        target = SDL_CreateTexture(ren, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_TARGET, pw, ph);
        targetW = pw;
        targetH = ph;
        if (target is null)
            return false;
        SDL_SetTextureBlendMode(target, SDL_BLENDMODE_NONE);
        return true;
    }

    /// Uploads a built chunk; null if it has nothing to draw or memory ran out.
    void* upload(const(MeshVert)[] v, const(int)[] idx, const(MeshVert)[] ov, const(int)[] oidx) @nogc nothrow @trusted {
        return shiro_scene_upload(scene, v.ptr, cast(uint)v.length, idx.ptr, cast(uint)idx.length,
                ov.ptr, cast(uint)ov.length, oidx.ptr, cast(uint)oidx.length);
    }

    /// Starts a frame covering a `w` x `h` render-unit area; `xf` maps world to clip space.
    bool begin(float w, float h, float[3] bg, ref const float[4] xf) @nogc nothrow @trusted {
        return fitTarget(w, h) && shiro_scene_begin(scene, target, bg[0], bg[1], bg[2], xf.ptr);
    }

    void draw(const(void)* chunk, uint firstVertex, uint firstIndex, uint numIndices,
            SDL_Texture* texture, bool wrap = false, float du = 0, float wave = float.nan) @nogc nothrow @trusted {
        shiro_scene_draw(scene, chunk, 0, firstVertex, firstIndex, numIndices, texture, wrap, du, wave);
    }

    /// Ends the pass and draws the result into the renderer's current target.
    void end(float w, float h) @nogc nothrow @trusted {
        shiro_scene_end(scene);
        immutable dst = SDL_FRect(0, 0, w, h);
        SDL_RenderTexture(ren, target, null, &dst);
    }
}
