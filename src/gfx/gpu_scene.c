/* GPU path for the tile mesh (SDL_gpu: Metal, Vulkan, D3D via Vulkan from one source).
 *
 * The viewer's SDL_Renderer is a GPU renderer (SDL_CreateGPURenderer), so Nuklear, the overview
 * image, grain and vignette keep using it. The tile mesh is different: it is thousands of
 * triangles that never change, so each chunk lives in static GPU buffers and a frame is a few
 * dozen draw calls. The mesh renders into an offscreen texture that the renderer then draws.
 *
 * Kept in C like nk_impl.c: SDL_gpu's create-info structs are large and nested, and the compiler
 * checks their layout where hand-written D bindings could only guess. The D side (gfx.gpu_scene)
 * sees opaque pointers.
 *
 * Call order per frame: shiro_scene_upload (any number) -> shiro_scene_begin -> shiro_scene_draw
 * (any number) -> shiro_scene_end. */
#include <SDL3/SDL.h>
#include <stddef.h>
#include <stdlib.h>

#include "shaders/scene_shaders.h"

/* Matches gfx.hex_mesh.MeshVert: x, y, packed rgba (r low), u, v. */
typedef struct {
    float x, y;
    Uint32 rgba;
    float u, v;
} SceneVert;

typedef struct {
    SDL_GPUDevice *dev;
    SDL_GPUBuffer *vb;
    SDL_GPUBuffer *ib;
} SceneChunk;

typedef struct ShiroScene {
    SDL_Renderer *renderer;
    SDL_GPUDevice *device;
    SDL_GPUGraphicsPipeline *pipeline;
    SDL_GPUSampler *clamp;
    SDL_GPUSampler *wrap;
    SDL_GPUTexture *white;
    SDL_GPUCommandBuffer *cmd;
    SDL_GPUCopyPass *copy;
    SDL_GPURenderPass *pass;
    SDL_GPUTextureFormat format;
    float xform[4];
    /* GPU textures already known to be on the GPU (see sync_texture). */
    SDL_GPUTexture *synced[8];
    int num_synced;
} ShiroScene;

static SDL_GPUShader *make_shader(SDL_GPUDevice *dev, SDL_GPUShaderStage stage, const unsigned char *spv,
                                  size_t spv_size, const unsigned char *msl, size_t msl_size,
                                  Uint32 samplers, Uint32 uniforms) {
    SDL_GPUShaderCreateInfo info;
    SDL_zero(info);
    info.stage = stage;
    info.num_samplers = samplers;
    info.num_uniform_buffers = uniforms;
    SDL_GPUShaderFormat have = SDL_GetGPUShaderFormats(dev);
    if (have & SDL_GPU_SHADERFORMAT_MSL) {
        info.format = SDL_GPU_SHADERFORMAT_MSL;
        info.code = msl;
        info.code_size = msl_size;
        info.entrypoint = "main0";
    } else if (have & SDL_GPU_SHADERFORMAT_SPIRV) {
        info.format = SDL_GPU_SHADERFORMAT_SPIRV;
        info.code = spv;
        info.code_size = spv_size;
        info.entrypoint = "main";
    } else {
        SDL_SetError("no supported shader format");
        return NULL;
    }
    return SDL_CreateGPUShader(dev, &info);
}

static SDL_GPUSampler *make_sampler(SDL_GPUDevice *dev, SDL_GPUSamplerAddressMode mode) {
    SDL_GPUSamplerCreateInfo info;
    SDL_zero(info);
    info.min_filter = info.mag_filter = SDL_GPU_FILTER_LINEAR;
    info.mipmap_mode = SDL_GPU_SAMPLERMIPMAPMODE_LINEAR;
    info.address_mode_u = info.address_mode_v = info.address_mode_w = mode;
    return SDL_CreateGPUSampler(dev, &info);
}

void shiro_scene_destroy(ShiroScene *s) {
    if (s == NULL)
        return;
    if (s->device != NULL) {
        SDL_WaitForGPUIdle(s->device);
        if (s->pipeline) SDL_ReleaseGPUGraphicsPipeline(s->device, s->pipeline);
        if (s->clamp) SDL_ReleaseGPUSampler(s->device, s->clamp);
        if (s->wrap) SDL_ReleaseGPUSampler(s->device, s->wrap);
        if (s->white) SDL_ReleaseGPUTexture(s->device, s->white);
    }
    free(s);
}

/* The scene is rendered into a texture of SDL_PIXELFORMAT_RGBA32, created through the renderer;
 * `target_probe` is such a texture, used to learn the matching GPU format. NULL if the renderer is
 * not a GPU renderer or setup failed. */
ShiroScene *shiro_scene_create(SDL_Renderer *renderer, SDL_Texture *target_probe) {
    SDL_GPUDevice *dev = SDL_GetGPURendererDevice(renderer);
    if (dev == NULL)
        return NULL;
    ShiroScene *s = (ShiroScene *)calloc(1, sizeof(ShiroScene));
    if (s == NULL)
        return NULL;
    s->renderer = renderer;
    s->device = dev;
    (void)target_probe;
    s->format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;

    SDL_GPUShader *vs = make_shader(dev, SDL_GPU_SHADERSTAGE_VERTEX, scene_vert_spv, sizeof scene_vert_spv,
                                    scene_vert_msl, sizeof scene_vert_msl, 0, 1);
    SDL_GPUShader *fs = make_shader(dev, SDL_GPU_SHADERSTAGE_FRAGMENT, scene_frag_spv, sizeof scene_frag_spv,
                                    scene_frag_msl, sizeof scene_frag_msl, 1, 0);
    if (vs == NULL || fs == NULL) {
        if (vs) SDL_ReleaseGPUShader(dev, vs);
        if (fs) SDL_ReleaseGPUShader(dev, fs);
        free(s);
        return NULL;
    }

    SDL_GPUVertexBufferDescription vbd;
    SDL_zero(vbd);
    vbd.pitch = sizeof(SceneVert);
    vbd.input_rate = SDL_GPU_VERTEXINPUTRATE_VERTEX;
    SDL_GPUVertexAttribute attrs[3];
    SDL_zero(attrs);
    attrs[0].location = 0;
    attrs[0].format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2;
    attrs[0].offset = offsetof(SceneVert, x);
    attrs[1].location = 1;
    attrs[1].format = SDL_GPU_VERTEXELEMENTFORMAT_UBYTE4_NORM;
    attrs[1].offset = offsetof(SceneVert, rgba);
    attrs[2].location = 2;
    attrs[2].format = SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2;
    attrs[2].offset = offsetof(SceneVert, u);

    /* SDL's BLENDMODE_BLEND: color by source alpha, alpha accumulates. */
    SDL_GPUColorTargetDescription ctd;
    SDL_zero(ctd);
    ctd.format = s->format;
    ctd.blend_state.enable_blend = true;
    ctd.blend_state.src_color_blendfactor = SDL_GPU_BLENDFACTOR_SRC_ALPHA;
    ctd.blend_state.dst_color_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    ctd.blend_state.color_blend_op = SDL_GPU_BLENDOP_ADD;
    ctd.blend_state.src_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE;
    ctd.blend_state.dst_alpha_blendfactor = SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA;
    ctd.blend_state.alpha_blend_op = SDL_GPU_BLENDOP_ADD;

    SDL_GPUGraphicsPipelineCreateInfo pi;
    SDL_zero(pi);
    pi.vertex_shader = vs;
    pi.fragment_shader = fs;
    pi.vertex_input_state.vertex_buffer_descriptions = &vbd;
    pi.vertex_input_state.num_vertex_buffers = 1;
    pi.vertex_input_state.vertex_attributes = attrs;
    pi.vertex_input_state.num_vertex_attributes = 3;
    pi.primitive_type = SDL_GPU_PRIMITIVETYPE_TRIANGLELIST;
    pi.rasterizer_state.fill_mode = SDL_GPU_FILLMODE_FILL;
    pi.rasterizer_state.cull_mode = SDL_GPU_CULLMODE_NONE;
    pi.multisample_state.sample_count = SDL_GPU_SAMPLECOUNT_1;
    pi.target_info.color_target_descriptions = &ctd;
    pi.target_info.num_color_targets = 1;
    s->pipeline = SDL_CreateGPUGraphicsPipeline(dev, &pi);
    SDL_ReleaseGPUShader(dev, vs);
    SDL_ReleaseGPUShader(dev, fs);

    s->clamp = make_sampler(dev, SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE);
    s->wrap = make_sampler(dev, SDL_GPU_SAMPLERADDRESSMODE_REPEAT);

    /* A 1x1 white texture stands in for "no texture" so one pipeline serves every detail level. */
    SDL_GPUTextureCreateInfo ti;
    SDL_zero(ti);
    ti.type = SDL_GPU_TEXTURETYPE_2D;
    ti.format = SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    ti.usage = SDL_GPU_TEXTUREUSAGE_SAMPLER;
    ti.width = ti.height = 1;
    ti.layer_count_or_depth = ti.num_levels = 1;
    s->white = SDL_CreateGPUTexture(dev, &ti);
    if (s->pipeline == NULL || s->clamp == NULL || s->wrap == NULL || s->white == NULL) {
        shiro_scene_destroy(s);
        return NULL;
    }
    SDL_GPUTransferBufferCreateInfo tbi;
    SDL_zero(tbi);
    tbi.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    tbi.size = 4;
    SDL_GPUTransferBuffer *tb = SDL_CreateGPUTransferBuffer(dev, &tbi);
    SDL_GPUCommandBuffer *cmd = SDL_AcquireGPUCommandBuffer(dev);
    if (tb == NULL || cmd == NULL) {
        shiro_scene_destroy(s);
        return NULL;
    }
    Uint8 *p = (Uint8 *)SDL_MapGPUTransferBuffer(dev, tb, false);
    p[0] = p[1] = p[2] = p[3] = 255;
    SDL_UnmapGPUTransferBuffer(dev, tb);
    SDL_GPUCopyPass *cp = SDL_BeginGPUCopyPass(cmd);
    SDL_GPUTextureTransferInfo src = {tb, 0, 0, 0};
    SDL_GPUTextureRegion dst;
    SDL_zero(dst);
    dst.texture = s->white;
    dst.w = dst.h = dst.d = 1;
    SDL_UploadToGPUTexture(cp, &src, &dst, false);
    SDL_EndGPUCopyPass(cp);
    SDL_SubmitGPUCommandBuffer(cmd);
    SDL_ReleaseGPUTransferBuffer(dev, tb);
    return s;
}

/* Uploads one chunk: tile layer then sparkle layer share a vertex buffer and an index buffer (the
 * second layer's indices stay relative, drawn with a vertex offset). Returns NULL on failure. */
SceneChunk *shiro_scene_upload(ShiroScene *s, const SceneVert *v, Uint32 nv, const int *idx, Uint32 ni,
                               const SceneVert *ov, Uint32 nov, const int *oidx, Uint32 noi) {
    Uint32 vbytes = (nv + nov) * (Uint32)sizeof(SceneVert), ibytes = (ni + noi) * (Uint32)sizeof(int);
    if (vbytes == 0 || ibytes == 0)
        return NULL;
    if (s->cmd == NULL) {
        s->cmd = SDL_AcquireGPUCommandBuffer(s->device);
        if (s->cmd == NULL)
            return NULL;
    }
    if (s->copy == NULL)
        s->copy = SDL_BeginGPUCopyPass(s->cmd);
    SceneChunk *c = (SceneChunk *)calloc(1, sizeof(SceneChunk));
    if (c != NULL)
        c->dev = s->device;
    SDL_GPUTransferBufferCreateInfo tbi;
    SDL_zero(tbi);
    tbi.usage = SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    tbi.size = vbytes + ibytes;
    SDL_GPUTransferBuffer *tb = SDL_CreateGPUTransferBuffer(s->device, &tbi);
    SDL_GPUBufferCreateInfo bi;
    SDL_zero(bi);
    bi.usage = SDL_GPU_BUFFERUSAGE_VERTEX;
    bi.size = vbytes;
    if (c != NULL)
        c->vb = SDL_CreateGPUBuffer(s->device, &bi);
    bi.usage = SDL_GPU_BUFFERUSAGE_INDEX;
    bi.size = ibytes;
    if (c != NULL)
        c->ib = SDL_CreateGPUBuffer(s->device, &bi);
    Uint8 *m = tb ? (Uint8 *)SDL_MapGPUTransferBuffer(s->device, tb, false) : NULL;
    if (c == NULL || tb == NULL || c->vb == NULL || c->ib == NULL || m == NULL) {
        if (tb) SDL_ReleaseGPUTransferBuffer(s->device, tb);
        if (c != NULL) {
            if (c->vb) SDL_ReleaseGPUBuffer(s->device, c->vb);
            if (c->ib) SDL_ReleaseGPUBuffer(s->device, c->ib);
            free(c);
        }
        return NULL;
    }
    SDL_memcpy(m, v, nv * sizeof(SceneVert));
    SDL_memcpy(m + nv * sizeof(SceneVert), ov, nov * sizeof(SceneVert));
    SDL_memcpy(m + vbytes, idx, ni * sizeof(int));
    SDL_memcpy(m + vbytes + ni * sizeof(int), oidx, noi * sizeof(int));
    SDL_UnmapGPUTransferBuffer(s->device, tb);
    SDL_GPUTransferBufferLocation from = {tb, 0};
    SDL_GPUBufferRegion to = {c->vb, 0, vbytes};
    SDL_UploadToGPUBuffer(s->copy, &from, &to, false);
    from.offset = vbytes;
    to.buffer = c->ib;
    to.size = ibytes;
    SDL_UploadToGPUBuffer(s->copy, &from, &to, false);
    SDL_ReleaseGPUTransferBuffer(s->device, tb);
    return c;
}

/* Frees a chunk's buffers. Needs only the device, so a MapMesh can drop its chunks without the
 * scene; the device must still be alive (SDL defers the release until the GPU is done with it). */
void shiro_chunk_free(SceneChunk *c) {
    if (c == NULL)
        return;
    SDL_ReleaseGPUBuffer(c->dev, c->vb);
    SDL_ReleaseGPUBuffer(c->dev, c->ib);
    free(c);
}

/* SDL's GPU renderer records texture uploads into one open command buffer that it submits only at
 * present, so a texture it created is empty on the GPU until then, and our own command buffer
 * (submitted earlier) would sample garbage. The first time we meet a texture, force that submit
 * with a 1x1 readback (it waits for the GPU, once per texture, at load time). */
static void sync_texture(ShiroScene *s, SDL_GPUTexture *t) {
    for (int i = 0; i < s->num_synced; i++)
        if (s->synced[i] == t)
            return;
    SDL_Rect px = {0, 0, 1, 1};
    SDL_Surface *surf = SDL_RenderReadPixels(s->renderer, &px);
    if (surf != NULL)
        SDL_DestroySurface(surf);
    if (s->num_synced < (int)(sizeof s->synced / sizeof s->synced[0]))
        s->synced[s->num_synced++] = t;
}

/* Starts the frame's render pass into `target` (a SDL_TEXTUREACCESS_TARGET RGBA32 texture of the
 * GPU renderer), cleared to (r, g, b). `xf` maps world units to clip space (see scene.vert). */
bool shiro_scene_begin(ShiroScene *s, SDL_Texture *target, float r, float g, float b, const float *xf) {
    SDL_PropertiesID props = SDL_GetTextureProperties(target);
    SDL_GPUTexture *tex = (SDL_GPUTexture *)SDL_GetPointerProperty(props, SDL_PROP_TEXTURE_GPU_TEXTURE_POINTER, NULL);
    if (tex == NULL)
        return false;
    if (s->cmd == NULL) {
        s->cmd = SDL_AcquireGPUCommandBuffer(s->device);
        if (s->cmd == NULL)
            return false;
    }
    if (s->copy != NULL) {
        SDL_EndGPUCopyPass(s->copy);
        s->copy = NULL;
    }
    SDL_GPUColorTargetInfo ct;
    SDL_zero(ct);
    ct.texture = tex;
    ct.clear_color.r = r;
    ct.clear_color.g = g;
    ct.clear_color.b = b;
    ct.clear_color.a = 1.0f;
    ct.load_op = SDL_GPU_LOADOP_CLEAR;
    ct.store_op = SDL_GPU_STOREOP_STORE;
    s->pass = SDL_BeginGPURenderPass(s->cmd, &ct, 1, NULL);
    if (s->pass == NULL)
        return false;
    SDL_BindGPUGraphicsPipeline(s->pass, s->pipeline);
    SDL_memcpy(s->xform, xf, sizeof s->xform);
    return true;
}

/* Draws one layer of a chunk. `layer` 0 is the tiles, 1 the sparkle overlay. `texture` is an
 * SDL_Texture of the renderer (NULL = untextured); `wrap` selects repeat addressing; `du` shifts
 * u, `wave` is the foam phase (NaN = no foam pulse). */
void shiro_scene_draw(ShiroScene *s, const SceneChunk *c, int layer, Uint32 nv_first, Uint32 ni_first,
                      Uint32 num_indices, SDL_Texture *texture, bool wrap, float du, float wave) {
    if (s->pass == NULL || c == NULL || num_indices == 0)
        return;
    SDL_GPUTexture *tex = s->white;
    if (texture != NULL) {
        SDL_PropertiesID props = SDL_GetTextureProperties(texture);
        SDL_GPUTexture *t = (SDL_GPUTexture *)SDL_GetPointerProperty(props, SDL_PROP_TEXTURE_GPU_TEXTURE_POINTER, NULL);
        if (t != NULL) {
            sync_texture(s, t);
            tex = t;
        }
    }
    SDL_GPUTextureSamplerBinding tsb = {tex, wrap ? s->wrap : s->clamp};
    SDL_BindGPUFragmentSamplers(s->pass, 0, &tsb, 1);
    float params[8] = {s->xform[0], s->xform[1], s->xform[2], s->xform[3], du, 0.0f, 0.0f, 0.0f};
    if (wave == wave) {
        params[5] = wave;
        params[6] = 1.0f;
    }
    SDL_PushGPUVertexUniformData(s->cmd, 0, params, sizeof params);
    SDL_GPUBufferBinding vb = {c->vb, 0}, ib = {c->ib, 0};
    SDL_BindGPUVertexBuffers(s->pass, 0, &vb, 1);
    SDL_BindGPUIndexBuffer(s->pass, &ib, SDL_GPU_INDEXELEMENTSIZE_32BIT);
    (void)layer;
    SDL_DrawGPUIndexedPrimitives(s->pass, num_indices, 1, ni_first, (Sint32)nv_first, 0);
}

void shiro_scene_end(ShiroScene *s) {
    if (s->pass != NULL) {
        SDL_EndGPURenderPass(s->pass);
        s->pass = NULL;
    }
    if (s->copy != NULL) {
        SDL_EndGPUCopyPass(s->copy);
        s->copy = NULL;
    }
    if (s->cmd != NULL) {
        SDL_SubmitGPUCommandBuffer(s->cmd);
        s->cmd = NULL;
    }
}
