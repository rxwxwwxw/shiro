// Hand-written Nuklear bindings: the widget subset the viewer panel uses, plus the shiro_nk_*
// shims from src/gui/nk_impl.c. nk_bool is C `bool` there (NK_BOOL), nk_flags is uint.
module bindings.nuklear.nuklear;

import bindings.sdl3.sdl : SDL_Event, SDL_Renderer, SDL_Window;

extern (C) @nogc nothrow:

struct nk_context;

alias nk_flags = uint;

struct nk_color {
    ubyte r, g, b, a;
}

enum nk_tree_type : int {
    NK_TREE_NODE,
    NK_TREE_TAB
}

enum nk_collapse_states : int {
    NK_MINIMIZED,
    NK_MAXIMIZED
}

struct nk_rect {
    float x, y, w, h;
}

enum : nk_flags {
    NK_WINDOW_BORDER = 1 << 0,
    NK_WINDOW_MOVABLE = 1 << 1,
    NK_WINDOW_SCALABLE = 1 << 2,
    NK_WINDOW_MINIMIZABLE = 1 << 4,
    NK_WINDOW_NO_SCROLLBAR = 1 << 5,
    NK_WINDOW_TITLE = 1 << 6,
}

enum : nk_flags {
    NK_TEXT_ALIGN_LEFT = 0x01,
    NK_TEXT_ALIGN_CENTERED = 0x02,
    NK_TEXT_ALIGN_MIDDLE = 0x10,
    NK_TEXT_LEFT = NK_TEXT_ALIGN_MIDDLE | NK_TEXT_ALIGN_LEFT,
    NK_TEXT_CENTERED = NK_TEXT_ALIGN_MIDDLE | NK_TEXT_ALIGN_CENTERED,
}

nk_context* shiro_nk_init(SDL_Window* win, SDL_Renderer* renderer, float scale, const(char)* textFont);
void shiro_nk_use_font(nk_context* ctx, int which);
void shiro_nk_dialogue_style(nk_context* ctx, int push);
void shiro_nk_handle_event(nk_context* ctx, SDL_Renderer* renderer, SDL_Event* evt);
void shiro_nk_render(nk_context* ctx);
void shiro_nk_shutdown(nk_context* ctx);

void nk_input_end(nk_context* ctx);
bool nk_begin(nk_context* ctx, const(char)* title, nk_rect bounds, nk_flags flags);
void nk_end(nk_context* ctx);
bool nk_window_is_any_hovered(const(nk_context)* ctx);
bool nk_item_is_any_active(const(nk_context)* ctx);
void nk_layout_row_dynamic(nk_context* ctx, float height, int cols);
void nk_label(nk_context* ctx, const(char)* text, nk_flags align_);
bool nk_button_label(nk_context* ctx, const(char)* title);
bool nk_checkbox_label(nk_context* ctx, const(char)* label, bool* active);
bool nk_option_label(nk_context* ctx, const(char)* label, bool active);
bool nk_slider_float(nk_context* ctx, float min, float* val, float max, float step);
bool nk_property_int(nk_context* ctx, const(char)* name, int min, int* val, int max, int step, float incPerPixel);
bool nk_tree_push_hashed(nk_context* ctx, nk_tree_type type, const(char)* title,
        nk_collapse_states initial, const(char)* hash, int len, int seed);
void nk_tree_pop(nk_context* ctx);
void nk_widget_disable_begin(nk_context* ctx);
void nk_widget_disable_end(nk_context* ctx);
void nk_label_colored(nk_context* ctx, const(char)* text, nk_flags align_, nk_color color);
void nk_text_wrap(nk_context* ctx, const(char)* text, int len);
void nk_text_colored(nk_context* ctx, const(char)* text, int len, nk_flags align_, nk_color color);
bool nk_button_text(nk_context* ctx, const(char)* title, int len);
void nk_spacing(nk_context* ctx, int cols);
