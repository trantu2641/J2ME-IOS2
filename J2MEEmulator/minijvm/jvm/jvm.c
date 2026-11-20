#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include "jvm.h"
#include "garbage.h"
#include "jvm_util.h"
#include "jdwp.h"

/* Helper to check whether the JVM or current thread has been asked to stop/exit */
static inline s32 _jvm_should_stop(MiniJVM *jvm, Runtime *runtime) {
    if (runtime && runtime->thrd_info && runtime->thrd_info->is_stop) {
        return 1;
    }
    if (jvm) {
        s32 st = get_jvm_state(jvm);
        if (st == JVM_STATUS_STOPED || st == JVM_STATUS_UNKNOW) {
            return 1;
        }
        if (jvm->collector && jvm->collector->exit_flag) {
            return 1;
        }
    }
    return 0;
}

void thread_boundle(Runtime *runtime) {

    JClass *thread_clazz = classes_load_get_with_clinit_c(NULL, STR_CLASS_JAVA_LANG_THREAD, runtime);
    //为主线程创建Thread实例
    Instance *t = instance_create(runtime, thread_clazz);
    instance_hold_to_thread(t, runtime);
    runtime->thrd_info->jthread = t;//Thread.init currentThread() need this
    //runtime->clazz = thread_clazz;
    instance_init(t, runtime);
    //destroy old runtime
    Runtime *r = jthread_get_stackframe_value(runtime->jvm, t);
    if (r) {
        gc_move_objs_thread_2_gc(r);
        runtime_destroy(r);
        jthread_set_stackframe_value(runtime->jvm, t, NULL);
    }
    //bind new runtime
    jthread_set_stackframe_value(runtime->jvm, t, runtime);
    jthread_init(runtime->jvm, t);
    instance_release_from_thread(t, runtime);

    runtime->thrd_info->thread_status = THREAD_STATUS_RUNNING;
}

void thread_unboundle(Runtime *runtime) {

    runtime->thrd_info->is_suspend = 1;
    Instance *t = runtime->thrd_info->jthread;
    //主线程实例被回收
    jthread_dispose(t, runtime);
}

void print_exception(Runtime *runtime) {
#if _JVM_DEBUG_LOG_LEVEL >= 0
    if (runtime && runtime->jvm &&
        runtime->jvm->jvm_state == JVM_STATUS_RUNNING) {
        Utf8String *stacktrack = utf8_create();
        getExceptionStack(runtime, stacktrack);
        jvm_printf("%s\n", utf8_cstr(stacktrack));
        utf8_destroy(stacktrack);

        runtime_clear_stacktrack(runtime);
    }
#endif
}

#if _JVM_DEBUG_PROFILE

void profile_init() {
    memset(&profile_instructs, 0, sizeof(ProfileDetail) * INST_COUNT);
}

void profile_put(u8 instruct_code, s64 cost_add, s64 count_add) {
    ProfileDetail *h_s_v = &profile_instructs[instruct_code];

    spin_lock(&pro_lock);
    h_s_v->cost += cost_add;
    h_s_v->count += count_add;
    spin_unlock(&pro_lock);

};

void profile_print() {
    s32 i;
    jvm_printf("id           total    count      avg inst  \n");
    for (i = 0; i < INST_COUNT; i++) {
        ProfileDetail *pd = &profile_instructs[i];
        jvm_printf("%2x %15lld %8d %8lld %s\n",
                   i | 0xffffff00, pd->cost, pd->count, pd->count ? (pd->cost / pd->count) : 0, INST_NAME[i]);
    }
}

#endif

PeerClassLoader *classloader_create(MiniJVM *jvm) {
    return classloader_create_with_path(jvm, "");
}

PeerClassLoader *classloader_create_with_path(MiniJVM *jvm, c8 *path) {
    PeerClassLoader *class_loader = jvm_calloc(sizeof(PeerClassLoader));

    class_loader->jvm = jvm;
    //split classpath
    class_loader->classpath = arraylist_create(0);
    Utf8String *g_classpath = utf8_create_c(path);
    classloader_add_jar_path(class_loader, g_classpath);
    utf8_destroy(g_classpath);
    //创建类容器
    class_loader->classes = hashtable_create(UNICODE_STR_HASH_FUNC, UNICODE_STR_EQUALS_FUNC);

    return class_loader;
}

void classloader_destroy(PeerClassLoader *class_loader) {
    if (!class_loader) return;
    HashtableIterator hti;
    if (class_loader->classes) {
        hashtable_iterate(class_loader->classes, &hti);
        for (; hashtable_iter_has_more(&hti);) {
            HashtableValue v = hashtable_iter_next_value(&hti);
            if (class_loader->jvm && class_loader->jvm->collector) {
                gc_obj_release(class_loader->jvm->collector, v);
            }
        }
        hashtable_clear(class_loader->classes);
        hashtable_destroy(class_loader->classes);
        class_loader->classes = NULL;
    }
    if (class_loader->classpath) {
        s32 i;
        for (i = 0; i < class_loader->classpath->length; i++) {
            utf8_destroy(arraylist_get_value(class_loader->classpath, i));
        }
        arraylist_destroy(class_loader->classpath);
        class_loader->classpath = NULL;
    }

    jvm_free(class_loader);
}

void classloader_remove_all_class(PeerClassLoader *class_loader) {
    hashtable_clear(class_loader->classes);
}

void classloader_release_class_static_field(PeerClassLoader *class_loader) {
    HashtableIterator hti;
    hashtable_iterate(class_loader->classes, &hti);
    for (; hashtable_iter_has_more(&hti);) {
        HashtableValue v = hashtable_iter_next_value(&hti);
        JClass *clazz = (JClass *) (v);
        class_clear_refer(class_loader, clazz);
    }
}


void classloader_add_jar_path(PeerClassLoader *class_loader, Utf8String *jar_path) {

    Utf8String *libname = utf8_create();
    s32 i;
    for (i = 0;; i++) {
        utf8_split_get_part(jar_path, PATHSEPARATOR, i, libname);
        if (libname->length) {
            arraylist_push_back(class_loader->classpath, libname);
            libname = utf8_create();
        } else {
            break;
        }
    }
    utf8_destroy(libname);
}

void classloaders_add(MiniJVM *jvm, PeerClassLoader *pcl) {
    spin_lock(&jvm->lock_cloader);
    {
        arraylist_push_back_unsafe(jvm->classloaders, pcl);
    }
    spin_unlock(&jvm->lock_cloader);
}

void classloaders_remove(MiniJVM *jvm, PeerClassLoader *pcl) {
    spin_lock(&jvm->lock_cloader);
    {
        arraylist_remove_unsafe(jvm->classloaders, pcl);
    }
    spin_unlock(&jvm->lock_cloader);
}

PeerClassLoader *classLoaders_find_by_instance(MiniJVM *jvm, Instance *jloader) {
    PeerClassLoader *r = NULL;
    spin_lock(&jvm->lock_cloader);
    {
        s32 i;
        for (i = 0; i < jvm->classloaders->length; i++) {
            PeerClassLoader *pcl = arraylist_get_value_unsafe(jvm->classloaders, i);
            if (pcl->jloader == jloader) {
                r = pcl;
            }
        }
    }
    spin_unlock(&jvm->lock_cloader);
    return r;
}

void classloaders_clear_all_static(MiniJVM *jvm) {
    spin_lock(&jvm->lock_cloader);
    {
        s32 i;
        for (i = 0; i < jvm->classloaders->length; i++) {
            PeerClassLoader *pcl = arraylist_get_value_unsafe(jvm->classloaders, i);
            //release class static field
            classloader_release_class_static_field(pcl);
        }
    }
    spin_unlock(&jvm->lock_cloader);
}

void classloaders_destroy_all(MiniJVM *jvm) {
    if (!jvm) return;
    if (jvm->classloaders) {
        spin_lock(&jvm->lock_cloader);
        {
            s32 i;
            for (i = 0; i < jvm->classloaders->length; i++) {
                PeerClassLoader *pcl = arraylist_get_value_unsafe(jvm->classloaders, i);
                classloader_destroy(pcl);
            }
        }
        spin_unlock(&jvm->lock_cloader);
        spin_destroy(&jvm->lock_cloader);
        arraylist_destroy(jvm->classloaders);
        jvm->classloaders = NULL;
    }
    jvm->boot_classloader = NULL;
}

void set_jvm_state(MiniJVM *jvm, s32 state) {
    if (!jvm) return;
    jvm->jvm_state = state;
}

s32 get_jvm_state(MiniJVM *jvm) {
    if (!jvm) return JVM_STATUS_UNKNOW;
    return jvm->jvm_state;
}

void _on_jvm_sig_print(s32 no) {
    jvm_printf("[SIGNAL]jvm sig:%d  errno: %d , %s\n", no, errno, strerror(errno));
}

/* On embedded/mobile hosts (like iOS JarBox), avoid killing the whole host process on signal;
 * log and let session cleanup / crash handler take over cleanly. */
void _on_jvm_sig(s32 no) {
    _on_jvm_sig_print(no);
}

MiniJVM *jvm_create() {
    MiniJVM *jvm = jvm_calloc(sizeof(MiniJVM));
    if (!jvm) {
        jvm_printf("jvm create error.");
        return NULL;
    }
    jvm->env = &jnienv;
    jvm->max_heap_size = MAX_HEAP_SIZE_DEFAULT;
    jvm->heap_overload_percent = GARBAGE_OVERLOAD_DEFAULT;
    jvm->garbage_collect_period_ms = GARBAGE_PERIOD_MS_DEFAULT;
    return jvm;
}

s32 jvm_init(MiniJVM *jvm, c8 *p_bootclasspath, c8 *p_classpath) {
    if (!jvm) {
        jvm_printf("jvm not found.");
        return -1;
    }

    signal(SIGABRT, _on_jvm_sig);
    signal(SIGFPE, _on_jvm_sig);
    signal(SIGSEGV, _on_jvm_sig);
    signal(SIGTERM, _on_jvm_sig);
#ifdef SIGPIPE
    signal(SIGPIPE, _on_jvm_sig_print); //not exit when network sigpipe
#endif

    set_jvm_state(jvm, JVM_STATUS_INITING);

    if (!p_classpath) {
        p_classpath = "./";
    }
    if (!jvm->startup_dir) {
        jvm->startup_dir = utf8_create_c("./");
    }
    //
    open_log();

#if _JVM_DEBUG_PROFILE
    profile_init();
#endif
    //
    init_jni_func_table(jvm);

    //创建线程容器
    jvm->thread_list = arraylist_create(0);
    jvm->shutdown_hook = arraylist_create(0);
    //创建垃圾收集器
    gc_create(jvm);

    //本地方法库
    jvm->native_libs = arraylist_create(0);
    reg_std_native_lib(jvm);
    reg_net_native_lib(jvm);
    reg_reflect_native_lib(jvm);

    //创建jstring 相关容器
    jvm->table_jstring_const = hashtable_create(UNICODE_STR_HASH_FUNC, UNICODE_STR_EQUALS_FUNC);
    hashtable_register_free_functions(jvm->table_jstring_const, (HashtableKeyFreeFunc) utf8_destroy, NULL);

    spin_init(&jvm->lock_cloader, 0);
    jvm->boot_classloader = classloader_create_with_path(jvm, p_bootclasspath);
    jvm->classloaders = arraylist_create(4);
    classloaders_add(jvm, jvm->boot_classloader);

    //装入系统属性
    sys_properties_load(jvm);
    sys_properties_set_c(jvm, STR_VM_JAVA_CLASS_PATH, p_classpath);
    sys_properties_set_c(jvm, STR_VM_SUN_BOOT_CLASS_PATH, p_bootclasspath);
    sys_properties_set_c(jvm, STR_VM_JAVA_CLASS_VERSION, "52.0");
    Utf8String *tmpstr = utf8_create();
    os_get_lang(tmpstr);
    sys_properties_set_c(jvm, STR_VM_USER_LANGUAGE, utf8_cstr(tmpstr));
    os_get_uuid(jvm, tmpstr);
    sys_properties_set_c(jvm, STR_VM_UUID, utf8_cstr(tmpstr));
    utf8_destroy(tmpstr);

    //启动调试器
    jdwp_start_server(jvm);

    set_jvm_state(jvm, JVM_STATUS_RUNNING);

    //init load thread, string etc
    Runtime *runtime = runtime_create(jvm);
    runtime->thrd_info->type = THREAD_TYPE_NORMAL;
    Utf8String *clsName = utf8_create_c(STR_CLASS_JAVA_LANG_INTEGER);
    JClass *c = classes_load_get_with_clinit(NULL, clsName, runtime);
    if (!c) {
        jvm_printf("[ERROR]maybe bootstrap classpath misstake: %s \n", p_bootclasspath);
        return -1;
    }
    //load bootstrap class
    utf8_clear(clsName);
    utf8_append_c(clsName, STR_CLASS_JAVA_LANG_THREAD);
    classes_load_get_with_clinit(NULL, clsName, runtime);

    utf8_clear(clsName);
    utf8_append_c(clsName, STR_CLASS_SUN_MISC_LAUNCHER);
    classes_load_get_with_clinit(NULL, clsName, runtime);
    //for interrupted thread
    utf8_clear(clsName);
    utf8_append_c(clsName, STR_CLASS_JAVA_LANG_INTERRUPTED);//must load this class ,because it will be used when thread interrupt ,but it can not load when that thread is marked as interrupted
    JClass *c2;
    c2 = classes_load_get_with_clinit(NULL, clsName, runtime);
    instance_create(runtime, c2);
    utf8_clear(clsName);


    if (!jvm->collector->runtime->thrd_info->jthread) {
        Instance *inst = instance_create(runtime, classes_get_c(jvm, NULL, STR_CLASS_JAVA_LANG_THREAD));
        jvm->collector->runtime->thrd_info->jthread = inst;
        hashset_put(jvm->collector->objs_holder, inst);
    }

    utf8_destroy(clsName);
    gc_move_objs_thread_2_gc(runtime);
    runtime_destroy(runtime);
    runtime = NULL;

    //启动垃圾回收
    gc_resume(jvm->collector);

#if _JVM_DEBUG_LOG_LEVEL > 0
    jvm_printf("[INFO]jvm inited\n");
#endif
    return 0;
}

void jvm_destroy(MiniJVM *jvm) {
    if (!jvm) return;

    /* 1. Mark JVM state as stopping immediately so bytecode loops & native checks see it */
    set_jvm_state(jvm, JVM_STATUS_STOPED);
    if (jvm->collector) {
        jvm->collector->exit_flag = 1;
    }

    /* 2. Stop JDWP server early so debugging sockets/threads do not block teardown */
    jdwp_stop_server(jvm);

    /* 3. Signal all running Java/native threads to stop */
    thread_stop_all(jvm);

    /* 4. Run shutdown hooks with a per-hook safety wait */
    Runtime *parent = runtime_create(jvm);
    if (parent && jvm->shutdown_hook) {
        while (jvm->shutdown_hook->length) {
            Instance *inst = arraylist_get_value(jvm->shutdown_hook, 0);
            arraylist_remove_at(jvm->shutdown_hook, 0);
            if (inst) {
                thrd_t t = jthread_start(inst, parent);
                thrd_join(t, NULL);
            }
        }
    }
    if (parent) {
        runtime_destroy(parent);
        parent = NULL;
    }

    /* Re-assert stop flags after hooks in case a hook spawned a thread */
    set_jvm_state(jvm, JVM_STATUS_STOPED);
    thread_stop_all(jvm);

#if _JVM_DEBUG_LOG_LEVEL > 0
    jvm_printf("[INFO]waiting for all threads to terminate\n");
#endif
    /* 5. Wait thoroughly for threads to exit; re-issue stop signal periodically if needed */
    {
        s32 wait_count = 0;
        s32 max_wait = 500; // 500 * 20ms = 10 seconds max wait
        while (threadlist_count_active(jvm) > 0 && wait_count < max_wait) {
            if ((wait_count % 25) == 0) {
                thread_stop_all(jvm);
            }
            threadSleep(20);
            wait_count++;
        }
        if (threadlist_count_active(jvm) > 0) {
            jvm_printf("[WARN]%d threads still active after %dms timeout, marking zombie\n",
                       threadlist_count_active(jvm), max_wait * 20);
            thread_zombie_all(jvm);
        }
    }

    /* 6. Tear down classloaders, GC, and JVM containers only after threads have stopped */
    classloaders_clear_all_static(jvm);
    classloaders_destroy_all(jvm);

    gc_destroy(jvm);

    if (jvm->table_jstring_const) {
        hashtable_destroy(jvm->table_jstring_const);
        jvm->table_jstring_const = NULL;
    }
    thread_lock_dispose(&jvm->threadlock);
    if (jvm->thread_list) {
        arraylist_destroy(jvm->thread_list);
        jvm->thread_list = NULL;
    }
    if (jvm->shutdown_hook) {
        arraylist_destroy(jvm->shutdown_hook);
        jvm->shutdown_hook = NULL;
    }
    native_lib_destroy(jvm);
    sys_properties_dispose(jvm);
    close_log();
#if _JVM_DEBUG_LOG_LEVEL > 0
    jvm_printf("[INFO]jvm destroyed\n");
#endif
    set_jvm_state(jvm, JVM_STATUS_UNKNOW);
    if (jvm->startup_dir) {
        utf8_destroy(jvm->startup_dir);
        jvm->startup_dir = NULL;
    }
    jvm_free(jvm);
}

s32 call_main(MiniJVM *jvm, c8 *p_mainclass, ArrayList *java_para) {
    if (!jvm) {
        jvm_printf("jvm not found .\n");
        return 1;
    }
    Runtime *runtime = runtime_create(jvm);
    runtime->thrd_info->type = THREAD_TYPE_NORMAL;
    thread_boundle(runtime);

    //准备参数
    s32 count = java_para ? java_para->length : 0;
    Utf8String *ustr = utf8_create_c(STR_CLASS_JAVA_LANG_STRING);
    Instance *arr = jarray_create_by_type_name(runtime, count, ustr, NULL);
    instance_hold_to_thread(arr, runtime);
    utf8_destroy(ustr);
    s32 i;
    for (i = 0; i < count; i++) {
        Utf8String *utfs = utf8_create_c(arraylist_get_value(java_para, i));
        Instance *jstr = jstring_create(utfs, runtime);
        jarray_set_field(arr, i, (intptr_t) jstr);
        utf8_destroy(utfs);
    }
    push_ref(runtime->stack, arr);
    instance_release_from_thread(arr, runtime);

    c8 *p_methodname = "main";
    c8 *p_methodtype = "([Ljava/lang/String;)V";
    s32 ret = call_method(jvm, p_mainclass, p_methodname, p_methodtype, runtime);

    thread_unboundle(runtime);
    runtime_destroy(runtime);
    return ret;
}


s32 call_method(MiniJVM *jvm, c8 *p_classname, c8 *p_methodname, c8 *p_methoddesc, Runtime *p_runtime) {
    if (p_runtime && p_runtime->jvm != jvm) {
        jvm_printf("[ERROR]runtime not adapted to jvm .\n");
        return RUNTIME_STATUS_ERROR;
    }
    if (!jvm) {
        jvm_printf("[ERROR]jvm not found .\n");
        return RUNTIME_STATUS_ERROR;
    }
    if (_jvm_should_stop(jvm, p_runtime)) {
        return RUNTIME_STATUS_ERROR;
    }
    //创建运行时栈
    Runtime *runtime = p_runtime;
    if (!p_runtime) {
        runtime = runtime_create(jvm);
        runtime->thrd_info->type = THREAD_TYPE_NORMAL;
        thread_boundle(runtime);
    }

    //开始装载类

    Utf8String *str_mainClsName = utf8_create_c(p_classname);
    utf8_replace_c(str_mainClsName, ".", "/");

    //find systemclassloader
    Instance *jloader = NULL;
    s32 ret = execute_method_impl(jvm->shortcut.launcher_getSystemClassLoader, runtime);
    if (!ret) {
        jloader = pop_ref(runtime->stack);
    } else {
        print_exception(runtime);
    }
    //装入主类
    JClass *clazz = classes_load_get_with_clinit(jloader, str_mainClsName, runtime);


    ret = 0;
    if (clazz) {
        Utf8String *methodName = utf8_create_c(p_methodname);
        Utf8String *methodType = utf8_create_c(p_methoddesc);

        MethodInfo *m = find_methodInfo_by_name(str_mainClsName, methodName, methodType, clazz->jloader, runtime);
        if (m) {


            s64 start = currentTimeMillis();
#if _JVM_DEBUG_LOG_LEVEL > 0
            jvm_printf("\n[INFO]main thread start\n");
#endif
            //调用主方法
            if (jvm->jdwp_enable) {
#if _JVM_DEBUG_LOG_LEVEL > 0
                jvm_printf("[JDWP]jdwp listening (port:%s) ...\n", JDWP_TCP_PORT);
#endif
                if (jvm->jdwp_suspend_on_start) {
                    jvm_printf("[JDWP]suspend on start, waitting for connect... \n");
                    jthread_suspend(runtime);
                }
            }//jdwp 会启动调试器

            runtime->method = NULL;
            runtime->clazz = clazz;
            ret = execute_method(m, runtime);
            if (ret == RUNTIME_STATUS_EXCEPTION) {
                print_exception(runtime);
            }
#if _JVM_DEBUG_LOG_LEVEL > 0
            jvm_printf("[INFO]main thread over %llx , return %d , spent : %lld\n",
                       (s64) (intptr_t) runtime->thrd_info->jthread, ret, (currentTimeMillis() - start));
#endif

#if _JVM_DEBUG_PROFILE
            profile_print();
#endif


        }
        utf8_destroy(methodName);
        utf8_destroy(methodType);
    } else {
        jvm_printf("[ERROR]main class not found: %s\n", p_classname);
        ret = RUNTIME_STATUS_ERROR;
    }
    if (!p_runtime) {
        thread_unboundle(runtime);
        runtime_destroy(runtime);
    }
    utf8_destroy(str_mainClsName);
    return ret;
}


s32 execute_method(MethodInfo *method, Runtime *runtime) {
    if (!runtime || !method) {
        return RUNTIME_STATUS_ERROR;
    }
    if (_jvm_should_stop(runtime->jvm, runtime)) {
        return RUNTIME_STATUS_ERROR;
    }
    // if not detect the son ,may cause jthread enter fake blocking state,
    // eg: call_bc-> call_native->(reenter) call_bc->ret_bc(fake_blocking)->ret_native->ret_bc
    // only the outer thread top call the java bytecode ,need check block state
    if (runtime->thrd_info->top_runtime->son == NULL) {// is top call bc, not reenter bc
        jthread_block_exit(runtime);
    }
    s32 ret = execute_method_impl(method, runtime);
    if (runtime->thrd_info->top_runtime->son == NULL) {
        jthread_block_enter(runtime);
    }
    return ret;
}
