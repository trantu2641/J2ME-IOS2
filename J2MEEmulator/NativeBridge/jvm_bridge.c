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
#include <stdatomic.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>

#include <mach/mach.h>
#include <mach/thread_info.h>

static MiniJVM *g_jvm = NULL;
static atomic_int g_jvm_stop_requested = 0;

static int g_saved_stdout = -1;
static int g_saved_stderr = -1;
static int g_log_redirected = 0;

int g_render_3d_scale = 1;

// ============================================================
// CPU profiler
// ============================================================

#define CPU_PROFILE_TOP_THREADS 8
#define CPU_PROFILE_INTERVAL_SECONDS 5

typedef struct CPUThreadSample {
    double cpu_percent;
    mach_port_t thread_port;
    char name[64];
} CPUThreadSample;

static pthread_t g_cpu_profiler_thread;
static atomic_int g_cpu_profiler_running = 0;
static int g_cpu_profiler_started = 0;

static void *cpu_profiler_main(void *argument) {

    (void)argument;

    pthread_setname_np("JarBoxCPUProfiler");

    while (atomic_load_explicit(
        &g_cpu_profiler_running,
        memory_order_relaxed
    )) {

        // Sleep in one-second pieces so shutdown is responsive.
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
                mach_port_deallocate(
                    mach_task_self(),
                    thread_list[i]
                );
                continue;
            }

            double cpu_percent =
                ((double)info.cpu_usage * 100.0)
                / (double)TH_USAGE_SCALE;

            if (cpu_percent > 0.1) {

                total_cpu += cpu_percent;
                active_threads++;

                CPUThreadSample sample = {0};

                sample.cpu_percent = cpu_percent;
                sample.thread_port = thread_list[i];

                pthread_t native_thread =
                    pthread_from_mach_thread_np(thread_list[i]);

                if (native_thread != NULL) {
                    pthread_getname_np(
                        native_thread,
                        sample.name,
                        sizeof(sample.name)
                    );
                }

                if (sample.name[0] == '\0') {
                    snprintf(
                        sample.name,
                        sizeof(sample.name),
                        "thread-%u",
                        (unsigned int)thread_list[i]
                    );
                }

                // Keep the highest CPU threads in descending order.
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

        printf(
            "[CPU] total=%.1f%% active=%d threads=%u",
            total_cpu,
            active_threads,
            thread_count
        );

        for (
            int i = 0;
            i < CPU_PROFILE_TOP_THREADS;
            i++
        ) {

            if (top[i].cpu_percent <= 0.1) {
                break;
            }

            printf(
                " | %s=%.1f%%",
                top[i].name,
                top[i].cpu_percent
            );
        }

        printf("\n");
    }

    return NULL;
}

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
        "[CPU Profiler] Started. Sampling every %d seconds.\n",
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

    // Previously 500ms, causing very frequent full GC cycles.
    // Increase to 2000ms while keeping heap pressure collection enabled.
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

    // Start thread CPU profiler after JVM initialization.
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

    // Stop and join the profiler before destroying the JVM.
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
