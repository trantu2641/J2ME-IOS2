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

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/thread_info.h>

#if defined(__arm64__)
#include <mach/arm/thread_status.h>
#endif

static MiniJVM *g_jvm = NULL;
static atomic_int g_jvm_stop_requested = 0;

static int g_saved_stdout = -1;
static int g_saved_stderr = -1;
static int g_log_redirected = 0;

int g_render_3d_scale = 1;

// Main MIDlet worker thread.
static pthread_t g_midlet_runner_pthread;
static int g_midlet_runner_pthread_valid = 0;


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


// ============================================================
// Helper
// ============================================================

static int cpu_profiler_pthread_is_zero(pthread_t value) {

    pthread_t zero_value;

    memset(&zero_value, 0, sizeof(zero_value));

    return memcmp(
        &value,
        &zero_value,
        sizeof(value)
    ) == 0;
}


static void cpu_profiler_append(
    char *destination,
    size_t capacity,
    const char *addition
) {

    if (!destination || !addition || capacity == 0) {
        return;
    }

    size_t used = strlen(destination);

    if (used >= capacity - 1) {
        return;
    }

    snprintf(
        destination + used,
        capacity - used,
        "%s",
        addition
    );
}


static const char *cpu_profiler_vm_role(int type) {

    switch (type) {

        case THREAD_TYPE_NORMAL:
            return "normal";

        case THREAD_TYPE_GC:
            return "gc";

        case THREAD_TYPE_JDWP:
            return "jdwp";

        default:
            return "unknown";
    }
}


// ============================================================
// MiniJVM Java Stack
// ============================================================

static void cpu_profiler_copy_java_stack(
    JavaThreadInfo *thread_info,
    CPUThreadSample *sample
) {

    if (!thread_info || !sample) {
        return;
    }

    Runtime *leaf = thread_info->top_runtime;

    int guard = 0;

    while (leaf && leaf->son && guard < 64) {

        leaf = leaf->son;
        guard++;
    }

    int frames = 0;

    for (
        Runtime *frame = leaf;
        frame && frames < CPU_PROFILE_JAVA_STACK_FRAMES;
        frame = frame->parent
    ) {

        MethodInfo *method = frame->method;

        if (
            !method ||
            !method->name ||
            !method->_this_class ||
            !method->_this_class->name
        ) {
            continue;
        }

        const char *class_name =
            utf8_cstr(method->_this_class->name);

        const char *method_name =
            utf8_cstr(method->name);

        if (!class_name || !method_name) {
            continue;
        }

        long long bytecode_offset = -1;

        if (method->converted_code && frame->pc) {

            uintptr_t code_address =
                (uintptr_t)method->converted_code->code;

            uintptr_t pc_address =
                (uintptr_t)frame->pc;

            if (pc_address >= code_address) {

                bytecode_offset =
                    (long long)(pc_address - code_address);
            }
        }

        char line[256];

        snprintf(
            line,
            sizeof(line),
            "%s%s.%s@bc+%lld",
            frames == 0 ? "" : " <- ",
            class_name,
            method_name,
            bytecode_offset
        );

        cpu_profiler_append(
            sample->java_stack,
            sizeof(sample->java_stack),
            line
        );

        frames++;
    }

    if (frames == 0) {

        snprintf(
            sample->java_stack,
            sizeof(sample->java_stack),
            "Java Runtime present, no active MethodInfo"
        );
    }
}


// ============================================================
// Match Mach Thread to MiniJVM Runtime
// ============================================================

static void cpu_profiler_attach_vm_context(
    pthread_t native_thread,
    CPUThreadSample *sample
) {

    if (!g_jvm || !g_jvm->thread_list || !sample) {
        return;
    }

    spin_lock(&g_jvm->thread_list->spinlock);

    for (
        int i = 0;
        i < g_jvm->thread_list->length;
        i++
    ) {

        Runtime *runtime = (Runtime *)
            arraylist_get_value_unsafe(
                g_jvm->thread_list,
                i
            );

        if (!runtime || !runtime->thrd_info) {
            continue;
        }

        JavaThreadInfo *thread_info = runtime->thrd_info;

        int matched = 0;

        if (!cpu_profiler_pthread_is_zero(
            thread_info->pthread
        )) {

            matched = pthread_equal(
                thread_info->pthread,
                native_thread
            );
        }

        // Main MIDlet Runtime:
        // thread_boundle() does not currently initialize pthread.
        // Bind it to the known GameViewController worker thread.
        if (
            !matched &&
            g_midlet_runner_pthread_valid &&
            pthread_equal(
                g_midlet_runner_pthread,
                native_thread
            ) &&
            cpu_profiler_pthread_is_zero(
                thread_info->pthread
            ) &&
            thread_info->type == THREAD_TYPE_NORMAL
        ) {

            thread_info->pthread = native_thread;
            matched = 1;
        }

        if (!matched) {
            continue;
        }

        sample->vm_matched = 1;

        snprintf(
            sample->vm_role,
            sizeof(sample->vm_role),
            "%s",
            cpu_profiler_vm_role(thread_info->type)
        );

        sample->vm_status = thread_info->thread_status;

        sample->vm_blocking = thread_info->is_blocking;

        cpu_profiler_copy_java_stack(
            thread_info,
            sample
        );

        break;
    }

    spin_unlock(&g_jvm->thread_list->spinlock);
}


// ============================================================
// Native Symbol Resolver
// ============================================================

static void cpu_profiler_resolve_symbol(
    uint64_t address,
    char *destination,
    size_t capacity
) {

    if (!destination || capacity == 0) {
        return;
    }

    uintptr_t lookup_address =
        (uintptr_t)(
            address & 0x0000FFFFFFFFFFFFULL
        );

    Dl_info symbol_info;

    memset(
        &symbol_info,
        0,
        sizeof(symbol_info)
    );

    if (
        lookup_address != 0 &&
        dladdr(
            (const void *)lookup_address,
            &symbol_info
        ) != 0 &&
        symbol_info.dli_sname
    ) {

        uintptr_t symbol_address =
            (uintptr_t)symbol_info.dli_saddr;

        unsigned long long offset =
            lookup_address >= symbol_address
            ? (unsigned long long)(
                lookup_address - symbol_address
            )
            : 0ULL;

        snprintf(
            destination,
            capacity,
            "%s+0x%llx [0x%llx]",
            symbol_info.dli_sname,
            offset,
            (unsigned long long)lookup_address
        );

    } else {

        snprintf(
            destination,
            capacity,
            "0x%llx",
            (unsigned long long)lookup_address
        );
    }
}


// ============================================================
// ARM64 Stack Reader
// ============================================================

#if defined(__arm64__)

static int cpu_profiler_read_frame(
    uint64_t frame_pointer,
    NativeFrameRecord *record
) {

    if (
        !record ||
        frame_pointer < 0x1000 ||
        (frame_pointer & 0x7) != 0
    ) {
        return 0;
    }

    // iOS uses vm_map.h APIs rather than mach_vm.h.
    vm_size_t bytes_read = 0;

    kern_return_t result = vm_read_overwrite(
        mach_task_self(),
        (vm_address_t)frame_pointer,
        (vm_size_t)sizeof(*record),
        (vm_address_t)record,
        &bytes_read
    );

    return (
        result == KERN_SUCCESS &&
        bytes_read == sizeof(*record)
    );
}

#endif


// ============================================================
// Capture Native Stack
// ============================================================

static void cpu_profiler_capture_native_stack(
    CPUThreadSample *sample
) {

    if (!sample) {
        return;
    }

#if defined(__arm64__)

    arm_thread_state64_t state;

    memset(
        &state,
        0,
        sizeof(state)
    );

    mach_msg_type_number_t state_count =
        ARM_THREAD_STATE64_COUNT;

    kern_return_t result = thread_get_state(
        sample->thread_port,
        ARM_THREAD_STATE64,
        (thread_state_t)&state,
        &state_count
    );

    if (result != KERN_SUCCESS) {

        snprintf(
            sample->native_pc,
            sizeof(sample->native_pc),
            "thread_get_state failed: %d",
            result
        );

        snprintf(
            sample->native_stack,
            sizeof(sample->native_stack),
            "Native stack unavailable"
        );

        return;
    }

    uint64_t pc = (uint64_t)state.__pc;

    uint64_t frame_pointer =
        (uint64_t)state.__fp;

    cpu_profiler_resolve_symbol(
        pc,
        sample->native_pc,
        sizeof(sample->native_pc)
    );

    for (
        int depth = 0;
        depth < CPU_PROFILE_NATIVE_STACK_FRAMES;
        depth++
    ) {

        NativeFrameRecord record = {0};

        if (!cpu_profiler_read_frame(
            frame_pointer,
            &record
        )) {
            break;
        }

        uint64_t return_address =
            record.return_address & 0x0000FFFFFFFFFFFFULL;

        if (return_address == 0) {
            break;
        }

        uint64_t lookup_address =
            return_address >= 4
            ? return_address - 4
            : return_address;

        char symbol[CPU_PROFILE_SYMBOL];

        cpu_profiler_resolve_symbol(
            lookup_address,
            symbol,
            sizeof(symbol)
        );

        char line[256];

        snprintf(
            line,
            sizeof(line),
            "%s#%d %s",
            depth == 0 ? "" : " | ",
            depth + 1,
            symbol
        );

        cpu_profiler_append(
            sample->native_stack,
            sizeof(sample->native_stack),
            line
        );

        uint64_t next_frame =
            record.previous_fp;

        if (
            next_frame <= frame_pointer ||
            next_frame - frame_pointer > 1024 * 1024
        ) {
            break;
        }

        frame_pointer = next_frame;
    }

    if (sample->native_stack[0] == '\0') {

        snprintf(
            sample->native_stack,
            sizeof(sample->native_stack),
            "PC captured; frame-pointer chain unavailable"
        );
    }

#else

    snprintf(
        sample->native_pc,
        sizeof(sample->native_pc),
        "ARM64 PC sampling unavailable"
    );

    snprintf(
        sample->native_stack,
        sizeof(sample->native_stack),
        "ARM64 stack sampling unavailable"
    );

#endif
}


// ============================================================
// CPU Profiler Thread
// ============================================================

static void *cpu_profiler_main(void *argument) {

    (void)argument;

    pthread_setname_np("JarBoxCPUProfiler");

    while (atomic_load_explicit(
        &g_cpu_profiler_running,
        memory_order_relaxed
    )) {

        for (
            int i = 0;
            i < CPU_PROFILE_INTERVAL_SECONDS;
            i++
        ) {

            if (!atomic_load_explicit(
                &g_cpu_profiler_running,
                memory_order_relaxed
            )) {
                break;
            }

            struct timespec delay;

            delay.tv_sec = 1;
            delay.tv_nsec = 0;

            nanosleep(&delay, NULL);
        }

        if (!atomic_load_explicit(
            &g_cpu_profiler_running,
            memory_order_relaxed
        )) {
            break;
        }

        thread_act_array_t thread_list = NULL;

        mach_msg_type_number_t thread_count = 0;

        kern_return_t result = task_threads(
            mach_task_self(),
            &thread_list,
            &thread_count
        );

        if (result != KERN_SUCCESS) {

            printf(
                "[CPU Profiler] task_threads failed: %d\n",
                result
            );

            continue;
        }

        CPUThreadSample top[CPU_PROFILE_TOP_THREADS] = {0};

        double total_cpu = 0.0;

        int active_threads = 0;

        for (
            mach_msg_type_number_t i = 0;
            i < thread_count;
            i++
        ) {

            thread_basic_info_data_t info;

            mach_msg_type_number_t info_count =
                THREAD_BASIC_INFO_COUNT;

            kern_return_t info_result = thread_info(
                thread_list[i],
                THREAD_BASIC_INFO,
                (thread_info_t)&info,
                &info_count
            );

            if (info_result != KERN_SUCCESS) {
                continue;
            }

            double cpu_percent =
                ((double)info.cpu_usage * 100.0) /
                (double)TH_USAGE_SCALE;

            if (cpu_percent <= 0.1) {
                continue;
            }

            total_cpu += cpu_percent;

            active_threads++;

            CPUThreadSample sample = {0};

            sample.cpu_percent = cpu_percent;

            sample.thread_port = thread_list[i];

            sample.vm_status = -1;

            snprintf(
                sample.vm_role,
                sizeof(sample.vm_role),
                "unmapped"
            );

            for (
                int position = 0;
                position < CPU_PROFILE_TOP_THREADS;
                position++
            ) {

                if (
                    cpu_percent >
                    top[position].cpu_percent
                ) {

                    for (
                        int shift = CPU_PROFILE_TOP_THREADS - 1;
                        shift > position;
                        shift--
                    ) {
                        top[shift] = top[shift - 1];
                    }

                    top[position] = sample;

                    break;
                }
            }
        }

        // Inspect only the four busiest threads.
        for (
            int i = 0;
            i < CPU_PROFILE_PRINT_TOP;
            i++
        ) {

            if (top[i].cpu_percent <= 0.1) {
                break;
            }

            pthread_t native_thread =
                pthread_from_mach_thread_np(
                    top[i].thread_port
                );

            if (native_thread != NULL) {

                if (
                    pthread_getname_np(
                        native_thread,
                        top[i].native_name,
                        sizeof(top[i].native_name)
                    ) != 0 ||
                    top[i].native_name[0] == '\0'
                ) {

                    snprintf(
                        top[i].native_name,
                        sizeof(top[i].native_name),
                        "unnamed"
                    );
                }

                cpu_profiler_attach_vm_context(
                    native_thread,
                    &top[i]
                );

            } else {

                snprintf(
                    top[i].native_name,
                    sizeof(top[i].native_name),
                    "no-pthread"
                );
            }

            cpu_profiler_capture_native_stack(&top[i]);
        }

        printf(
            "[CPU] total=%.1f%% active=%d threads=%u\n",
            total_cpu,
            active_threads,
            thread_count
        );

        for (
            int i = 0;
            i < CPU_PROFILE_PRINT_TOP;
            i++
        ) {

            if (top[i].cpu_percent <= 0.1) {
                break;
            }

            printf(
                "[CPU Thread] mach=%u cpu=%.1f%% name=%s vm=%s status=%d blocking=%d\n",
                (unsigned int)top[i].thread_port,
                top[i].cpu_percent,
                top[i].native_name,
                top[i].vm_role,
                top[i].vm_status,
                top[i].vm_blocking
            );

            printf(
                "[CPU Native PC] mach=%u %s\n",
                (unsigned int)top[i].thread_port,
                top[i].native_pc
            );

            printf(
                "[CPU Native Stack] mach=%u %s\n",
                (unsigned int)top[i].thread_port,
                top[i].native_stack
            );

            if (top[i].vm_matched) {

                printf(
                    "[CPU Java Stack] mach=%u %s\n",
                    (unsigned int)top[i].thread_port,
                    top[i].java_stack
                );

            } else {

                printf(
                    "[CPU Java Stack] mach=%u no MiniJVM Runtime match\n",
                    (unsigned int)top[i].thread_port
                );
            }
        }

        // Release the Mach thread ports returned by task_threads().
        for (
            mach_msg_type_number_t i = 0;
            i < thread_count;
            i++
        ) {

            mach_port_deallocate(
                mach_task_self(),
                thread_list[i]
            );
        }

        if (thread_list != NULL) {

            vm_deallocate(
                mach_task_self(),
                (vm_address_t)thread_list,
                (vm_size_t)(thread_count * sizeof(thread_t))
            );
        }
    }

    return NULL;
}


// ============================================================
// Start / Stop Profiler
// ============================================================

static void cpu_profiler_start(void) {

    if (g_cpu_profiler_started) {
        return;
    }

    atomic_store_explicit(
        &g_cpu_profiler_running,
        1,
        memory_order_relaxed
    );

    int result = pthread_create(
        &g_cpu_profiler_thread,
        NULL,
        cpu_profiler_main,
        NULL
    );

    if (result != 0) {

        atomic_store_explicit(
            &g_cpu_profiler_running,
            0,
            memory_order_relaxed
        );

        printf(
            "[CPU Profiler] pthread_create failed: %d\n",
            result
        );

        return;
    }

    g_cpu_profiler_started = 1;

    printf(
        "[CPU Profiler] Started. Sampling top %d threads every %d seconds.\n",
        CPU_PROFILE_PRINT_TOP,
        CPU_PROFILE_INTERVAL_SECONDS
    );
}


static void cpu_profiler_stop(void) {

    if (!g_cpu_profiler_started) {
        return;
    }

    atomic_store_explicit(
        &g_cpu_profiler_running,
        0,
        memory_order_relaxed
    );

    pthread_join(
        g_cpu_profiler_thread,
        NULL
    );

    g_cpu_profiler_started = 0;

    printf("[CPU Profiler] Stopped.\n");
}


// ============================================================
// Runtime log
// ============================================================

static void start_runtime_log(const char *save_root) {

    if (!save_root || !save_root[0]) {
        return;
    }

    char path[2048];

    snprintf(
        path,
        sizeof(path),
        "%s/minijvm.log",
        save_root
    );

    int fd = open(
        path,
        O_WRONLY | O_CREAT | O_TRUNC,
        0600
    );

    if (fd < 0) {

        fprintf(
            stderr,
            "[JVM Bridge] Cannot open diagnostic log: %s\n",
            path
        );

        return;
    }

    fflush(stdout);
    fflush(stderr);

    if (g_saved_stdout < 0) {
        g_saved_stdout = dup(STDOUT_FILENO);
    }

    if (g_saved_stderr < 0) {
        g_saved_stderr = dup(STDERR_FILENO);
    }

    if (
        dup2(fd, STDOUT_FILENO) < 0 ||
        dup2(fd, STDERR_FILENO) < 0
    ) {

        close(fd);
        return;
    }

    close(fd);

    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    g_log_redirected = 1;

    printf(
        "[JVM Bridge] Diagnostic log: %s\n",
        path
    );
}


static void stop_runtime_log(void) {

    if (!g_log_redirected) {
        return;
    }

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

    if (!jar_path || !jar_path[0]) {
        printf("[JVM Bridge] ERROR: Empty JAR path\n");
        return NULL;
    }

    s64 manifest_size = zip_get_file_unzip_size(
        jar_path,
        "META-INF/MANIFEST.MF"
    );

    if (
        manifest_size <= 0 ||
        manifest_size > 1024 * 1024
    ) {

        printf(
            "[JVM Bridge] ERROR: Invalid or missing MIDlet manifest, size=%lld\n",
            (long long)manifest_size
        );

        return NULL;
    }

    char *manifest = (char *)malloc(
        (size_t)manifest_size + 1
    );

    if (!manifest) {
        printf("[JVM Bridge] ERROR: Cannot allocate manifest buffer\n");
        return NULL;
    }

    memset(
        manifest,
        0,
        (size_t)manifest_size + 1
    );

    s32 result = zip_loadfile_to_mem(
        jar_path,
        "META-INF/MANIFEST.MF",
        manifest,
        manifest_size
    );

    if (result != 0) {

        printf("[JVM Bridge] ERROR: Cannot extract MIDlet manifest\n");

        free(manifest);
        return NULL;
    }

    manifest[manifest_size] = '\0';

    printf(
        "[JVM Bridge] Manifest loaded successfully (%lld bytes)\n",
        (long long)manifest_size
    );

    return manifest;
}


// ============================================================
// JVM init
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

    if (g_jvm) {
        printf("[JVM Bridge] JVM already initialized\n");
        return -1;
    }

    // GameViewController invokes init and MIDlet execution on the same
    // background worker. Keep its pthread ID for main-Runtime correlation.
    g_midlet_runner_pthread = pthread_self();
    g_midlet_runner_pthread_valid = 1;
    pthread_setname_np("J2ME-MIDlet");

    start_runtime_log(save_root);

    char bootclasspath[1024];

    snprintf(
        bootclasspath,
        sizeof(bootclasspath),
        "%s/minijvm_rt.jar",
        res_root
    );

    char classpath[4096];

    snprintf(
        classpath,
        sizeof(classpath),
        "%s/j2me_api.jar:%s",
        res_root,
        midlet_jar
    );

    printf(
        "[JVM Bridge] bootclasspath: %s\n",
        bootclasspath
    );

    printf(
        "[JVM Bridge] classpath: %s\n",
        classpath
    );

    g_jvm = jvm_create();

    if (!g_jvm) {

        printf("[JVM Bridge] ERROR: jvm_create() failed\n");

        stop_runtime_log();
        return -2;
    }

    g_jvm->jdwp_enable = 0;
    g_jvm->jdwp_suspend_on_start = 0;
    g_jvm->max_heap_size = 128 * 1024 * 1024;

    // Keep the existing 2000ms GC interval.
    g_jvm->garbage_collect_period_ms = 2000;

    g_jvm->heap_overload_percent = 70;

    printf(
        "[JVM Bridge] GC interval: %d ms, heap threshold: %d%%\n",
        g_jvm->garbage_collect_period_ms,
        g_jvm->heap_overload_percent
    );

    s32 ret = jvm_init(
        g_jvm,
        (c8 *)bootclasspath,
        (c8 *)classpath
    );

    if (ret) {

        printf(
            "[JVM Bridge] ERROR: jvm_init() failed: %d\n",
            ret
        );

        jvm_destroy(g_jvm);
        g_jvm = NULL;

        stop_runtime_log();

        return -3;
    }

    j2me_render_reg_natives(g_jvm);
    j2me_input_reg_natives(g_jvm);
    j2me_ui_reg_natives(g_jvm);
    j2me_audio_reg_natives(g_jvm);
    j2me_micro3d_gl_reg_natives(g_jvm);
    j2me_m3g_reg_natives(g_jvm);

    sys_properties_set_c(g_jvm, "os.name", "iOS");
    sys_properties_set_c(g_jvm, "app.save.root", save_root);
    sys_properties_set_c(g_jvm, "microedition.platform", "Apple/iPhone");
    sys_properties_set_c(g_jvm, "microedition.encoding", "UTF-8");
    sys_properties_set_c(g_jvm, "microedition.locale", "en");
    sys_properties_set_c(g_jvm, "microedition.profiles", "MIDP-2.0");
    sys_properties_set_c(g_jvm, "microedition.configuration", "CLDC-1.1");

    char sw[16];
    char sh[16];

    snprintf(sw, sizeof(sw), "%d", screen_width);
    snprintf(sh, sizeof(sh), "%d", screen_height);

    sys_properties_set_c(g_jvm, "j2me.screen.width", sw);
    sys_properties_set_c(g_jvm, "j2me.screen.height", sh);

    g_render_3d_scale =
        render_3d_scale > 0 ? render_3d_scale : 1;

    char ss[8];

    snprintf(
        ss,
        sizeof(ss),
        "%d",
        g_render_3d_scale
    );

    sys_properties_set_c(
        g_jvm,
        "micro3d.v3.fbo.scale",
        ss
    );

    if (fps_limit > 0) {

        char fl[8];

        snprintf(
            fl,
            sizeof(fl),
            "%d",
            fps_limit
        );

        sys_properties_set_c(
            g_jvm,
            "j2me.fps.limit",
            fl
        );
    }

    printf(
        "[JVM Bridge] Screen: %dx%d, scale: %d, FPS: %d\n",
        screen_width,
        screen_height,
        g_render_3d_scale,
        fps_limit
    );

    printf("[JVM Bridge] JVM initialized successfully\n");

    cpu_profiler_start();

    return 0;
}


// ============================================================
// Run MIDlet
// ============================================================

int jvm_bridge_run_midlet(const char *midlet_jar_path) {

    if (!g_jvm) {
        printf("[JVM Bridge] ERROR: JVM not initialized\n");
        return -1;
    }

    printf(
        "[JVM Bridge] Reading MIDlet JAR: %s\n",
        midlet_jar_path
    );

    char *manifest = load_midlet_manifest(midlet_jar_path);

    if (!manifest) {

        printf("[JVM Bridge] ERROR: Manifest extraction failed");

        return -4;
    }

    ArrayList *java_para = arraylist_create(0);

    if (!java_para) {
        free(manifest);
        return -5;
    }

    arraylist_push_back(
        java_para,
        (void *)midlet_jar_path
    );

    arraylist_push_back(
        java_para,
        (void *)manifest
    );

    printf("[JVM Bridge] Starting MIDletRunner\n");

    s32 ret = call_main(
        g_jvm,
        (c8 *)"javax/microedition/shell/MIDletRunner",
        java_para
    );

    arraylist_destroy(java_para);

    free(manifest);

    printf(
        "[JVM Bridge] MIDlet finished with code %d\n",
        ret
    );

    return ret;
}


// ============================================================
// Destroy
// ============================================================

void jvm_bridge_destroy(void) {

    cpu_profiler_stop();

    if (g_jvm) {

        printf("[JVM Bridge] Destroying JVM\n");

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

        atomic_store(
            &g_jvm_stop_requested,
            0
        );

        printf(
            "[JVM Bridge] JVM destroyed and native state cleaned up\n"
        );
    }

    g_midlet_runner_pthread_valid = 0;

    stop_runtime_log();
}


// ============================================================
// Stop request
// ============================================================

void jvm_bridge_request_stop(void) {

    printf("[JVM Bridge] Stop requested\n");

    atomic_store(
        &g_jvm_stop_requested,
        1
    );
}

int jvm_bridge_is_stop_requested(void) {
    return atomic_load(&g_jvm_stop_requested);
}
