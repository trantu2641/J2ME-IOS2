//
// j2me_render.m
// Core Graphics rendering bridge for J2ME LCDUI.
//
// Optimizations:
// - Unlimited FPS when the FPS setting is 0.
// - Cache immutable JAR images instead of snapshotting them on every draw.
// - Skip framebuffer snapshots while the UI already has a frame waiting.
//

#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreHaptics/CoreHaptics.h>
#import <mach/mach_time.h>

#include "j2me_render.h"
#include "jvm.h"
#include "jvm_util.h"

#include <stdio.h>
#include <stdatomic.h>
#include <stdint.h>

// ============================================================
// Internal structures
// ============================================================

typedef struct RenderContext {
    CGContextRef ctx;
    int width;
    int height;
    CTFontRef font;
    float fontSize;
    int fontStyle;
    int clipSaved;
    int ownsPixels;
    _Atomic int32_t refcount;
    struct RenderContext *next_dead;
} RenderContext;

typedef struct RenderImage {
    CGContextRef ctx;
    CGImageRef cachedImage;
    int width;
    int height;
    int isMutable;
    _Atomic int32_t refcount;
    struct RenderImage *next_dead;
} RenderImage;

static j2me_flush_callback g_flush_callback = NULL;
static MiniJVM *g_active_render_jvm = NULL;
static j2me_flush_ready_callback g_flush_ready_callback = NULL;
static CGColorSpaceRef g_colorSpace = NULL;

// FPS limiter applies before creating a framebuffer snapshot.
// A zero interval means unlimited frame export.
static _Atomic uint64_t g_frame_interval_ticks = 0;
static _Atomic uint64_t g_last_frame_ticks = 0;

// Set by jvm_bridge before native cleanup. All acquire functions
// check this and return NULL, so zombie threads can't touch freed resources.
static volatile int g_render_stopped = 0;

// Global tracking arrays for forced cleanup between game sessions.
// Protected by g_track_lock. Entries are added on create, removed on release.
#define TRACK_MAX 8192

static RenderContext *g_live_rc[TRACK_MAX];
static int g_live_rc_count = 0;

static RenderImage *g_live_img[TRACK_MAX];
static int g_live_img_count = 0;

static spinlock_t g_track_lock = {0, 0, 0};

static void track_rc(RenderContext *rc) {
    spin_lock(&g_track_lock);

    if (g_live_rc_count < TRACK_MAX) {
        g_live_rc[g_live_rc_count++] = rc;
    }

    spin_unlock(&g_track_lock);
}

static void untrack_rc(RenderContext *rc) {
    spin_lock(&g_track_lock);

    for (int i = 0; i < g_live_rc_count; i++) {
        if (g_live_rc[i] == rc) {
            g_live_rc[i] = g_live_rc[--g_live_rc_count];
            break;
        }
    }

    spin_unlock(&g_track_lock);
}

static void track_img(RenderImage *img) {
    spin_lock(&g_track_lock);

    if (g_live_img_count < TRACK_MAX) {
        g_live_img[g_live_img_count++] = img;
    }

    spin_unlock(&g_track_lock);
}

static void untrack_img(RenderImage *img) {
    spin_lock(&g_track_lock);

    for (int i = 0; i < g_live_img_count; i++) {
        if (g_live_img[i] == img) {
            g_live_img[i] = g_live_img[--g_live_img_count];
            break;
        }
    }

    spin_unlock(&g_track_lock);
}

// ============================================================
// Native memory counter — visible to MiniJVM GC via gc_sum_heap()
// ============================================================

extern s64 g_native_extra_heap;

static inline void native_heap_add(s32 bytes) {
    __atomic_fetch_add(
        &g_native_extra_heap,
        (s64)bytes,
        __ATOMIC_RELAXED
    );
}

static inline void native_heap_sub(s32 bytes) {
    __atomic_fetch_sub(
        &g_native_extra_heap,
        (s64)bytes,
        __ATOMIC_RELAXED
    );
}

// ============================================================
// Dead shell reclamation
// ============================================================

static _Atomic(RenderContext *) g_dead_rc_gen0 = NULL;
static RenderContext *g_dead_rc_gen1 = NULL;

static _Atomic(RenderImage *) g_dead_img_gen0 = NULL;
static RenderImage *g_dead_img_gen1 = NULL;

static void enqueue_dead_rc(RenderContext *rc) {
    RenderContext *old;

    do {
        old = atomic_load_explicit(
            &g_dead_rc_gen0,
            memory_order_relaxed
        );

        rc->next_dead = old;

    } while (!atomic_compare_exchange_weak_explicit(
        &g_dead_rc_gen0,
        &old,
        rc,
        memory_order_release,
        memory_order_relaxed
    ));
}

static void enqueue_dead_img(RenderImage *img) {
    RenderImage *old;

    do {
        old = atomic_load_explicit(
            &g_dead_img_gen0,
            memory_order_relaxed
        );

        img->next_dead = old;

    } while (!atomic_compare_exchange_weak_explicit(
        &g_dead_img_gen0,
        &old,
        img,
        memory_order_release,
        memory_order_relaxed
    ));
}

static void process_dead_shells(void) {

    RenderContext *rc = g_dead_rc_gen1;

    while (rc) {
        RenderContext *next = rc->next_dead;
        free(rc);
        rc = next;
    }

    RenderImage *img = g_dead_img_gen1;

    while (img) {
        RenderImage *next = img->next_dead;
        free(img);
        img = next;
    }

    g_dead_rc_gen1 = atomic_exchange_explicit(
        &g_dead_rc_gen0,
        NULL,
        memory_order_acquire
    );

    g_dead_img_gen1 = atomic_exchange_explicit(
        &g_dead_img_gen0,
        NULL,
        memory_order_acquire
    );
}

// ============================================================
// Reference counting
// ============================================================

static inline RenderContext *rc_acquire(s64 handle) {

    if (g_render_stopped || handle == 0) {
        return NULL;
    }

    RenderContext *rc = (RenderContext *)(intptr_t)handle;

    int32_t old = atomic_load_explicit(
        &rc->refcount,
        memory_order_relaxed
    );

    do {
        if (old <= 0) {
            return NULL;
        }

    } while (!atomic_compare_exchange_weak_explicit(
        &rc->refcount,
        &old,
        old + 1,
        memory_order_acquire,
        memory_order_relaxed
    ));

    return rc;
}

static inline void rc_release(RenderContext *rc) {

    if (!rc) {
        return;
    }

    if (atomic_fetch_sub_explicit(
        &rc->refcount,
        1,
        memory_order_release
    ) == 1) {

        atomic_thread_fence(memory_order_acquire);

        untrack_rc(rc);

        int pixels = rc->ownsPixels
            ? rc->width * rc->height * 4
            : 0;

        CGContextRef ctx = rc->ctx;

        CTFontRef font = __atomic_exchange_n(
            &rc->font,
            NULL,
            __ATOMIC_ACQ_REL
        );

        rc->ctx = NULL;
        rc->ownsPixels = 0;

        if (ctx) {
            CGContextRelease(ctx);
        }

        if (font) {
            CFRelease(font);
        }

        if (pixels > 0) {
            native_heap_sub(pixels);
        }

        enqueue_dead_rc(rc);
    }
}

static inline RenderImage *img_acquire(s64 handle) {

    if (g_render_stopped || handle == 0) {
        return NULL;
    }

    RenderImage *img = (RenderImage *)(intptr_t)handle;

    int32_t old = atomic_load_explicit(
        &img->refcount,
        memory_order_relaxed
    );

    do {
        if (old <= 0) {
            return NULL;
        }

    } while (!atomic_compare_exchange_weak_explicit(
        &img->refcount,
        &old,
        old + 1,
        memory_order_acquire,
        memory_order_relaxed
    ));

    return img;
}

static inline void img_release(RenderImage *img) {

    if (!img) {
        return;
    }

    if (atomic_fetch_sub_explicit(
        &img->refcount,
        1,
        memory_order_release
    ) == 1) {

        atomic_thread_fence(memory_order_acquire);

        untrack_img(img);

        int pixels = img->width * img->height * 4;

        CGContextRef ctx = img->ctx;
        CGImageRef cachedImage = img->cachedImage;

        img->ctx = NULL;
        img->cachedImage = NULL;

        if (cachedImage) {
            CGImageRelease(cachedImage);
        }

        if (ctx) {
            CGContextRelease(ctx);
        }

        if (pixels > 0) {
            native_heap_sub(pixels);
        }

        enqueue_dead_img(img);
    }
}

// ============================================================
// Color space
// ============================================================

static CGColorSpaceRef getColorSpace(void) {

    if (!g_colorSpace) {
        g_colorSpace = CGColorSpaceCreateDeviceRGB();
    }

    return g_colorSpace;
}

// ============================================================
// Frame rate limiter
// ============================================================

void j2me_render_set_active_jvm(MiniJVM *jvm) {
    g_active_render_jvm = jvm;
}

void j2me_render_set_flush_callback(
    j2me_flush_callback callback
) {
    g_flush_callback = callback;
}

void j2me_render_set_flush_ready_callback(
    j2me_flush_ready_callback callback
) {
    g_flush_ready_callback = callback;
}

void j2me_render_set_fps_limit(int fps) {

    // Zero or a negative value means unlimited.
    if (fps <= 0) {

        atomic_store_explicit(
            &g_frame_interval_ticks,
            0,
            memory_order_relaxed
        );

        atomic_store_explicit(
            &g_last_frame_ticks,
            0,
            memory_order_relaxed
        );

        return;
    }

    if (fps > 45) {
        fps = 45;
    }

    mach_timebase_info_data_t timebase = {0, 0};

    if (mach_timebase_info(&timebase) != KERN_SUCCESS ||
        timebase.numer == 0 ||
        timebase.denom == 0) {

        atomic_store_explicit(
            &g_frame_interval_ticks,
            0,
            memory_order_relaxed
        );

        atomic_store_explicit(
            &g_last_frame_ticks,
            0,
            memory_order_relaxed
        );

        return;
    }

    uint64_t ticks_per_second =
        (1000000000ULL * (uint64_t)timebase.denom) /
        (uint64_t)timebase.numer;

    uint64_t interval =
        ticks_per_second / (uint64_t)fps;

    if (interval == 0) {
        interval = 1;
    }

    atomic_store_explicit(
        &g_frame_interval_ticks,
        interval,
        memory_order_relaxed
    );

    atomic_store_explicit(
        &g_last_frame_ticks,
        0,
        memory_order_relaxed
    );
}

/// Returns 1 when a new frame may be exported.
/// Returns 0 when the frame interval has not elapsed.
static int j2me_render_frame_due(void) {

    uint64_t interval = atomic_load_explicit(
        &g_frame_interval_ticks,
        memory_order_relaxed
    );

    // A zero interval means unlimited.
    if (interval == 0) {
        return 1;
    }

    uint64_t now = mach_absolute_time();

    uint64_t last = atomic_load_explicit(
        &g_last_frame_ticks,
        memory_order_relaxed
    );

    for (;;) {

        if (last != 0 && now - last < interval) {
            return 0;
        }

        if (atomic_compare_exchange_weak_explicit(
            &g_last_frame_ticks,
            &last,
            now,
            memory_order_relaxed,
            memory_order_relaxed
        )) {
            return 1;
        }
    }
}

// ============================================================
// Helper
// ============================================================

static inline void setColorFromARGB(
    CGContextRef ctx,
    int argb
) {

    CGFloat a = ((argb >> 24) & 0xFF) / 255.0;
    CGFloat r = ((argb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((argb >> 8) & 0xFF) / 255.0;
    CGFloat b = (argb & 0xFF) / 255.0;

    CGContextSetRGBFillColor(ctx, r, g, b, a);
    CGContextSetRGBStrokeColor(ctx, r, g, b, a);
}

// ============================================================
// Context management
// ============================================================

static RenderContext *createRenderContext(
    int width,
    int height
) {

    RenderContext *rc = (RenderContext *)calloc(
        1,
        sizeof(RenderContext)
    );

    if (!rc) {
        return NULL;
    }

    atomic_init(&rc->refcount, 1);

    rc->width = width;
    rc->height = height;

    CGColorSpaceRef cs = getColorSpace();

    rc->ctx = CGBitmapContextCreate(
        NULL,
        width,
        height,
        8,
        width * 4,
        cs,
        kCGImageAlphaPremultipliedFirst |
        kCGBitmapByteOrder32Little
    );

    if (!rc->ctx) {
        free(rc);
        return NULL;
    }

    CGContextTranslateCTM(rc->ctx, 0, height);
    CGContextScaleCTM(rc->ctx, 1.0, -1.0);

    CGContextSetLineWidth(rc->ctx, 1.0);
    CGContextSetLineCap(rc->ctx, kCGLineCapSquare);
    CGContextSetLineJoin(rc->ctx, kCGLineJoinMiter);

    rc->fontSize = 14.0;
    rc->fontStyle = 0;
    rc->font = CTFontCreateWithName(
        CFSTR("Helvetica"),
        rc->fontSize,
        NULL
    );

    rc->ownsPixels = 1;

    track_rc(rc);
    native_heap_add(width * height * 4);

    return rc;
}

static void destroyRenderContext(RenderContext *rc) {
    if (!rc) return;
    rc_release(rc);
}

// ============================================================
// Image management
// ============================================================

static RenderImage *createMutableImage(
    int width,
    int height
) {

    RenderImage *img = (RenderImage *)calloc(
        1,
        sizeof(RenderImage)
    );

    if (!img) {
        return NULL;
    }

    atomic_init(&img->refcount, 1);

    img->width = width;
    img->height = height;
    img->isMutable = 1;

    CGColorSpaceRef cs = getColorSpace();

    img->ctx = CGBitmapContextCreate(
        NULL,
        width,
        height,
        8,
        width * 4,
        cs,
        kCGImageAlphaPremultipliedFirst |
        kCGBitmapByteOrder32Little
    );

    if (!img->ctx) {
        free(img);
        return NULL;
    }

    CGContextClearRect(
        img->ctx,
        CGRectMake(0, 0, width, height)
    );

    CGContextTranslateCTM(img->ctx, 0, height);
    CGContextScaleCTM(img->ctx, 1.0, -1.0);

    track_img(img);
    native_heap_add(width * height * 4);

    return img;
}

static RenderImage *createImageFromData(
    const uint8_t *data,
    int length
) {

    RenderImage *img = (RenderImage *)calloc(
        1,
        sizeof(RenderImage)
    );

    if (!img) {
        return NULL;
    }

    atomic_init(&img->refcount, 1);
    img->isMutable = 0;

    CFDataRef cfData = CFDataCreate(
        NULL,
        data,
        length
    );

    if (!cfData) {
        free(img);
        return NULL;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData(
        cfData,
        NULL
    );

    CFRelease(cfData);

    CGImageRef cgImage = NULL;

    if (source) {
        cgImage = CGImageSourceCreateImageAtIndex(
            source,
            0,
            NULL
        );

        CFRelease(source);
    }

    if (!cgImage) {
        free(img);
        return NULL;
    }

    img->width = (int)CGImageGetWidth(cgImage);
    img->height = (int)CGImageGetHeight(cgImage);

    CGColorSpaceRef cs = getColorSpace();

    img->ctx = CGBitmapContextCreate(
        NULL,
        img->width,
        img->height,
        8,
        img->width * 4,
        cs,
        kCGImageAlphaPremultipliedFirst |
        kCGBitmapByteOrder32Little
    );

    if (!img->ctx) {
        CGImageRelease(cgImage);
        free(img);
        return NULL;
    }

    CGContextClearRect(
        img->ctx,
        CGRectMake(0, 0, img->width, img->height)
    );

    CGContextDrawImage(
        img->ctx,
        CGRectMake(0, 0, img->width, img->height),
        cgImage
    );

    CGImageRelease(cgImage);

    // Immutable JAR image data never changes after loading.
    // Keep one CGImage snapshot and reuse it for drawImage/drawRegion.
    img->cachedImage = CGBitmapContextCreateImage(img->ctx);

    track_img(img);
    native_heap_add(img->width * img->height * 4);

    return img;
}

/// Returns a cached image for immutable assets.
/// Mutable images still get a fresh snapshot so updates remain visible.
/// Set releaseAfterUse when the returned image is owned by the caller.
static CGImageRef drawingImageFor(
    RenderImage *img,
    int *releaseAfterUse
) {

    if (releaseAfterUse) {
        *releaseAfterUse = 0;
    }

    if (!img) {
        return NULL;
    }

    if (!img->isMutable && img->cachedImage) {
        return img->cachedImage;
    }

    if (!img->ctx) {
        return NULL;
    }

    CGImageRef image = CGBitmapContextCreateImage(img->ctx);

    if (image && releaseAfterUse) {
        *releaseAfterUse = 1;
    }

    return image;
}

static void destroyImage(RenderImage *img) {
    if (!img) return;
    img_release(img);
}

// ============================================================
// Native method implementations
// ============================================================

static s32 n_createContext(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s32 w = env->localvar_getInt(runtime->localvar, 0);
    s32 h = env->localvar_getInt(runtime->localvar, 1);

    RenderContext *rc = createRenderContext(w, h);

    env->push_long(
        runtime->stack,
        (s64)(intptr_t)rc
    );

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_destroyContext(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    if (g_render_stopped || handle == 0) {
        return RUNTIME_STATUS_NORMAL;
    }

    destroyRenderContext(
        (RenderContext *)(intptr_t)handle
    );

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Native framebuffer flush
// ============================================================

static s32 n_flushToScreen(
    Runtime *runtime,
    JClass *clazz
) {

    process_dead_shells();

    // Only the currently selected JAR is presented to UIKit.
    // Other JARs continue executing their own VM threads and render contexts.
    if (g_active_render_jvm && runtime->jvm != g_active_render_jvm) {
        return RUNTIME_STATUS_NORMAL;
    }

    // First skip frames blocked by the FPS limiter.
    if (!g_flush_callback || !j2me_render_frame_due()) {
        return RUNTIME_STATUS_NORMAL;
    }

    // Do not create a costly framebuffer snapshot when Swift
    // already has a frame waiting for the next display refresh.
    if (g_flush_ready_callback &&
        !g_flush_ready_callback()) {

        return RUNTIME_STATUS_NORMAL;
    }

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    RenderContext *rc = rc_acquire(handle);

    if (rc) {

        CGImageRef image = CGBitmapContextCreateImage(
            rc->ctx
        );

        if (image) {
            // Ownership transfers to Swift flushCallback.
            g_flush_callback(
                image,
                rc->width,
                rc->height
            );
        }
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Color and state
// ============================================================

static s32 n_setColor(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 argb = env->localvar_getInt(
        runtime->localvar,
        2
    );

    RenderContext *rc = rc_acquire(handle);

    if (rc) {
        setColorFromARGB(rc->ctx, argb);
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setClip(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);

    RenderContext *rc = rc_acquire(handle);

    if (rc) {

        if (rc->clipSaved) {
            CGContextRestoreGState(rc->ctx);
        }

        CGContextSaveGState(rc->ctx);
        rc->clipSaved = 1;

        CGContextClipToRect(
            rc->ctx,
            CGRectMake(x, y, w, h)
        );
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setStrokeStyle(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 style = env->localvar_getInt(
        runtime->localvar,
        2
    );

    RenderContext *rc = rc_acquire(handle);

    if (rc) {

        if (style == 1) {

            CGFloat dash[] = {2.0, 2.0};

            CGContextSetLineDash(
                rc->ctx,
                0,
                dash,
                2
            );

        } else {

            CGContextSetLineDash(
                rc->ctx,
                0,
                NULL,
                0
            );
        }
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Drawing
// ============================================================

static s32 n_drawLine(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 x1 = env->localvar_getInt(runtime->localvar, 2);
    s32 y1 = env->localvar_getInt(runtime->localvar, 3);
    s32 x2 = env->localvar_getInt(runtime->localvar, 4);
    s32 y2 = env->localvar_getInt(runtime->localvar, 5);

    RenderContext *rc = rc_acquire(handle);

    if (rc) {
        CGContextBeginPath(rc->ctx);
        CGContextMoveToPoint(rc->ctx, x1 + 0.5, y1 + 0.5);
        CGContextAddLineToPoint(rc->ctx, x2 + 0.5, y2 + 0.5);
        CGContextStrokePath(rc->ctx);
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillRect(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);

    RenderContext *rc = rc_acquire(handle);

    if (rc) {
        CGContextFillRect(
            rc->ctx,
            CGRectMake(x, y, w, h)
        );
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawRect(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);

    RenderContext *rc = rc_acquire(handle);

    if (rc) {
        CGContextStrokeRect(
            rc->ctx,
            CGRectMake(x + 0.5, y + 0.5, w, h)
        );
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillArc(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 startAngle = env->localvar_getInt(runtime->localvar, 6);
    s32 arcAngle = env->localvar_getInt(runtime->localvar, 7);

    RenderContext *rc = rc_acquire(handle);

    if (rc) {

        CGFloat cx = x + w / 2.0;
        CGFloat cy = y + h / 2.0;
        CGFloat rx = w / 2.0;
        CGFloat ry = h / 2.0;

        CGContextSaveGState(rc->ctx);
        CGContextTranslateCTM(rc->ctx, cx, cy);
        CGContextScaleCTM(rc->ctx, 1.0, ry / rx);

        CGContextBeginPath(rc->ctx);
        CGContextMoveToPoint(rc->ctx, 0, 0);

        CGFloat sa = -startAngle * M_PI / 180.0;
        CGFloat ea = -(startAngle + arcAngle) * M_PI / 180.0;

        CGContextAddArc(
            rc->ctx,
            0,
            0,
            rx,
            sa,
            ea,
            arcAngle > 0 ? 1 : 0
        );

        CGContextClosePath(rc->ctx);
        CGContextFillPath(rc->ctx);
        CGContextRestoreGState(rc->ctx);
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawArc(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 startAngle = env->localvar_getInt(runtime->localvar, 6);
    s32 arcAngle = env->localvar_getInt(runtime->localvar, 7);

    RenderContext *rc = rc_acquire(handle);

    if (rc) {

        CGFloat cx = x + w / 2.0;
        CGFloat cy = y + h / 2.0;
        CGFloat rx = w / 2.0;
        CGFloat ry = h / 2.0;

        CGContextSaveGState(rc->ctx);
        CGContextTranslateCTM(rc->ctx, cx, cy);
        CGContextScaleCTM(rc->ctx, 1.0, ry / rx);

        CGContextBeginPath(rc->ctx);

        CGFloat sa = -startAngle * M_PI / 180.0;
        CGFloat ea = -(startAngle + arcAngle) * M_PI / 180.0;

        CGContextAddArc(
            rc->ctx,
            0,
            0,
            rx,
            sa,
            ea,
            arcAngle > 0 ? 1 : 0
        );

        CGContextStrokePath(rc->ctx);
        CGContextRestoreGState(rc->ctx);
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillRoundRect(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 aw = env->localvar_getInt(runtime->localvar, 6);
    s32 ah = env->localvar_getInt(runtime->localvar, 7);

    RenderContext *rc = rc_acquire(handle);

    if (rc) {

        CGFloat radius = fmin(aw, ah) / 2.0;

        CGPathRef path = CGPathCreateWithRoundedRect(
            CGRectMake(x, y, w, h),
            radius,
            radius,
            NULL
        );

        CGContextAddPath(rc->ctx, path);
        CGContextFillPath(rc->ctx);
        CGPathRelease(path);
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawRoundRect(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 aw = env->localvar_getInt(runtime->localvar, 6);
    s32 ah = env->localvar_getInt(runtime->localvar, 7);

    RenderContext *rc = rc_acquire(handle);

    if (rc) {

        CGFloat radius = fmin(aw, ah) / 2.0;

        CGPathRef path = CGPathCreateWithRoundedRect(
            CGRectMake(x + 0.5, y + 0.5, w, h),
            radius,
            radius,
            NULL
        );

        CGContextAddPath(rc->ctx, path);
        CGContextStrokePath(rc->ctx);
        CGPathRelease(path);
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Text
// ============================================================

static s32 n_setFont(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 face = env->localvar_getInt(runtime->localvar, 2);
    s32 style = env->localvar_getInt(runtime->localvar, 3);
    s32 size = env->localvar_getInt(runtime->localvar, 4);

    RenderContext *rc = rc_acquire(handle);

    if (rc) {

        CGFloat ptSize;

        switch (size) {
            case 8:  ptSize = 10.0; break;
            case 0:  ptSize = 14.0; break;
            case 16: ptSize = 18.0; break;
            default: ptSize = 14.0; break;
        }

        CFStringRef fontName;

        if (style & 1) {

            if (style & 2) {
                fontName = CFSTR("Helvetica-BoldOblique");
            } else {
                fontName = CFSTR("Helvetica-Bold");
            }

        } else if (style & 2) {

            fontName = CFSTR("Helvetica-Oblique");

        } else {

            if (face == 32) {
                fontName = CFSTR("Courier");
            } else {
                fontName = CFSTR("Helvetica");
            }
        }

        CTFontRef newFont = CTFontCreateWithName(
            fontName,
            ptSize,
            NULL
        );

        CTFontRef oldFont = __atomic_exchange_n(
            &rc->font,
            newFont,
            __ATOMIC_ACQ_REL
        );

        rc->fontSize = ptSize;
        rc->fontStyle = style;

        if (oldFont) {
            CFRelease(oldFont);
        }
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawString(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    Instance *jstr = env->localvar_getRefer(
        runtime->localvar,
        2
    );

    s32 x = env->localvar_getInt(runtime->localvar, 3);
    s32 y = env->localvar_getInt(runtime->localvar, 4);
    s32 anchor = env->localvar_getInt(runtime->localvar, 5);

    RenderContext *rc = rc_acquire(handle);

    if (!rc || !jstr) {
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    Utf8String *ustr = utf8_create();

    env->jstring_2_utf8(
        jstr,
        ustr,
        runtime
    );

    CFStringRef str = CFStringCreateWithCString(
        NULL,
        utf8_cstr(ustr),
        kCFStringEncodingUTF8
    );

    utf8_destroy(ustr);

    if (!str) {
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
        NULL,
        3,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );

    CFDictionarySetValue(
        attrs,
        kCTFontAttributeName,
        rc->font
    );

    CFDictionarySetValue(
        attrs,
        kCTForegroundColorFromContextAttributeName,
        kCFBooleanTrue
    );

    CFAttributedStringRef attrStr =
        CFAttributedStringCreate(NULL, str, attrs);

    CTLineRef line = CTLineCreateWithAttributedString(attrStr);

    CGFloat ascent;
    CGFloat descent;
    CGFloat leading;

    double textWidth = CTLineGetTypographicBounds(
        line,
        &ascent,
        &descent,
        &leading
    );

    CGFloat textHeight = ascent + descent;

    CGFloat dx = x;
    CGFloat dy = y;

    if (anchor & 1) {
        dx -= textWidth / 2;
    }

    if (anchor & 8) {
        dx -= textWidth;
    }

    if (anchor & 4) {
        dy -= 0;
    }

    if (anchor & 32) {
        dy -= textHeight;
    }

    if (anchor == 0 || (anchor & 16)) {
        dy += 0;
    }

    CGContextSaveGState(rc->ctx);
    CGContextTranslateCTM(rc->ctx, dx, dy + ascent);
    CGContextScaleCTM(rc->ctx, 1.0, -1.0);
    CGContextSetTextPosition(rc->ctx, 0, 0);
    CTLineDraw(line, rc->ctx);
    CGContextRestoreGState(rc->ctx);

    CFRelease(line);
    CFRelease(attrStr);
    CFRelease(attrs);
    CFRelease(str);

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getStringWidth(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    Instance *jstr = env->localvar_getRefer(
        runtime->localvar,
        2
    );

    RenderContext *rc = rc_acquire(handle);

    if (!rc || !jstr) {
        rc_release(rc);
        env->push_int(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }

    Utf8String *ustr = utf8_create();

    env->jstring_2_utf8(
        jstr,
        ustr,
        runtime
    );

    CFStringRef str = CFStringCreateWithCString(
        NULL,
        utf8_cstr(ustr),
        kCFStringEncodingUTF8
    );

    utf8_destroy(ustr);

    if (!str) {
        rc_release(rc);
        env->push_int(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }

    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
        NULL,
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks
    );

    CFDictionarySetValue(
        attrs,
        kCTFontAttributeName,
        rc->font
    );

    CFAttributedStringRef attrStr =
        CFAttributedStringCreate(NULL, str, attrs);

    CTLineRef line = CTLineCreateWithAttributedString(attrStr);

    double width = CTLineGetTypographicBounds(
        line,
        NULL,
        NULL,
        NULL
    );

    CFRelease(line);
    CFRelease(attrStr);
    CFRelease(attrs);
    CFRelease(str);

    rc_release(rc);

    env->push_int(
        runtime->stack,
        (s32)ceil(width)
    );

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getFontHeight(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    RenderContext *rc = rc_acquire(handle);

    if (!rc) {
        env->push_int(runtime->stack, 14);
        return RUNTIME_STATUS_NORMAL;
    }

    CGFloat ascent = CTFontGetAscent(rc->font);
    CGFloat descent = CTFontGetDescent(rc->font);

    rc_release(rc);

    env->push_int(
        runtime->stack,
        (s32)ceil(ascent + descent)
    );

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getFontAscent(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    RenderContext *rc = rc_acquire(handle);

    if (!rc) {
        env->push_int(runtime->stack, 12);
        return RUNTIME_STATUS_NORMAL;
    }

    CGFloat ascent = CTFontGetAscent(rc->font);

    rc_release(rc);

    env->push_int(
        runtime->stack,
        (s32)ceil(ascent)
    );

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Image
// ============================================================

static s32 n_createMutableImage(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s32 w = env->localvar_getInt(runtime->localvar, 0);
    s32 h = env->localvar_getInt(runtime->localvar, 1);

    RenderImage *img = createMutableImage(w, h);

    env->push_long(
        runtime->stack,
        (s64)(intptr_t)img
    );

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_createImageFromData(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    Instance *arr = env->localvar_getRefer(
        runtime->localvar,
        0
    );

    s32 offset = env->localvar_getInt(runtime->localvar, 1);
    s32 length = env->localvar_getInt(runtime->localvar, 2);

    if (!arr) {
        env->push_long(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }

    c8 *arrBody = arr->arr_body;

    RenderImage *img = createImageFromData(
        (uint8_t *)arrBody + offset,
        length
    );

    env->push_long(
        runtime->stack,
        (s64)(intptr_t)img
    );

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_destroyImage(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    if (g_render_stopped || handle == 0) {
        return RUNTIME_STATUS_NORMAL;
    }

    destroyImage((RenderImage *)(intptr_t)handle);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageWidth(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    RenderImage *img = img_acquire(handle);

    env->push_int(
        runtime->stack,
        img ? img->width : 0
    );

    img_release(img);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageHeight(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    RenderImage *img = img_acquire(handle);

    env->push_int(
        runtime->stack,
        img ? img->height : 0
    );

    img_release(img);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageContext(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    RenderImage *img = img_acquire(handle);

    if (img && img->isMutable && img->ctx) {

        RenderContext *rc = (RenderContext *)calloc(
            1,
            sizeof(RenderContext)
        );

        if (!rc) {
            img_release(img);
            env->push_long(runtime->stack, 0);
            return RUNTIME_STATUS_NORMAL;
        }

        atomic_init(&rc->refcount, 1);

        rc->ctx = img->ctx;
        CGContextRetain(rc->ctx);

        rc->width = img->width;
        rc->height = img->height;

        rc->fontSize = 14.0;
        rc->font = CTFontCreateWithName(
            CFSTR("Helvetica"),
            14.0,
            NULL
        );

        rc->ownsPixels = 0;

        track_rc(rc);

        img_release(img);

        env->push_long(
            runtime->stack,
            (s64)(intptr_t)rc
        );

    } else {

        img_release(img);
        env->push_long(runtime->stack, 0);
    }

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawImage(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 ctxHandle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s64 imgHandle = env->localvar_getLong_2slot(
        runtime->localvar,
        2
    );

    s32 x = env->localvar_getInt(runtime->localvar, 4);
    s32 y = env->localvar_getInt(runtime->localvar, 5);
    s32 anchor = env->localvar_getInt(runtime->localvar, 6);

    RenderContext *rc = rc_acquire(ctxHandle);
    RenderImage *img = img_acquire(imgHandle);

    if (!rc || !img) {
        img_release(img);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    int imgW = img->width;
    int imgH = img->height;

    if (anchor & 1) x -= imgW / 2;
    if (anchor & 8) x -= imgW;
    if (anchor & 2) y -= imgH / 2;
    if (anchor & 32) y -= imgH;

    int releaseImage = 0;

    CGImageRef cgImage = drawingImageFor(
        img,
        &releaseImage
    );

    if (cgImage) {

        CGContextSaveGState(rc->ctx);

        CGContextTranslateCTM(
            rc->ctx,
            x,
            y + imgH
        );

        CGContextScaleCTM(rc->ctx, 1.0, -1.0);

        CGContextDrawImage(
            rc->ctx,
            CGRectMake(0, 0, imgW, imgH),
            cgImage
        );

        CGContextRestoreGState(rc->ctx);

        if (releaseImage) {
            CGImageRelease(cgImage);
        }
    }

    img_release(img);
    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// drawRegion
// ============================================================

#define TRANS_NONE           0
#define TRANS_ROT90          5
#define TRANS_ROT180         3
#define TRANS_ROT270         6
#define TRANS_MIRROR         2
#define TRANS_MIRROR_ROT90   7
#define TRANS_MIRROR_ROT180  1
#define TRANS_MIRROR_ROT270  4

static s32 n_drawRegion(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 ctxHandle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s64 imgHandle = env->localvar_getLong_2slot(
        runtime->localvar,
        2
    );

    s32 xSrc = env->localvar_getInt(runtime->localvar, 4);
    s32 ySrc = env->localvar_getInt(runtime->localvar, 5);
    s32 wSrc = env->localvar_getInt(runtime->localvar, 6);
    s32 hSrc = env->localvar_getInt(runtime->localvar, 7);
    s32 transform = env->localvar_getInt(runtime->localvar, 8);
    s32 xDst = env->localvar_getInt(runtime->localvar, 9);
    s32 yDst = env->localvar_getInt(runtime->localvar, 10);
    s32 anchor = env->localvar_getInt(runtime->localvar, 11);

    RenderContext *rc = rc_acquire(ctxHandle);
    RenderImage *img = img_acquire(imgHandle);

    if (!rc || !img) {
        img_release(img);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    CGContextRef rctx = rc->ctx;

    int outW = wSrc;
    int outH = hSrc;

    if (transform == TRANS_ROT90 ||
        transform == TRANS_ROT270 ||
        transform == TRANS_MIRROR_ROT90 ||
        transform == TRANS_MIRROR_ROT270) {

        outW = hSrc;
        outH = wSrc;
    }

    if (anchor & 1) xDst -= outW / 2;
    if (anchor & 8) xDst -= outW;
    if (anchor & 2) yDst -= outH / 2;
    if (anchor & 32) yDst -= outH;

    int releaseFullImage = 0;

    CGImageRef fullImage = drawingImageFor(
        img,
        &releaseFullImage
    );

    if (!fullImage) {
        img_release(img);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    CGImageRef subImage = CGImageCreateWithImageInRect(
        fullImage,
        CGRectMake(xSrc, ySrc, wSrc, hSrc)
    );

    if (releaseFullImage) {
        CGImageRelease(fullImage);
    }

    if (!subImage) {
        img_release(img);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    CGContextSaveGState(rctx);

    CGContextTranslateCTM(
        rctx,
        xDst,
        yDst
    );

    switch (transform) {

        case TRANS_NONE:
            CGContextTranslateCTM(rctx, 0, hSrc);
            CGContextScaleCTM(rctx, 1, -1);
            break;

        case TRANS_MIRROR_ROT180:
            break;

        case TRANS_MIRROR:
            CGContextTranslateCTM(rctx, wSrc, hSrc);
            CGContextScaleCTM(rctx, -1, -1);
            break;

        case TRANS_ROT180:
            CGContextTranslateCTM(rctx, wSrc, 0);
            CGContextScaleCTM(rctx, -1, 1);
            break;

        case TRANS_ROT90:
            CGContextRotateCTM(rctx, M_PI_2);
            CGContextScaleCTM(rctx, 1, -1);
            break;

        case TRANS_ROT270:
            CGContextTranslateCTM(rctx, hSrc, wSrc);
            CGContextRotateCTM(rctx, -M_PI_2);
            CGContextScaleCTM(rctx, 1, -1);
            break;

        case TRANS_MIRROR_ROT90:
            CGContextTranslateCTM(rctx, 0, wSrc);
            CGContextRotateCTM(rctx, -M_PI_2);
            break;

        case TRANS_MIRROR_ROT270:
            CGContextTranslateCTM(rctx, hSrc, 0);
            CGContextRotateCTM(rctx, M_PI_2);
            break;
    }

    CGContextDrawImage(
        rctx,
        CGRectMake(0, 0, wSrc, hSrc),
        subImage
    );

    CGContextRestoreGState(rctx);

    CGImageRelease(subImage);

    img_release(img);
    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// drawRGB
// ============================================================

static s32 n_drawRGB(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 ctxHandle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    Instance *arr = env->localvar_getRefer(
        runtime->localvar,
        2
    );

    s32 offset = env->localvar_getInt(runtime->localvar, 3);
    s32 scanlength = env->localvar_getInt(runtime->localvar, 4);
    s32 x = env->localvar_getInt(runtime->localvar, 5);
    s32 y = env->localvar_getInt(runtime->localvar, 6);
    s32 w = env->localvar_getInt(runtime->localvar, 7);
    s32 h = env->localvar_getInt(runtime->localvar, 8);
    s32 processAlpha = env->localvar_getInt(runtime->localvar, 9);

    RenderContext *rc = rc_acquire(ctxHandle);

    if (!rc || !arr || w <= 0 || h <= 0) {
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    s32 arrLen = arr->arr_length;
    s32 *srcData = (s32 *)arr->arr_body;

    CGColorSpaceRef cs = getColorSpace();

    CGContextRef tmpCtx = CGBitmapContextCreate(
        NULL,
        w,
        h,
        8,
        w * 4,
        cs,
        kCGImageAlphaPremultipliedFirst |
        kCGBitmapByteOrder32Little
    );

    if (!tmpCtx) {
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    uint8_t *dst = (uint8_t *)CGBitmapContextGetData(tmpCtx);

    for (int row = 0; row < h; row++) {

        for (int col = 0; col < w; col++) {

            int srcIdx = offset + row * scanlength + col;

            if (srcIdx < 0 || srcIdx >= arrLen) {
                continue;
            }

            s32 argb = srcData[srcIdx];

            int dstIdx = (row * w + col) * 4;

            uint8_t a = processAlpha
                ? ((argb >> 24) & 0xFF)
                : 0xFF;

            uint8_t r = (argb >> 16) & 0xFF;
            uint8_t g = (argb >> 8) & 0xFF;
            uint8_t b = argb & 0xFF;

            if (a < 255 && a > 0) {

                r = (uint8_t)(r * a / 255);
                g = (uint8_t)(g * a / 255);
                b = (uint8_t)(b * a / 255);

            } else if (a == 0) {

                r = 0;
                g = 0;
                b = 0;
            }

            dst[dstIdx + 0] = b;
            dst[dstIdx + 1] = g;
            dst[dstIdx + 2] = r;
            dst[dstIdx + 3] = a;
        }
    }

    CGImageRef img = CGBitmapContextCreateImage(tmpCtx);

    CGContextRelease(tmpCtx);

    if (img) {

        CGContextSaveGState(rc->ctx);

        CGContextTranslateCTM(
            rc->ctx,
            x,
            y + h
        );

        CGContextScaleCTM(rc->ctx, 1, -1);

        CGContextDrawImage(
            rc->ctx,
            CGRectMake(0, 0, w, h),
            img
        );

        CGContextRestoreGState(rc->ctx);

        CGImageRelease(img);
    }

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// getImageRGB
// ============================================================

static s32 n_getImageRGB(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 imgHandle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    Instance *arr = env->localvar_getRefer(
        runtime->localvar,
        2
    );

    s32 offset = env->localvar_getInt(runtime->localvar, 3);
    s32 scanlength = env->localvar_getInt(runtime->localvar, 4);
    s32 x = env->localvar_getInt(runtime->localvar, 5);
    s32 y = env->localvar_getInt(runtime->localvar, 6);
    s32 w = env->localvar_getInt(runtime->localvar, 7);
    s32 h = env->localvar_getInt(runtime->localvar, 8);

    RenderImage *img = img_acquire(imgHandle);

    if (!img || !arr) {
        img_release(img);
        return RUNTIME_STATUS_NORMAL;
    }

    s32 *dstData = (s32 *)arr->arr_body;

    uint8_t *srcData =
        (uint8_t *)CGBitmapContextGetData(img->ctx);

    int imgW = img->width;

    for (int row = 0; row < h; row++) {

        for (int col = 0; col < w; col++) {

            int srcIdx =
                ((y + row) * imgW + (x + col)) * 4;

            uint8_t b = srcData[srcIdx + 0];
            uint8_t g = srcData[srcIdx + 1];
            uint8_t r = srcData[srcIdx + 2];
            uint8_t a = srcData[srcIdx + 3];

            s32 argb =
                (a << 24) |
                (r << 16) |
                (g << 8) |
                b;

            dstData[offset + row * scanlength + col] = argb;
        }
    }

    img_release(img);

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// fillPolygon / drawPolygon
// ============================================================

static s32 n_fillPolygon(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    Instance *xArr = env->localvar_getRefer(
        runtime->localvar,
        2
    );

    Instance *yArr = env->localvar_getRefer(
        runtime->localvar,
        3
    );

    s32 nPoints = env->localvar_getInt(
        runtime->localvar,
        4
    );

    RenderContext *rc = rc_acquire(handle);

    if (!rc || !xArr || !yArr || nPoints < 3) {
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    s32 *xPts = (s32 *)xArr->arr_body;
    s32 *yPts = (s32 *)yArr->arr_body;

    CGContextBeginPath(rc->ctx);

    CGContextMoveToPoint(
        rc->ctx,
        xPts[0],
        yPts[0]
    );

    for (int i = 1; i < nPoints; i++) {
        CGContextAddLineToPoint(
            rc->ctx,
            xPts[i],
            yPts[i]
        );
    }

    CGContextClosePath(rc->ctx);
    CGContextFillPath(rc->ctx);

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawPolygon(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    Instance *xArr = env->localvar_getRefer(
        runtime->localvar,
        2
    );

    Instance *yArr = env->localvar_getRefer(
        runtime->localvar,
        3
    );

    s32 nPoints = env->localvar_getInt(
        runtime->localvar,
        4
    );

    RenderContext *rc = rc_acquire(handle);

    if (!rc || !xArr || !yArr || nPoints < 3) {
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    s32 *xPts = (s32 *)xArr->arr_body;
    s32 *yPts = (s32 *)yArr->arr_body;

    CGContextBeginPath(rc->ctx);

    CGContextMoveToPoint(
        rc->ctx,
        xPts[0] + 0.5,
        yPts[0] + 0.5
    );

    for (int i = 1; i < nPoints; i++) {
        CGContextAddLineToPoint(
            rc->ctx,
            xPts[i] + 0.5,
            yPts[i] + 0.5
        );
    }

    CGContextClosePath(rc->ctx);
    CGContextStrokePath(rc->ctx);

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// copyArea
// ============================================================

static s32 n_copyArea(
    Runtime *runtime,
    JClass *clazz
) {

    JniEnv *env = runtime->jnienv;

    s64 handle = env->localvar_getLong_2slot(
        runtime->localvar,
        0
    );

    s32 xSrc = env->localvar_getInt(runtime->localvar, 2);
    s32 ySrc = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 xDst = env->localvar_getInt(runtime->localvar, 6);
    s32 yDst = env->localvar_getInt(runtime->localvar, 7);

    RenderContext *rc = rc_acquire(handle);

    if (!rc || w <= 0 || h <= 0) {
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    CGImageRef fullImg = CGBitmapContextCreateImage(rc->ctx);

    if (!fullImg) {
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    CGImageRef subImg = CGImageCreateWithImageInRect(
        fullImg,
        CGRectMake(xSrc, ySrc, w, h)
    );

    CGImageRelease(fullImg);

    if (!subImg) {
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    CGContextSaveGState(rc->ctx);

    CGContextTranslateCTM(
        rc->ctx,
        xDst,
        yDst + h
    );

    CGContextScaleCTM(rc->ctx, 1, -1);

    CGContextDrawImage(
        rc->ctx,
        CGRectMake(0, 0, w, h),
        subImg
    );

    CGContextRestoreGState(rc->ctx);

    CGImageRelease(subImg);

    rc_release(rc);

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Haptics
// ============================================================

static CHHapticEngine *g_hapticEngine API_AVAILABLE(ios(13.0)) = nil;
static id<CHHapticPatternPlayer> g_hapticPlayer API_AVAILABLE(ios(13.0)) = nil;

static void ensureHapticEngine(void) API_AVAILABLE(ios(13.0)) {

    if (g_hapticEngine) {
        return;
    }

    NSError *err = nil;

    g_hapticEngine = [[CHHapticEngine alloc]
        initAndReturnError:&err];

    if (err) {

        printf(
            "[Haptics] Engine init error: %s\n",
            err.localizedDescription.UTF8String
        );

        g_hapticEngine = nil;
        return;
    }

    g_hapticEngine.resetHandler = ^{

        NSError *startErr = nil;

        [g_hapticEngine startAndReturnError:&startErr];
    };

    [g_hapticEngine startAndReturnError:&err];

    if (err) {

        printf(
            "[Haptics] Engine start error: %s\n",
            err.localizedDescription.UTF8String
        );

        g_hapticEngine = nil;
    }
}

static s32 n_vibrate(
    Runtime *runtime,
    JClass *clazz
) {

    s32 durationMs = runtime->jnienv->localvar_getInt(
        runtime->localvar,
        0
    );

    dispatch_async(dispatch_get_main_queue(), ^{

        if (@available(iOS 13.0, *)) {

            if (g_hapticPlayer) {

                NSError *err = nil;

                [g_hapticPlayer stopAtTime:0 error:&err];
                g_hapticPlayer = nil;
            }

            if (durationMs <= 0) {
                return;
            }

            ensureHapticEngine();

            if (!g_hapticEngine) {
                return;
            }

            float duration = durationMs / 1000.0f;

            CHHapticEventParameter *intensity =
                [[CHHapticEventParameter alloc]
                    initWithParameterID:CHHapticEventParameterIDHapticIntensity
                    value:0.35f];

            CHHapticEventParameter *sharpness =
                [[CHHapticEventParameter alloc]
                    initWithParameterID:CHHapticEventParameterIDHapticSharpness
                    value:0.1f];

            CHHapticEvent *event =
                [[CHHapticEvent alloc]
                    initWithEventType:CHHapticEventTypeHapticContinuous
                    parameters:@[intensity, sharpness]
                    relativeTime:0
                    duration:duration];

            NSError *err = nil;

            CHHapticPattern *pattern =
                [[CHHapticPattern alloc]
                    initWithEvents:@[event]
                    parameters:@[]
                    error:&err];

            if (err) {
                return;
            }

            g_hapticPlayer =
                [g_hapticEngine createPlayerWithPattern:pattern error:&err];

            if (err) {
                return;
            }

            [g_hapticPlayer startAtTime:0 error:&err];
        }
    });

    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Native method table
// ============================================================

#define CLS "javax/microedition/lcdui/NativeBridge"

static java_native_method j2me_render_methods[] = {

    // Context
    {CLS, "createContext",    "(II)J",                                   n_createContext},
    {CLS, "destroyContext",   "(J)V",                                    n_destroyContext},
    {CLS, "flushToScreen",    "(J)V",                                    n_flushToScreen},

    // Color & State
    {CLS, "setColor",         "(JI)V",                                   n_setColor},
    {CLS, "setClip",          "(JIIII)V",                                n_setClip},
    {CLS, "setStrokeStyle",   "(JI)V",                                   n_setStrokeStyle},

    // Drawing
    {CLS, "drawLine",         "(JIIII)V",                                n_drawLine},
    {CLS, "fillRect",         "(JIIII)V",                                n_fillRect},
    {CLS, "drawRect",         "(JIIII)V",                                n_drawRect},
    {CLS, "fillArc",          "(JIIIIII)V",                              n_fillArc},
    {CLS, "drawArc",          "(JIIIIII)V",                              n_drawArc},
    {CLS, "fillRoundRect",    "(JIIIIII)V",                              n_fillRoundRect},
    {CLS, "drawRoundRect",    "(JIIIIII)V",                              n_drawRoundRect},

    // Text
    {CLS, "setFont",          "(JIII)V",                                 n_setFont},
    {CLS, "drawString",       "(JLjava/lang/String;III)V",               n_drawString},
    {CLS, "getStringWidth",   "(JLjava/lang/String;)I",                  n_getStringWidth},
    {CLS, "getFontHeight",    "(J)I",                                    n_getFontHeight},
    {CLS, "getFontAscent",    "(J)I",                                    n_getFontAscent},

    // Image
    {CLS, "createMutableImage",  "(II)J",                                n_createMutableImage},
    {CLS, "createImageFromData", "([BII)J",                              n_createImageFromData},
    {CLS, "destroyImage",        "(J)V",                                 n_destroyImage},
    {CLS, "getImageWidth",       "(J)I",                                 n_getImageWidth},
    {CLS, "getImageHeight",      "(J)I",                                 n_getImageHeight},
    {CLS, "getImageContext",     "(J)J",                                 n_getImageContext},
    {CLS, "drawImage",           "(JJIII)V",                             n_drawImage},
    {CLS, "drawRegion",          "(JJIIIIIIII)V",                        n_drawRegion},
    {CLS, "drawRGB",             "(J[IIIIIIII)V",                        n_drawRGB},
    {CLS, "getImageRGB",         "(J[IIIIIII)V",                         n_getImageRGB},
    {CLS, "fillPolygon",         "(J[I[II)V",                            n_fillPolygon},
    {CLS, "drawPolygon",         "(J[I[II)V",                            n_drawPolygon},
    {CLS, "copyArea",            "(JIIIIII)V",                           n_copyArea},

    // Haptics
    {CLS, "vibrate",             "(I)V",                                 n_vibrate},
};

#undef CLS

void j2me_render_reg_natives(MiniJVM *jvm) {

    native_reg_lib(
        jvm,
        j2me_render_methods,
        sizeof(j2me_render_methods) / sizeof(java_native_method)
    );

    printf(
        "[J2ME Render] Registered %lu native methods\n",
        sizeof(j2me_render_methods) / sizeof(java_native_method)
    );
}

void j2me_render_stop(void) {
    g_render_stopped = 1;
}

void j2me_render_cleanup(void) {

    // g_render_stopped must already be set (via j2me_render_stop).
    // Two passes free both generations of dead shells.
    process_dead_shells();
    process_dead_shells();

    // Force-release all still-live RenderContexts.
    spin_lock(&g_track_lock);

    int rc_count = g_live_rc_count;

    for (int i = 0; i < g_live_rc_count; i++) {

        RenderContext *rc = g_live_rc[i];

        if (rc->ctx) {
            CGContextRelease(rc->ctx);
            rc->ctx = NULL;
        }

        CTFontRef font = rc->font;
        rc->font = NULL;

        if (font) {
            CFRelease(font);
        }

        free(rc);
    }

    g_live_rc_count = 0;

    // Force-release all still-live RenderImages.
    int img_count = g_live_img_count;

    for (int i = 0; i < g_live_img_count; i++) {

        RenderImage *img = g_live_img[i];

        if (img->cachedImage) {
            CGImageRelease(img->cachedImage);
            img->cachedImage = NULL;
        }

        if (img->ctx) {
            CGContextRelease(img->ctx);
            img->ctx = NULL;
        }

        free(img);
    }

    g_live_img_count = 0;

    spin_unlock(&g_track_lock);

    // Clear dead queues.
    atomic_store_explicit(
        &g_dead_rc_gen0,
        NULL,
        memory_order_relaxed
    );

    g_dead_rc_gen1 = NULL;

    atomic_store_explicit(
        &g_dead_img_gen0,
        NULL,
        memory_order_relaxed
    );

    g_dead_img_gen1 = NULL;

    // Reset native heap counter.
    __atomic_store_n(
        &g_native_extra_heap,
        0,
        __ATOMIC_RELAXED
    );

    // Reset FPS timing for the next game session.
    // The controller sets FPS to unlimited after cleanup.
    atomic_store_explicit(
        &g_frame_interval_ticks,
        0,
        memory_order_relaxed
    );

    atomic_store_explicit(
        &g_last_frame_ticks,
        0,
        memory_order_relaxed
    );

    // Clear callbacks before a new session registers its callbacks.
    g_flush_callback = NULL;
    g_flush_ready_callback = NULL;
    g_active_render_jvm = NULL;

    // Stop haptic engine.
    if (@available(iOS 13.0, *)) {

        if (g_hapticPlayer) {

            NSError *err = nil;

            [g_hapticPlayer stopAtTime:0 error:&err];
            g_hapticPlayer = nil;
        }

        if (g_hapticEngine) {

            [g_hapticEngine stopWithCompletionHandler:nil];
            g_hapticEngine = nil;
        }
    }

    g_render_stopped = 0;

    printf(
        "[J2ME Render] Cleanup: %d contexts, %d images released\n",
        rc_count,
        img_count
    );
}
