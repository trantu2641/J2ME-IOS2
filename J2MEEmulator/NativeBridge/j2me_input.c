//
// j2me_input.c — Thread-safe input event bridge between iOS and miniJVM
//
// Uses a lock-free ring buffer for single-producer (iOS main thread)
// single-consumer (JVM thread) communication.
//

#include "j2me_input.h"
#include "jvm_bridge.h"
#include "jvm.h"
#include "jvm_util.h"
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>

// ============================================================
// Ring buffer
// ============================================================

#define INPUT_QUEUE_SIZE 256
#define INPUT_QUEUE_MASK (INPUT_QUEUE_SIZE - 1)
#define INPUT_MAX_SESSIONS 16

typedef struct {
    int type;
    int x, y;
    int keyCode;
} InputEvent;

typedef struct {
    MiniJVM *jvm;
    InputEvent queue[INPUT_QUEUE_SIZE];
    atomic_int write_pos;
    atomic_int read_pos;
    int used;
} InputSessionQueue;

static InputSessionQueue g_input_sessions[INPUT_MAX_SESSIONS];
static pthread_mutex_t g_input_lock = PTHREAD_MUTEX_INITIALIZER;
static MiniJVM *g_active_input_jvm = NULL;

static InputSessionQueue *find_input_queue_locked(MiniJVM *jvm) {
    if (!jvm) return NULL;
    for (int i = 0; i < INPUT_MAX_SESSIONS; i++) {
        if (g_input_sessions[i].used && g_input_sessions[i].jvm == jvm) {
            return &g_input_sessions[i];
        }
    }
    return NULL;
}

static InputSessionQueue *ensure_input_queue(MiniJVM *jvm) {
    pthread_mutex_lock(&g_input_lock);
    InputSessionQueue *q = find_input_queue_locked(jvm);
    if (!q) {
        for (int i = 0; i < INPUT_MAX_SESSIONS; i++) {
            if (!g_input_sessions[i].used) {
                q = &g_input_sessions[i];
                memset(q, 0, sizeof(*q));
                q->jvm = jvm;
                q->used = 1;
                atomic_init(&q->write_pos, 0);
                atomic_init(&q->read_pos, 0);
                break;
            }
        }
    }
    pthread_mutex_unlock(&g_input_lock);
    return q;
}

void j2me_input_set_active_jvm(MiniJVM *jvm) {
    g_active_input_jvm = jvm;
    if (jvm) ensure_input_queue(jvm);
}

void j2me_input_remove_jvm(MiniJVM *jvm) {
    pthread_mutex_lock(&g_input_lock);
    InputSessionQueue *q = find_input_queue_locked(jvm);
    if (q) memset(q, 0, sizeof(*q));
    if (g_active_input_jvm == jvm) g_active_input_jvm = NULL;
    pthread_mutex_unlock(&g_input_lock);
}

static void enqueue_event_for(MiniJVM *jvm, int type, int x, int y, int keyCode) {
    InputSessionQueue *q = ensure_input_queue(jvm);
    if (!q) return;

    int wp = atomic_load_explicit(&q->write_pos, memory_order_relaxed);
    int next_wp = (wp + 1) & INPUT_QUEUE_MASK;
    int rp = atomic_load_explicit(&q->read_pos, memory_order_acquire);
    if (next_wp == rp) return;

    q->queue[wp].type = type;
    q->queue[wp].x = x;
    q->queue[wp].y = y;
    q->queue[wp].keyCode = keyCode;
    atomic_store_explicit(&q->write_pos, next_wp, memory_order_release);
}

static int dequeue_event_for(MiniJVM *jvm, InputEvent *out) {
    InputSessionQueue *q = ensure_input_queue(jvm);
    if (!q) return 0;

    int rp = atomic_load_explicit(&q->read_pos, memory_order_relaxed);
    int wp = atomic_load_explicit(&q->write_pos, memory_order_acquire);
    if (rp == wp) return 0;

    *out = q->queue[rp];
    atomic_store_explicit(&q->read_pos, (rp + 1) & INPUT_QUEUE_MASK, memory_order_release);
    return 1;
}

void j2me_input_set_canvas_size(int width, int height) {
    (void)width;
    (void)height;
}

void j2me_input_post_touch(int type, int x, int y) {
    enqueue_event_for(g_active_input_jvm, type, x, y, 0);
}

void j2me_input_post_key(int type, int keyCode) {
    enqueue_event_for(g_active_input_jvm, type, 0, 0, keyCode);
}

void j2me_input_reset(void) {
    pthread_mutex_lock(&g_input_lock);
    for (int i = 0; i < INPUT_MAX_SESSIONS; i++) {
        if (g_input_sessions[i].used) {
            atomic_store_explicit(&g_input_sessions[i].write_pos, 0, memory_order_relaxed);
            atomic_store_explicit(&g_input_sessions[i].read_pos, 0, memory_order_relaxed);
        }
    }
    pthread_mutex_unlock(&g_input_lock);
    printf("[J2ME Input] All session queues reset\n");
}

// ============================================================
// Native method: NativeBridge.pollInputEvent() → int[] or null
// Returns int[4]: {type, x, y, keyCode}
// ============================================================

static s32 n_pollInputEvent(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    InputEvent evt;

    if (!dequeue_event_for(runtime->jvm, &evt)) {
        env->push_ref(runtime->stack, NULL);
        return RUNTIME_STATUS_NORMAL;
    }

    // Create int[4] array
    Utf8String *type_name = utf8_create_c("[I");
    Instance *arr = jarray_create_by_type_index(runtime, 4, DATATYPE_INT);
    if (!arr) {
        utf8_destroy(type_name);
        env->push_ref(runtime->stack, NULL);
        return RUNTIME_STATUS_NORMAL;
    }
    utf8_destroy(type_name);

    // Fill array
    s32 *body = (s32 *)arr->arr_body;
    body[0] = evt.type;
    body[1] = evt.x;
    body[2] = evt.y;
    body[3] = evt.keyCode;

    env->push_ref(runtime->stack, arr);
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Native method: NativeBridge.isStopRequested() → boolean
// ============================================================

static s32 n_isStopRequested(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, jvm_bridge_is_stop_requested_for_vm(runtime->jvm) ? 1 : 0);
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Reset (call between game sessions)
// ============================================================

void j2me_input_reset(void) {
    atomic_store_explicit(&g_write_pos, 0, memory_order_relaxed);
    atomic_store_explicit(&g_read_pos, 0, memory_order_relaxed);
    printf("[J2ME Input] Ring buffer reset\n");
}

// ============================================================
// Native method table
// ============================================================

#define CLS "javax/microedition/lcdui/NativeBridge"

static java_native_method j2me_input_methods[] = {
    {CLS, "pollInputEvent", "()[I", n_pollInputEvent},
    {CLS, "isStopRequested", "()Z", n_isStopRequested},
};

#undef CLS

void j2me_input_reg_natives(MiniJVM *jvm) {
    native_reg_lib(jvm, j2me_input_methods,
                   sizeof(j2me_input_methods) / sizeof(java_native_method));
    printf("[J2ME Input] Registered %lu native methods\n",
           sizeof(j2me_input_methods) / sizeof(java_native_method));
}
