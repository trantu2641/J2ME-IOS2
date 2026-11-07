
/*
 * MiniJVM class management and initialization.
 * J2ME compatibility diagnostics.
 */

#include "jvm.h"
#include "jvm_util.h"
#include "garbage.h"

/* ============================================================
 * Create and load
 * ============================================================ */

JClass *class_create(Runtime *runtime) {
    s32 jcsize = sizeof(JClass);
    JClass *clazz = jvm_calloc(jcsize);

    clazz->mb.heap_size = jcsize;
    clazz->mb.clazz = clazz;
    clazz->mb.type = MEM_TYPE_CLASS;
    clazz->field_instance_len = 0;
    clazz->field_static = NULL;
    clazz->status = CLASS_STATUS_RAW;
    clazz->_load_class_from_bytes = _LOAD_CLASS_FROM_BYTES;

    jthreadlock_create(runtime, &clazz->mb);
    constant_list_create(clazz);

    clazz->arr_class_type = pairlist_create(16);
    clazz->insFieldPtrIndex = arraylist_create(8);
    clazz->staticFieldPtrIndex = arraylist_create(4);
    clazz->supers = arraylist_create(4);

    gc_obj_reg(runtime, clazz);

    return clazz;
}

s32 class_destroy(JClass *clazz) {
    _DESTROY_CLASS(clazz);
    pairlist_destroy(clazz->arr_class_type);
    arraylist_destroy(clazz->insFieldPtrIndex);
    arraylist_destroy(clazz->staticFieldPtrIndex);
    pairlist_destroy(clazz->supers);
    jvm_free(clazz);

    return 0;
}

void constant_list_create(JClass *clazz) {
    clazz->constantPool.utf8CP = arraylist_create(0);
    clazz->constantPool.classRef = arraylist_create(0);
    clazz->constantPool.stringRef = arraylist_create(0);
    clazz->constantPool.fieldRef = arraylist_create(0);
    clazz->constantPool.methodRef = arraylist_create(0);
    clazz->constantPool.interfaceMethodRef = arraylist_create(0);
}

void constant_list_destroy(JClass *clazz) {
    arraylist_destroy(clazz->constantPool.utf8CP);
    arraylist_destroy(clazz->constantPool.classRef);
    arraylist_destroy(clazz->constantPool.stringRef);
    arraylist_destroy(clazz->constantPool.fieldRef);
    arraylist_destroy(clazz->constantPool.methodRef);
    arraylist_destroy(clazz->constantPool.interfaceMethodRef);
}

void class_clear_refer(PeerClassLoader *cloader, JClass *clazz) {
    s32 i, len;

    if (clazz->field_static) {
        FieldPool *fp = &clazz->fieldPool;

        for (i = 0; i < fp->field_used; i++) {
            FieldInfo *fi = &fp->field[i];

            if ((fi->access_flags & ACC_STATIC) != 0 && fi->isrefer) {
                c8 *ptr = getStaticFieldPtr(fi);

                if (ptr) {
                    setFieldRefer(ptr, NULL);
                }
            }
        }
    }

    ArrayList *utf8list = clazz->constantPool.utf8CP;

    for (i = 0, len = utf8list->length; i < len; i++) {
        ConstantUTF8 *cutf = arraylist_get_value(utf8list, i);
        gc_obj_release(cloader->jvm->collector, cutf->jstr);
    }

    gc_obj_release(cloader->jvm->collector, clazz->ins_class);
    clazz->ins_class = NULL;
}

/* ============================================================
 * Class preparation
 * ============================================================ */

s32 class_prepar(Instance *loader, JClass *clazz, Runtime *runtime) {
    if (!clazz) {
        return -1;
    }

    if (clazz->status >= CLASS_STATUS_PREPARING) {
        return 0;
    }

    jvm_printf(
        "[MiniJVM TRACE] prepare begin: %s\n",
        utf8_cstr(clazz->name)
    );

    clazz->status = CLASS_STATUS_PREPARING;

    s32 ret = 0;
    s32 superid = clazz->cff.super_class;

    if (superid && !clazz->superclass) {
        ConstantClassRef *ccf =
            class_get_constant_classref(clazz, superid);

        if (ccf) {
            Utf8String *clsName_u =
                class_get_constant_utf8(clazz, ccf->stringIndex)->utfstr;

            JClass *other =
                classes_load_get_without_resolve(
                    loader,
                    clsName_u,
                    runtime
                );

            clazz->superclass = other;
        } else {
            jvm_printf(
                "[MiniJVM] ERROR: Cannot resolve superclass of %s\n",
                utf8_cstr(clazz->name)
            );
        }
    }

    find_supers(clazz, runtime);

    s32 i;

    FieldInfo *f = clazz->fieldPool.field;

    s32 static_len = 0;
    s32 instance_len = 0;
    s32 field_count = clazz->fieldPool.field_used;

    s32 *mem_align_order =
        jvm_calloc(field_count * sizeof(s32));

    s32 order_idx = 0;
    s32 datawidth = 8;

    /* Arrange fields by alignment: 8, 4, 2, 1 bytes. */
    while (datawidth > 0) {
        for (i = 0; i < field_count; i++) {
            s32 width = DATA_TYPE_BYTES[f[i].datatype_idx];

            if (width == datawidth) {
                mem_align_order[order_idx] = i;
                order_idx++;
            }
        }

        datawidth /= 2;
    }

    for (i = 0; i < field_count; i++) {
        FieldInfo *fi = &f[mem_align_order[i]];

        s32 width = DATA_TYPE_BYTES[fi->datatype_idx];

        if (fi->access_flags & ACC_STATIC) {
            fi->offset = static_len;
            static_len += width;
        } else {
            fi->offset = instance_len;
            instance_len += width;
        }

        fi->_this_class = clazz;
    }

    jvm_free(mem_align_order);

    s32 align = 8;

    static_len =
        static_len / align * align +
        ((static_len % align) > 0 ? align : 0);

    instance_len =
        instance_len / align * align +
        ((instance_len % align) > 0 ? align : 0);

    clazz->field_static_len = static_len;

    if (clazz->field_static_len) {
        clazz->field_static = jvm_calloc(clazz->field_static_len);
    }

    if (clazz->superclass) {
        clazz->field_instance_start =
            clazz->superclass->field_instance_len;

        clazz->field_instance_len =
            clazz->field_instance_start + instance_len;
    } else {
        clazz->field_instance_start = 0;
        clazz->field_instance_len = instance_len;
    }

    for (i = 0; i < clazz->fieldPool.field_used; i++) {
        FieldInfo *fi = &clazz->fieldPool.field[i];

        if (fi->_this_class) {
            fi->offset_instance =
                fi->_this_class->field_instance_start + fi->offset;
        }
    }

    /* MiniJVM runtime field caches. */
    ShortCut *jvm_runtime_cache = &runtime->jvm->shortcut;

    if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_CLASS)) {
        FieldInfo *fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_CLASS,
            STR_FIELD_CLASSHANDLE,
            "J",
            NULL,
            runtime
        );

        jvm_runtime_cache->class_classHandle = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_CLASS,
            STR_FIELD_CLASSLOADER,
            "Ljava/lang/ClassLoader;",
            NULL,
            runtime
        );

        jvm_runtime_cache->class_classLoader = fi;

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_STRING)) {
        FieldInfo *fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_STRING,
            STR_FIELD_COUNT,
            "I",
            NULL,
            runtime
        );
        jvm_runtime_cache->string_count = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_STRING,
            STR_FIELD_OFFSET,
            "I",
            NULL,
            runtime
        );
        jvm_runtime_cache->string_offset = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_STRING,
            STR_FIELD_VALUE,
            "[C",
            NULL,
            runtime
        );
        jvm_runtime_cache->string_value = fi;

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_STRINGBUILDER)) {
        FieldInfo *fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_STRINGBUILDER,
            STR_FIELD_COUNT,
            "I",
            NULL,
            runtime
        );
        jvm_runtime_cache->stringbuilder_count = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_STRINGBUILDER,
            STR_FIELD_VALUE,
            "[C",
            NULL,
            runtime
        );
        jvm_runtime_cache->stringbuilder_value = fi;

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_THREAD)) {
        FieldInfo *fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_THREAD,
            STR_FIELD_NAME,
            "[C",
            NULL,
            runtime
        );
        jvm_runtime_cache->thread_name = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_THREAD,
            STR_FIELD_STACKFRAME,
            "J",
            NULL,
            runtime
        );
        jvm_runtime_cache->thread_stackFrame = fi;

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_STACKTRACE)) {
        FieldInfo *fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_STACKTRACE,
            "declaringClass",
            STR_INS_JAVA_LANG_STRING,
            NULL,
            runtime
        );
        jvm_runtime_cache->stacktrace_declaringClass = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_STACKTRACE,
            "methodName",
            STR_INS_JAVA_LANG_STRING,
            NULL,
            runtime
        );
        jvm_runtime_cache->stacktrace_methodName = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_STACKTRACE,
            "fileName",
            STR_INS_JAVA_LANG_STRING,
            NULL,
            runtime
        );
        jvm_runtime_cache->stacktrace_fileName = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_STACKTRACE,
            "lineNumber",
            "I",
            NULL,
            runtime
        );
        jvm_runtime_cache->stacktrace_lineNumber = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_STACKTRACE,
            "parent",
            STR_INS_JAVA_LANG_STACKTRACEELEMENT,
            NULL,
            runtime
        );
        jvm_runtime_cache->stacktrace_parent = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_JAVA_LANG_STACKTRACE,
            "declaringClazz",
            STR_INS_JAVA_LANG_CLASS,
            NULL,
            runtime
        );
        jvm_runtime_cache->stacktrace_declaringClazz = fi;

    } else if (utf8_equals_c(clazz->name, STR_CLASS_ORG_MINI_REFLECT_DIRECTMEMOBJ)) {
        FieldInfo *fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_ORG_MINI_REFLECT_DIRECTMEMOBJ,
            "memAddr",
            "J",
            NULL,
            runtime
        );
        jvm_runtime_cache->dmo_memAddr = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_ORG_MINI_REFLECT_DIRECTMEMOBJ,
            "length",
            "I",
            NULL,
            runtime
        );
        jvm_runtime_cache->dmo_length = fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_ORG_MINI_REFLECT_DIRECTMEMOBJ,
            "typeDesc",
            "C",
            NULL,
            runtime
        );
        jvm_runtime_cache->dmo_desc = fi;

    } else if (utf8_equals_c(clazz->name, STR_CLASS_ORG_MINI_REFLECT_REFLECTMETHOD)) {
        FieldInfo *fi;

        fi = find_fieldInfo_by_name_c(
            STR_CLASS_ORG_MINI_REFLECT_REFLECTMETHOD,
            "methodId",
            "J",
            NULL,
            runtime
        );

        jvm_runtime_cache->reflm_methodId = fi;

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_BOOLEAN)) {
        jvm_runtime_cache->booleanclass = clazz;

        jvm_runtime_cache->boolean_value =
            find_fieldInfo_by_name_c(
                STR_CLASS_JAVA_LANG_BOOLEAN,
                "value",
                "Z",
                NULL,
                runtime
            );

        jvm_runtime_cache->boolean_valueOf =
            find_methodInfo_by_name_c(
                STR_CLASS_JAVA_LANG_BOOLEAN,
                "valueOf",
                "(Z)Ljava/lang/Boolean;",
                NULL,
                runtime
            );

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_BYTE)) {
        jvm_runtime_cache->byteclass = clazz;

        jvm_runtime_cache->byte_value =
            find_fieldInfo_by_name_c(
                STR_CLASS_JAVA_LANG_BYTE,
                "value",
                "B",
                NULL,
                runtime
            );

        jvm_runtime_cache->byte_valueOf =
            find_methodInfo_by_name_c(
                STR_CLASS_JAVA_LANG_BYTE,
                "valueOf",
                "(B)Ljava/lang/Byte;",
                NULL,
                runtime
            );

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_SHORT)) {
        jvm_runtime_cache->shortclass = clazz;

        jvm_runtime_cache->short_value =
            find_fieldInfo_by_name_c(
                STR_CLASS_JAVA_LANG_SHORT,
                "value",
                "S",
                NULL,
                runtime
            );

        jvm_runtime_cache->short_valueOf =
            find_methodInfo_by_name_c(
                STR_CLASS_JAVA_LANG_SHORT,
                "valueOf",
                "(S)Ljava/lang/Short;",
                NULL,
                runtime
            );

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_CHARACTER)) {
        jvm_runtime_cache->characterclass = clazz;

        jvm_runtime_cache->character_value =
            find_fieldInfo_by_name_c(
                STR_CLASS_JAVA_LANG_CHARACTER,
                "value",
                "C",
                NULL,
                runtime
            );

        jvm_runtime_cache->character_valueOf =
            find_methodInfo_by_name_c(
                STR_CLASS_JAVA_LANG_CHARACTER,
                "valueOf",
                "(C)Ljava/lang/Character;",
                NULL,
                runtime
            );

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_INTEGER)) {
        jvm_runtime_cache->intclass = clazz;

        jvm_runtime_cache->int_value =
            find_fieldInfo_by_name_c(
                STR_CLASS_JAVA_LANG_INTEGER,
                "value",
                "I",
                NULL,
                runtime
            );

        jvm_runtime_cache->int_valueOf =
            find_methodInfo_by_name_c(
                STR_CLASS_JAVA_LANG_INTEGER,
                "valueOf",
                "(I)Ljava/lang/Integer;",
                NULL,
                runtime
            );

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_LONG)) {
        jvm_runtime_cache->longclass = clazz;

        jvm_runtime_cache->long_value =
            find_fieldInfo_by_name_c(
                STR_CLASS_JAVA_LANG_LONG,
                "value",
                "J",
                NULL,
                runtime
            );

        jvm_runtime_cache->long_valueOf =
            find_methodInfo_by_name_c(
                STR_CLASS_JAVA_LANG_LONG,
                "valueOf",
                "(J)Ljava/lang/Long;",
                NULL,
                runtime
            );

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_FLOAT)) {
        jvm_runtime_cache->floatclass = clazz;

        jvm_runtime_cache->float_value =
            find_fieldInfo_by_name_c(
                STR_CLASS_JAVA_LANG_FLOAT,
                "value",
                "F",
                NULL,
                runtime
            );

        jvm_runtime_cache->float_valueOf =
            find_methodInfo_by_name_c(
                STR_CLASS_JAVA_LANG_FLOAT,
                "valueOf",
                "(F)Ljava/lang/Float;",
                NULL,
                runtime
            );

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_DOUBLE)) {
        jvm_runtime_cache->doubleclass = clazz;

        jvm_runtime_cache->double_value =
            find_fieldInfo_by_name_c(
                STR_CLASS_JAVA_LANG_DOUBLE,
                "value",
                "D",
                NULL,
                runtime
            );

        jvm_runtime_cache->double_valueOf =
            find_methodInfo_by_name_c(
                STR_CLASS_JAVA_LANG_DOUBLE,
                "valueOf",
                "(D)Ljava/lang/Double;",
                NULL,
                runtime
            );

    } else if (utf8_equals_c(clazz->name, STR_CLASS_SUN_MISC_LAUNCHER)) {
        jvm_runtime_cache->launcher_loadClass =
            find_methodInfo_by_name_c(
                STR_CLASS_SUN_MISC_LAUNCHER,
                "loadClass",
                "(Ljava/lang/String;Ljava/lang/ClassLoader;)Ljava/lang/Class;",
                NULL,
                runtime
            );

        jvm_runtime_cache->launcher_getSystemClassLoader =
            find_methodInfo_by_name_c(
                STR_CLASS_SUN_MISC_LAUNCHER,
                "getSystemClassLoader",
                "()Ljava/lang/ClassLoader;",
                NULL,
                runtime
            );

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_REF_REFERENCE)) {
        jvm_runtime_cache->reference_target =
            find_fieldInfo_by_name_c(
                STR_CLASS_JAVA_LANG_REF_REFERENCE,
                "target",
                STR_INS_JAVA_LANG_OBJECT,
                NULL,
                runtime
            );

        /*
         * Guard against an absent runtime field.
         * Never dereference an unresolved FieldInfo.
         */
        if (jvm_runtime_cache->reference_target) {
            jvm_runtime_cache->reference_target->is_ref_target = 1;
        } else {
            jvm_printf(
                "[MiniJVM] WARNING: java.lang.ref.Reference.target "
                "was not found\n"
            );
        }

        jvm_runtime_cache->reference_vmEnqueneReference =
            find_methodInfo_by_name_c(
                STR_CLASS_JAVA_LANG_REF_REFERENCE,
                "vmEnqueneReference",
                "(Ljava/lang/ref/Reference;)V",
                NULL,
                runtime
            );

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_REF_WEAKREFERENCE)) {
        jvm_runtime_cache->weakreference = clazz;

    } else if (utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_THROWABLE)) {
        jvm_runtime_cache->throwable_detailMessage =
            find_fieldInfo_by_name_c(
                STR_CLASS_JAVA_LANG_THROWABLE,
                "detailMessage",
                STR_INS_JAVA_LANG_STRING,
                NULL,
                runtime
            );
    }

    /* Mark ClassLoader subclasses. */
    if (!utf8_equals_c(clazz->name, STR_CLASS_JAVA_LANG_CLASSLOADER)) {
        JClass *cl_clazz =
            classes_get_c(
                runtime->jvm,
                NULL,
                STR_CLASS_JAVA_LANG_CLASSLOADER
            );

        if (cl_clazz && assignable_from(cl_clazz, clazz)) {
            clazz->is_jcloader = 1;
        }
    }

    /* Mark WeakReference subclasses. */
    JClass *weak_clazz =
        classes_get_c(
            runtime->jvm,
            NULL,
            STR_CLASS_JAVA_LANG_REF_WEAKREFERENCE
        );

    if (weak_clazz && assignable_from(weak_clazz, clazz)) {
        clazz->is_weakref = 1;
    }

    clazz->status = CLASS_STATUS_PREPARED;

    jvm_printf(
        "[MiniJVM TRACE] prepare done: %s fields=%d\n",
        utf8_cstr(clazz->name),
        clazz->fieldPool.field_used
    );

    return ret;
}

/* ============================================================
 * Class initialization
 * ============================================================ */

void class_clinit(JClass *clazz, Runtime *runtime) {

    if (!clazz || !runtime || !runtime->jvm) {
        return;
    }

    vm_share_lock(runtime->jvm);
    runtime->thrd_info->no_pause++;

    if (clazz->status < CLASS_STATUS_PREPARED) {
        class_prepar(clazz->jloader, clazz, runtime);
    }

    if (clazz->status < CLASS_STATUS_CLINITING) {

        clazz->status = CLASS_STATUS_CLINITING;

        jvm_printf(
            "[MiniJVM TRACE] clinit begin: %s\n",
            utf8_cstr(clazz->name)
        );

        s32 i, len;

        /*
         * Resolve method references.
         */
        for (i = 0; i < clazz->constantPool.methodRef->length; i++) {

            ConstantMethodRef *cmr =
                (ConstantMethodRef *)arraylist_get_value(
                    clazz->constantPool.methodRef,
                    i
                );

            cmr->methodInfo =
                find_methodInfo_by_methodref(
                    clazz,
                    cmr->item.index,
                    runtime
                );

            cmr->virtual_methods = pairlist_create(0);
        }

        /*
         * Resolve interface method references.
         */
        for (i = 0; i < clazz->constantPool.interfaceMethodRef->length; i++) {

            ConstantMethodRef *cmr =
                (ConstantMethodRef *)arraylist_get_value(
                    clazz->constantPool.interfaceMethodRef,
                    i
                );

            cmr->methodInfo =
                find_methodInfo_by_methodref(
                    clazz,
                    cmr->item.index,
                    runtime
                );

            cmr->virtual_methods = pairlist_create(0);
        }

        /*
         * Resolve field references.
         *
         * The old code dereferenced fi->_this_class even if both
         * lookups failed. This version preserves unresolved entries
         * for the interpreter's lazy resolution path.
         */
        for (i = 0; i < clazz->constantPool.fieldRef->length; i++) {

            ConstantFieldRef *cfr =
                (ConstantFieldRef *)arraylist_get_value(
                    clazz->constantPool.fieldRef,
                    i
                );

            if (!cfr) {
                continue;
            }

            FieldInfo *fi =
                find_fieldInfo_by_fieldref(
                    clazz,
                    cfr->item.index,
                    runtime
                );

            if (!fi) {

                ConstantNameAndType *nat =
                    class_get_constant_name_and_type(
                        clazz,
                        cfr->nameAndTypeIndex
                    );

                ConstantClassRef *ownerRef =
                    class_get_constant_classref(
                        clazz,
                        cfr->classIndex
                    );

                const char *ownerName = "<unknown>";
                const char *fieldName = "<unknown>";
                const char *fieldDescriptor = "<unknown>";

                if (ownerRef) {
                    Utf8String *owner =
                        class_get_constant_utf8(
                            clazz,
                            ownerRef->stringIndex
                        )->utfstr;

                    ownerName = utf8_cstr(owner);
                }

                if (nat) {
                    ConstantUTF8 *nameUtf8 =
                        class_get_constant_utf8(
                            clazz,
                            nat->nameIndex
                        );

                    ConstantUTF8 *descriptorUtf8 =
                        class_get_constant_utf8(
                            clazz,
                            nat->typeIndex
                        );

                    if (nameUtf8) {
                        fieldName = utf8_cstr(nameUtf8->utfstr);
                    }

                    if (descriptorUtf8) {
                        fieldDescriptor =
                            utf8_cstr(descriptorUtf8->utfstr);
                    }
                }

                jvm_printf(
                    "[MiniJVM TRACE] field lookup retry: "
                    "from=%s target=%s.%s descriptor=%s\n",
                    utf8_cstr(clazz->name),
                    ownerName,
                    fieldName,
                    fieldDescriptor
                );

                /*
                 * Retry once. The class may have become available
                 * after another class-loading operation.
                 */
                fi =
                    find_fieldInfo_by_fieldref(
                        clazz,
                        cfr->item.index,
                        runtime
                    );

                if (!fi) {
                    jvm_printf(
                        "[MiniJVM TRACE] unresolved field: "
                        "from=%s target=%s.%s descriptor=%s\n",
                        utf8_cstr(clazz->name),
                        ownerName,
                        fieldName,
                        fieldDescriptor
                    );
                } else {
                    jvm_printf(
                        "[MiniJVM TRACE] field resolved on retry: "
                        "%s.%s %s\n",
                        ownerName,
                        fieldName,
                        fieldDescriptor
                    );
                }
            }

            /*
             * Store the final lookup result.
             */
            cfr->fieldInfo = fi;

            /*
             * Do not dereference unresolved FieldInfo.
             * The interpreter can retry resolution when the field
             * instruction is actually executed.
             */
            if (!fi) {
                continue;
            }

            if (fi->_this_class &&
                fi->_this_class->status < CLASS_STATUS_CLINITED) {

                /*
                 * Do not initialize the referenced class here.
                 * This is intentionally lazy to avoid early
                 * circular class initialization.
                 */
            }
        }

        jvm_printf(
            "[MiniJVM TRACE] field references done: %s count=%d\n",
            utf8_cstr(clazz->name),
            clazz->constantPool.fieldRef->length
        );

        /*
         * Find finalize method.
         * Do not process java.lang.Object.finalize().
         */
        clazz->finalizeMethod =
            find_methodInfo_by_name_c(
                utf8_cstr(clazz->name),
                STR_METHOD_FINALIZE,
                "()V",
                clazz->jloader,
                runtime
            );

        if (clazz->finalizeMethod &&
            clazz->finalizeMethod->_this_class &&
            utf8_equals_c(
                clazz->finalizeMethod->_this_class->name,
                STR_CLASS_JAVA_LANG_OBJECT
            )) {

            clazz->finalizeMethod = NULL;
        }

        /*
         * Initialize constant Java strings.
         */
        ArrayList *strlist = clazz->constantPool.stringRef;

        for (i = 0, len = strlist->length; i < len; i++) {

            ConstantStringRef *strRef =
                arraylist_get_value_unsafe(
                    strlist,
                    i
                );

            ConstantUTF8 *cutf =
                class_get_constant_utf8(
                    clazz,
                    strRef->stringIndex
                );

            Instance *jstr =
                hashtable_get(
                    runtime->jvm->table_jstring_const,
                    cutf->utfstr
                );

            if (!jstr) {

                jstr = jstring_create(
                    cutf->utfstr,
                    runtime
                );

                Utf8String *ustr =
                    utf8_create_copy(cutf->utfstr);

                hashtable_put(
                    runtime->jvm->table_jstring_const,
                    ustr,
                    jstr
                );

                gc_obj_hold(
                    runtime->jvm->collector,
                    jstr
                );
            }

            cutf->jstr = jstr;
        }

        jvm_printf(
            "[MiniJVM TRACE] string constants done: %s count=%d\n",
            utf8_cstr(clazz->name),
            strlist->length
        );

        /*
         * Initialize static constant fields.
         */
        for (i = 0; i < clazz->fieldPool.field_used; i++) {

            FieldInfo *fi = &clazz->fieldPool.field[i];

            if (fi->const_value_item &&
                (fi->access_flags & ACC_STATIC)) {

                c8 *ptr = getStaticFieldPtr(fi);

                if (!ptr) {
                    jvm_printf(
                        "[MiniJVM] WARNING: no static storage for %s.%s\n",
                        utf8_cstr(clazz->name),
                        utf8_cstr(fi->name)
                    );
                    continue;
                }

                s32 datatype = fi->datatype_idx;

                switch (datatype) {

                    case DATATYPE_BOOLEAN:
                    case DATATYPE_BYTE: {
                        setFieldByte(
                            ptr,
                            (s8)((ConstantInteger *)fi->const_value_item)->value
                        );
                        break;
                    }

                    case DATATYPE_SHORT:
                    case DATATYPE_JCHAR: {
                        setFieldShort(
                            ptr,
                            (s16)((ConstantInteger *)fi->const_value_item)->value
                        );
                        break;
                    }

                    case DATATYPE_INT: {
                        setFieldInt(
                            ptr,
                            ((ConstantInteger *)fi->const_value_item)->value
                        );
                        break;
                    }

                    case DATATYPE_FLOAT: {
                        setFieldFloat(
                            ptr,
                            ((ConstantFloat *)fi->const_value_item)->value
                        );
                        break;
                    }

                    case DATATYPE_LONG: {
                        setFieldLong(
                            ptr,
                            ((ConstantLong *)fi->const_value_item)->value
                        );
                        break;
                    }

                    case DATATYPE_DOUBLE: {
                        setFieldDouble(
                            ptr,
                            ((ConstantDouble *)fi->const_value_item)->value
                        );
                        break;
                    }

                    default: {
                        if (utf8_equals_c(
                            fi->descriptor,
                            STR_INS_JAVA_LANG_STRING
                        )) {

                            setFieldRefer(
                                ptr,
                                class_get_constant_utf8(
                                    fi->_this_class,
                                    ((ConstantStringRef *)fi->const_value_item)->stringIndex
                                )->jstr
                            );
                        }
                        break;
                    }
                }
            }
        }

        jvm_printf(
            "[MiniJVM TRACE] static constants done: %s\n",
            utf8_cstr(clazz->name)
        );

        /*
         * Initialize superclass first.
         */
        JClass *superclass = getSuperClass(clazz);

        if (superclass &&
            superclass->status < CLASS_STATUS_CLINITED) {

            jvm_printf(
                "[MiniJVM TRACE] superclass init: %s -> %s\n",
                utf8_cstr(clazz->name),
                utf8_cstr(superclass->name)
            );

            class_clinit(superclass, runtime);

            jvm_printf(
                "[MiniJVM TRACE] superclass initialized: %s\n",
                utf8_cstr(superclass->name)
            );
        }

        /*
         * Run the class static initializer.
         */
        MethodPool *p = &(clazz->methodPool);

        for (i = 0; i < p->method_used; i++) {

            MethodInfo *mi = &(p->method[i]);

            if (utf8_equals_c(mi->name, STR_METHOD_CLINIT)) {

                if (runtime->thrd_info->is_stop) {
                    jvm_printf(
                        "[MiniJVM TRACE] skipping clinit during stop: %s\n",
                        utf8_cstr(clazz->name)
                    );
                    break;
                }

                jvm_printf(
                    "[MiniJVM TRACE] executing <clinit>: %s\n",
                    utf8_cstr(clazz->name)
                );

                s32 initResult =
                    execute_method_impl(mi, runtime);

                if (initResult != RUNTIME_STATUS_NORMAL) {
                    jvm_printf(
                        "[MiniJVM TRACE] <clinit> returned status=%d: %s\n",
                        initResult,
                        utf8_cstr(clazz->name)
                    );

                    print_exception(runtime);
                } else {
                    jvm_printf(
                        "[MiniJVM TRACE] <clinit> completed: %s\n",
                        utf8_cstr(clazz->name)
                    );
                }

                break;
            }
        }

        clazz->status = CLASS_STATUS_CLINITED;

        jvm_printf(
            "[MiniJVM TRACE] clinit done: %s\n",
            utf8_cstr(clazz->name)
        );
    }

    runtime->thrd_info->no_pause--;
    vm_share_unlock(runtime->jvm);
}

/* ============================================================
 * Cached virtual method cleanup
 * ============================================================ */

void class_clear_cached_virtualmethod(MiniJVM *jvm, JClass *tgt) {
    s32 i;

    HashtableIterator hti;

    PeerClassLoader *pcl =
        classLoaders_find_by_instance(
            jvm,
            tgt->jloader
        );

    while (pcl &&
           (pcl = classLoaders_find_by_instance(
               jvm,
               pcl->parent
           )) != NULL) {

        hashtable_iterate(pcl->classes, &hti);

        for (; hashtable_iter_has_more(&hti);) {

            JClass *clazz = hashtable_iter_next_value(&hti);

            for (i = 0; i < clazz->constantPool.methodRef->length; i++) {

                ConstantMethodRef *cmr =
                    (ConstantMethodRef *)arraylist_get_value(
                        clazz->constantPool.methodRef,
                        i
                    );

                if (cmr->virtual_methods) {
#if _JVM_DEBUG_LOG_LEVEL > 2
                    if (pairlist_get(cmr->virtual_methods, tgt)) {
                        jvm_printf(
                            "virtual method clear %s in %s.%s\n",
                            utf8_cstr(tgt->name),
                            utf8_cstr(cmr->clsName),
                            utf8_cstr(cmr->name)
                        );
                    }
#endif
                    pairlist_remove(cmr->virtual_methods, tgt);
                }
            }

            for (i = 0; i < clazz->constantPool.interfaceMethodRef->length; i++) {

                ConstantMethodRef *cmr =
                    (ConstantMethodRef *)arraylist_get_value(
                        clazz->constantPool.methodRef,
                        i
                    );

                if (cmr->virtual_methods) {
#if _JVM_DEBUG_LOG_LEVEL > 2
                    if (pairlist_get(cmr->virtual_methods, tgt)) {
                        jvm_printf(
                            "virtual method clear %s in %s.%s\n",
                            utf8_cstr(tgt->name),
                            utf8_cstr(cmr->clsName),
                            utf8_cstr(cmr->name)
                        );
                    }
#endif
                    pairlist_remove(cmr->virtual_methods, tgt);
                }
            }
        }

        if (pcl == jvm->boot_classloader) {
            break;
        }
    }
}

/* ============================================================
 * Instantiation
 * ============================================================ */

u8 instance_of(Instance *ins, JClass *other) {
    if (!ins) {
        return 0;
    }

    JClass *clazz = ins->mb.clazz;

    s32 i, imax;

    if (clazz) {
        for (i = 0, imax = clazz->supers->length; i < imax; i++) {

            JClass *cl = clazz->supers->data[i];

            if (other == cl) {
                return 1;
            }
        }
    }

    return 0;
}

u8 isSonOfInterface(JClass *clazz, JClass *son, Runtime *runtime) {
    if (!clazz || !son) {
        return 0;
    }

    s32 i;

    for (i = 0; i < son->interfacePool.clasz_used; i++) {

        ConstantClassRef *ccr =
            (son->interfacePool.clasz + i);

        JClass *other =
            classes_load_get_with_clinit(
                son->jloader,
                class_get_constant_utf8(
                    son,
                    ccr->stringIndex
                )->utfstr,
                runtime
            );

        if (clazz == other) {
            return 1;
        }

        if (other) {
            u8 sure = isSonOfInterface(
                clazz,
                other,
                runtime
            );

            if (sure) {
                return 1;
            }
        }
    }

    return 0;
}

u8 assignable_from(JClass *clazzParent, JClass *clazzSon) {
    s32 i, imax;

    if (clazzSon) {
        for (i = 0, imax = clazzSon->supers->length; i < imax; i++) {

            JClass *cl = clazzSon->supers->data[i];

            if (clazzParent == cl) {
                return 1;
            }
        }
    }

    return 0;
}

JClass *getSuperClass(JClass *clazz) {
    if (!clazz) {
        return NULL;
    }

    return clazz->superclass;
}

/* ============================================================
 * Class data access
 * ============================================================ */

JClass *getClassByConstantClassRef(
    JClass *clazz,
    s32 index,
    Runtime *runtime
) {
    if (!clazz) {
        return NULL;
    }

    ConstantClassRef *ccf =
        class_get_constant_classref(clazz, index);

    if (!ccf) {
        return NULL;
    }

    if (!ccf->clazz) {

        Utf8String *clsName =
            class_get_utf8_string(
                clazz,
                ccf->stringIndex
            );

        ccf->clazz =
            classes_load_get_with_clinit(
                clazz->jloader,
                clsName,
                runtime
            );
    }

    return ccf->clazz;
}

/* ============================================================
 * Field lookup
 * ============================================================ */

FieldInfo *find_fieldInfo_by_fieldref(
    JClass *clazz,
    s32 field_ref,
    Runtime *runtime
) {
    if (!clazz) {
        return NULL;
    }

    ConstantFieldRef *cfr =
        class_get_constant_fieldref(
            clazz,
            field_ref
        );

    if (!cfr) {
        return NULL;
    }

    ConstantNameAndType *nat =
        class_get_constant_name_and_type(
            clazz,
            cfr->nameAndTypeIndex
        );

    ConstantClassRef *ccr =
        class_get_constant_classref(
            clazz,
            cfr->classIndex
        );

    if (!nat || !ccr) {
        return NULL;
    }

    Utf8String *clsName =
        class_get_utf8_string(
            clazz,
            ccr->stringIndex
        );

    Utf8String *fieldName =
        class_get_utf8_string(
            clazz,
            nat->nameIndex
        );

    Utf8String *type =
        class_get_utf8_string(
            clazz,
            nat->typeIndex
        );

    if (!clsName || !fieldName || !type) {
        return NULL;
    }

    return find_fieldInfo_by_name(
        clsName,
        fieldName,
        type,
        clazz->jloader,
        runtime
    );
}

FieldInfo *find_fieldInfo_by_name_c(
    c8 const *pclsName,
    c8 const *pfieldName,
    c8 const *pfieldType,
    Instance *jloader,
    Runtime *runtime
) {
    Utf8String *clsName = utf8_create_c(pclsName);
    Utf8String *fieldName = utf8_create_c(pfieldName);
    Utf8String *fieldType = utf8_create_c(pfieldType);

    FieldInfo *fi =
        find_fieldInfo_by_name(
            clsName,
            fieldName,
            fieldType,
            jloader,
            runtime
        );

    utf8_destroy(clsName);
    utf8_destroy(fieldName);
    utf8_destroy(fieldType);

    return fi;
}

FieldInfo *find_fieldInfo_by_name(
    Utf8String *clsName,
    Utf8String *fieldName,
    Utf8String *fieldType,
    Instance *jloader,
    Runtime *runtime
) {
    if (!clsName || !fieldName || !fieldType || !runtime) {
        return NULL;
    }

    FieldInfo *fi = NULL;

    JClass *other =
        classes_load_get_without_resolve(
            jloader,
            clsName,
            runtime
        );

    if (!other) {
        jvm_printf(
            "[MiniJVM] field owner class not found: %s\n",
            utf8_cstr(clsName)
        );

        return NULL;
    }

    while (fi == NULL && other) {

        FieldPool *fp = &(other->fieldPool);

        s32 i = 0;

        for (; i < fp->field_used; i++) {

            FieldInfo *tmp = &fp->field[i];

            if (utf8_equals(fieldName, tmp->name) == 1 &&
                utf8_equals(fieldType, tmp->descriptor) == 1) {

                fi = tmp;
                break;
            }
        }

        /*
         * Search interface fields.
         */
        if (fi == NULL) {

            for (i = 0; i < other->interfacePool.clasz_used; i++) {

                ConstantClassRef *ccr =
                    (other->interfacePool.clasz + i);

                Utf8String *icl_name =
                    class_get_constant_utf8(
                        other,
                        ccr->stringIndex
                    )->utfstr;

                FieldInfo *ifi =
                    find_fieldInfo_by_name(
                        icl_name,
                        fieldName,
                        fieldType,
                        jloader,
                        runtime
                    );

                if (ifi != NULL) {
                    fi = ifi;
                    break;
                }
            }
        }

        other = getSuperClass(other);
    }

    return fi;
}

/* ============================================================
 * Method lookup
 * ============================================================ */

MethodInfo *find_instance_methodInfo_by_name(
    Instance *ins,
    Utf8String *methodName,
    Utf8String *methodType,
    Runtime *runtime
) {
    if (!ins) {
        return NULL;
    }

    return find_methodInfo_by_name(
        ins->mb.clazz->name,
        methodName,
        methodType,
        ins->mb.clazz->jloader,
        runtime
    );
}

MethodInfo *find_methodInfo_by_methodref(
    JClass *clazz,
    s32 method_ref,
    Runtime *runtime
) {
    if (!clazz) {
        return NULL;
    }

    ConstantMethodRef *cmr =
        class_get_constant_method_ref(
            clazz,
            method_ref
        );

    if (!cmr) {
        return NULL;
    }

    Utf8String *clsName = cmr->clsName;
    Utf8String *methodName = cmr->name;
    Utf8String *methodType = cmr->descriptor;

    return find_methodInfo_by_name(
        clsName,
        methodName,
        methodType,
        clazz->jloader,
        runtime
    );
}

MethodInfo *find_methodInfo_by_name_c(
    c8 const *pclsName,
    c8 const *pmethodName,
    c8 const *pmethodType,
    Instance *jloader,
    Runtime *runtime
) {
    Utf8String *clsName = utf8_create_c(pclsName);
    Utf8String *methodName = utf8_create_c(pmethodName);
    Utf8String *methodType = utf8_create_c(pmethodType);

    MethodInfo *mi =
        find_methodInfo_by_name(
            clsName,
            methodName,
            methodType,
            jloader,
            runtime
        );

    utf8_destroy(clsName);
    utf8_destroy(methodName);
    utf8_destroy(methodType);

    return mi;
}

MethodInfo *find_methodInfo_by_name(
    Utf8String *clsName,
    Utf8String *methodName,
    Utf8String *methodType,
    Instance *jloader,
    Runtime *runtime
) {
    if (!clsName || !methodName || !methodType || !runtime) {
        return NULL;
    }

    MethodInfo *mi = NULL;

    JClass *other =
        classes_load_get_without_resolve(
            jloader,
            clsName,
            runtime
        );

    if (!other) {
        jvm_printf(
            "method not exist: %s.%s%s\n",
            utf8_cstr(clsName),
            utf8_cstr(methodName),
            utf8_cstr(methodType)
        );

        return NULL;
    }

    while (mi == NULL && other) {

        MethodPool *fp = &(other->methodPool);

        s32 i;

        for (i = 0; i < fp->method_used; i++) {

            MethodInfo *tmp = &fp->method[i];

            if (utf8_equals(methodName, tmp->name) == 1 &&
                utf8_equals(methodType, tmp->descriptor) == 1) {

                mi = tmp;

                if (!mi->_this_class) {
                    mi->_this_class = other;
                }

                break;
            }
        }

        /*
         * Find interface default method implementation.
         */
        if (mi == NULL) {

            for (i = 0; i < other->interfacePool.clasz_used; i++) {

                ConstantClassRef *ccr =
                    (other->interfacePool.clasz + i);

                Utf8String *icl_name =
                    class_get_constant_utf8(
                        other,
                        ccr->stringIndex
                    )->utfstr;

                classes_load_get_without_resolve(
                    jloader,
                    icl_name,
                    runtime
                );

                MethodInfo *imi =
                    find_methodInfo_by_name(
                        icl_name,
                        methodName,
                        methodType,
                        jloader,
                        runtime
                    );

                if (imi != NULL &&
                    imi->converted_code != NULL) {

                    mi = imi;
                    break;
                }
            }
        }

        /*
         * Find superclass.
         */
        s32 sonIsInterface =
            other->cff.access_flags & ACC_INTERFACE;

        other = getSuperClass(other);

        if (sonIsInterface &&
            other &&
            !(other->cff.access_flags & ACC_INTERFACE)) {

            other = NULL;
        }
    }

    return mi;
}

/* ============================================================
 * Superclass and interface collection
 * ============================================================ */

static void find_supers_impl(
    JClass *clazz,
    Runtime *runtime,
    ArrayList *list
) {
    if (!clazz || !list) {
        return;
    }

    JClass *other = clazz;

    s32 i;

    while (other) {

        if (arraylist_index_of(
            list,
            DEFAULT_ARRAYLIST_EQUALS_FUNC,
            other
        ) < 0) {

            arraylist_push_back(list, other);
        }

        /*
         * Include interfaces and their parent interfaces.
         */
        for (i = 0; i < other->interfacePool.clasz_used; i++) {

            ConstantClassRef *ccr =
                (other->interfacePool.clasz + i);

            Utf8String *icl_name =
                class_get_constant_utf8(
                    other,
                    ccr->stringIndex
                )->utfstr;

            JClass *icl =
                classes_load_get_without_resolve(
                    other->jloader,
                    icl_name,
                    runtime
                );

            if (icl &&
                arraylist_index_of(
                    list,
                    DEFAULT_ARRAYLIST_EQUALS_FUNC,
                    icl
                ) < 0) {

                find_supers_impl(
                    icl,
                    runtime,
                    list
                );
            }
        }

        other = getSuperClass(other);
    }
}

void find_supers(JClass *clazz, Runtime *runtime) {
    if (!clazz) {
        return;
    }

    find_supers_impl(
        clazz,
        runtime,
        clazz->supers
    );
}

/* ============================================================
 * Class file version
 * ============================================================ */

c8 *getMajorVersionString(u16 major_number) {
    if (major_number == 0x33) {
        return "J2SE 7";
    }

    if (major_number == 0x32) {
        return "J2SE 6.0";
    }

    return "NONE";
}
