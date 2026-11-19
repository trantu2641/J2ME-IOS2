#include "jvm_bridge.h"
#include "jvm.h"
#include "jvm_util.h"
#include "garbage.h"
#include "j2me_render.h"
#include "j2me_input.h"
#include "j2me_ui.h"
#include "j2me_audio.h"
#include "j2me_micro3d_gl.h"
#include "m3g/j2me_m3g.h"
#include "../minijvm/utils/miniz_wrapper.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <dlfcn.h>
#include <limits.h>

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/thread_info.h>

#if defined(__arm64__)
#include <mach/arm/thread_status.h>
#endif

static MiniJVM *g_jvm = NULL;
static atomic_int g_jvm_stop_requested = 0;

// ============================================================
// Multi-session runtime manager
// ============================================================

#define J2ME_MAX_SESSIONS 16

typedef struct J2MEProxyConfig {
    int type; // 0 = none, 1 = HTTP CONNECT, 2 = SOCKS5
    char host[256];
    int port;
    char username[128];
    char password[128];
} J2MEProxyConfig;

typedef struct J2MESession {
    int id;
    int used;
    MiniJVM *jvm;
    pthread_t runner;
    int runner_valid;
    atomic_int stop_requested;
    atomic_int running;
    char res_root[PATH_MAX];
    char save_root[PATH_MAX];
    char jar_path[PATH_MAX];
    J2MEProxyConfig proxy;
} J2MESession;

static J2MESession g_sessions[J2ME_MAX_SESSIONS];
static pthread_mutex_t g_sessions_lock = PTHREAD_MUTEX_INITIALIZER;
static MiniJVM *g_active_session_jvm = NULL;
static j2me_session_exit_callback g_session_exit_callback = NULL;

static char *load_midlet_manifest(const char *jar_path);

void jvm_bridge_set_session_exit_callback(j2me_session_exit_callback callback) {
    g_session_exit_callback = callback;
}

static J2MESession *session_find_locked(int id) {
    if (id < 1 || id > J2ME_MAX_SESSIONS) return NULL;
    J2MESession *s = &g_sessions[id - 1];
    return s->used ? s : NULL;
}

static J2MESession *session_find_by_vm_locked(MiniJVM *jvm) {
    if (!jvm) return NULL;
    for (int i = 0; i < J2ME_MAX_SESSIONS; i++) {
        if (g_sessions[i].used && g_sessions[i].jvm == jvm) {
            return &g_sessions[i];
        }
    }
    return NULL;
}

void jvm_bridge_session_set_proxy(int session_id,
                                  int proxy_type,
                                  const char *host,
                                  int port,
                                  const char *username,
                                  const char *password) {
    pthread_mutex_lock(&g_sessions_lock);
    J2MESession *s = session_find_locked(session_id);
    if (s) {
        memset(&s->proxy, 0, sizeof(s->proxy));
        if (proxy_type > 0 && host && host[0] != '\0' && port > 0 && port <= 65535) {
            s->proxy.type = proxy_type;
            snprintf(s->proxy.host, sizeof(s->proxy.host), "%s", host);
            s->proxy.port = port;
            if (username && username[0] != '\0') {
                snprintf(s->proxy.username, sizeof(s->proxy.username), "%s", username);
            }
            if (password && password[0] != '\0') {
                snprintf(s->proxy.password, sizeof(s->proxy.password), "%s", password);
            }
        }
    }
    pthread_mutex_unlock(&g_sessions_lock);
}

int jvm_bridge_get_proxy_for_vm(MiniJVM *jvm,
                                int *out_type,
                                char *out_host,
                                int host_cap,
                                int *out_port,
                                char *out_user,
                                int user_cap,
                                char *out_pass,
                                int pass_cap) {
    if (out_type) *out_type = 0;
    if (out_port) *out_port = 0;
    if (out_host && host_cap > 0) out_host[0] = '\0';
    if (out_user && user_cap > 0) out_user[0] = '\0';
    if (out_pass && pass_cap > 0) out_pass[0] = '\0';

    if (!jvm) return 0;

    int active = 0;
    pthread_mutex_lock(&g_sessions_lock);
    J2MESession *s = session_find_by_vm_locked(jvm);
    if (s && s->proxy.type > 0 && s->proxy.host[0] != '\0' && s->proxy.port > 0) {
        active = 1;
        if (out_type) *out_type = s->proxy.type;
        if (out_port) *out_port = s->proxy.port;
        if (out_host && host_cap > 0) {
            snprintf(out_host, (size_t)host_cap, "%s", s->proxy.host);
        }
        if (out_user && user_cap > 0) {
            snprintf(out_user, (size_t)user_cap, "%s", s->proxy.username);
        }
        if (out_pass && pass_cap > 0) {
            snprintf(out_pass, (size_t)pass_cap, "%s", s->proxy.password);
        }
    }
    pthread_mutex_unlock(&g_sessions_lock);
    return active;
}

static void session_configure_jvm(
    MiniJVM *jvm,
    const char *save_root,
    int screen_width,
    int screen_height,
    int render_3d_scale,
    int fps_limit
) {
    jvm->jdwp_enable = 0;
    jvm->jdwp_suspend_on_start = 0;
    jvm->max_heap_size = 128 * 1024 * 1024;
    jvm->garbage_collect_period_ms = 2000;
    jvm->heap_overload_percent = 70;

    j2me_render_reg_natives(jvm);
    j2me_input_reg_natives(jvm);
    j2me_ui_reg_natives(jvm);
    j2me_audio_reg_natives(jvm);
    j2me_micro3d_gl_reg_natives(jvm);
    j2me_m3g_reg_natives(jvm);

    sys_properties_set_c(jvm, "os.name", "iOS");
    sys_properties_set_c(jvm, "app.save.root", save_root);
    sys_properties_set_c(jvm, "microedition.platform", "Apple/iPhone");
    sys_properties_set_c(jvm, "microedition.encoding", "UTF-8");
    sys_properties_set_c(jvm, "microedition.locale", "en");
    sys_properties_set_c(jvm, "microedition.profiles", "MIDP-2.0");
    sys_properties_set_c(jvm, "microedition.configuration", "CLDC-1.1");

    char sw[16], sh[16], ss[8];
    snprintf(sw, sizeof(sw), "%d", screen_width);
    snprintf(sh, sizeof(sh), "%d", screen_height);
    snprintf(ss, sizeof(ss), "%d", render_3d_scale > 0 ? render_3d_scale : 1);

    sys_properties_set_c(jvm, "j2me.screen.width", sw);
    sys_properties_set_c(jvm, "j2me.screen.height", sh);
    sys_properties_set_c(jvm, "micro3d.v3.fbo.scale", ss);

    if (fps_limit > 0) {
        char fl[8];
        snprintf(fl, sizeof(fl), "%d", fps_limit);
        sys_properties_set_c(jvm, "j2me.fps.limit", fl);
    }
}

static void *session_runner_main(void *arg) {
    J2MESession *s = (J2MESession *)arg;
    if (!s) {
        return NULL;
    }

    int session_id = s->id;
    pthread_setname_np("J2ME-MIDlet");
    atomic_store(&s->running, 1);

    printf("[JVM Session %d] Starting MIDlet: %s\n", session_id, s->jar_path);

    char *manifest = load_midlet_manifest(s->jar_path);
    if (!manifest) {
        printf("[JVM Session %d] ERROR: Manifest extraction failed\n", session_id);
        atomic_store(&s->running, 0);
        if (g_session_exit_callback && !atomic_load(&s->stop_requested)) {
            g_session_exit_callback(session_id, -1);
        }
        return NULL;
    }

    ArrayList *java_para = arraylist_create(0);
    if (!java_para) {
        free(manifest);
        atomic_store(&s->running, 0);
        if (g_session_exit_callback && !atomic_load(&s->stop_requested)) {
            g_session_exit_callback(session_id, -2);
        }
        return NULL;
    }

    arraylist_push_back(java_para, (void *)s->jar_path);
    arraylist_push_back(java_para, (void *)manifest);

    s32 ret = call_main(
        s->jvm,
        (c8 *)"javax/microedition/shell/MIDletRunner",
        java_para
    );

    arraylist_destroy(java_para);
    free(manifest);

    printf("[JVM Session %d] MIDlet finished with code %d\n", session_id, ret);

    int was_manually_stopped = atomic_load(&s->stop_requested);
    atomic_store(&s->running, 0);

    // Notify Swift UI when the MIDlet exits on its own (e.g. in-game Exit button)
    if (!was_manually_stopped && g_session_exit_callback) {
        g_session_exit_callback(session_id, (int)ret);
    }

    return NULL;
}

static int g_saved_stdout = -1;
static int g_saved_stderr = -1;
static int g_log_redirected = 0;

int g_render_3d_scale = 1;

static pthread_t g_ios_main_pthread;
static int g_ios_main_pthread_valid = 0;

static pthread_t g_midlet_runner_pthread;
static int g_midlet_runner_pthread_valid = 0;

void jvm_bridge_register_main_thread(void) {
    if (!pthread_main_np()) {
        fprintf(stderr, "[CPU Profiler] Main-thread registration called off main thread\n");
        return;
    }
    g_ios_main_pthread = pthread_self();
    g_ios_main_pthread_valid = 1;
}

// ============================================================
// CPU PROFILER
// ============================================================

#define CPU_PROFILE_TOP_THREADS 8
#define CPU_PROFILE_PRINT_TOP 4
#define CPU_PROFILE_INTERVAL_SECONDS 5
#define CPU_PROFILE_JAVA_STACK_FRAMES 8
#define CPU_PROFILE_NATIVE_STACK_FRAMES 8
#define CPU_PROFILE_TEXT 1024
#define CPU_PROFILE_SYMBOL 192
#define CPU_PROFILE_NAME 64

typedef struct CPUThreadSample {
    double cpu_percent;
    mach_port_t thread_port;
    char native_name[CPU_PROFILE_NAME];
    char vm_role[24];
    int vm_status;
    int vm_blocking;
    int vm_matched;
    int is_ios_main_thread;
    char java_stack[CPU_PROFILE_TEXT];
    char native_pc[CPU_PROFILE_SYMBOL];
    char native_stack[CPU_PROFILE_TEXT];
} CPUThreadSample;

typedef struct NativeFrameRecord {
    uint64_t previous_fp;
    uint64_t return_address;
} NativeFrameRecord;

static pthread_t g_cpu_profiler_thread;
static atomic_int g_cpu_profiler_running = 0;
static int g_cpu_profiler_started = 0;

static int cpu_profiler_pthread_is_zero(pthread_t value) {
    pthread_t zero_value;
    memset(&zero_value, 0, sizeof(zero_value));
    return memcmp(&value, &zero_value, sizeof(value)) == 0;
}

static void cpu_profiler_append(char *destination, size_t capacity, const char *addition) {
    if (!destination || !addition || capacity == 0) return;
    size_t used = strlen(destination);
    if (used >= capacity - 1) return;
    snprintf(destination + used, capacity - used, "%s", addition);
}

static const char *cpu_profiler_vm_role(int type) {
    switch (type) {
        case THREAD_TYPE_NORMAL: return "normal";
        case THREAD_TYPE_GC: return "gc";
        case THREAD_TYPE_JDWP: return "jdwp";
        default: return "unknown";
    }
}

static void cpu_profiler_copy_java_stack(JavaThreadInfo *thread_info, CPUThreadSample *sample) {
    if (!thread_info || !sample) return;
    Runtime *leaf = thread_info->top_runtime;
    int guard = 0;
    while (leaf && leaf->son && guard < 64) {
        leaf = leaf->son;
        guard++;
    }
    int frames = 0;
    for (Runtime *frame = leaf; frame && frames < CPU_PROFILE_JAVA_STACK_FRAMES; frame = frame->parent) {
        MethodInfo *method = frame->method;
        if (!method || !method->name || !method->_this_class || !method->_this_class->name) continue;
        const char *class_name = utf8_cstr(method->_this_class->name);
        const char *method_name = utf8_cstr(method->name);
        if (!class_name || !method_name) continue;
        long long bytecode_offset = -1;
        if (method->converted_code && frame->pc) {
            uintptr_t code_address = (uintptr_t)method->converted_code->code;
            uintptr_t pc_address = (uintptr_t)frame->pc;
            if (pc_address >= code_address) {
                bytecode_offset = (long long)(pc_address - code_address);
            }
        }
        char line[256];
        snprintf(line, sizeof(line), "%s%s.%s@bc+%lld", frames == 0 ? "" : " <- ", class_name, method_name, bytecode_offset);
        cpu_profiler_append(sample->java_stack, sizeof(sample->java_stack), line);
        frames++;
    }
    if (frames == 0) {
        snprintf(sample->java_stack, sizeof(sample->java_stack), "Java Runtime present, no active MethodInfo");
    }
}

static int cpu_profiler_attach_from_jvm(MiniJVM *jvm, pthread_t native_thread, CPUThreadSample *sample) {
    if (!jvm || !jvm->thread_list || !sample) return 0;
    int found = 0;
    spin_lock(&jvm->thread_list->spinlock);
    for (int i = 0; i < jvm->thread_list->length; i++) {
        Runtime *runtime = (Runtime *)arraylist_get_value_unsafe(jvm->thread_list, i);
        if (!runtime || !runtime->thrd_info) continue;
        JavaThreadInfo *thread_info = runtime->thrd_info;
        int matched = 0;
        if (!cpu_profiler_pthread_is_zero(thread_info->pthread)) {
            matched = pthread_equal(thread_info->pthread, native_thread);
        }
        if (!matched && g_midlet_runner_pthread_valid &&
            pthread_equal(g_midlet_runner_pthread, native_thread) &&
            cpu_profiler_pthread_is_zero(thread_info->pthread) &&
            thread_info->type == THREAD_TYPE_NORMAL) {
            thread_info->pthread = native_thread;
            matched = 1;
        }
        if (!matched) continue;
        sample->vm_matched = 1;
        snprintf(sample->vm_role, sizeof(sample->vm_role), "%s", cpu_profiler_vm_role(thread_info->type));
        sample->vm_status = thread_info->thread_status;
        sample->vm_blocking = thread_info->is_blocking;
        cpu_profiler_copy_java_stack(thread_info, sample);
        found = 1;
        break;
    }
    spin_unlock(&jvm->thread_list->spinlock);
    return found;
}

static void cpu_profiler_attach_vm_context(pthread_t native_thread, CPUThreadSample *sample) {
    if (!sample) return;
    if (g_jvm && cpu_profiler_attach_from_jvm(g_jvm, native_thread, sample)) {
        return;
    }
    MiniJVM *session_jvms[J2ME_MAX_SESSIONS] = {0};
    int count = 0;
    pthread_mutex_lock(&g_sessions_lock);
    for (int i = 0; i < J2ME_MAX_SESSIONS; i++) {
        if (g_sessions[i].used && g_sessions[i].jvm) {
            session_jvms[count++] = g_sessions[i].jvm;
        }
    }
    pthread_mutex_unlock(&g_sessions_lock);
    for (int i = 0; i < count; i++) {
        if (cpu_profiler_attach_from_jvm(session_jvms[i], native_thread, sample)) {
            return;
        }
    }
}

static void cpu_profiler_resolve_symbol(uint64_t address, char *destination, size_t capacity) {
    if (!destination || capacity == 0) return;
    uintptr_t lookup_address = (uintptr_t)(address & 0x0000FFFFFFFFFFFFULL);
    Dl_info symbol_info;
    memset(&symbol_info, 0, sizeof(symbol_info));
    if (lookup_address != 0 && dladdr((const void *)lookup_address, &symbol_info) != 0 && symbol_info.dli_sname) {
        uintptr_t symbol_address = (uintptr_t)symbol_info.dli_saddr;
        unsigned long long offset = lookup_address >= symbol_address ? (unsigned long long)(lookup_address - symbol_address) : 0ULL;
        snprintf(destination, capacity, "%s+0x%llx [0x%llx]", symbol_info.dli_sname, offset, (unsigned long long)lookup_address);
    } else {
        snprintf(destination, capacity, "0x%llx", (unsigned long long)lookup_address);
    }
}

#if defined(__arm64__)
static int cpu_profiler_read_frame(uint64_t frame_pointer, NativeFrameRecord *record) {
    if (!record || frame_pointer < 0x1000 || (frame_pointer & 0x7) != 0) return 0;
    vm_size_t bytes_read = 0;
    kern_return_t result = vm_read_overwrite(
        mach_task_self(),
        (vm_address_t)frame_pointer,
        (vm_size_t)sizeof(*record),
        (vm_address_t)record,
        &bytes_read
    );
    return (result == KERN_SUCCESS && bytes_read == sizeof(*record));
}
#endif

static void cpu_profiler_capture_native_stack(CPUThreadSample *sample) {
    if (!sample) return;
#if defined(__arm64__)
    arm_thread_state64_t state;
    memset(&state, 0, sizeof(state));
    mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
    kern_return_t result = thread_get_state(sample->thread_port, ARM_THREAD_STATE64, (thread_state_t)&state, &state_count);
    if (result != KERN_SUCCESS) {
        snprintf(sample->native_pc, sizeof(sample->native_pc), "thread_get_state failed: %d", result);
        snprintf(sample->native_stack, sizeof(sample->native_stack), "Native stack unavailable");
        return;
    }
    uint64_t pc = (uint64_t)state.__pc;
    uint64_t frame_pointer = (uint64_t)state.__fp;
    cpu_profiler_resolve_symbol(pc, sample->native_pc, sizeof(sample->native_pc));
    for (int depth = 0; depth < CPU_PROFILE_NATIVE_STACK_FRAMES; depth++) {
        NativeFrameRecord record = {0};
        if (!cpu_profiler_read_frame(frame_pointer, &record)) break;
        uint64_t return_address = record.return_address & 0x0000FFFFFFFFFFFFULL;
        if (return_address == 0) break;
        uint64_t lookup_address = return_address >= 4 ? return_address - 4 : return_address;
        char symbol[CPU_PROFILE_SYMBOL];
        cpu_profiler_resolve_symbol(lookup_address, symbol, sizeof(symbol));
        char line[256];
        snprintf(line, sizeof(line), "%s#%d %s", depth == 0 ? "" : " | ", depth + 1, symbol);
        cpu_profiler_append(sample->native_stack, sizeof(sample->native_stack), line);
        uint64_t next_frame = record.previous_fp;
        if (next_frame <= frame_pointer || next_frame - frame_pointer > 1024 * 1024) break;
        frame_pointer = next_frame;
    }
    if (sample->native_stack[0] == '\0') {
        snprintf(sample->native_stack, sizeof(sample->native_stack), "PC captured; frame-pointer chain unavailable");
    }
#else
    snprintf(sample->native_pc, sizeof(sample->native_pc), "ARM64 PC sampling unavailable");
    snprintf(sample->native_stack, sizeof(sample->native_stack), "ARM64 stack sampling unavailable");
#endif
}

static void *cpu_profiler_main(void *argument) {
    (void)argument;
    pthread_setname_np("JarBoxCPUProfiler");
    while (atomic_load_explicit(&g_cpu_profiler_running, memory_order_relaxed)) {
        for (int i = 0; i < CPU_PROFILE_INTERVAL_SECONDS; i++) {
            if (!atomic_load_explicit(&g_cpu_profiler_running, memory_order_relaxed)) break;
            struct timespec delay = {1, 0};
            nanosleep(&delay, NULL);
        }
        if (!atomic_load_explicit(&g_cpu_profiler_running, memory_order_relaxed)) break;

        thread_act_array_t thread_list = NULL;
        mach_msg_type_number_t thread_count = 0;
        if (task_threads(mach_task_self(), &thread_list, &thread_count) != KERN_SUCCESS) continue;

        CPUThreadSample top[CPU_PROFILE_TOP_THREADS] = {0};
        for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
            thread_basic_info_data_t info;
            mach_msg_type_number_t info_count = THREAD_BASIC_INFO_COUNT;
            if (thread_info(thread_list[i], THREAD_BASIC_INFO, (thread_info_t)&info, &info_count) != KERN_SUCCESS) continue;
            double cpu_percent = ((double)info.cpu_usage * 100.0) / (double)TH_USAGE_SCALE;
            if (cpu_percent <= 0.1) continue;
            CPUThreadSample sample = {0};
            sample.cpu_percent = cpu_percent;
            sample.thread_port = thread_list[i];
            sample.vm_status = -1;
            snprintf(sample.vm_role, sizeof(sample.vm_role), "unmapped");
            for (int pos = 0; pos < CPU_PROFILE_TOP_THREADS; pos++) {
                if (cpu_percent > top[pos].cpu_percent) {
                    for (int shift = CPU_PROFILE_TOP_THREADS - 1; shift > pos; shift--) {
                        top[shift] = top[shift - 1];
                    }
                    top[pos] = sample;
                    break;
                }
            }
        }

        for (int i = 0; i < CPU_PROFILE_PRINT_TOP; i++) {
            if (top[i].cpu_percent <= 0.1) break;
            pthread_t native_thread = pthread_from_mach_thread_np(top[i].thread_port);
            if (native_thread != NULL) {
                top[i].is_ios_main_thread = g_ios_main_pthread_valid && pthread_equal(native_thread, g_ios_main_pthread);
                if (pthread_getname_np(native_thread, top[i].native_name, sizeof(top[i].native_name)) != 0 || top[i].native_name[0] == '\0') {
                    snprintf(top[i].native_name, sizeof(top[i].native_name), "unnamed");
                }
                if (top[i].is_ios_main_thread) snprintf(top[i].vm_role, sizeof(top[i].vm_role), "ios-main");
                cpu_profiler_attach_vm_context(native_thread, &top[i]);
            }
            cpu_profiler_capture_native_stack(&top[i]);
        }

        for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
            mach_port_deallocate(mach_task_self(), thread_list[i]);
        }
        if (thread_list != NULL) {
            vm_deallocate(mach_task_self(), (vm_address_t)thread_list, (vm_size_t)(thread_count * sizeof(thread_t)));
        }
    }
    return NULL;
}

static void cpu_profiler_start(void) {
    if (g_cpu_profiler_started) return;
    atomic_store_explicit(&g_cpu_profiler_running, 1, memory_order_relaxed);
    if (pthread_create(&g_cpu_profiler_thread, NULL, cpu_profiler_main, NULL) != 0) {
        atomic_store_explicit(&g_cpu_profiler_running, 0, memory_order_relaxed);
        return;
    }
    g_cpu_profiler_started = 1;
}

static void cpu_profiler_stop(void) {
    if (!g_cpu_profiler_started) return;
    atomic_store_explicit(&g_cpu_profiler_running, 0, memory_order_relaxed);
    pthread_join(g_cpu_profiler_thread, NULL);
    g_cpu_profiler_started = 0;
}

// ============================================================
// Runtime log
// ============================================================

static void start_runtime_log(const char *save_root) {
    if (!save_root || !save_root[0]) return;
    char path[2048];
    snprintf(path, sizeof(path), "%s/minijvm.log", save_root);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    fflush(stdout);
    fflush(stderr);
    if (g_saved_stdout < 0) g_saved_stdout = dup(STDOUT_FILENO);
    if (g_saved_stderr < 0) g_saved_stderr = dup(STDERR_FILENO);
    if (dup2(fd, STDOUT_FILENO) < 0 || dup2(fd, STDERR_FILENO) < 0) {
        close(fd);
        return;
    }
    close(fd);
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    g_log_redirected = 1;
}

static void stop_runtime_log(void) {
    if (!g_log_redirected) return;
    fflush(stdout);
    fflush(stderr);
    if (g_saved_stdout >= 0) {
        dup2(g_saved_stdout, STDOUT_FILENO);
        close(g_saved_stdout);
        g_saved_stdout = -1;
    }
    if (g_saved_stderr >= 0) {
        dup2(g_saved_stderr, STDERR_FILENO);
        close(g_saved_stderr);
        g_saved_stderr = -1;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    g_log_redirected = 0;
}

// ============================================================
// Manifest
// ============================================================

static char *load_midlet_manifest(const char *jar_path) {
    if (!jar_path || !jar_path[0]) return NULL;
    s64 manifest_size = zip_get_file_unzip_size(jar_path, "META-INF/MANIFEST.MF");
    if (manifest_size <= 0 || manifest_size > 1024 * 1024) return NULL;
    char *manifest = (char *)malloc((size_t)manifest_size + 1);
    if (!manifest) return NULL;
    memset(manifest, 0, (size_t)manifest_size + 1);
    if (zip_loadfile_to_mem(jar_path, "META-INF/MANIFEST.MF", manifest, manifest_size) != 0) {
        free(manifest);
        return NULL;
    }
    manifest[manifest_size] = '\0';
    return manifest;
}

// ============================================================
// Legacy single-JVM init & run (preserved for compatibility)
// ============================================================

int jvm_bridge_init(
    const char *res_root,
    const char *save_root,
    const char *midlet_jar,
    int screen_width,
    int screen_height,
    int render_3d_scale,
    int fps_limit
) {
    if (g_jvm) return -1;

    g_midlet_runner_pthread = pthread_self();
    g_midlet_runner_pthread_valid = 1;
    pthread_setname_np("J2ME-MIDlet");
    start_runtime_log(save_root);

    char bootclasspath[1024];
    snprintf(bootclasspath, sizeof(bootclasspath), "%s/minijvm_rt.jar", res_root);

    char classpath[4096];
    snprintf(classpath, sizeof(classpath), "%s/j2me_api.jar:%s", res_root, midlet_jar);

    g_jvm = jvm_create();
    if (!g_jvm) {
        stop_runtime_log();
        return -2;
    }

    g_jvm->jdwp_enable = 0;
    g_jvm->jdwp_suspend_on_start = 0;
    g_jvm->max_heap_size = 128 * 1024 * 1024;
    g_jvm->garbage_collect_period_ms = 2000;
    g_jvm->heap_overload_percent = 70;

    if (jvm_init(g_jvm, (c8 *)bootclasspath, (c8 *)classpath)) {
        jvm_destroy(g_jvm);
        g_jvm = NULL;
        stop_runtime_log();
        return -3;
    }

    g_render_3d_scale = render_3d_scale > 0 ? render_3d_scale : 1;
    session_configure_jvm(g_jvm, save_root, screen_width, screen_height, g_render_3d_scale, fps_limit);
    cpu_profiler_start();
    return 0;
}

int jvm_bridge_run_midlet(const char *midlet_jar_path) {
    if (!g_jvm) return -1;
    char *manifest = load_midlet_manifest(midlet_jar_path);
    if (!manifest) return -4;
    ArrayList *java_para = arraylist_create(0);
    if (!java_para) {
        free(manifest);
        return -5;
    }
    arraylist_push_back(java_para, (void *)midlet_jar_path);
    arraylist_push_back(java_para, (void *)manifest);
    s32 ret = call_main(g_jvm, (c8 *)"javax/microedition/shell/MIDletRunner", java_para);
    arraylist_destroy(java_para);
    free(manifest);
    return ret;
}

// ============================================================
// Multi-session API
// ============================================================

int jvm_bridge_session_create(
    const char *res_root,
    const char *save_root,
    const char *midlet_jar,
    int screen_width,
    int screen_height,
    int render_3d_scale,
    int fps_limit
) {
    if (!res_root || !save_root || !midlet_jar) {
        return -1000;
    }

    pthread_mutex_lock(&g_sessions_lock);
    J2MESession *s = NULL;
    for (int i = 0; i < J2ME_MAX_SESSIONS; i++) {
        if (!g_sessions[i].used) {
            s = &g_sessions[i];
            memset(s, 0, sizeof(*s));
            s->id = i + 1;
            s->used = 1;
            atomic_init(&s->stop_requested, 0);
            atomic_init(&s->running, 0);
            break;
        }
    }
    pthread_mutex_unlock(&g_sessions_lock);

    if (!s) return -1001;

    snprintf(s->res_root, sizeof(s->res_root), "%s", res_root);
    snprintf(s->save_root, sizeof(s->save_root), "%s", save_root);
    snprintf(s->jar_path, sizeof(s->jar_path), "%s", midlet_jar);

    char bootclasspath[PATH_MAX * 2];
    char classpath[PATH_MAX * 3];
    snprintf(bootclasspath, sizeof(bootclasspath), "%s/minijvm_rt.jar", res_root);
    snprintf(classpath, sizeof(classpath), "%s/j2me_api.jar:%s", res_root, midlet_jar);

    s->jvm = jvm_create();
    if (!s->jvm) {
        pthread_mutex_lock(&g_sessions_lock);
        s->used = 0;
        pthread_mutex_unlock(&g_sessions_lock);
        return -1002;
    }

    s32 ret = jvm_init(s->jvm, (c8 *)bootclasspath, (c8 *)classpath);
    if (ret) {
        jvm_destroy(s->jvm);
        s->jvm = NULL;
        pthread_mutex_lock(&g_sessions_lock);
        s->used = 0;
        pthread_mutex_unlock(&g_sessions_lock);
        return -1003;
    }

    session_configure_jvm(
        s->jvm,
        save_root,
        screen_width,
        screen_height,
        render_3d_scale,
        fps_limit
    );

    printf("[JVM Session %d] JVM initialized: %dx%d\n", s->id, screen_width, screen_height);
    return s->id;
}

int jvm_bridge_session_start(int session_id) {
    pthread_mutex_lock(&g_sessions_lock);
    J2MESession *s = session_find_locked(session_id);
    if (!s || !s->jvm) {
        pthread_mutex_unlock(&g_sessions_lock);
        return -1100;
    }

    if (s->runner_valid || atomic_load(&s->running)) {
        pthread_mutex_unlock(&g_sessions_lock);
        return 0;
    }

    atomic_store(&s->stop_requested, 0);
    int rc = pthread_create(&s->runner, NULL, session_runner_main, s);
    if (rc == 0) {
        s->runner_valid = 1;
    }
    pthread_mutex_unlock(&g_sessions_lock);
    return rc == 0 ? 0 : -1101;
}

void jvm_bridge_session_set_active(int session_id) {
    pthread_mutex_lock(&g_sessions_lock);
    J2MESession *s = session_find_locked(session_id);
    g_active_session_jvm = s ? s->jvm : NULL;
    pthread_mutex_unlock(&g_sessions_lock);

    j2me_render_set_active_jvm(g_active_session_jvm);
    j2me_input_set_active_jvm(g_active_session_jvm);
}

int jvm_bridge_session_is_running(int session_id) {
    pthread_mutex_lock(&g_sessions_lock);
    J2MESession *s = session_find_locked(session_id);
    int result = s ? atomic_load(&s->running) : 0;
    pthread_mutex_unlock(&g_sessions_lock);
    return result;
}

void jvm_bridge_session_request_stop(int session_id) {
    pthread_mutex_lock(&g_sessions_lock);
    J2MESession *s = session_find_locked(session_id);
    if (s) {
        atomic_store(&s->stop_requested, 1);
        if (s->jvm) {
            if (s->jvm->collector) {
                s->jvm->collector->exit_flag = 1;
            }
            thread_stop_all(s->jvm);
        }
    }
    pthread_mutex_unlock(&g_sessions_lock);
    j2me_audio_stop_all();
}

void jvm_bridge_session_destroy(int session_id) {
    pthread_mutex_lock(&g_sessions_lock);
    J2MESession *s = session_find_locked(session_id);
    if (!s) {
        pthread_mutex_unlock(&g_sessions_lock);
        return;
    }

    if (s->jvm == g_active_session_jvm) {
        g_active_session_jvm = NULL;
        j2me_render_set_active_jvm(NULL);
        j2me_input_set_active_jvm(NULL);
    }
    pthread_mutex_unlock(&g_sessions_lock);

    jvm_bridge_session_request_stop(session_id);

    pthread_mutex_lock(&g_sessions_lock);
    s = session_find_locked(session_id);
    if (!s) {
        pthread_mutex_unlock(&g_sessions_lock);
        return;
    }

    MiniJVM *jvm = s->jvm;
    pthread_t runner = s->runner;
    int runner_valid = s->runner_valid;
    pthread_mutex_unlock(&g_sessions_lock);

    if (runner_valid && !pthread_equal(pthread_self(), runner)) {
        pthread_join(runner, NULL);
    }

    j2me_audio_stop_all();
    j2me_input_remove_jvm(jvm);

    if (jvm) {
        jvm_destroy(jvm);
    }

    pthread_mutex_lock(&g_sessions_lock);
    s = session_find_locked(session_id);
    if (s) {
        memset(s, 0, sizeof(*s));
    }
    pthread_mutex_unlock(&g_sessions_lock);
}

void jvm_bridge_session_destroy_all(void) {
    for (int i = 1; i <= J2ME_MAX_SESSIONS; i++) {
        jvm_bridge_session_destroy(i);
    }

    j2me_audio_stop_all();
    j2me_render_stop();
    j2me_render_cleanup();
    zip_reader_cache_clear();
}

int jvm_bridge_is_stop_requested_for_vm(MiniJVM *jvm) {
    if (!jvm) return 0;
    pthread_mutex_lock(&g_sessions_lock);
    J2MESession *s = session_find_by_vm_locked(jvm);
    int result = s ? atomic_load(&s->stop_requested) : atomic_load(&g_jvm_stop_requested);
    pthread_mutex_unlock(&g_sessions_lock);
    return result;
}

void jvm_bridge_destroy(void) {
    cpu_profiler_stop();
    if (g_jvm) {
        j2me_render_stop();
        g_jvm->collector->exit_flag = 1;
        thread_stop_all(g_jvm);
        jvm_destroy(g_jvm);
        g_jvm = NULL;

        j2me_input_reset();
        j2me_audio_stop_all();
        j2me_micro3d_gl_cleanup();
        j2me_m3g_cleanup();
        j2me_render_cleanup();
        zip_reader_cache_clear();
        atomic_store(&g_jvm_stop_requested, 0);
    }
    g_midlet_runner_pthread_valid = 0;
    stop_runtime_log();
}

void jvm_bridge_request_stop(void) {
    atomic_store(&g_jvm_stop_requested, 1);
}

int jvm_bridge_is_stop_requested(void) {
    return atomic_load(&g_jvm_stop_requested);
}

int jvm_bridge_extract_jar_entry(
    const char *jar_path,
    const char *entry_name,
    void **out_data,
    int64_t *out_size
) {
    if (!jar_path || !entry_name || !out_data || !out_size) return -1;
    *out_data = NULL;
    *out_size = 0;

    const s64 entry_size = zip_get_file_unzip_size(jar_path, entry_name);
    if (entry_size <= 0 || entry_size > (50LL * 1024LL * 1024LL)) return -1;

    void *buffer = malloc((size_t)entry_size);
    if (!buffer) return -1;

    if (zip_loadfile_to_mem(jar_path, entry_name, (c8 *)buffer, entry_size) != 0) {
        free(buffer);
        return -1;
    }

    *out_data = buffer;
    *out_size = (int64_t)entry_size;
    return 0;
}

void jvm_bridge_release_jar_entry(void *data) {
    free(data);
}
