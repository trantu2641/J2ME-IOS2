#ifndef JVM_BRIDGE_H
#define JVM_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Forward declaration.
 *
 * jvm_bridge.h chỉ dùng MiniJVM dưới dạng con trỏ nên không cần
 * include jvm.h ở đây.
 *
 * jvm.h cũng khai báo MiniJVM bằng:
 *
 * typedef struct _MiniJVM MiniJVM;
 */
typedef struct _MiniJVM MiniJVM;

/**
 * 3D supersampling scale factor.
 *
 * Shared by M3G and MascotCapsule.
 * Set by jvm_bridge_init(), read by j2me_m3g_jni.c
 * and MC3D via system property.
 */
extern int g_render_3d_scale;

/*
 * Register the current thread as the JVM main thread.
 */
void jvm_bridge_register_main_thread(void);

/*
 * Initialize the JVM bridge.
 */
int jvm_bridge_init(const char *res_root,
                    const char *save_root,
                    const char *midlet_jar,
                    int screen_width,
                    int screen_height,
                    int render_3d_scale,
                    int fps_limit);

/*
 * Run a MIDlet from a JAR path.
 */
int jvm_bridge_run_midlet(const char *midlet_jar_path);

/*
 * Create a new JVM/MIDlet session.
 */
int jvm_bridge_session_create(const char *res_root,
                              const char *save_root,
                              const char *midlet_jar,
                              int screen_width,
                              int screen_height,
                              int render_3d_scale,
                              int fps_limit);

/*
 * Start an existing session.
 */
int jvm_bridge_session_start(int session_id);

/*
 * Set which session is currently active.
 */
void jvm_bridge_session_set_active(int session_id);

/*
 * Check whether a session is still running.
 */
int jvm_bridge_session_is_running(int session_id);

/*
 * Request a session to stop.
 */
void jvm_bridge_session_request_stop(int session_id);

/*
 * Destroy a session.
 */
void jvm_bridge_session_destroy(int session_id);

/*
 * Destroy all sessions.
 */
void jvm_bridge_session_destroy_all(void);

/*
 * Check whether stop has been requested for a specific MiniJVM.
 *
 * MiniJVM is forward-declared above because this header only needs
 * the pointer type.
 */
int jvm_bridge_is_stop_requested_for_vm(MiniJVM *jvm);

/*
 * Destroy the JVM bridge.
 */
void jvm_bridge_destroy(void);

/*
 * Request global JVM stop.
 */
void jvm_bridge_request_stop(void);

/*
 * Check whether global JVM stop has been requested.
 */
int jvm_bridge_is_stop_requested(void);

#ifdef __cplusplus
}
#endif

#endif /* JVM_BRIDGE_H */
