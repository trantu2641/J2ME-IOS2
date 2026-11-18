#ifndef JVM_BRIDGE_H
#define JVM_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct _MiniJVM MiniJVM;

extern int g_render_3d_scale;

void jvm_bridge_register_main_thread(void);

int jvm_bridge_init(const char *res_root,
                    const char *save_root,
                    const char *midlet_jar,
                    int screen_width,
                    int screen_height,
                    int render_3d_scale,
                    int fps_limit);

int jvm_bridge_run_midlet(const char *midlet_jar_path);

int jvm_bridge_session_create(const char *res_root,
                              const char *save_root,
                              const char *midlet_jar,
                              int screen_width,
                              int screen_height,
                              int render_3d_scale,
                              int fps_limit);

int jvm_bridge_session_start(int session_id);
void jvm_bridge_session_set_active(int session_id);
int jvm_bridge_session_is_running(int session_id);
void jvm_bridge_session_request_stop(int session_id);
void jvm_bridge_session_destroy(int session_id);
void jvm_bridge_session_destroy_all(void);
int jvm_bridge_is_stop_requested_for_vm(MiniJVM *jvm);

/*
 * Per-session network proxy configuration.
 * type: 0 = none, 1 = HTTP CONNECT, 2 = SOCKS5
 */
void jvm_bridge_session_set_proxy(int session_id,
                                  int proxy_type,
                                  const char *host,
                                  int port,
                                  const char *username,
                                  const char *password);

int jvm_bridge_get_proxy_for_vm(MiniJVM *jvm,
                                int *out_type,
                                char *out_host,
                                int host_cap,
                                int *out_port,
                                char *out_user,
                                int user_cap,
                                char *out_pass,
                                int pass_cap);

/*
 * Callback invoked when a MIDlet session exits naturally (e.g. notifyDestroyed()).
 */
typedef void (*j2me_session_exit_callback)(int session_id, int exit_code);
void jvm_bridge_set_session_exit_callback(j2me_session_exit_callback callback);

void jvm_bridge_destroy(void);
void jvm_bridge_request_stop(void);
int jvm_bridge_is_stop_requested(void);

int jvm_bridge_extract_jar_entry(const char *jar_path,
                                 const char *entry_name,
                                 void **out_data,
                                 int64_t *out_size);
void jvm_bridge_release_jar_entry(void *data);

#ifdef __cplusplus
}
#endif

#endif /* JVM_BRIDGE_H */
