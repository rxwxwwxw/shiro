// Hand-written SDL3 (3.4) bindings: only the subset the viewer uses. Layouts are pinned with
// static asserts against offsets measured from the vendored headers (third-party/SDL3/include).
module bindings.sdl3.sdl;

extern (C) @nogc nothrow:

alias SDL_WindowFlags = ulong;
alias SDL_Keycode = uint;
alias SDL_Keymod = ushort;

struct SDL_Window;
struct SDL_Renderer;
struct SDL_Texture;
struct SDL_IOStream;

enum uint SDL_INIT_VIDEO = 0x20;

enum SDL_WindowFlags SDL_WINDOW_RESIZABLE = 0x20;
enum SDL_WindowFlags SDL_WINDOW_HIDDEN = 0x08;
enum SDL_WindowFlags SDL_WINDOW_HIGH_PIXEL_DENSITY = 0x2000;

struct SDL_FPoint {
    float x, y;
}

struct SDL_FRect {
    float x, y, w, h;
}

struct SDL_FColor {
    float r, g, b, a;
}

struct SDL_Vertex {
    SDL_FPoint position;
    SDL_FColor color;
    SDL_FPoint tex_coord;
}

static assert(SDL_Vertex.sizeof == 32);

struct SDL_Surface {
    uint flags;
    uint format;
    int w, h;
    int pitch;
    void* pixels;
    int refcount;
    void* reserved;
}

static assert(SDL_Surface.sizeof == 48 && SDL_Surface.pitch.offsetof == 16 && SDL_Surface.pixels.offsetof == 24);

// ---- events ----------------------------------------------------------------------------------

enum : uint {
    SDL_EVENT_QUIT = 0x100,
    SDL_EVENT_WINDOW_RESIZED = 0x206,
    SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED = 0x207,
    SDL_EVENT_WINDOW_MOUSE_LEAVE = 0x20D,
    SDL_EVENT_WINDOW_FOCUS_LOST = 0x20F,
    SDL_EVENT_WINDOW_CLOSE_REQUESTED = 0x210,
    SDL_EVENT_KEY_DOWN = 0x300,
    SDL_EVENT_KEY_UP = 0x301,
    SDL_EVENT_MOUSE_MOTION = 0x400,
    SDL_EVENT_MOUSE_BUTTON_DOWN = 0x401,
    SDL_EVENT_MOUSE_BUTTON_UP = 0x402,
    SDL_EVENT_MOUSE_WHEEL = 0x403,
}

enum ubyte SDL_BUTTON_LEFT = 1;
enum ubyte SDL_BUTTON_MIDDLE = 2;
enum ubyte SDL_BUTTON_RIGHT = 3;

enum SDL_Keymod SDL_KMOD_SHIFT = 0x0003;

enum : SDL_Keycode {
    SDLK_BACKSPACE = 0x08,
    SDLK_TAB = 0x09,
    SDLK_RETURN = 0x0d,
    SDLK_SPACE = 0x20,
    SDLK_COMMA = 0x2c,
    SDLK_PERIOD = 0x2e,
    SDLK_1 = 0x31,
    SDLK_2 = 0x32,
    SDLK_3 = 0x33,
    SDLK_4 = 0x34,
    SDLK_5 = 0x35,
    SDLK_6 = 0x36,
    SDLK_B = 0x62,
    SDLK_E = 0x65,
    SDLK_P = 0x70,
    SDLK_Q = 0x71,
    SDLK_T = 0x74,
    SDLK_U = 0x75,
    SDLK_DELETE = 0x7f,
    SDLK_ESCAPE = 0x1b,
    SDLK_MINUS = 0x2d,
    SDLK_EQUALS = 0x3d,
    SDLK_A = 0x61,
    SDLK_D = 0x64,
    SDLK_F = 0x66,
    SDLK_O = 0x6f,
    SDLK_R = 0x72,
    SDLK_S = 0x73,
    SDLK_W = 0x77,
    SDLK_RIGHT = 0x4000004f,
    SDLK_LEFT = 0x40000050,
    SDLK_DOWN = 0x40000051,
    SDLK_UP = 0x40000052,
}

struct SDL_KeyboardEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    uint windowID;
    uint which;
    uint scancode;
    SDL_Keycode key;
    SDL_Keymod mod;
    ushort raw;
    bool down;
    bool repeat;
}

static assert(SDL_KeyboardEvent.key.offsetof == 28 && SDL_KeyboardEvent.mod.offsetof == 32
        && SDL_KeyboardEvent.down.offsetof == 36 && SDL_KeyboardEvent.repeat.offsetof == 37);

struct SDL_MouseMotionEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    uint windowID;
    uint which;
    uint state;
    float x, y;
    float xrel, yrel;
}

static assert(SDL_MouseMotionEvent.state.offsetof == 24 && SDL_MouseMotionEvent.x.offsetof == 28
        && SDL_MouseMotionEvent.xrel.offsetof == 36);

struct SDL_MouseButtonEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    uint windowID;
    uint which;
    ubyte button;
    bool down;
    ubyte clicks;
    ubyte padding;
    float x, y;
}

static assert(SDL_MouseButtonEvent.button.offsetof == 24 && SDL_MouseButtonEvent.x.offsetof == 28);

struct SDL_MouseWheelEvent {
    uint type;
    uint reserved;
    ulong timestamp;
    uint windowID;
    uint which;
    float x, y;
    uint direction;
    float mouse_x, mouse_y;
    int integer_x, integer_y;
}

static assert(SDL_MouseWheelEvent.y.offsetof == 28 && SDL_MouseWheelEvent.mouse_x.offsetof == 36);

union SDL_Event {
    uint type;
    SDL_KeyboardEvent key;
    SDL_MouseMotionEvent motion;
    SDL_MouseButtonEvent button;
    SDL_MouseWheelEvent wheel;
    ubyte[128] padding;
}

static assert(SDL_Event.sizeof == 128);

// ---- functions -------------------------------------------------------------------------------

bool SDL_Init(uint flags);
void SDL_Quit();
const(char)* SDL_GetError();

SDL_Window* SDL_CreateWindow(const(char)* title, int w, int h, SDL_WindowFlags flags);
void SDL_DestroyWindow(SDL_Window* window);
float SDL_GetWindowDisplayScale(SDL_Window* window);
bool SDL_GetWindowSize(SDL_Window* window, int* w, int* h);

SDL_Renderer* SDL_CreateRenderer(SDL_Window* window, const(char)* name);
/// A 2D renderer on an SDL_gpu device (Metal, Vulkan, D3D12); the device is created when null.
SDL_Renderer* SDL_CreateGPURenderer(void* device, SDL_Window* window);
void* SDL_GetGPURendererDevice(SDL_Renderer* renderer);
const(char)* SDL_GetGPUDeviceDriver(void* device);
bool SDL_GetRenderScale(SDL_Renderer* renderer, float* scaleX, float* scaleY);
void SDL_DestroyRenderer(SDL_Renderer* renderer);
bool SDL_SetRenderVSync(SDL_Renderer* renderer, int vsync);
bool SDL_SetRenderScale(SDL_Renderer* renderer, float scaleX, float scaleY);
bool SDL_SetRenderDrawColor(SDL_Renderer* renderer, ubyte r, ubyte g, ubyte b, ubyte a);
bool SDL_RenderClear(SDL_Renderer* renderer);
bool SDL_RenderPresent(SDL_Renderer* renderer);
bool SDL_RenderGeometry(SDL_Renderer* renderer, void* texture, const(SDL_Vertex)* vertices,
        int numVertices, const(int)* indices, int numIndices);
bool SDL_RenderDebugText(SDL_Renderer* renderer, float x, float y, const(char)* str);
bool SDL_RenderLines(SDL_Renderer* renderer, const(SDL_FPoint)* points, int count);
SDL_Surface* SDL_RenderReadPixels(SDL_Renderer* renderer, const(void)* rect);

bool SDL_PollEvent(SDL_Event* event);

SDL_IOStream* SDL_IOFromConstMem(const(void)* mem, size_t size);
SDL_Surface* SDL_LoadPNG_IO(SDL_IOStream* src, bool closeio);
SDL_Texture* SDL_CreateTextureFromSurface(SDL_Renderer* renderer, SDL_Surface* surface);
void SDL_DestroyTexture(SDL_Texture* texture);
const(char)* SDL_GetBasePath();
SDL_Surface* SDL_LoadPNG(const(char)* file);
SDL_Surface* SDL_ConvertSurface(SDL_Surface* surface, uint format);
SDL_Texture* SDL_CreateTexture(SDL_Renderer* renderer, uint format, int access, int w, int h);
bool SDL_UpdateTexture(SDL_Texture* texture, const(void)* rect, const(void)* pixels, int pitch);
bool SDL_SetTextureScaleMode(SDL_Texture* texture, int scaleMode);
bool SDL_SetTextureBlendMode(SDL_Texture* texture, uint blendMode);
bool SDL_RenderTexture(SDL_Renderer* renderer, SDL_Texture* texture, const(SDL_FRect)* srcrect,
        const(SDL_FRect)* dstrect);
SDL_Surface* SDL_LoadSurface(const(char)* file);
bool SDL_GetTextureSize(SDL_Texture* texture, float* w, float* h);
bool SDL_SetTextureColorModFloat(SDL_Texture* texture, float r, float g, float b);
bool SDL_SetTextureAlphaModFloat(SDL_Texture* texture, float alpha);
bool SDL_RenderFillRect(SDL_Renderer* renderer, const(SDL_FRect)* rect);
bool SDL_RenderRect(SDL_Renderer* renderer, const(SDL_FRect)* rect);
bool SDL_SetRenderTextureAddressMode(SDL_Renderer* renderer, int uMode, int vMode);
enum int SDL_TEXTURE_ADDRESS_AUTO = 0, SDL_TEXTURE_ADDRESS_WRAP = 2;
bool SDL_WaitEventTimeout(SDL_Event* event, int timeoutMS);

/// SDL_PIXELFORMAT_RGBA32 on little-endian machines (bytes in memory: R, G, B, A).
enum uint SDL_PIXELFORMAT_RGBA32 = 0x16762004;
enum int SDL_TEXTUREACCESS_STATIC = 0, SDL_TEXTUREACCESS_TARGET = 2;
enum int SDL_SCALEMODE_LINEAR = 1;

bool SDL_SaveBMP(SDL_Surface* surface, const(char)* file);
void SDL_DestroySurface(SDL_Surface* surface);

ulong SDL_GetPerformanceCounter();
ulong SDL_GetPerformanceFrequency();
bool SDL_GetCurrentRenderOutputSize(SDL_Renderer* renderer, int* w, int* h);

enum uint SDL_BLENDMODE_NONE = 0x0, SDL_BLENDMODE_BLEND = 0x1, SDL_BLENDMODE_ADD = 0x2;
bool SDL_SetRenderDrawBlendMode(SDL_Renderer* renderer, uint blendMode);
