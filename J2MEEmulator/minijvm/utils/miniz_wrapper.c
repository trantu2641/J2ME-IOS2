
#include "miniz.h"
#include "miniz_wrapper.h"


s32 zip_loadfile(char const *jarpath, char const *filename, ByteBuf *buf) {
    int file_index = -1;
    mz_zip_archive zipArchive = {0};
    mz_zip_archive_file_stat file_stat = {0};

    /* Skip the first '/' */
    if (filename && filename[0] == '/') {
        filename += 1;
    }

    int ret = 0;

    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {
        ret = -1;
    } else {
        /*
         * IMPORTANT:
         * Java class names are case-sensitive.
         * A JAR may contain both dH.class and dh.class.
         * Never use flags=0 here because it allows case-insensitive lookup.
         */
        file_index = mz_zip_reader_locate_file(
            &zipArchive,
            filename,
            NULL,
            MZ_ZIP_FLAG_CASE_SENSITIVE
        );

        if (file_index < 0 ||
            !mz_zip_reader_file_stat(&zipArchive, file_index, &file_stat)) {
            ret = -1;
        } else {
            size_t uncompressed_size = (size_t)file_stat.m_uncomp_size;

            if (!bytebuf_expand(buf, (s32)uncompressed_size)) {
                ret = -1;
            } else {
                mz_bool p = mz_zip_reader_extract_file_to_mem(
                    &zipArchive,
                    file_stat.m_filename,
                    buf->buf,
                    uncompressed_size,
                    MZ_ZIP_FLAG_CASE_SENSITIVE
                );

                if (p == MZ_FALSE) {
                    ret = -1;
                } else {
                    buf->wp = (s32)uncompressed_size;
                }
            }
        }

        mz_zip_reader_end(&zipArchive);
    }

    return ret;
}


s32 zip_loadfile_to_mem(
    char const *jarpath,
    char const *filename,
    c8 *buf,
    s64 bufsize
) {
    int file_index = -1;
    mz_zip_archive zipArchive = {0};
    mz_zip_archive_file_stat file_stat = {0};

    /* Skip the first '/' */
    if (filename && filename[0] == '/') {
        filename += 1;
    }

    int ret = 0;

    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {
        ret = -1;
    } else {
        file_index = mz_zip_reader_locate_file(
            &zipArchive,
            filename,
            NULL,
            MZ_ZIP_FLAG_CASE_SENSITIVE
        );

        if (file_index < 0 ||
            !mz_zip_reader_file_stat(&zipArchive, file_index, &file_stat)) {
            ret = -1;
        } else {
            size_t uncompressed_size = (size_t)file_stat.m_uncomp_size;

            if ((s64)uncompressed_size > bufsize) {
                ret = -1;
            } else {
                mz_bool op = mz_zip_reader_extract_file_to_mem(
                    &zipArchive,
                    file_stat.m_filename,
                    buf,
                    bufsize,
                    MZ_ZIP_FLAG_CASE_SENSITIVE
                );

                if (!op) {
                    ret = -1;
                }
            }
        }

        mz_zip_reader_end(&zipArchive);
    }

    return ret;
}


s64 zip_get_file_unzip_size(char const *jarpath, char const *filename) {
    int file_index = -1;
    mz_zip_archive zipArchive = {0};
    mz_zip_archive_file_stat file_stat = {0};

    /* Skip the first '/' */
    if (filename && filename[0] == '/') {
        filename += 1;
    }

    s64 ret = 0;

    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {
        ret = -1;
    } else {
        file_index = mz_zip_reader_locate_file(
            &zipArchive,
            filename,
            NULL,
            MZ_ZIP_FLAG_CASE_SENSITIVE
        );

        if (file_index < 0 ||
            !mz_zip_reader_file_stat(&zipArchive, file_index, &file_stat)) {
            ret = -1;
        } else {
            ret = (s64)file_stat.m_uncomp_size;
        }

        mz_zip_reader_end(&zipArchive);
    }

    return ret;
}


s32 zip_get_file_index(char const *jarpath, char const *filename) {
    int file_index = -1;
    mz_zip_archive zipArchive = {0};
    mz_zip_archive_file_stat file_stat = {0};

    /* Skip the first '/' */
    if (filename && filename[0] == '/') {
        filename += 1;
    }

    int ret = -1;

    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {
        ret = -1;
    } else {
        file_index = mz_zip_reader_locate_file(
            &zipArchive,
            filename,
            NULL,
            MZ_ZIP_FLAG_CASE_SENSITIVE
        );

        if (file_index < 0 ||
            !mz_zip_reader_file_stat(&zipArchive, file_index, &file_stat)) {
            ret = -1;
        } else {
            ret = file_index;
        }

        mz_zip_reader_end(&zipArchive);
    }

    return ret;
}


s32 zip_savefile_mem(
    char const *jarpath,
    char const *filename,
    char const *buf,
    int size
) {
    mz_zip_archive zipArchive = {0};

    /* Skip the first '/' */
    if (filename && filename[0] == '/') {
        filename += 1;
    }

    int ret = 0;

    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {
        if (mz_zip_writer_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {
            ret = -1;
        }
    } else {
        if (mz_zip_writer_init_from_reader(&zipArchive, jarpath) == MZ_FALSE) {
            ret = -1;
        }
    }

    if (ret == 0) {
        if (mz_zip_writer_add_mem(
            &zipArchive,
            filename,
            buf,
            size,
            MZ_DEFAULT_COMPRESSION
        ) == MZ_FALSE) {
            ret = -1;
        }

        if (mz_zip_writer_finalize_archive(&zipArchive) == MZ_FALSE) {
            ret = -1;
        }

        mz_zip_writer_end(&zipArchive);
    }

    return ret;
}


s32 zip_savefile(
    char const *jarpath,
    char const *filename,
    ByteBuf *buf
) {
    if (!buf) {
        return -1;
    }

    return zip_savefile_mem(
        jarpath,
        filename,
        buf->buf,
        buf->wp
    );
}


s32 zip_filecount(char *jarpath) {
    mz_zip_archive zipArchive = {0};

    int ret = 0;

    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {
        ret = -1;
    } else {
        ret = mz_zip_reader_get_num_files(&zipArchive);
        mz_zip_reader_end(&zipArchive);
    }

    return ret;
}


ArrayList *zip_get_filenames(char *jarpath) {
    mz_zip_archive zipArchive = {0};

    ArrayList *list = arraylist_create(0);

    if (!list) {
        return NULL;
    }

    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {
        return list;
    }

    int count = mz_zip_reader_get_num_files(&zipArchive);
    int i;

    for (i = 0; i < count; i++) {
        char buf[1024] = {0};

        mz_uint requiremore = mz_zip_reader_get_filename(
            &zipArchive,
            i,
            buf,
            sizeof(buf)
        );

        (void)requiremore;

        if (strlen(buf)) {
            Utf8String *ustr = utf8_create_c(buf);

            if (ustr) {
                arraylist_push_back_unsafe(list, ustr);
            }
        }
    }

    mz_zip_reader_end(&zipArchive);

    return list;
}


void zip_destroy_filenames_list(ArrayList *list) {
    if (!list) {
        return;
    }

    s32 i;

    for (i = 0; i < list->length; i++) {
        Utf8String *ustr = arraylist_get_value_unsafe(list, i);

        if (ustr) {
            utf8_destroy(ustr);
        }
    }

    arraylist_destroy(list);
}


s32 zip_is_directory(char *jarpath, int index) {
    mz_zip_archive zipArchive = {0};

    int ret = -1;

    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {
        ret = -1;
    } else {
        ret = mz_zip_reader_is_file_a_directory(&zipArchive, index);
        mz_zip_reader_end(&zipArchive);
    }

    return ret;
}


s32 zip_extract(char *zip_data, int size, ByteBuf *data) {
    mz_zip_archive zipArchive = {0};
    mz_zip_archive_file_stat file_stat = {0};

    int ret = 0;

    if (!zip_data || !data || size <= 0) {
        return -1;
    }

    if (mz_zip_reader_init_mem(
        &zipArchive,
        zip_data,
        size,
        0
    ) == MZ_FALSE) {
        ret = -1;
    } else {
        if (!mz_zip_reader_file_stat(&zipArchive, 0, &file_stat)) {
            ret = -1;
        } else {
            size_t uncompressed_size = (size_t)file_stat.m_uncomp_size;

            if (!bytebuf_expand(data, (s32)uncompressed_size)) {
                ret = -1;
            } else {
                mz_bool p = mz_zip_reader_extract_to_mem(
                    &zipArchive,
                    0,
                    data->buf,
                    uncompressed_size,
                    0
                );

                if (p == MZ_FALSE) {
                    ret = -1;
                } else {
                    data->wp = (s32)uncompressed_size;
                }
            }
        }

        mz_zip_reader_end(&zipArchive);
    }

    return ret;
}


s32 zip_compress(char *data, int size, ByteBuf *zip_data) {
    mz_zip_archive zipArchive = {0};

    int ret = 0;

    if (!data || !zip_data || size < 0) {
        return -1;
    }

    if (mz_zip_writer_init_heap(&zipArchive, 0, 0) == MZ_FALSE) {
        ret = -1;
    } else {
        if (mz_zip_writer_add_mem(
            &zipArchive,
            "",
            data,
            size,
            MZ_DEFAULT_COMPRESSION
        ) == MZ_FALSE) {
            ret = -1;
        } else {
            void *buf = NULL;
            size_t outSize = 0;

            if (mz_zip_writer_finalize_heap_archive(
                &zipArchive,
                &buf,
                &outSize
            ) == MZ_FALSE) {
                ret = -1;
            } else {
                bytebuf_write_batch(zip_data, buf, (s32)outSize);
            }
        }

        mz_zip_writer_end(&zipArchive);
    }

    return ret;
}


// Create a complete GZIP stream.
s32 gzip_compress(char *data, int size, ByteBuf *gzip_data) {
    if (!data || !gzip_data || size < 0) {
        return -1;
    }

    mz_stream stream = {0};
    int status;

    mz_ulong crc = mz_crc32(
        MZ_CRC32_INIT,
        (const unsigned char *)data,
        size
    );

    /* Reserve 10 bytes for the header and 8 bytes for the footer. */
    mz_ulong compressed_size = mz_compressBound(size) + 18;

    unsigned char *compressed_data =
        (unsigned char *)MZ_MALLOC(compressed_size);

    if (!compressed_data) {
        return -1;
    }

    /* GZIP header */
    compressed_data[0] = 0x1F;
    compressed_data[1] = 0x8B;
    compressed_data[2] = 0x08;
    compressed_data[3] = 0x00;
    compressed_data[4] = 0x00;
    compressed_data[5] = 0x00;
    compressed_data[6] = 0x00;
    compressed_data[7] = 0x00;
    compressed_data[8] = 0x00;
    compressed_data[9] = 0xFF;

    stream.next_in = (const unsigned char *)data;
    stream.avail_in = size;
    stream.next_out = compressed_data + 10;
    stream.avail_out = compressed_size - 18;

    status = mz_deflateInit2(
        &stream,
        MZ_DEFAULT_LEVEL,
        MZ_DEFLATED,
        -MZ_DEFAULT_WINDOW_BITS,
        8,
        MZ_DEFAULT_STRATEGY
    );

    if (status != MZ_OK) {
        MZ_FREE(compressed_data);
        return -1;
    }

    status = mz_deflate(&stream, MZ_FINISH);

    if (status != MZ_STREAM_END) {
        mz_deflateEnd(&stream);
        MZ_FREE(compressed_data);
        return -1;
    }

    mz_ulong compressed_len = stream.total_out;

    mz_deflateEnd(&stream);

    /* GZIP footer */
    unsigned char *footer = compressed_data + 10 + compressed_len;

    *(mz_uint32 *)footer = crc;
    *(mz_uint32 *)(footer + 4) = (mz_uint32)size;

    bytebuf_write_batch(
        gzip_data,
        (char *)compressed_data,
        (s32)(compressed_len + 18)
    );

    MZ_FREE(compressed_data);

    return 0;
}


// Extract a standard GZIP stream.
s32 gzip_extract(char *gzip_data, int size, ByteBuf *data) {
    if (!gzip_data || !data || size < 18 ||
        (unsigned char)gzip_data[0] != 0x1F ||
        (unsigned char)gzip_data[1] != 0x8B ||
        (unsigned char)gzip_data[2] != 0x08) {
        return -1;
    }

    mz_stream stream = {0};
    int status;

    /* Read original size and expected CRC from the footer. */
    mz_uint32 original_size =
        *(mz_uint32 *)(gzip_data + size - 4);

    mz_uint32 expected_crc =
        *(mz_uint32 *)(gzip_data + size - 8);

    unsigned char *uncompressed_data =
        (unsigned char *)MZ_MALLOC(original_size);

    if (!uncompressed_data) {
        return -1;
    }

    stream.next_in = (unsigned char *)gzip_data + 10;
    stream.avail_in = size - 18;
    stream.next_out = uncompressed_data;
    stream.avail_out = original_size;

    status = mz_inflateInit2(
        &stream,
        -MZ_DEFAULT_WINDOW_BITS
    );

    if (status != MZ_OK) {
        MZ_FREE(uncompressed_data);
        return -1;
    }

    status = mz_inflate(&stream, MZ_FINISH);

    mz_inflateEnd(&stream);

    if (status != MZ_STREAM_END ||
        stream.total_out != original_size) {
        MZ_FREE(uncompressed_data);
        return -1;
    }

    /* Verify CRC32. */
    mz_uint32 computed_crc = mz_crc32(
        MZ_CRC32_INIT,
        uncompressed_data,
        original_size
    );

    if (computed_crc != expected_crc) {
        MZ_FREE(uncompressed_data);
        return -1;
    }

    bytebuf_write_batch(
        data,
        (char *)uncompressed_data,
        (s32)original_size
    );

    MZ_FREE(uncompressed_data);

    return 0;
}
