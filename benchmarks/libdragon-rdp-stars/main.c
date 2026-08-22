/** Matched counterpart to src/benchmarks/rdp_stars.zig. */
#include <libdragon.h>
#include <math.h>
#include <stdint.h>

enum { WIDTH = 320, HEIGHT = 240, WARMUPS = 2, SAMPLES = 8 };
static const int STAR_COUNTS[] = {32, 64, 128};
static const color_t COLORS[] = {
    RGBA32(255, 0, 0, 255), RGBA32(0, 0, 255, 255),
    RGBA32(0, 255, 0, 255), RGBA32(0, 255, 255, 255),
    RGBA32(255, 0, 255, 255), RGBA32(255, 255, 0, 255),
};
static surface_t framebuffer, texture;

typedef struct { uint64_t submit, total; } timing_t;

static void init_texture(void)
{
    texture = surface_alloc(FMT_RGBA32, 32, 32);
    for (int y = 0; y < 32; y++) for (int x = 0; x < 32; x++) {
        float xf = x / 32.0f - 0.5f, yf = y / 32.0f - 0.5f;
        float yp = sqrtf(xf*xf + yf*yf);
        float dist = fmaxf(0.0f, 1.0f - yp);
        float xp = atan2f(xf, yf);
        xf = xp + yp * 2.0f; yf = yp;
        float t = (cosf(xf * (float)M_PI * 1.93f) * 0.1f - yf + 0.4f) / 0.1f;
        t = fminf(1.0f, fmaxf(0.0f, t));
        uint8_t d = dist * 255.0f, a = t*t*(3.0f-2.0f*t) * 255.0f;
        ((color_t *)(texture.buffer + y * texture.stride))[x] = RGBA32(d, d, d, a);
    }
}

static inline void draw_star(void)
{
    const float s = sinf(0.25f), c = cosf(0.25f);
    const float m20 = 160.0f - 16.0f*c - 16.0f*s;
    const float m21 = 120.0f + 16.0f*s - 16.0f*c;
    float v0[] = {m20,             m21,              0,  0, 1};
    float v1[] = {32*c+m20,        -32*s+m21,       32,  0, 1};
    float v2[] = {32*c+32*s+m20,   -32*s+32*c+m21, 32, 32, 1};
    float v3[] = {32*s+m20,        32*c+m21,         0, 32, 1};
    rdpq_triangle(&TRIFMT_TEX, v0, v1, v2);
    rdpq_triangle(&TRIFMT_TEX, v0, v2, v3);
}

static timing_t render(int count)
{
    uint64_t start = get_ticks();
    rdpq_attach(&framebuffer, NULL);
    rdpq_clear(RGBA32(0x40, 0x40, 0x40, 0xFF));
    rdpq_set_mode_standard();
    rdpq_mode_combiner(RDPQ_COMBINER_TEX_FLAT);
    rdpq_mode_blender(RDPQ_BLENDER_MULTIPLY);
    rdpq_tex_upload(TILE0, &texture, NULL);
    for (int i = 0; i < count; i++) {
        rdpq_set_prim_color(COLORS[i % 6]);
        draw_star();
    }
    rdpq_detach();
    uint64_t submitted = get_ticks();
    rspq_wait();
    uint64_t completed = get_ticks();
    return (timing_t){submitted-start, completed-start};
}

static void measure(int count)
{
    for (int i = 0; i < WARMUPS; i++) render(count);
    uint64_t submit = 0, total = 0;
    for (int i = 0; i < SAMPLES; i++) {
        timing_t t = render(count); submit += t.submit; total += t.total;
    }
    debugf("@@RDP_STARS_BENCH@@ impl=libdragon stars=%d warmup=%d samples=%d submit_ticks=%llu total_ticks=%llu\n",
        count, WARMUPS, SAMPLES, submit/SAMPLES, total/SAMPLES);
}

int main(void)
{
    debug_init_usblog();
    display_init(RESOLUTION_320x240, DEPTH_16_BPP, 2, GAMMA_NONE, FILTERS_RESAMPLE);
    rdpq_init();
    framebuffer = surface_alloc(FMT_RGBA16, WIDTH, HEIGHT);
    init_texture();
    debugf("RDP stars benchmark: libdragon rdpq, warmup=%d, samples=%d\n", WARMUPS, SAMPLES);
    for (unsigned i = 0; i < sizeof(STAR_COUNTS)/sizeof(*STAR_COUNTS); i++) measure(STAR_COUNTS[i]);
    debugf("@@RDP_STARS_BENCH_END@@\n");
    while (1) {}
}
