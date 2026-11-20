#include <errno.h>
#include "jvm.h"
#include "garbage.h"
#include "jvm_util.h"

s32 _gc_thread_run(void *para);

void _dump_refer(GcCollector *collector);

void _gc_get_obj_name(GcCollector *collector, void *memblock, Utf8String *name);

void _garbage_clear(GcCollector *collector);

void _gc_copy_objs(MiniJVM *jvm);

s32 _gc_big_search(GcCollector *collector);

s32 _gc_pause_the_world(MiniJVM *jvm);

s32 _gc_resume_the_world(MiniJVM *jvm);

s32 _gc_wait_thread_suspend(MiniJVM *jvm, Runtime *runtime);

void _gc_mark_object(GcCollector *collector, __refer ref, u8 flag_cnt);

s32 _gc_copy_objs_from_thread(Runtime *pruntime);

s64 _garbage_collect(GcCollector *collector);

void _gc_print_obj_list(GcCollector *pType);

s32 gc_create(MiniJVM *jvm) {
    GcCollector *collector = jvm_calloc(sizeof(GcCollector));
    jvm->collector = collector;
    collector->jvm = jvm;
    collector->objs_holder = hashset_create();
    collector->objs_2_count = hashtable_create(UNICODE_STR_HASH_FUNC, UNICODE_STR_EQUALS_FUNC);

    collector->runtime_refer_copy = arraylist_create(256);

    collector->runtime = runtime_create(jvm);
    collector->runtime->thrd_info->type = THREAD_TYPE_GC;
    collector->_garbage_thread_status = GARBAGE_THREAD_PAUSE;
    thread_lock_init(&jvm->threadlock);

    collector->lastgc = currentTimeMillis();

    s32 rc = thrd_create(&collector->garbage_thread, _gc_thread_run, collector);
    if (rc != thrd_success) {
        jvm_printf("ERROR: garbage thread can't create is %d\n", rc);
    }
    return 0;
}

void gc_destroy(MiniJVM *jvm) {
    if (!jvm || !jvm->collector) return;
    GcCollector *collector = jvm->collector;
    gc_stop(collector);
    vm_share_lock(jvm);
    int wait_guard = 0;
    while (collector->_garbage_thread_status != GARBAGE_THREAD_DEAD && wait_guard < 50) {
        vm_share_timedwait(jvm, 100);
        wait_guard++;
    }
    collector->_garbage_thread_status = GARBAGE_THREAD_DEAD;
    vm_share_unlock(jvm);

    _garbage_clear(collector);

    if (collector->objs_holder) {
        hashset_destroy(collector->objs_holder);
        collector->objs_holder = NULL;
    }

    if (collector->runtime_refer_copy) {
        arraylist_destroy(collector->runtime_refer_copy);
        collector->runtime_refer_copy = NULL;
    }
    if (collector->objs_2_count) {
        hashtable_destroy(collector->objs_2_count);
        collector->objs_2_count = NULL;
    }

    if (collector->runtime) {
        runtime_destroy(collector->runtime);
        collector->runtime = NULL;
    }
    jvm_free(collector);
    jvm->collector = NULL;
}

void _garbage_clear(GcCollector *collector) {
    if (!collector || !collector->jvm) return;
#if _JVM_DEBUG_LOG_LEVEL > 1
    jvm_printf("[INFO]garbage clear start\n");
    jvm_printf("[INFO]objs size :%lld\n", collector->obj_count);
#endif
    MiniJVM *jvm = collector->jvm;

    while (_garbage_collect(collector) > 0);

#if _JVM_DEBUG_LOG_LEVEL > 1
    jvm_printf("[INFO]objs size :%lld\n", collector->obj_count);
    jvm_printf("[INFO]clear class static field \n");
#endif
    if (collector->objs_holder) {
        hashset_clear(collector->objs_holder);
    }
    if (jvm->classloaders) {
        classloaders_clear_all_static(jvm);
    }
    while (_garbage_collect(collector) > 0);

#if _JVM_DEBUG_LOG_LEVEL > 1
    jvm_printf("[INFO]objs size :%lld\n", collector->obj_count);
    jvm_printf("[INFO]clear boot classes \n");
#endif
    if (jvm->boot_classloader) {
        classloader_remove_all_class(jvm->boot_classloader);
    }
    while (_garbage_collect(collector) > 0);
    if (jvm->classloaders) {
        classloaders_destroy_all(jvm);
    }

#if _JVM_DEBUG_LOG_LEVEL > 1
    jvm_printf("[INFO]objs size :%lld\n", collector->obj_count);
#endif
}

void gc_pause(GcCollector *collector) {
    if (!collector || !collector->jvm) return;
    vm_share_lock(collector->jvm);
    collector->_garbage_thread_status = GARBAGE_THREAD_PAUSE;
    vm_share_unlock(collector->jvm);
}

void gc_resume(GcCollector *collector) {
    if (!collector || !collector->jvm) return;
    vm_share_lock(collector->jvm);
    collector->_garbage_thread_status = GARBAGE_THREAD_NORMAL;
    vm_share_unlock(collector->jvm);
}

void gc_stop(GcCollector *collector) {
    if (!collector || !collector->jvm) return;
    vm_share_lock(collector->jvm);
    collector->_garbage_thread_status = GARBAGE_THREAD_STOP;
    vm_share_unlock(collector->jvm);
}

//===============================   inner  ====================================
void _gc_add_obj_count(GcCollector *collector, MemoryBlock *mb) {
    if (!collector || !mb || mb->type == MEM_TYPE_CLASS) {
        return;
    }
    if (collector->_garbage_thread_status != GARBAGE_THREAD_NORMAL) {
        return;
    }
    if (!mb->clazz || !mb->clazz->name || !collector->objs_2_count) {
        return;
    }
    HashtableValue v = hashtable_get(collector->objs_2_count, mb->clazz->name);
    if (!v) {
        s64 count = 1;
        if (sizeof(void *) == 8) {
            count = count << 32;
            count = count | mb->heap_size;
        }
        hashtable_put(collector->objs_2_count, mb->clazz->name, (HashtableValue) (intptr_t) count);
    } else {
        s64 val = (s64) (intptr_t) v;
        if (sizeof(void *) == 8) {
            s32 pc = (s32) (val >> 32);
            s32 msize = (s32) val;
            pc++;
            val = ((s64) pc) << 32;
            msize += mb->heap_size;
            val = val | msize;
        } else {
            val++;
        }
        hashtable_put(collector->objs_2_count, mb->clazz->name, (HashtableValue) (intptr_t) val);
    }
}

void _gc_print_obj_list(GcCollector *collector) {
    if (!collector || !collector->objs_2_count) return;
    jvm_printf("[INFO]--------------------------types: %d\n", collector->objs_2_count->entries);
    jvm_printf("[INFO] -----count----- ---memo size---  ----name---\n");
    HashtableIterator hti;
    hashtable_iterate(collector->objs_2_count, &hti);
    for (; hashtable_iter_has_more(&hti);) {
        Utf8String *clsName = hashtable_iter_next_key(&hti);
        s64 val = (s64) (intptr_t) hashtable_get(collector->objs_2_count, clsName);
        s32 pc = 0, msize = 0;
        if (sizeof(void *) == 8) {
            pc = (s32) (val >> 32);
            msize = (s32) val;
        } else {
            pc = (s32) val;
        }
        jvm_printf("[INFO] %15d %15d  %s\n", pc, msize, utf8_cstr(clsName));
    }
    hashtable_clear(collector->objs_2_count);
    jvm_printf("[INFO]--------------------------\n");
}

//=============================   debug ===================================
void _gc_get_obj_name(GcCollector *collector, void *memblock, Utf8String *name) {
    MemoryBlock *mb = (MemoryBlock *) memblock;
    if (!mb) {
        utf8_append_c(name, "NULL");
    } else {
        switch (mb->type) {
            case MEM_TYPE_CLASS: {
                utf8_append_c(name, "C");
                JClass *clazz = collector->_garbage_thread_status == GARBAGE_THREAD_NORMAL ? (JClass *) mb : NULL;
                if (clazz)
                    utf8_append(name, clazz->name);
                break;
            }
            case MEM_TYPE_INS: {
                Instance *ins = (Instance *) mb;
                utf8_append_c(name, "L");
                JClass *clazz = collector->_garbage_thread_status == GARBAGE_THREAD_NORMAL ? ins->mb.clazz : NULL;
                if (clazz)
                    utf8_append(name, clazz->name);
                utf8_append_c(name, ";");
                break;
            }
            case MEM_TYPE_ARR: {
                Instance *arr = (Instance *) mb;
                utf8_append_c(name, "Array{");
                JClass *clazz = collector->_garbage_thread_status == GARBAGE_THREAD_NORMAL ? arr->mb.clazz : NULL;
                if (clazz)
                    utf8_append(name, clazz->name);
                utf8_append_c(name, "}");
                break;
            }
            default:
                utf8_append_c(name, "ERROR");
        }
    }
}

s32 _getMBSize(MemoryBlock *mb) {
    return mb ? mb->heap_size : 0;
}

void _dump_refer(GcCollector *collector) {
    if (!collector) return;
    MemoryBlock *mb = collector->tmp_header;
    while (mb) {
        Utf8String *name = utf8_create();
        _gc_get_obj_name(collector, mb, name);
        jvm_printf("   %s[%llx] \n", utf8_cstr(name), (s64) (intptr_t) mb);
        utf8_destroy(name);
        mb = mb->next;
    }
}

void gc_dump_runtime(GcCollector *collector) {
    if (!collector || !collector->jvm || !collector->jvm->thread_list) return;
    s32 i;
    Utf8String *name = utf8_create();
    for (i = 0; i < collector->jvm->thread_list->length; i++) {
        Runtime *runtime = threadlist_get(collector->jvm, i);
        if (!runtime) continue;

        jvm_printf("[INFO]============ runtime dump [%llx] ============\n", (s64) (intptr_t) runtime);
        s32 j;
        StackEntry *entry;
        RuntimeStack *stack = runtime->stack;
        if (!stack) continue;
        for (j = 0; j < stack_size(stack); j++) {
            entry = stack->store + j;
            if (entry->rvalue) {
                __refer ref = entry->rvalue;
                if (ref) {
                    utf8_clear(name);
                    _gc_get_obj_name(collector, ref, name);
                    jvm_printf("   %s[%llx] \n", utf8_cstr(name), (s64) (intptr_t) ref);
                }
            }
        }
    }
    utf8_destroy(name);
}

s64 g_native_extra_heap = 0;

s64 gc_sum_heap(GcCollector *collector) {
    if (!collector || !collector->jvm) return 0;
    s64 hsize = threadlist_sum_heap(collector->jvm);
    spin_lock(&collector->lock);
    {
        hsize += collector->obj_heap_size;
    }
    spin_unlock(&collector->lock);
    s64 native_extra = __atomic_load_n(&g_native_extra_heap, __ATOMIC_RELAXED);
    if (native_extra > 0) hsize += native_extra;
    return hsize;
}

s32 _gc_thread_run(void *para) {
    GcCollector *collector = (GcCollector *) para;
    MiniJVM *jvm = collector->jvm;

    while (1) {
        s64 cur_mil = currentTimeMillis();

        if (collector->_garbage_thread_status == GARBAGE_THREAD_STOP) {
            break;
        }
        if (collector->_garbage_thread_status == GARBAGE_THREAD_PAUSE) {
            threadSleep(1000);
            continue;
        }
        if (cur_mil - collector->lastgc < jvm->garbage_collect_period_ms) {
            threadSleep(jvm->garbage_collect_period_ms / 2);
            continue;
        }

        s64 heap = gc_sum_heap(collector);
        s64 threshold = jvm->max_heap_size * jvm->heap_overload_percent / 100;
        s64 native_extra = __atomic_load_n(&g_native_extra_heap, __ATOMIC_RELAXED);
        if (cur_mil - collector->lastgc > jvm->garbage_collect_period_ms || heap >= threshold) {
            s64 heap_before = heap;
            _garbage_collect(collector);
            s64 heap_after = gc_sum_heap(collector);
            s64 native_after = __atomic_load_n(&g_native_extra_heap, __ATOMIC_RELAXED);
            jvm_printf("[GC] collected: java %lldKB→%lldKB, native %lldKB, total %lldKB→%lldKB (threshold %lldKB) objs=%lld\n",
                       (heap_before - native_extra) / 1024, (heap_after - native_after) / 1024,
                       native_after / 1024,
                       heap_before / 1024, heap_after / 1024,
                       threshold / 1024,
                       (s64)collector->obj_count);
            collector->lastgc = cur_mil;
        } else {
            threadSleep(jvm->garbage_collect_period_ms / 2);
        }
    }
    collector->_garbage_thread_status = GARBAGE_THREAD_DEAD;
    thrd_exit(0);
    return 0;
}

s64 _garbage_collect(GcCollector *collector) {
    if (!collector || !collector->jvm) return 0;
    collector->isgc = 1;
    s64 mem_total = 0, mem_free = 0;
    s64 del = 0;
    s64 time, start;
    MiniJVM *jvm = collector->jvm;

    start = time = currentTimeMillis();

    vm_share_lock(jvm);
    {
        if (_gc_pause_the_world(jvm) != 0) {
            _gc_resume_the_world(jvm);
            vm_share_unlock(jvm);
            jvm_printf("[WARN] GC canceled - failed to pause the world\n");
            collector->isgc = 0;
            return -1;
        }
        collector->isworldstoped = 1;
#if _JVM_DEBUG_GARBAGE
        jvm_printf("garbage_move_cache %lld\n", (currentTimeMillis() - time));
        time = currentTimeMillis();
#endif
        if (collector->tmp_header) {
            collector->tmp_tailer->next = collector->header;
            collector->header = collector->tmp_header;
            collector->tmp_header = NULL;
            collector->tmp_tailer = NULL;
        }
#if _JVM_DEBUG_GARBAGE
        jvm_printf("garbage_move_cache %lld\n", (currentTimeMillis() - time));
        time = currentTimeMillis();
#endif
        _gc_copy_objs(jvm);

#if _JVM_DEBUG_GARBAGE
        jvm_printf("garbage_copy_refer %lld\n", (currentTimeMillis() - time));
        time = currentTimeMillis();
#endif
        collector->mark_cnt++;
        if (collector->mark_cnt == 0) {
            collector->mark_cnt = 1;
        }
        _gc_big_search(collector);

#if _JVM_DEBUG_GARBAGE
        jvm_printf("garbage_big_search %lld\n", (currentTimeMillis() - time));
        time = currentTimeMillis();
#endif

#if _JVM_DEBUG_GARBAGE_DUMP > 0
        _gc_print_obj_list(collector);
#endif

        collector->isworldstoped = 0;
        _gc_resume_the_world(jvm);
    }
    vm_share_unlock(jvm);

#if _JVM_DEBUG_GARBAGE
    jvm_printf("garbage_resume_the_world %lld\n", (currentTimeMillis() - time));
#endif

#if _JVM_DEBUG_LOG_LEVEL > 1
    s64 time_stopWorld = currentTimeMillis() - start;
#endif
    time = currentTimeMillis();

    MemoryBlock *head = NULL;
    MemoryBlock *nextmb = collector->header;
    MemoryBlock *curmb, *prevmb = NULL;

    if (collector->_garbage_thread_status == GARBAGE_THREAD_NORMAL) {
        while (nextmb) {
            curmb = nextmb;
            nextmb = curmb->next;
            if (curmb->type == MEM_TYPE_INS) {
                if (curmb->clazz && curmb->clazz->finalizeMethod) {
                    if (curmb->garbage_mark != collector->mark_cnt && !GCFLAG_FINALIZED_GET(curmb->gcflag)) {
                        instance_finalize((Instance *) curmb, collector->runtime);
                        if (!head) {
                            head = curmb;
                            curmb->tmp_next = NULL;
                        } else {
                            curmb->tmp_next = head;
                            head = curmb;
                        }
                        GCFLAG_FINALIZED_SET(curmb->gcflag);
                    }
                }
                if (GCFLAG_WEAKREFERENCE_GET(curmb->gcflag)) {
                    Instance *target = getFieldRefer(getInstanceFieldPtr((Instance *) curmb, jvm->shortcut.reference_target));
                    if (target && target->mb.garbage_mark != collector->mark_cnt) {
                        instance_of_reference_enqueue((Instance *) curmb, collector->runtime);
                        if (!head) {
                            head = curmb;
                            curmb->tmp_next = NULL;
                        } else {
                            curmb->tmp_next = head;
                            head = curmb;
                        }
                    }
                }
            }
        }

        nextmb = head;
        while (nextmb) {
            curmb = nextmb;
            nextmb = curmb->tmp_next;
            _gc_mark_object(collector, curmb, collector->mark_cnt);
        }
    }

#if _JVM_DEBUG_GARBAGE
    jvm_printf("garbage_finalize %lld\n", (currentTimeMillis() - time));
    time = currentTimeMillis();
#endif

    nextmb = collector->header;
    prevmb = NULL;
    s64 iter = 0;
    while (nextmb) {
        iter++;
        curmb = nextmb;
        nextmb = curmb->next;
        s32 size = curmb->heap_size;
        mem_total += size;
        if (curmb->garbage_mark != collector->mark_cnt) {
            mem_free += size;
#if _JVM_DEBUG_GARBAGE_DUMP > 1
            Utf8String *sus = utf8_create();
            _gc_get_obj_name(collector, curmb, sus);
            jvm_printf("X: %s[%llx]\n", utf8_cstr(sus), (s64) (intptr_t) curmb);
            utf8_destroy(sus);
#endif
            if (curmb->type == MEM_TYPE_CLASS) {
                classes_remove(collector->jvm, (JClass *) curmb);
            } else if (GCFLAG_JLOADER_GET(curmb->gcflag)) {
#if _JVM_DEBUG_GARBAGE_DUMP > 1
                jvm_printf("X: [%llx] classloader\n", (s64) (intptr_t) curmb);
#endif
                PeerClassLoader *pcl = classLoaders_find_by_instance(jvm, (Instance *) curmb);
                if (pcl) {
                    classloaders_remove(jvm, pcl);
                    classloader_destroy(pcl);
                }
            } else if (GCFLAG_JTHREAD_GET(curmb->gcflag)) {
                Runtime *ort = jthread_get_stackframe_value(jvm, (Instance *) curmb);
                if (ort) {
                    jthread_run_finalize(ort);
                }
            }
            memoryblock_destroy(curmb);
            if (prevmb) prevmb->next = nextmb;
            else collector->header = nextmb;
            del++;
        } else {
            prevmb = curmb;
        }
    }
    spin_lock(&collector->lock);
    collector->obj_count = iter - del;
    collector->obj_heap_size -= mem_free;
    spin_unlock(&collector->lock);

#if _JVM_DEBUG_LOG_LEVEL > 1
    s64 time_gc = currentTimeMillis() - time;
    jvm_printf("[INFO]gc obj: %lld->%lld   heap : %lld -> %lld  stop_world: %lld  gc:%lld\n", iter, collector->obj_count, mem_total, collector->obj_heap_size, time_stopWorld, time_gc);
#endif

#ifdef MEM_ALLOC_LTALLOC
    jvm_squeeze(0);
#endif
    collector->isgc = 0;
    return del;
}

static void _list_iter_thread_pause(ArrayListValue value, void *para) {
    if (value) {
        jthread_suspend((Runtime *) value);
    }
}

s32 _gc_pause_the_world(MiniJVM *jvm) {
    if (!jvm || !jvm->collector) return -1;
    GcCollector *collector = jvm->collector;
    ArrayList *thread_list = jvm->thread_list;
    s32 i;
    if (thread_list && thread_list->length) {
        arraylist_iter_safe(thread_list, _list_iter_thread_pause, NULL);

        spin_lock(&thread_list->spinlock);
        {
            for (i = 0; i < thread_list->length; i++) {
                Runtime *runtime = arraylist_get_value(thread_list, i);
                if (!runtime) continue;
                if (_gc_wait_thread_suspend(jvm, runtime) == -1) {
                    spin_unlock(&thread_list->spinlock);
                    return -1;
                }
                gc_move_objs_thread_2_gc(runtime);

#if _JVM_DEBUG_GARBAGE_DUMP > 1
                Utf8String *stack = utf8_create();
                getRuntimeStack(runtime, stack);
                jvm_printf("%s\n", utf8_cstr(stack));
                utf8_destroy(stack);
#endif
            }
        }
        spin_unlock(&thread_list->spinlock);
    }
    if (collector->runtime) {
        gc_move_objs_thread_2_gc(collector->runtime);
    }

    return 0;
}

s32 _gc_resume_the_world(MiniJVM *jvm) {
    if (!jvm || !jvm->thread_list) return 0;
    ArrayList *thread_list = jvm->thread_list;
    s32 i;
    for (i = 0; i < thread_list->length; i++) {
        Runtime *runtime = arraylist_get_value(thread_list, i);
        if (runtime) {
#if _JVM_DEBUG_GARBAGE_DUMP > 1
            Utf8String *stack = utf8_create();
            getRuntimeStack(runtime, stack);
            jvm_printf("%s\n", utf8_cstr(stack));
            utf8_destroy(stack);
#endif
            jthread_resume(runtime);
            vm_share_notifyall(jvm);
        }
    }

    return 0;
}

s32 _gc_wait_thread_suspend(MiniJVM *jvm, Runtime *runtime) {
    if (!runtime || !runtime->thrd_info) return 0;
    if (runtime->thrd_info->thread_status == THREAD_STATUS_NEW || runtime->thrd_info->thread_status == THREAD_STATUS_ZOMBIE) {
        return 0;
    }
    while (!(runtime->thrd_info->is_suspend ||
             runtime->thrd_info->is_blocking)) {
        vm_share_notifyall(jvm);
        vm_share_timedwait(jvm, 100);
        if (!jvm->collector || jvm->collector->_garbage_thread_status != GARBAGE_THREAD_NORMAL) {
            return -1;
        }
    }
    return 0;
}

//=================================  big_search ==================================
s32 _gc_big_search(GcCollector *collector) {
    if (!collector || !collector->jvm) return 0;

    if (collector->runtime_refer_copy) {
        s32 i, len;
        for (i = 0, len = collector->runtime_refer_copy->length; i < len; i++) {
            __refer r = arraylist_get_value(collector->runtime_refer_copy, i);
            if (r) {
                _gc_mark_object(collector, r, collector->mark_cnt);
            }
        }
    }

    if (collector->objs_holder) {
        HashsetIterator hi;
        hashset_iterate(collector->objs_holder, &hi);
        while (hashset_iter_has_more(&hi)) {
            HashsetKey k = hashset_iter_next_key(&hi);
            if (k) {
                _gc_mark_object(collector, k, collector->mark_cnt);
            }
        }
    }

    if (collector->jvm->boot_classloader && collector->jvm->boot_classloader->classes) {
        HashtableIterator hti;
        hashtable_iterate(collector->jvm->boot_classloader->classes, &hti);
        while (hashtable_iter_has_more(&hti)) {
            HashtableValue v = hashtable_iter_next_value(&hti);
            if (v) {
                _gc_mark_object(collector, v, collector->mark_cnt);
            }
        }
    }

    return 0;
}

void _gc_copy_objs(MiniJVM *jvm) {
    if (!jvm || !jvm->collector || !jvm->collector->runtime_refer_copy) return;
    arraylist_clear(jvm->collector->runtime_refer_copy);
    s32 i;
    if (jvm->thread_list) {
        for (i = 0; i < jvm->thread_list->length; i++) {
            Runtime *runtime = threadlist_get(jvm, i);
            if (runtime && runtime->thrd_info && runtime->thrd_info->thread_status != THREAD_STATUS_ZOMBIE) {
                _gc_copy_objs_from_thread(runtime);
            }
        }
    }
    if (jvm->jdwp_enable && jvm->jdwpserver) {
        Runtime *runtime = jdwp_get_runtime(jvm->jdwpserver);
        if (runtime) {
            _gc_copy_objs_from_thread(runtime);
        }
    }
}

s32 _gc_copy_objs_from_thread(Runtime *pruntime) {
    if (!pruntime || !pruntime->jvm || !pruntime->jvm->collector || !pruntime->thrd_info) return 0;
    GcCollector *collector = pruntime->jvm->collector;
    if (pruntime->thrd_info->jthread) {
        arraylist_push_back_unsafe(collector->runtime_refer_copy, pruntime->thrd_info->jthread);
    }

    Runtime *runtime = pruntime;
    RuntimeStack *stack = runtime->stack;
    if (stack) {
        stack->gc_clean = stack->sp;
        if (stack->sp && stack->max_size >= stack_size(stack)) {
            memset(stack->sp, 0, sizeof(StackEntry) * (stack->max_size - stack_size(stack)));
        }

        s32 i, imax;
        StackEntry *entry;
        for (i = 0, imax = stack_size(stack); i < imax; i++) {
            entry = stack->store + i;
            if (entry->rvalue) {
                arraylist_push_back_unsafe(collector->runtime_refer_copy, entry->rvalue);
            }
        }
    }
    MemoryBlock *next = runtime->thrd_info->tmp_holder;
    for (; next;) {
        arraylist_push_back_unsafe(collector->runtime_refer_copy, next);
        next = next->hold_next;
    }

    return 0;
}

static inline void _gc_instance_mark(GcCollector *collector, Instance *ins, u8 flag_cnt) {
    if (!collector || !ins) return;
    s32 i, len;
    JClass *clazz = ins->mb.clazz;
    while (clazz) {
        ArrayList *fiList = clazz->insFieldPtrIndex;
        if (fiList) {
            for (i = 0, len = fiList->length; i < len; i++) {
                FieldInfo *fi = arraylist_get_value_unsafe(fiList, i);
                if (!fi) continue;
                if (fi->is_ref_target && GCFLAG_WEAKREFERENCE_GET(ins->mb.gcflag)) continue;
                c8 *ptr = getInstanceFieldPtr(ins, fi);
                if (ptr) {
                    __refer ref = getFieldRefer(ptr);
                    if (ref) _gc_mark_object(collector, ref, flag_cnt);
                }
                if (fi->_this_class) {
                    _gc_mark_object(collector, fi->_this_class, flag_cnt);
                }
            }
        }
        _gc_mark_object(collector, clazz, flag_cnt);
        clazz = getSuperClass(clazz);
    }

    if (GCFLAG_JLOADER_GET(ins->mb.gcflag) && collector->jvm) {
        PeerClassLoader *pcl = classLoaders_find_by_instance(collector->jvm, ins);
        if (pcl && pcl->classes) {
            HashtableIterator hi;
            hashtable_iterate(pcl->classes, &hi);
            while (hashtable_iter_has_more(&hi)) {
                HashtableValue v = hashtable_iter_next_value(&hi);
                if (v) {
                    _gc_mark_object(collector, v, flag_cnt);
                }
            }
        }
    }
}

static inline void _gc_jarray_mark(GcCollector *collector, Instance *arr, u8 flag_cnt) {
    if (arr && arr->mb.type == MEM_TYPE_ARR) {
        if (isDataReferByIndex(arr->mb.arr_type_index)) {
            s32 i;
            for (i = 0; i < arr->arr_length; i++) {
                s64 val = jarray_get_field(arr, i);
                if (val) _gc_mark_object(collector, (__refer) (intptr_t) val, flag_cnt);
            }
        }
    }
}

static inline void _gc_class_mark(GcCollector *collector, JClass *clazz, u8 flag_cnt) {
    if (!collector || !clazz) return;
    s32 i, len;
    if (clazz->field_static && clazz->staticFieldPtrIndex) {
        ArrayList *fiList = clazz->staticFieldPtrIndex;
        for (i = 0, len = fiList->length; i < len; i++) {
            FieldInfo *fi = arraylist_get_value_unsafe(fiList, i);
            if (!fi) continue;
            c8 *ptr = getStaticFieldPtr(fi);
            if (ptr) {
                __refer ref = getFieldRefer(ptr);
                if (ref) _gc_mark_object(collector, ref, flag_cnt);
            }
        }
    }
    if (clazz->ins_class) {
        _gc_mark_object(collector, clazz->ins_class, flag_cnt);
    }
    if (clazz->jloader) {
        _gc_mark_object(collector, clazz->jloader, flag_cnt);
    }
}

void _gc_mark_object(GcCollector *collector, __refer ref, u8 flag_cnt) {
    if (ref && collector) {
        MemoryBlock *mb = (MemoryBlock *) ref;
        if (flag_cnt != mb->garbage_mark) {
#if _JVM_DEBUG_GARBAGE_DUMP > 0
            _gc_add_obj_count(collector, mb);
#endif
            mb->garbage_mark = flag_cnt;
            switch (mb->type) {
                case MEM_TYPE_INS:
                    _gc_instance_mark(collector, (Instance *) mb, flag_cnt);
                    break;
                case MEM_TYPE_ARR:
                    _gc_jarray_mark(collector, (Instance *) mb, flag_cnt);
                    break;
                case MEM_TYPE_CLASS:
                    _gc_class_mark(collector, (JClass *) mb, flag_cnt);
                    break;
            }
        }
    }
}

//=================================  reg unreg ==================================
s32 _gc_is_alive_in_link(MemoryBlock *header, MemoryBlock *target) {
    MemoryBlock *mb = header;
    while (mb) {
        if (mb == target) {
            return 1;
        }
        mb = mb->next;
    }
    return 0;
}

MemoryBlock *gc_is_alive(GcCollector *collector, __refer ref) {
    if (!collector || !ref) return NULL;
    __refer result = collector->objs_holder ? hashset_get(collector->objs_holder, ref) : NULL;
    if (result) return ref;

    MiniJVM *jvm = collector->jvm;
    if (!jvm) return NULL;
    spin_lock(&collector->lock);
    if (!result) {
        MemoryBlock *mb = collector->header;
        if (_gc_is_alive_in_link(mb, ref)) {
            result = ref;
        }
    }
    if (!result && jvm->collector) {
        MemoryBlock *mb = jvm->collector->tmp_header;
        if (_gc_is_alive_in_link(mb, ref)) {
            result = ref;
        }
    }
    if (!result && jvm->thread_list) {
        s32 i;
        for (i = 0; i < jvm->thread_list->length; i++) {
            Runtime *runtime = threadlist_get(jvm, i);
            if (runtime && runtime->thrd_info) {
                MemoryBlock *mb = runtime->thrd_info->objs_header;
                if (_gc_is_alive_in_link(mb, ref)) {
                    result = ref;
                }
            }
        }
    }
    if (!result) {
        if (jvm->jdwp_enable && jvm->jdwpserver) {
            Runtime *runtime = jdwp_get_runtime(jvm->jdwpserver);
            if (runtime && runtime->thrd_info) {
                MemoryBlock *mb = runtime->thrd_info->objs_header;
                if (_gc_is_alive_in_link(mb, ref)) {
                    result = ref;
                }
            }
        }
    }
    spin_unlock(&collector->lock);
    return (MemoryBlock *) result;
}

void gc_obj_reg(Runtime *runtime, __refer ref) {
    if (!runtime || !ref || !runtime->thrd_info) return;
    MemoryBlock *mb = (MemoryBlock *) ref;
    if (!GCFLAG_REG_GET(mb->gcflag)) {
        GCFLAG_REG_SET(mb->gcflag);
        JavaThreadInfo *ti = runtime->thrd_info;
        mb->next = ti->objs_header;
        ti->objs_header = ref;
        if (!ti->objs_tailer) {
            ti->objs_tailer = ref;
        }
        ti->objs_heap_of_thread += mb->heap_size;

#if _JVM_DEBUG_GARBAGE_DUMP > 1
        Utf8String *sus = utf8_create();
        _gc_get_obj_name(runtime->jvm->collector, mb, sus);
        getRuntimeStackWithOutReturn(runtime, sus);
        jvm_printf("R: [%llx]%s\n", (s64) (intptr_t) mb, utf8_cstr(sus));
        utf8_destroy(sus);
#endif
    }
}

void gc_move_objs_thread_2_gc(Runtime *runtime) {
    if (runtime && runtime->thrd_info && runtime->jvm && runtime->jvm->collector) {
        JavaThreadInfo *ti = runtime->thrd_info;
        GcCollector *collector = runtime->jvm->collector;
        spin_lock(&collector->lock);
        {
            if (ti->objs_header) {
#if _JVM_DEBUG_GARBAGE_DUMP > 1
                MemoryBlock *mb = ti->objs_header;
                while (mb) {
                    Utf8String *sus = utf8_create();
                    _gc_get_obj_name(runtime->jvm->collector, mb, sus);
                    jvm_printf("M: %s[%llx]\n", utf8_cstr(sus), (s64) (intptr_t) mb);
                    utf8_destroy(sus);
                    mb = mb->next;
                }
#endif
                ti->objs_tailer->next = collector->tmp_header;
                if (!collector->tmp_tailer) {
                    collector->tmp_tailer = ti->objs_tailer;
                }
                collector->tmp_header = ti->objs_header;
                collector->obj_heap_size += ti->objs_heap_of_thread;

                ti->objs_header = NULL;
                ti->objs_tailer = NULL;

                ti->objs_heap_of_thread = 0;
            }
        }
        spin_unlock(&collector->lock);
    }
}

void gc_obj_hold(GcCollector *collector, __refer ref) {
    if (collector && collector->objs_holder && ref) {
        hashset_put(collector->objs_holder, ref);
    }
}

void gc_obj_release(GcCollector *collector, __refer ref) {
    if (collector && collector->objs_holder && ref) {
        hashset_remove(collector->objs_holder, ref, 0);
    }
}
