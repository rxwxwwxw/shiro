// RAII owners for the SDL objects the viewer uses (AGENTS.md: no manual cleanup routines).
// Declare them in creation order; D destroys locals in reverse, which is the order SDL needs.
module gfx.sdl_handles;

import bindings.sdl3.sdl;
import core.result : EngineError;
import core.stdc.stdio : fprintf, stderr;

private EngineError fail(const(char)* what) @nogc nothrow @trusted {
    fprintf(stderr, "%s failed: %s\n", what, SDL_GetError());
    return EngineError.InitializationFailed;
}

struct SdlVideo {
    private bool up;

    @disable this(this);

    EngineError open() @nogc nothrow @trusted {
        if (!SDL_Init(SDL_INIT_VIDEO))
            return fail("SDL_Init");
        up = true;
        return EngineError.None;
    }

    ~this() @nogc nothrow @trusted {
        if (up)
            SDL_Quit();
    }
}

struct Window {
    SDL_Window* handle;

    @disable this(this);

    EngineError open(const(char)* title, int w, int h, SDL_WindowFlags flags) @nogc nothrow @trusted {
        handle = SDL_CreateWindow(title, w, h, flags);
        return handle is null ? fail("SDL_CreateWindow") : EngineError.None;
    }

    ~this() @nogc nothrow @trusted {
        if (handle !is null)
            SDL_DestroyWindow(handle);
    }
}

struct Renderer {
    SDL_Renderer* handle;

    @disable this(this);

    EngineError open(ref Window window) @nogc nothrow @trusted {
        handle = SDL_CreateRenderer(window.handle, null);
        if (handle is null)
            return fail("SDL_CreateRenderer");
        SDL_SetRenderVSync(handle, 1);
        SDL_SetRenderDrawBlendMode(handle, SDL_BLENDMODE_BLEND);
        return EngineError.None;
    }

    ~this() @nogc nothrow @trusted {
        if (handle !is null)
            SDL_DestroyRenderer(handle);
    }
}

/// A GPU texture decoded from PNG bytes.
struct Texture {
    SDL_Texture* handle;
    /// Level-blended copies stacked vertically in the texture (1 for a plain image).
    int variants = 1;

    @disable this(this);

    EngineError openPng(ref Renderer r, const(ubyte)[] png) @nogc nothrow @trusted {
        auto surf = SDL_LoadPNG_IO(SDL_IOFromConstMem(png.ptr, png.length), true);
        if (surf is null)
            return fail("SDL_LoadPNG_IO");
        scope (exit)
            SDL_DestroySurface(surf);
        handle = SDL_CreateTextureFromSurface(r.handle, surf);
        return handle is null ? fail("SDL_CreateTextureFromSurface") : EngineError.None;
    }

    /// Builds `count` copies of the atlas, copy k mixing `low` towards `high` by k / (count - 1)
    /// (the reference blends its moody and winter atlases by elevation), each reduced to
    /// `size` x `size` and stacked vertically. Mixes in linear light like the reference.
    EngineError openBlend(ref Renderer r, const(char)* low, const(char)* high, int count, int size,
            float saturation = 1.0f, float exposure = 1.0f) @nogc nothrow @trusted {
        import core.stdc.math : powf;
        import core.stdc.stdlib : free, malloc;

        auto sa = loadRgba(low), sb = loadRgba(high);
        scope (exit) {
            if (sa !is null)
                SDL_DestroySurface(sa);
            if (sb !is null)
                SDL_DestroySurface(sb);
        }
        if (sa is null || sb is null || sa.w != sb.w || sa.h != sb.h || sa.w != sa.h || size < 1
                || sa.w % size != 0 || count < 2)
            return fail("blend atlases");
        immutable f = sa.w / size;
        auto px = cast(ubyte*)malloc(cast(size_t)size * size * count * 4);
        if (px is null)
            return EngineError.InitializationFailed;
        scope (exit)
            free(px);
        float[256] lin;
        foreach (i; 0 .. 256)
            lin[i] = powf(i / 255.0f, 2.2f);
        immutable inv = 1.0f / (f * f);
        foreach (y; 0 .. size)
            foreach (x; 0 .. size) {
                float[4] a = 0, b = 0;
                foreach (dy; 0 .. f)
                    foreach (dx; 0 .. f) {
                        immutable o = (y * f + dy) * sa.pitch + (x * f + dx) * 4;
                        immutable o2 = (y * f + dy) * sb.pitch + (x * f + dx) * 4;
                        foreach (c; 0 .. 3) {
                            a[c] += lin[(cast(ubyte*)sa.pixels)[o + c]];
                            b[c] += lin[(cast(ubyte*)sb.pixels)[o2 + c]];
                        }
                        a[3] += (cast(ubyte*)sa.pixels)[o + 3];
                        b[3] += (cast(ubyte*)sb.pixels)[o2 + 3];
                    }
                foreach (k; 0 .. count) {
                    immutable t = cast(float)k / (count - 1);
                    auto dst = px + ((cast(size_t)k * size + y) * size + x) * 4;
                    float[3] rgb;
                    foreach (c; 0 .. 3)
                        rgb[c] = powf((a[c] + (b[c] - a[c]) * t) * inv, 1.0f / 2.2f);
                    // The reference lights its tiles with an HDR environment and tone-maps them,
                    // which lifts and saturates the palette; fold that into the atlas.
                    immutable luma = 0.299f * rgb[0] + 0.587f * rgb[1] + 0.114f * rgb[2];
                    foreach (c; 0 .. 3) {
                        immutable v = (luma + (rgb[c] - luma) * saturation) * exposure * 255.0f + 0.5f;
                        dst[c] = cast(ubyte)(v < 0 ? 0 : (v > 255 ? 255 : v));
                    }
                    immutable al = (a[3] + (b[3] - a[3]) * t) * inv + 0.5f;
                    dst[3] = cast(ubyte)(al > 255 ? 255 : al);
                }
            }
        handle = SDL_CreateTexture(r.handle, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, size, size * count);
        if (handle is null || !SDL_UpdateTexture(handle, null, px, size * 4))
            return fail("blend texture");
        SDL_SetTextureScaleMode(handle, SDL_SCALEMODE_LINEAR);
        variants = count;
        return EngineError.None;
    }

    /// The water sparkle layer: the reference's tileable caustic image as white with alpha
    /// floor + (1 - floor) * clamp((gray - brightness) * contrast) (the floor is a faint even sheen
    /// over all water), meant to be tiled over water with wrapped UVs.
    EngineError openCaustic(ref Renderer r, const(char)* path, float brightness, float contrast, float floor = 0.0f) @nogc nothrow @trusted {
        import core.stdc.stdlib : free, malloc;

        auto raw = SDL_LoadSurface(path);
        if (raw is null)
            return fail("caustic image");
        auto surf = SDL_ConvertSurface(raw, SDL_PIXELFORMAT_RGBA32);
        SDL_DestroySurface(raw);
        if (surf is null)
            return fail("caustic convert");
        scope (exit)
            SDL_DestroySurface(surf);
        auto px = cast(ubyte*)malloc(cast(size_t)surf.w * surf.h * 4);
        if (px is null)
            return EngineError.InitializationFailed;
        scope (exit)
            free(px);
        foreach (y; 0 .. surf.h)
            foreach (x; 0 .. surf.w) {
                const src = cast(ubyte*)surf.pixels + y * surf.pitch + x * 4;
                immutable a = (src[0] / 255.0f - brightness) * contrast;
                auto dst = px + (cast(size_t)y * surf.w + x) * 4;
                dst[0] = dst[1] = dst[2] = 255;
                immutable sparkle = a < 0 ? 0 : (a > 1 ? 1 : a);
                dst[3] = cast(ubyte)((floor + (1.0f - floor) * sparkle) * 255.0f + 0.5f);
            }
        handle = SDL_CreateTexture(r.handle, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, surf.w, surf.h);
        if (handle is null || !SDL_UpdateTexture(handle, null, px, surf.w * 4))
            return fail("caustic texture");
        SDL_SetTextureScaleMode(handle, SDL_SCALEMODE_LINEAR);
        SDL_SetTextureBlendMode(handle, SDL_BLENDMODE_BLEND);
        return EngineError.None;
    }

    /// A tile of film grain: random black / white speckles at a few percent opacity, to be wrapped
    /// over the screen at a random offset each frame.
    EngineError openGrain(ref Renderer r, int size, ubyte alpha) @nogc nothrow @trusted {
        import core.stdc.stdlib : free, malloc;

        auto px = cast(ubyte*)malloc(cast(size_t)size * size * 4);
        if (px is null)
            return EngineError.InitializationFailed;
        scope (exit)
            free(px);
        uint rng = 0x9E3779B9u;
        foreach (i; 0 .. cast(size_t)size * size) {
            rng = rng * 1664525u + 1013904223u;
            immutable v = (rng >> 24) & 0xFF;
            px[4 * i] = px[4 * i + 1] = px[4 * i + 2] = cast(ubyte)(v < 128 ? 0 : 255);
            px[4 * i + 3] = cast(ubyte)(alpha * (0.4f + 0.6f * ((rng >> 8 & 0xFF) / 255.0f)));
        }
        handle = SDL_CreateTexture(r.handle, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, size, size);
        if (handle is null || !SDL_UpdateTexture(handle, null, px, size * 4))
            return fail("grain texture");
        SDL_SetTextureBlendMode(handle, SDL_BLENDMODE_BLEND);
        return EngineError.None;
    }

    private static SDL_Surface* loadRgba(const(char)* path) @nogc nothrow @trusted {
        auto raw = SDL_LoadPNG(path);
        if (raw is null)
            return null;
        auto conv = SDL_ConvertSurface(raw, SDL_PIXELFORMAT_RGBA32);
        SDL_DestroySurface(raw);
        return conv;
    }

    ~this() @nogc nothrow @trusted {
        if (handle !is null)
            SDL_DestroyTexture(handle);
    }
}

/// Saves the current render target (call before present) as a BMP.
EngineError saveScreenshot(SDL_Renderer* r, const(char)* path) @nogc nothrow @trusted {
    auto surf = SDL_RenderReadPixels(r, null);
    if (surf is null)
        return fail("SDL_RenderReadPixels");
    scope (exit)
        SDL_DestroySurface(surf);
    if (!SDL_SaveBMP(surf, path))
        return fail("SDL_SaveBMP");
    return EngineError.None;
}
