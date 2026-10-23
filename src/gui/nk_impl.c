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
/* Nuklear clips window backgrounds and borders to its "no clip" rectangle (-8192 .. +8192). The GPU
 * renderer drops geometry clipped that way, so the backend's clip rectangles are cut to the output
 * first (the classic renderers accept either). */
static bool shiro_set_clip(SDL_Renderer *renderer, const SDL_Rect *rect) {
    if (rect == NULL)
        return SDL_SetRenderClipRect(renderer, NULL);
    int ow = 0, oh = 0;
    float sx = 1, sy = 1;
    SDL_GetCurrentRenderOutputSize(renderer, &ow, &oh);
    SDL_GetRenderScale(renderer, &sx, &sy);
    const int w = (int)(ow / (sx > 0 ? sx : 1)) + 1, h = (int)(oh / (sy > 0 ? sy : 1)) + 1;
    int x0 = rect->x < 0 ? 0 : rect->x, y0 = rect->y < 0 ? 0 : rect->y;
    int x1 = rect->x + rect->w > w ? w : rect->x + rect->w, y1 = rect->y + rect->h > h ? h : rect->y + rect->h;
    SDL_Rect r = {x0, y0, x1 > x0 ? x1 - x0 : 0, y1 > y0 ? y1 - y0 : 0};
    return SDL_SetRenderClipRect(renderer, &r);
}
#define SDL_SetRenderClipRect shiro_set_clip

#define NK_SDL3_RENDERER_IMPLEMENTATION
#include "nuklear_sdl3_renderer.h"

#undef SDL_SetRenderClipRect

static char *nk_sdl_dtoa(char *str, double d) {
    NK_ASSERT(str);
    if (!str)
        return NULL;
    (void)SDL_snprintf(str, 99999, "%.17g", d);
    return str;
}

/* Baked fonts: 0 = the panel's default font, 1 = dialogue text, 2 = speaker names, 3 = titles. */
static struct nk_font *shiro_fonts[4];

/* Creates the context, bakes the default font (and, when `text_font` names a TTF, the dialogue
 * fonts with Latin, Vietnamese and punctuation ranges) at `scale`, and starts the first input
 * frame. A missing TTF leaves the dialogue on the default font. */
struct nk_context *shiro_nk_init(SDL_Window *win, SDL_Renderer *renderer, float scale, const char *text_font) {
    static const nk_rune ranges[] = {0x0020, 0x00FF, 0x0100, 0x024F, 0x0300, 0x036F,
                                     0x1EA0, 0x1EFF, 0x2010, 0x2027, 0x2030, 0x205E, 0};
    struct nk_context *ctx = nk_sdl_init(win, renderer, nk_sdl_allocator());
    struct nk_font_config config = nk_font_config(0);
    struct nk_font_atlas *atlas = nk_sdl_font_stash_begin(ctx);
    shiro_fonts[0] = nk_font_atlas_add_default(atlas, 13 * scale, &config);
    shiro_fonts[1] = shiro_fonts[2] = NULL;
    if (text_font && SDL_GetPathInfo(text_font, NULL)) {
        struct nk_font_config tc = nk_font_config(0);
        tc.range = ranges;
        tc.oversample_h = 2;
        shiro_fonts[1] = nk_font_atlas_add_from_file(atlas, text_font, 18 * scale, &tc);
        shiro_fonts[2] = nk_font_atlas_add_from_file(atlas, text_font, 22 * scale, &tc);
        shiro_fonts[3] = nk_font_atlas_add_from_file(atlas, text_font, 44 * scale, &tc);
    }
    nk_sdl_font_stash_end(ctx);
    for (int i = 0; i < 4; i++)
        if (shiro_fonts[i])
            shiro_fonts[i]->handle.height /= scale;
    nk_style_set_font(ctx, &shiro_fonts[0]->handle);
    nk_input_begin(ctx);
    return ctx;
}

/* Switches the font for the widgets that follow (falls back to the default font). */
void shiro_nk_use_font(struct nk_context *ctx, int which) {
    struct nk_font *f = which >= 0 && which < 4 && shiro_fonts[which] ? shiro_fonts[which] : shiro_fonts[0];
    nk_style_set_font(ctx, &f->handle);
}

/* The dialogue box look: a borderless see-through window (the box art is drawn underneath) with
 * lacquer-red choice buttons and warm text. `push` 1 applies it, 0 restores the panel look. */
void shiro_nk_dialogue_style(struct nk_context *ctx, int push) {
    struct nk_style *s = &ctx->style;
    if (!push) {
        nk_style_pop_style_item(ctx);
        nk_style_pop_style_item(ctx);
        nk_style_pop_style_item(ctx);
        nk_style_pop_style_item(ctx);
        for (int i = 0; i < 6; i++)
            nk_style_pop_color(ctx);
        nk_style_pop_vec2(ctx);
        return;
    }
    nk_style_push_style_item(ctx, &s->window.fixed_background, nk_style_item_color(nk_rgba(0, 0, 0, 0)));
    nk_style_push_style_item(ctx, &s->button.normal, nk_style_item_color(nk_rgba(112, 38, 30, 225)));
    nk_style_push_style_item(ctx, &s->button.hover, nk_style_item_color(nk_rgba(150, 56, 40, 240)));
    nk_style_push_style_item(ctx, &s->button.active, nk_style_item_color(nk_rgba(186, 120, 52, 255)));
    nk_style_push_color(ctx, &s->window.border_color, nk_rgba(0, 0, 0, 0));
    nk_style_push_color(ctx, &s->button.border_color, nk_rgba(214, 170, 92, 255));
    nk_style_push_color(ctx, &s->button.text_normal, nk_rgba(255, 238, 205, 255));
    nk_style_push_color(ctx, &s->button.text_hover, nk_rgba(255, 250, 230, 255));
    nk_style_push_color(ctx, &s->button.text_active, nk_rgba(40, 20, 10, 255));
    nk_style_push_color(ctx, &s->text.color, nk_rgba(250, 236, 210, 255));
    nk_style_push_vec2(ctx, &s->window.padding, nk_vec2(10, 8));
}

/* The game's own look for menus and the HUD: dark lacquer panels with a gold rim, red buttons and
 * warm text. `push` 1 applies it, 0 restores the panel look. */
void shiro_nk_game_style(struct nk_context *ctx, int push) {
    struct nk_style *s = &ctx->style;
    if (!push) {
        for (int i = 0; i < 5; i++)
            nk_style_pop_style_item(ctx);
        for (int i = 0; i < 8; i++)
            nk_style_pop_color(ctx);
        nk_style_pop_float(ctx);
        return;
    }
    nk_style_push_style_item(ctx, &s->window.fixed_background, nk_style_item_color(nk_rgba(30, 22, 20, 228)));
    nk_style_push_style_item(ctx, &s->button.normal, nk_style_item_color(nk_rgba(112, 38, 30, 235)));
    nk_style_push_style_item(ctx, &s->button.hover, nk_style_item_color(nk_rgba(150, 56, 40, 245)));
    nk_style_push_style_item(ctx, &s->button.active, nk_style_item_color(nk_rgba(186, 120, 52, 255)));
    nk_style_push_style_item(ctx, &s->checkbox.normal, nk_style_item_color(nk_rgba(70, 50, 40, 255)));
    nk_style_push_color(ctx, &s->window.border_color, nk_rgba(196, 150, 78, 255));
    nk_style_push_color(ctx, &s->button.border_color, nk_rgba(214, 170, 92, 255));
    nk_style_push_color(ctx, &s->button.text_normal, nk_rgba(255, 238, 205, 255));
    nk_style_push_color(ctx, &s->button.text_hover, nk_rgba(255, 250, 230, 255));
    nk_style_push_color(ctx, &s->button.text_active, nk_rgba(40, 20, 10, 255));
    nk_style_push_color(ctx, &s->text.color, nk_rgba(250, 236, 210, 255));
    nk_style_push_color(ctx, &s->checkbox.text_normal, nk_rgba(250, 236, 210, 255));
    nk_style_push_color(ctx, &s->option.text_normal, nk_rgba(250, 236, 210, 255));
    nk_style_push_float(ctx, &s->button.rounding, 4.0f);
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
