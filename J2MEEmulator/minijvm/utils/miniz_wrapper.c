#include "miniz.h"
#include "miniz_wrapper.h"

#include <pthread.h>
#include <sys/stat.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

/*
 * Keep JAR readers alive between class/resource requests.
 *
 * The old implementation reopened and reparsed the JAR for every
 * zip_loadfile()/zip_get_file_*() call. A MIDlet can perform hundreds or
 * thousands of resource/class lookups during startup. Reusing the parsed
 * central directory makes JAR execution behave like a normal persistent
 * JarFile/ResourceLoader instead of repeatedly rescanning the archive.
 */
#define ZIP_READER_CACHE_CAPACITY 24

typedef struct ZipReaderCacheEntry {
    int used;
    char path[PATH_MAX];
    mz_zip_archive archive;
    dev_t device;
    ino_t inode;
    off_t file_size;
    time_t modified_sec;
    long modified_nsec;
    uint64_t last_used;
} ZipReaderCacheEntry;

static ZipReaderCacheEntry g_zip_reader_cache[ZIP_READER_CACHE_CAPACITY];
static pthread_mutex_t g_zip_reader_cache_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_zip_reader_cache_clock = 0;

static void zip_cache_stat_values(const struct stat *st, time_t *sec, long *nsec) {
#if defined(__APPLE__)
    *sec = st->st_mtimespec.tv_sec;
    *nsec = st->st_mtimespec.tv_nsec;
#else
    *sec = st->st_mtim.tv_sec;
    *nsec = st->st_mtim.tv_nsec;
#endif
}

static int zip_cache_matches_stat(const ZipReaderCacheEntry *entry, const struct stat *st) {
    time_t sec = 0;
    long nsec = 0;
    zip_cache_stat_values(st, &sec, &nsec);
    return entry->device == st->st_dev &&
           entry->inode == st->st_ino &&
           entry->file_size == st->st_size &&
           entry->modified_sec == sec &&
           entry->modified_nsec == nsec;
}

static void zip_cache_close_entry(ZipReaderCacheEntry *entry) {
    if (!entry || !entry->used) return;
    mz_zip_reader_end(&entry->archive);
    memset(entry, 0, sizeof(*entry));
}

static void zip_cache_invalidate_locked(const char *path) {
    if (!path) return;
    for (int i = 0; i < ZIP_READER_CACHE_CAPACITY; i++) {
        if (g_zip_reader_cache[i].used && strcmp(g_zip_reader_cache[i].path, path) == 0) {
            zip_cache_close_entry(&g_zip_reader_cache[i]);
        }
    }
}

/* Caller must hold g_zip_reader_cache_lock. */
static ZipReaderCacheEntry *zip_cache_get_locked(const char *path) {
    if (!path || !path[0] || strlen(path) >= PATH_MAX) return NULL;

    struct stat st;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) return NULL;

    ZipReaderCacheEntry *empty = NULL;
    ZipReaderCacheEntry *lru = NULL;

    for (int i = 0; i < ZIP_READER_CACHE_CAPACITY; i++) {
        ZipReaderCacheEntry *entry = &g_zip_reader_cache[i];

        if (!entry->used) {
            if (!empty) empty = entry;
            continue;
        }

        if (strcmp(entry->path, path) == 0) {
            if (zip_cache_matches_stat(entry, &st)) {
                entry->last_used = ++g_zip_reader_cache_clock;
                return entry;
            }

            /* The JAR was replaced/updated. Rebuild its index. */
            zip_cache_close_entry(entry);
            empty = entry;
            break;
        }

        if (!lru || entry->last_used < lru->last_used) lru = entry;
    }

    ZipReaderCacheEntry *slot = empty ? empty : lru;
    if (!slot) return NULL;
    if (slot->used) zip_cache_close_entry(slot);

    memset(slot, 0, sizeof(*slot));
    mz_zip_zero_struct(&slot->archive);

    if (mz_zip_reader_init_file(&slot->archive, path, 0) == MZ_FALSE) {
        memset(slot, 0, sizeof(*slot));
        return NULL;
    }

    snprintf(slot->path, sizeof(slot->path), "%s", path);
    slot->device = st.st_dev;
    slot->inode = st.st_ino;
    slot->file_size = st.st_size;
    zip_cache_stat_values(&st, &slot->modified_sec, &slot->modified_nsec);
    slot->last_used = ++g_zip_reader_cache_clock;
    slot->used = 1;
    return slot;
}

void zip_reader_cache_clear(void) {
    pthread_mutex_lock(&g_zip_reader_cache_lock);
    for (int i = 0; i < ZIP_READER_CACHE_CAPACITY; i++) {
        zip_cache_close_entry(&g_zip_reader_cache[i]);
    }
    g_zip_reader_cache_clock = 0;
    pthread_mutex_unlock(&g_zip_reader_cache_lock);
}

static const char *zip_normalize_name(const char *filename) {
    if (!filename) return NULL;
    while (*filename == '/') filename++;
    return filename;
}

/*
 * Resource lookup compatibility helper.
 *
 * JAR/ZIP entry names are technically case-sensitive, but a significant
 * number of old J2ME MIDlets were built on case-insensitive filesystems and
 * contain references whose case does not exactly match the ZIP entry.
 *
 * Keep exact lookup first. Only when it fails do we ask miniz for a
 * case-insensitive match. This does not impose an item/resource count limit.
 */
static int zip_locate_file_compatible(
    mz_zip_archive *archive,
    const char *filename
) {
    if (!archive || !filename || !filename[0]) return -1;

    int index = mz_zip_reader_locate_file(
        archive,
        filename,
        NULL,
        MZ_ZIP_FLAG_CASE_SENSITIVE
    );

    if (index >= 0) return index;

    /* miniz performs the non-case-sensitive lookup when the flag is clear. */
    return mz_zip_reader_locate_file(
        archive,
        filename,
        NULL,
        0
    );
}

s32 zip_loadfile(char const *jarpath, char const *filename, ByteBuf *buf) {
    if (!jarpath || !filename || !buf) return -1;
    filename = zip_normalize_name(filename);

    s32 ret = -1;
    pthread_mutex_lock(&g_zip_reader_cache_lock);
    ZipReaderCacheEntry *entry = zip_cache_get_locked(jarpath);

    if (entry) {
        int index = zip_locate_file_compatible(
            &entry->archive, filename);
        mz_zip_archive_file_stat st;
        memset(&st, 0, sizeof(st));

        if (index >= 0 && mz_zip_reader_file_stat(&entry->archive, (mz_uint)index, &st)) {
            mz_uint64 size = st.m_uncomp_size;
            if (size <= 0x7FFFFFFFULL) {
                if (size > 0 && buf->_alloc_size < (u32)size) {
                    bytebuf_expand(buf, (u32)size);
                }
                if (size == 0) {
                    buf->wp = 0;
                    ret = 0;
                } else if (buf->buf && buf->_alloc_size >= (u32)size) {
                    if (mz_zip_reader_extract_to_mem(&entry->archive, (mz_uint)index,
                                                     buf->buf, (size_t)size, 0) != MZ_FALSE) {
                        buf->wp = (s32)size;
                        ret = 0;
                    }
                }
            }
        }
    }

    pthread_mutex_unlock(&g_zip_reader_cache_lock);
    return ret;
}

s32 zip_loadfile_to_mem(char const *jarpath, char const *filename, c8 *buf, s64 bufsize) {
    if (!jarpath || !filename || !buf || bufsize < 0) return -1;
    filename = zip_normalize_name(filename);

    s32 ret = -1;
    pthread_mutex_lock(&g_zip_reader_cache_lock);
    ZipReaderCacheEntry *entry = zip_cache_get_locked(jarpath);

    if (entry) {
        int index = zip_locate_file_compatible(
            &entry->archive, filename);
        mz_zip_archive_file_stat st;
        memset(&st, 0, sizeof(st));

        if (index >= 0 && mz_zip_reader_file_stat(&entry->archive, (mz_uint)index, &st)) {
            mz_uint64 size = st.m_uncomp_size;
            if (size <= (mz_uint64)bufsize && size <= (mz_uint64)SIZE_MAX) {
                if (mz_zip_reader_extract_to_mem(&entry->archive, (mz_uint)index,
                                                 buf, (size_t)size, 0) != MZ_FALSE) {
                    ret = 0;
                }
            }
        }
    }

    pthread_mutex_unlock(&g_zip_reader_cache_lock);
    return ret;
}

s64 zip_get_file_unzip_size(char const *jarpath, char const *filename) {
    if (!jarpath || !filename) return -1;
    filename = zip_normalize_name(filename);

    s64 ret = -1;
    pthread_mutex_lock(&g_zip_reader_cache_lock);
    ZipReaderCacheEntry *entry = zip_cache_get_locked(jarpath);

    if (entry) {
        int index = zip_locate_file_compatible(
            &entry->archive, filename);
        mz_zip_archive_file_stat st;
        memset(&st, 0, sizeof(st));
        if (index >= 0 && mz_zip_reader_file_stat(&entry->archive, (mz_uint)index, &st) &&
            st.m_uncomp_size <= (mz_uint64)INT64_MAX) {
            ret = (s64)st.m_uncomp_size;
        }
    }

    pthread_mutex_unlock(&g_zip_reader_cache_lock);
    return ret;
}

s32 zip_get_file_index(char const *jarpath, char const *filename) {
    if (!jarpath || !filename) return -1;
    filename = zip_normalize_name(filename);

    s32 ret = -1;
    pthread_mutex_lock(&g_zip_reader_cache_lock);
    ZipReaderCacheEntry *entry = zip_cache_get_locked(jarpath);

    if (entry) {
        int index = zip_locate_file_compatible(
            &entry->archive, filename);
        mz_zip_archive_file_stat st;
        memset(&st, 0, sizeof(st));
        if (index >= 0 && mz_zip_reader_file_stat(&entry->archive, (mz_uint)index, &st)) {
            ret = index;
        }
    }

    pthread_mutex_unlock(&g_zip_reader_cache_lock);
    return ret;
}

s32 zip_savefile_mem(
    char const *jarpath,
    char const *filename,
    char const *buf,
    int size
) {
    mz_zip_archive zipArchive = {0};

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

            if (uncompressed_size > 0x7FFFFFFF) {
                ret = -1;
            } else {
                if (data->_alloc_size < (u32)uncompressed_size) {
                    bytebuf_expand(data, (u32)uncompressed_size);
                }

                if (!data->buf ||
                    data->_alloc_size < (u32)uncompressed_size) {
                    ret = -1;
                } else {
                    mz_bool result = mz_zip_reader_extract_to_mem(
                        &zipArchive,
                        0,
                        data->buf,
                        uncompressed_size,
                        0
                    );

                    if (result == MZ_FALSE) {
                        ret = -1;
                    } else {
                        data->wp = (s32)uncompressed_size;
                    }
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

    mz_ulong compressed_size = mz_compressBound(size) + 18;

    unsigned char *compressed_data =
        (unsigned char *)MZ_MALLOC(compressed_size);

    if (!compressed_data) {
        return -1;
    }

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
