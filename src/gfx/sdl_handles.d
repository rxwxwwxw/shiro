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
