/*
 * android_shims.c — glibc compatibility stubs for Android Bionic.
 *
 * Zig's libc++ is compiled against glibc Linux and references several
 * glibc-internal symbols that Android Bionic does not export.
 * This file provides minimal compatible implementations.
 *
 * Symbols confirmed missing from Android Bionic (tested on API 36):
 *   bcmp                  — deprecated in POSIX 2008, never added to Bionic
 *   __ctype_b_loc         — glibc internal for locale ctype tables
 *   __ctype_tolower_loc   — glibc internal for tolower tables
 *   catopen/catgets/close — POSIX message catalog (not in Bionic)
 *
 * Symbols NOT shimmed here (available in NDK 30 / Android API 36):
 *   __errno_location      — in Bionic as glibc compat
 *   aligned_alloc         — available since Android API 28
 *   getrandom             — available since Android API 28
 *   __res_init            — in Bionic resolv
 *
 * strtod_l/strtof_l: NDK 30's bits/stdlib_inlines.h provides these as
 * `static inline`, so they're only available to C/C++ TUs that include that
 * header — there's no exported symbol in libc.so to link a prebuilt archive
 * (Zig's libc++.a) against. Confirmed needed (M3.4): linking a binary target
 * pulls in libc++'s <locale> num_get<float/double> path, which calls these.
 * Single-locale (C/POSIX) Android has no per-locale variants, so plain
 * strtof/strtod is the correct behavior regardless of the ignored locale_t.
 *
 * Hidden visibility: resolved internally, not exported from the .so.
 */

#include <string.h>
#include <stdint.h>
#include <errno.h>

#define HIDDEN __attribute__((visibility("hidden")))

/* ── PT_TLS alignment (M3.4 finding, binaries only) ─────────────────────────
 * Modern ARM64 Bionic refuses to load any ELF whose PT_TLS segment isn't
 * placed at a >=64-byte-aligned address ("executable's TLS segment is
 * underaligned" — observed on the Pixel 6 / Android 16 running the M3.4
 * arm_prove_smoke binary; not previously hit because M2/M3.1-3.3 only ever
 * loaded a cdylib via dlopen, which isn't checked the same way). lld sizes
 * and places the merged PT_TLS segment based on the highest alignment any
 * contributing `__thread`/TLS variable requests; if every real TLS variable
 * only asks for 16, that's what gets emitted and placed — patching the
 * p_align field after the fact (e.g. via termux-elf-cleaner) does not move
 * the segment, so the loader's stricter skew check still fails. Linking in
 * one over-aligned dummy TLS variable forces lld to lay out (not just label)
 * the segment on a 64-byte boundary from the start. Unused; never read. */
HIDDEN __thread __attribute__((aligned(64))) char runewright_tls_align_force[64];

/* Deliberately not including <stdlib.h>: NDK 30's bits/stdlib_inlines.h
 * declares strtof_l/strtod_l as `static inline`, which would collide with
 * the definitions below (the symbol Zig's prebuilt libc++.a actually needs
 * to link against — an inline-only definition produces no linkable symbol).
 * Forward-declare the real (non-"_l") Bionic functions and the real
 * locale_t type by hand instead of pulling in the header that shadows them. */
extern float strtof(const char *nptr, char **endptr);
extern double strtod(const char *nptr, char **endptr);
typedef struct __locale_t *locale_t;

HIDDEN float strtof_l(const char *nptr, char **endptr, locale_t loc) {
    (void)loc;
    return strtof(nptr, endptr);
}

HIDDEN double strtod_l(const char *nptr, char **endptr, locale_t loc) {
    (void)loc;
    return strtod(nptr, endptr);
}

/* ── __res_init ──────────────────────────────────────────────────────────────
 * glibc resolver init (double-underscore internal). Android provides
 * res_init() without the prefix; __res_init is not exported.
 * Barretenberg does no DNS lookups; returning 0 (success) is safe. */
HIDDEN int __res_init(void) { return 0; }

/* ── __errno_location ────────────────────────────────────────────────────────
 * glibc TLS errno accessor. Android Bionic provides __errno() instead;
 * it does not export __errno_location. */
HIDDEN int *__errno_location(void) {
    return &errno;
}

/* ── bcmp ────────────────────────────────────────────────────────────────────
 * Deprecated in POSIX 2008; not in Android Bionic.
 * Identical semantics to memcmp on all relevant platforms. */
HIDDEN int bcmp(const void *s1, const void *s2, size_t n) {
    return memcmp(s1, s2, n);
}

/* ── POSIX message catalogs ──────────────────────────────────────────────────
 * Not in Android Bionic. Zig's libc++ locale code references these via the
 * generic Linux ctype path. Barretenberg (a math library) should never call
 * them at runtime. Return canonical failure/passthrough values. */
typedef void    *nl_catd_compat;
typedef int      nl_item_compat;

HIDDEN nl_catd_compat catopen(const char *name, int oflag) {
    (void)name; (void)oflag;
    return (nl_catd_compat)(intptr_t)-1;
}
HIDDEN char *catgets(nl_catd_compat catd, int set_id, int msg_id, const char *s) {
    (void)catd; (void)set_id; (void)msg_id;
    return (char *)s;
}
HIDDEN int catclose(nl_catd_compat catd) {
    (void)catd;
    return -1;
}

/* ── glibc ctype tables ──────────────────────────────────────────────────────
 * __ctype_b_loc and __ctype_tolower_loc are glibc internals used by Zig's
 * libc++ ctype<char> facet on Linux targets. Android Bionic does not export
 * them. We provide the standard C/POSIX locale tables.
 *
 * Bit layout — glibc AArch64 little-endian (same as x86_64):
 *   _ISbit(b) = b < 8 ? (1 << (b+8)) : (1 << (b-8))
 *
 *   _ISupper  = 0x0100   _ISblank  = 0x0002
 *   _ISlower  = 0x0200   _ISgraph  = 0x0001
 *   _ISalpha  = 0x0400   _IScntrl  = 0x0004
 *   _ISdigit  = 0x0800
 *   _ISxdigit = 0x1000
 *   _ISspace  = 0x2000
 *   _ISprint  = 0x4000
 *   _ISpunct  = 0x8000
 *
 * The array has 384 entries; the returned pointer points to entry 128 (=char 0)
 * so callers can index by signed char (-128..127) or unsigned char (0..255).
 */

#define _GP  0x4001u  /* print | graph */
#define _GPP 0xC001u  /* print | graph | punct */
#define _GDX 0x5801u  /* print | graph | digit | xdigit */
#define _GUX 0x5501u  /* print | graph | upper | alpha | xdigit */
#define _GUA 0x4501u  /* print | graph | upper | alpha */
#define _GLX 0x5601u  /* print | graph | lower | alpha | xdigit */
#define _GLA 0x4601u  /* print | graph | lower | alpha */
#define _CTL 0x0004u  /* cntrl */
#define _SPC 0x6002u  /* print | space | blank */
#define _CSB 0x2006u  /* cntrl | space | blank  (HT) */
#define _CSP 0x2004u  /* cntrl | space (LF/VT/FF/CR) */

static const unsigned short ctype_b_tab[384] = {
    /* entries 0-127: zero-padding for negative signed-char indexing */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,

    /* chars 0-8:   NUL..BS — control */
    _CTL,_CTL,_CTL,_CTL,_CTL,_CTL,_CTL,_CTL,_CTL,
    /* char  9:     HT — cntrl | space | blank */
    _CSB,
    /* chars 10-13: LF,VT,FF,CR — cntrl | space */
    _CSP,_CSP,_CSP,_CSP,
    /* chars 14-31: SO..US — control */
    _CTL,_CTL,_CTL,_CTL,_CTL,_CTL,_CTL,_CTL,
    _CTL,_CTL,_CTL,_CTL,_CTL,_CTL,_CTL,_CTL,_CTL,_CTL,
    /* char 32:     SPACE — print | space | blank */
    _SPC,
    /* chars 33-47: !"#$%&'()*+,-./ — print | graph | punct */
    _GPP,_GPP,_GPP,_GPP,_GPP,_GPP,_GPP,_GPP,
    _GPP,_GPP,_GPP,_GPP,_GPP,_GPP,_GPP,
    /* chars 48-57: 0..9 — print | graph | digit | xdigit */
    _GDX,_GDX,_GDX,_GDX,_GDX,_GDX,_GDX,_GDX,_GDX,_GDX,
    /* chars 58-64: :;<=>?@ — print | graph | punct */
    _GPP,_GPP,_GPP,_GPP,_GPP,_GPP,_GPP,
    /* chars 65-70: A..F — print | graph | upper | alpha | xdigit */
    _GUX,_GUX,_GUX,_GUX,_GUX,_GUX,
    /* chars 71-90: G..Z — print | graph | upper | alpha */
    _GUA,_GUA,_GUA,_GUA,_GUA,_GUA,_GUA,_GUA,_GUA,_GUA,
    _GUA,_GUA,_GUA,_GUA,_GUA,_GUA,_GUA,_GUA,_GUA,_GUA,
    /* chars 91-96: [\]^_` — print | graph | punct */
    _GPP,_GPP,_GPP,_GPP,_GPP,_GPP,
    /* chars 97-102: a..f — print | graph | lower | alpha | xdigit */
    _GLX,_GLX,_GLX,_GLX,_GLX,_GLX,
    /* chars 103-122: g..z — print | graph | lower | alpha */
    _GLA,_GLA,_GLA,_GLA,_GLA,_GLA,_GLA,_GLA,_GLA,_GLA,
    _GLA,_GLA,_GLA,_GLA,_GLA,_GLA,_GLA,_GLA,_GLA,_GLA,
    /* chars 123-126: {|}~ — print | graph | punct */
    _GPP,_GPP,_GPP,_GPP,
    /* char 127: DEL — control */
    _CTL,
    /* chars 128-255: high bytes — nothing in C locale */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
};
static const unsigned short * const ctype_b_ptr = &ctype_b_tab[128];

HIDDEN const unsigned short **__ctype_b_loc(void) {
    return (const unsigned short **)&ctype_b_ptr;
}

/* __ctype_tolower_loc: C-locale tolower table.
 * Entry [128+c] = tolower(c). A-Z→a-z; all others identity. */
static const int ctype_tolower_tab[384] = {
    /* entries 0-127: identity pad */
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
    16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
    32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,
    48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,
    64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,
    80,81,82,83,84,85,86,87,88,89,90,91,92,93,94,95,
    96,97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,
    112,113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,

    /* chars 0-64: identity */
    0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,
    16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,
    32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,
    48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64,
    /* chars 65-90: A-Z → a-z */
    97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,
    113,114,115,116,117,118,119,120,121,122,
    /* chars 91-255: identity */
    91,92,93,94,95,96,
    97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,
    113,114,115,116,117,118,119,120,121,122,123,124,125,126,127,
    128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,
    144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
    160,161,162,163,164,165,166,167,168,169,170,171,172,173,174,175,
    176,177,178,179,180,181,182,183,184,185,186,187,188,189,190,191,
    192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,
    208,209,210,211,212,213,214,215,216,217,218,219,220,221,222,223,
    224,225,226,227,228,229,230,231,232,233,234,235,236,237,238,239,
    240,241,242,243,244,245,246,247,248,249,250,251,252,253,254,255,
};
static const int * const ctype_tolower_ptr = &ctype_tolower_tab[128];

HIDDEN const int **__ctype_tolower_loc(void) {
    return (const int **)&ctype_tolower_ptr;
}
