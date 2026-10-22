/* Nuklear implementation unit + SDL3 renderer backend for the Shiro viewer.
 *
 * Configuration follows third-party/Nuklear/demo/sdl3_renderer/main.c: Nuklear reuses SDL's
 * portable types and libc replacements, nk_bool is C `bool` (D `bool`). The shiro_nk_* shims keep
 * nk_allocator / font atlas structs on the C side so the D bindings only see opaque pointers. */
#include <SDL3/SDL.h>

#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#define NK_INCLUDE_COMMAND_USERDATA
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT

#define NK_INT8 Sint8
#define NK_UINT8 Uint8
#define NK_INT16 Sint16
#define NK_UINT16 Uint16
#define NK_INT32 Sint32
#define NK_UINT32 Uint32
#define NK_SIZE_TYPE uintptr_t
#define NK_POINTER_TYPE uintptr_t
#define NK_BOOL bool

#define NK_ASSERT(condition) SDL_assert(condition)
#define NK_STATIC_ASSERT(exp) SDL_COMPILE_TIME_ASSERT(, exp)
#define NK_MEMSET(dst, c, len) SDL_memset(dst, c, len)
#define NK_MEMCPY(dst, src, len) SDL_memcpy(dst, src, len)
#define NK_VSNPRINTF(s, n, f, a) SDL_vsnprintf(s, n, f, a)
#define NK_STRTOD(str, endptr) SDL_strtod(str, endptr)
static char *nk_sdl_dtoa(char *str, double d);
#define NK_DTOA(str, d) nk_sdl_dtoa(str, d)
#define NK_INV_SQRT(f) (1.0f / SDL_sqrtf(f))
#define NK_SIN(f) SDL_sinf(f)
#define NK_COS(f) SDL_cosf(f)

#define STBTT_ifloor(x) ((int)SDL_floor(x))
#define STBTT_iceil(x) ((int)SDL_ceil(x))
#define STBTT_sqrt(x) SDL_sqrt(x)
#define STBTT_pow(x, y) SDL_pow(x, y)
#define STBTT_fmod(x, y) SDL_fmod(x, y)
#define STBTT_cos(x) SDL_cosf(x)
#define STBTT_acos(x) SDL_acos(x)
#define STBTT_fabs(x) SDL_fabs(x)
#define STBTT_assert(x) SDL_assert(x)
#define STBTT_strlen(x) SDL_strlen(x)
#define STBTT_memcpy SDL_memcpy
#define STBTT_memset SDL_memset
#define stbtt_uint8 Uint8
#define stbtt_int8 Sint8
#define stbtt_uint16 Uint16
#define stbtt_int16 Sint16
#define stbtt_uint32 Uint32
#define stbtt_int32 Sint32
#define STBRP_SORT SDL_qsort
#define STBRP_ASSERT SDL_assert

#define NK_IMPLEMENTATION
#include "nuklear.h"
#define NK_SDL3_RENDERER_IMPLEMENTATION
#include "nuklear_sdl3_renderer.h"

static char *nk_sdl_dtoa(char *str, double d) {
    NK_ASSERT(str);
    if (!str)
        return NULL;
    (void)SDL_snprintf(str, 99999, "%.17g", d);
    return str;
}

/* Creates the context, bakes the default font at `scale` and starts the first input frame. */
struct nk_context *shiro_nk_init(SDL_Window *win, SDL_Renderer *renderer, float scale) {
    struct nk_context *ctx = nk_sdl_init(win, renderer, nk_sdl_allocator());
    struct nk_font_config config = nk_font_config(0);
    struct nk_font_atlas *atlas = nk_sdl_font_stash_begin(ctx);
    struct nk_font *font = nk_font_atlas_add_default(atlas, 13 * scale, &config);
    nk_sdl_font_stash_end(ctx);
    font->handle.height /= scale;
    nk_style_set_font(ctx, &font->handle);
    nk_input_begin(ctx);
    return ctx;
}

/* Feeds one event to Nuklear (converting to render coordinates first). */
void shiro_nk_handle_event(struct nk_context *ctx, SDL_Renderer *renderer, SDL_Event *evt) {
    SDL_ConvertEventToRenderCoordinates(renderer, evt);
    nk_sdl_handle_event(ctx, evt);
}

/* Draws the UI, then opens the input window for the next frame's events. */
void shiro_nk_render(struct nk_context *ctx) {
    nk_sdl_render(ctx, NK_ANTI_ALIASING_ON);
    nk_sdl_update_TextInput(ctx);
    nk_input_begin(ctx);
}

void shiro_nk_shutdown(struct nk_context *ctx) {
    nk_sdl_shutdown(ctx);
}
