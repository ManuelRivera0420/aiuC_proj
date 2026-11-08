/*
 * Newlib syscall stubs for this bare-metal RV32IM target. Confirmed by
 * actually attempting to link against the toolchain's bundled Newlib
 * (built for rv32im/ilp32 -- see docs/known_limitations.md) that this is
 * the COMPLETE set of undefined symbols: _sbrk, _write, _read, _close,
 * _lseek, _fstat, _isatty, _kill, _getpid, _exit. Everything else
 * (malloc/free, string functions, sprintf, qsort, ...) comes from Newlib
 * itself once these are provided -- no need to hand-write a libc.
 *
 * _sbrk is the only one that matters for correctness (it's what makes
 * malloc work, which DoomGeneric depends on heavily via Z_Malloc's
 * underlying allocator). Everything else is either genuinely unused by a
 * freestanding target with no filesystem/terminal/process model, or is a
 * deliberate "fail safely" stub -- not filled in with fake success.
 */
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>

/* Heap region: placed by the linker script (see firmware/linker/ *.ld),
   symbols __heap_start / _stack_top mark [heap_start, stack_top) as the
   region sbrk is allowed to grow into. No guard page, no overlap check
   beyond this -- a sufficiently large allocation request will walk into
   the stack, same risk profile as any other bare-metal bump allocator. */
extern char __heap_start[];
extern char _stack_top[];

static char *heap_cur = 0;

void *_sbrk(int incr) {
    char *prev;
    if (heap_cur == 0) {
        heap_cur = __heap_start;
    }
    prev = heap_cur;
    if (prev + incr > _stack_top) {
        errno = ENOMEM;
        return (void *)-1;
    }
    heap_cur += incr;
    return prev;
}

int _write(int fd, const char *buf, int len) {
    (void)fd; (void)buf;
    /* No UART/console in this design (mission scope excludes it except as
       an optional diagnostic -- see docs/board_resource_selection.md).
       Report success without doing anything, matching "this target has
       no stdout" rather than failing calls DoomGeneric doesn't actually
       check the return value of (e.g. any stray printf/fprintf). */
    return len;
}

int _read(int fd, char *buf, int len) {
    (void)fd; (void)buf; (void)len;
    return 0; /* EOF: no stdin on this target */
}

int _close(int fd) {
    (void)fd;
    return 0;
}

/* No filesystem on this target: _open/mkdir/_unlink/_link all fail
   cleanly (ENOENT/ENOSYS) rather than pretending to succeed. DoomGeneric
   code that calls these (M_MakeDirectory for a config-file directory,
   savegame path checks, etc.) is not exercised by the read-only,
   preloaded-WAD boot path this project uses -- see
   software/doom_port/w_file_de2115.c. */
int _open(const char *path, int flags, int mode) {
    (void)path; (void)flags; (void)mode;
    errno = ENOENT;
    return -1;
}

int mkdir(const char *path, mode_t mode) {
    (void)path; (void)mode;
    errno = ENOSYS;
    return -1;
}

int _unlink(const char *path) {
    (void)path;
    errno = ENOENT;
    return -1;
}

int _link(const char *oldpath, const char *newpath) {
    (void)oldpath; (void)newpath;
    errno = ENOSYS;
    return -1;
}

long _lseek(int fd, long offset, int whence) {
    (void)fd; (void)offset; (void)whence;
    return 0;
}

int _fstat(int fd, struct stat *st) {
    (void)fd;
    st->st_mode = S_IFCHR; /* pretend everything is a character device */
    return 0;
}

int _isatty(int fd) {
    (void)fd;
    return 1;
}

int _kill(int pid, int sig) {
    (void)pid; (void)sig;
    errno = EINVAL;
    return -1;
}

int _getpid(void) {
    return 1;
}

void _exit(int status) {
    (void)status;
    __asm__ volatile ("ecall");
    for (;;) { /* unreachable: cpu_core.sv halts on ecall */ }
}
