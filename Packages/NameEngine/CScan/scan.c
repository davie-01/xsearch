#include "CScan.h"
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/fsgetpath.h>
#include <sys/mount.h>
#include <sys/vnode.h>
#include <unistd.h>
#include <zlib.h>

#define XS_COMMON (ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | \
                   ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_FNDRINFO | ATTR_CMN_FLAGS | ATTR_CMN_FILEID)

static void xs_attrs(struct attrlist *al) {
    memset(al, 0, sizeof(*al));
    al->bitmapcount = ATTR_BIT_MAP_COUNT;
    al->commonattr = XS_COMMON;
    al->dirattr = ATTR_DIR_MOUNTSTATUS;
    al->fileattr = ATTR_FILE_DATALENGTH;
}

static int ts_ns(const char **p, int64_t *out) {
    struct timespec ts;
    memcpy(&ts, *p, sizeof(ts));
    *p += sizeof(ts);
    *out = (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
    return 0;
}

// Parses one packed record (after its leading length field). Attributes appear in bit order.
// `layout` overrides which attributes occupy space (FSOPT_PACK_INVAL_ATTRS packs all requested).
static int parse(const char *rec, xs_entry *e, const char **name_out, const attribute_set_t *layout) {
    const char *p = rec;
    attribute_set_t got;
    memcpy(&got, p, sizeof(got));
    p += sizeof(got);
    if (layout) got = *layout;
    memset(e, 0, sizeof(*e));
    if (got.commonattr & ATTR_CMN_ERROR) {
        uint32_t err;
        memcpy(&err, p, sizeof(err));
        p += sizeof(err);
        if (err) return (int)err;
    }
    *name_out = NULL;
    if (got.commonattr & ATTR_CMN_NAME) {
        attrreference_t ref;
        memcpy(&ref, p, sizeof(ref));
        *name_out = p + ref.attr_dataoffset;
        e->name_len = ref.attr_length ? ref.attr_length - 1 : 0;
        p += sizeof(ref);
    }
    if (got.commonattr & ATTR_CMN_DEVID) { dev_t d; memcpy(&d, p, sizeof(d)); e->dev = (uint32_t)d; p += sizeof(d); }
    if (got.commonattr & ATTR_CMN_OBJTYPE) {
        fsobj_type_t t;
        memcpy(&t, p, sizeof(t));
        p += sizeof(t);
        e->type = t == VREG ? XS_TYPE_FILE : t == VDIR ? XS_TYPE_DIR : t == VLNK ? XS_TYPE_SYMLINK : XS_TYPE_OTHER;
    }
    if (got.commonattr & ATTR_CMN_CRTIME) ts_ns(&p, &e->birth_ns);
    if (got.commonattr & ATTR_CMN_MODTIME) ts_ns(&p, &e->mtime_ns);
    if (got.commonattr & ATTR_CMN_FNDRINFO) {
        // FileInfo/FolderInfo: finderFlags is the big-endian u16 at offset 8.
        const unsigned char *f = (const unsigned char *)p;
        e->finder_flags = (uint16_t)((f[8] << 8) | f[9]);
        p += 32;
    }
    if (got.commonattr & ATTR_CMN_FLAGS) { memcpy(&e->bsd_flags, p, sizeof(uint32_t)); p += sizeof(uint32_t); }
    if (got.commonattr & ATTR_CMN_FILEID) { memcpy(&e->ino, p, sizeof(uint64_t)); p += sizeof(uint64_t); }
    if (got.dirattr & ATTR_DIR_MOUNTSTATUS) {
        uint32_t m;
        memcpy(&m, p, sizeof(m));
        p += sizeof(m);
        e->is_mount = (m & (DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER)) != 0;
    }
    if (got.fileattr & ATTR_FILE_DATALENGTH) { off_t l; memcpy(&l, p, sizeof(l)); e->size = l; p += sizeof(l); }
    return 0;
}

int xs_list_dir(const char *path, xs_entry_cb cb, void *ctx) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno;
    struct attrlist al;
    xs_attrs(&al);
    // Heap buffer: scans run on worker threads with small stacks.
    static const size_t cap = 256 * 1024;
    char *buf = malloc(cap);
    if (!buf) { close(fd); return ENOMEM; }
    int status = 0;
    for (;;) {
        int n = getattrlistbulk(fd, &al, buf, cap, 0);
        if (n < 0) { status = errno; break; }
        if (n == 0) break;
        const char *rec = buf;
        for (int i = 0; i < n; i++) {
            uint32_t len;
            memcpy(&len, rec, sizeof(len));
            xs_entry e;
            const char *name;
            if (parse(rec + sizeof(len), &e, &name, NULL) == 0 && name) {
                e.name = name;
                if (cb(ctx, &e)) { free(buf); close(fd); return 0; }
            }
            rec += len;
        }
    }
    free(buf);
    close(fd);
    return status;
}

int xs_stat_path(const char *path, xs_entry *out, char *name_buf, size_t name_cap) {
    struct attrlist al;
    xs_attrs(&al);
    al.commonattr &= ~ATTR_CMN_ERROR;  // bulk-only attribute
    char buf[2048] __attribute__((aligned(8)));
    if (getattrlist(path, &al, buf, sizeof(buf), FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS) != 0) return errno;
    // FSOPT_PACK_INVAL_ATTRS packs every requested attribute, so parse with the requested layout
    // and discard the ones the object type does not have.
    attribute_set_t layout = {.commonattr = al.commonattr, .dirattr = al.dirattr, .fileattr = al.fileattr};
    const char *name;
    int err = parse(buf + sizeof(uint32_t), out, &name, &layout);
    if (err) return err;
    if (out->type != XS_TYPE_DIR) out->is_mount = 0;
    if (out->type != XS_TYPE_FILE) out->size = 0;
    if (name && name_buf && name_cap) {
        size_t n = out->name_len < name_cap - 1 ? out->name_len : name_cap - 1;
        memcpy(name_buf, name, n);
        name_buf[n] = 0;
        out->name = name_buf;
    }
    return 0;
}

uint32_t xs_crc32(uint32_t crc, const void *buf, size_t len) {
    while (len > 0) {
        uInt chunk = len > 0x40000000 ? 0x40000000 : (uInt)len;
        crc = (uint32_t)crc32(crc, buf, chunk);
        buf = (const char *)buf + chunk;
        len -= chunk;
    }
    return crc;
}

int xs_path_for_inode(const char *volume_path, uint64_t ino, char *buf, size_t cap) {
    struct statfs fs;
    if (statfs(volume_path, &fs) != 0) return errno;
    ssize_t n = fsgetpath(buf, cap, &fs.f_fsid, ino);
    if (n < 0) return errno;
    if ((size_t)n >= cap) return ENAMETOOLONG;
    buf[n] = 0;
    return 0;
}
