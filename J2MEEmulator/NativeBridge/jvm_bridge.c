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

static MiniJVM *g_jvm = NULL;
static atomic_int g_jvm_stop_requested = 0;

int g_render_3d_scale = 1;

/*
 * Read META-INF/MANIFEST.MF using MiniJVM's native ZIP reader.
 *
 * This avoids java.util.zip.ZipFile, which is not part of CLDC 1.1.
 */
static char *load_midlet_manifest(const char *jar_path) {

    if (!jar_path || !jar_path[0]) {
        printf("[JVM Bridge] ERROR: Empty JAR path\n");
        return NULL;
    }

    s64 manifest_size = zip_get_file_unzip_size(
        jar_path,
        "META-INF/MANIFEST.MF"
    );

    if (manifest_size <= 0 || manifest_size > 1024 * 1024) {
        printf(
            "[JVM Bridge] ERROR: Invalid or missing MIDlet manifest, size=%lld\n",
            (long long)manifest_size
        );
        return NULL;
    }

    char *manifest = (char *)malloc((size_t)manifest_size + 1);

    if (!manifest) {
        printf("[JVM Bridge] ERROR: Cannot allocate manifest buffer\n");
        return NULL;
    }

    memset(manifest, 0, (size_t)manifest_size + 1);

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

    /*
     * Stop state is reset after the previous JVM is destroyed.
     */

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
        return -2;
    }

    g_jvm->jdwp_enable = 0;
    g_jvm->jdwp_suspend_on_start = 0;
    g_jvm->max_heap_size = 128 * 1024 * 1024;
    g_jvm->garbage_collect_period_ms = 500;
    g_jvm->heap_overload_percent = 70;

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

        return -3;
    }

    /*
     * Register native methods.
     */

    j2me_render_reg_natives(g_jvm);
    j2me_input_reg_natives(g_jvm);
    j2me_ui_reg_natives(g_jvm);
    j2me_audio_reg_natives(g_jvm);
    j2me_micro3d_gl_reg_natives(g_jvm);
    j2me_m3g_reg_natives(g_jvm);

    /*
     * Standard J2ME properties.
     */

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

    /*
     * 3D supersampling.
     */

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

    /*
     * FPS limit.
     */

    if (fps_limit > 0) {
        char fl[8];

        snprintf(fl, sizeof(fl), "%d", fps_limit);

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

    return 0;
}

/*
 * Run the MIDlet.
 *
 * Java arguments:
 * args[0] = JAR path
 * args[1] = raw manifest text
 */
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
        printf("[JVM Bridge] ERROR: Manifest extraction failed\n");
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

void jvm_bridge_destroy(void) {

    if (g_jvm) {

        printf("[JVM Bridge] Destroying JVM\n");

        /*
         * Stop rendering before JVM destruction.
         */

        j2me_render_stop();

        /*
         * Stop threads.
         */

        g_jvm->collector->exit_flag = 1;

        thread_stop_all(g_jvm);

        /*
         * Destroy JVM.
         */

        jvm_destroy(g_jvm);

        g_jvm = NULL;

        /*
         * Clean native subsystems.
         */

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
}

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
