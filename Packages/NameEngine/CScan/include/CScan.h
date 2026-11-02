#ifndef XSEARCH_CSCAN_H
#define XSEARCH_CSCAN_H
#include <stdint.h>
#include <stddef.h>

enum { XS_TYPE_FILE = 1, XS_TYPE_DIR = 2, XS_TYPE_SYMLINK = 5, XS_TYPE_OTHER = 0 };

typedef struct {
    const char *name;        // NUL-terminated on-disk name; valid only during the callback
    uint32_t name_len;
    uint32_t type;           // XS_TYPE_*
    uint32_t dev;
    uint32_t bsd_flags;      // st_flags (UF_HIDDEN, ...)
    uint64_t ino;
    int64_t birth_ns;
    int64_t mtime_ns;
    int64_t size;            // data fork length; 0 for directories
    uint16_t finder_flags;   // kHasBundle = 0x2000, kIsInvisible = 0x4000
    uint8_t is_mount;        // mount point or automount trigger: never descended into
} xs_entry;

/// Return non-zero to stop listing early.
typedef int (*xs_entry_cb)(void *ctx, const xs_entry *entry);

/// Lists a directory with getattrlistbulk without following symlinks. Returns 0 or an errno.
/// Entries the kernel reports with a per-entry error are skipped and counted in `*skipped`: the
/// listing then does not prove that an entry it lacks is gone.
int xs_list_dir(const char *path, xs_entry_cb cb, void *ctx, int *skipped);

/// Attributes of a single path (not following symlinks), including its on-disk name, which
/// may differ in case from `path` on case-insensitive volumes. `name_buf` receives the name.
int xs_stat_path(const char *path, xs_entry *out, char *name_buf, size_t name_cap);

/// Current path of an inode on the volume that contains `volume_path` (fsgetpath). Lets a
/// reconcile tell "moved elsewhere" from "deleted". Returns 0 or an errno.
int xs_path_for_inode(const char *volume_path, uint64_t ino, char *buf, size_t cap);

uint32_t xs_crc32(uint32_t crc, const void *buf, size_t len);
#endif
