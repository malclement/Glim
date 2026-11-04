// glim — talk DDC/CI (VESA MCCS) to an external monitor on Apple Silicon Macs.
//
// Transport: the private IOAVService I2C API exposed by the DCP display
// coprocessor (the same path m1ddc, MonitorControl and BetterDisplay use).
// The monitor is I2C slave 0x37; host frames are sent with sub-address 0x51.
//
// Build:  make            (or: clang -O2 -Wall -o glim src/glim.c -framework IOKit -framework CoreFoundation)
// Usage:  glim help
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ---- private IOAVService API (IOKit, not in public headers) ---------------
typedef CFTypeRef IOAVServiceRef;
extern IOAVServiceRef IOAVServiceCreateWithService(CFAllocatorRef, io_service_t);
extern IOReturn IOAVServiceReadI2C(IOAVServiceRef, uint32_t chip, uint32_t off, void *buf, uint32_t len);
extern IOReturn IOAVServiceWriteI2C(IOAVServiceRef, uint32_t chip, uint32_t addr, void *buf, uint32_t len);

#define DDC_CHIP 0x37
#define DDC_SUBADDR 0x51
#define DDC_DEST 0x6E   // display's 8-bit write address, folded into the host checksum
#define DDC_HOST 0x50   // host virtual address, folded into the reply checksum

static int verbose = 0;
static useconds_t write_delay_us = 10000;   // between duplicated writes
static useconds_t reply_delay_us = 50000;   // MCCS asks for >= 40 ms before reading a reply
static int write_repeats = 2;               // DCP drops the first write now and then; m1ddc does the same

// ---- display discovery ------------------------------------------------------
#define MAX_DISPLAYS 8
static IOAVServiceRef services[MAX_DISPLAYS];
static int n_services = 0;

static void discover(void) {
    io_iterator_t it;
    io_registry_entry_t root = IORegistryGetRootEntry(kIOMainPortDefault);
    if (IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &it) != KERN_SUCCESS) return;
    io_service_t s;
    while ((s = IOIteratorNext(it)) && n_services < MAX_DISPLAYS) {
        io_name_t name;
        IORegistryEntryGetName(s, name);
        if (strcmp(name, "DCPAVServiceProxy") == 0) {
            CFStringRef loc = IORegistryEntryCreateCFProperty(s, CFSTR("Location"), kCFAllocatorDefault, 0);
            if (loc && CFStringCompare(loc, CFSTR("External"), 0) == kCFCompareEqualTo) {
                IOAVServiceRef sv = IOAVServiceCreateWithService(kCFAllocatorDefault, s);
                if (sv) services[n_services++] = sv;
            }
            if (loc) CFRelease(loc);
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
}

// ---- framing ------------------------------------------------------------------
static void hexdump(const char *tag, const uint8_t *b, int n) {
    if (!verbose) return;
    fprintf(stderr, "%s", tag);
    for (int i = 0; i < n; i++) fprintf(stderr, " %02X", b[i]);
    fprintf(stderr, "\n");
}

// Send one DDC/CI message. `payload` is the op-code and its arguments.
static int ddc_send(IOAVServiceRef sv, const uint8_t *payload, int n) {
    uint8_t buf[64];
    buf[0] = 0x80 | n;
    memcpy(buf + 1, payload, n);
    uint8_t chk = DDC_DEST ^ DDC_SUBADDR;
    for (int i = 0; i < n + 1; i++) chk ^= buf[i];
    buf[n + 1] = chk;
    hexdump("  -> 51", buf, n + 2);
    IOReturn r = kIOReturnError;
    for (int i = 0; i < write_repeats; i++) {
        usleep(write_delay_us);
        r = IOAVServiceWriteI2C(sv, DDC_CHIP, DDC_SUBADDR, buf, n + 2);
    }
    return r == kIOReturnSuccess;
}

// Read a reply. Returns payload length (op-code onward) or -1. Validates checksum.
static int ddc_recv(IOAVServiceRef sv, uint8_t *payload, int maxlen) {
    uint8_t r[64] = {0};
    usleep(reply_delay_us);
    if (IOAVServiceReadI2C(sv, DDC_CHIP, DDC_SUBADDR, r, 40) != kIOReturnSuccess) return -1;
    int len = r[1] & 0x7F;
    hexdump("  <-", r, len + 3 > 40 ? 40 : len + 3);
    // The timing reply (op 0x4E) is sent with a bare length byte (0x06, no 0x80 bit).
    if (r[0] != DDC_DEST || len + 3 > 40) return -1;
    if (!(r[1] & 0x80) && !(len == 6 && r[2] == 0x4E)) return -1;
    uint8_t chk = DDC_HOST;
    for (int i = 0; i < len + 2; i++) chk ^= r[i];
    if (chk != r[len + 2]) { if (verbose) fprintf(stderr, "  checksum mismatch\n"); return -1; }
    if (len > maxlen) len = maxlen;
    memcpy(payload, r + 2, len);
    return len;
}

// ---- MCCS operations ----------------------------------------------------------
enum { VCP_OK = 1, VCP_UNSUPPORTED = 0, VCP_NOREPLY = -1 };

static int vcp_get(IOAVServiceRef sv, uint8_t code, int *type, int *cur, int *max) {
    uint8_t q[2] = {0x01, code}, r[40];
    for (int attempt = 0; attempt < 4; attempt++) {
        if (!ddc_send(sv, q, 2)) continue;
        int n = ddc_recv(sv, r, sizeof r);
        // 02 rc code type mh ml ch cl
        if (n < 8 || r[0] != 0x02 || r[2] != code) continue;
        if (r[1] != 0) return VCP_UNSUPPORTED;
        *type = r[3]; *max = (r[4] << 8) | r[5]; *cur = (r[6] << 8) | r[7];
        return VCP_OK;
    }
    return VCP_NOREPLY;
}

static int vcp_set(IOAVServiceRef sv, uint8_t code, int value) {
    uint8_t q[4] = {0x03, code, (uint8_t)(value >> 8), (uint8_t)(value & 0xFF)};
    return ddc_send(sv, q, 4);
}

// ---- named codes --------------------------------------------------------------
struct named { const char *name; uint8_t code; };
static const struct named names[] = {
    {"brightness", 0x10}, {"luminance", 0x10}, {"contrast", 0x12},
    {"red", 0x16}, {"green", 0x18}, {"blue", 0x1A},
    {"red-black", 0x6C}, {"green-black", 0x6E}, {"blue-black", 0x70},
    {"color-preset", 0x14}, {"color-temp", 0x0C}, {"sharpness", 0x87},
    {"scaling", 0x86}, {"input", 0x60}, {"volume", 0x62}, {"mute", 0x8D},
    {"osd", 0xCA}, {"language", 0xCC}, {"power", 0xD6}, {"display-mode", 0xDC},
    {"usage-hours", 0xC0}, {"firmware", 0xC9}, {"mccs-version", 0xDF},
    {"h-freq", 0xAC}, {"v-freq", 0xAE}, {"orientation", 0xAA},
};

static int parse_code(const char *s) {
    for (size_t i = 0; i < sizeof names / sizeof *names; i++)
        if (strcasecmp(s, names[i].name) == 0) return names[i].code;
    char *end; long v = strtol(s, &end, 16);
    if (*end || v < 0 || v > 0xFF) return -1;
    return (int)v;
}

static long parse_num(const char *s) {   // decimal, or hex with 0x prefix
    char *end; long v = strtol(s, &end, 0);
    if (*end) { fprintf(stderr, "bad number: %s\n", s); exit(2); }
    return v;
}

// Writes that can blank the screen, drop it off the bus, or wipe settings.
static int is_dangerous(uint8_t code) {
    return code == 0x04 || code == 0x60 || code == 0xD6 || code == 0xCA || code == 0xDC || code >= 0xE0;
}

// ---- commands -----------------------------------------------------------------
static int cmd_caps(IOAVServiceRef sv) {
    char caps[4096] = {0};
    int total = 0, fails = 0;
    while (total < 4000 && fails < 6) {
        uint8_t q[3] = {0xF3, (uint8_t)(total >> 8), (uint8_t)(total & 0xFF)}, r[40];
        ddc_send(sv, q, 3);
        int n = ddc_recv(sv, r, sizeof r);
        // E3 offH offL data...
        if (n < 3 || r[0] != 0xE3 || ((r[1] << 8) | r[2]) != total) { fails++; continue; }
        if (n == 3) break;                 // empty fragment = end of string
        memcpy(caps + total, r + 3, n - 3);
        total += n - 3;
        fails = 0;
    }
    if (!total) { fprintf(stderr, "no capabilities reply\n"); return 1; }
    // strip trailing NUL padding some monitors send
    while (total && caps[total - 1] == 0) total--;
    caps[total] = 0;
    printf("%s\n", caps);
    return 0;
}

static int cmd_scan(IOAVServiceRef sv, int show_all) {
    for (int c = 0; c < 256; c++) {
        int t, cur, max;
        int ok = vcp_get(sv, (uint8_t)c, &t, &cur, &max);
        if (ok == VCP_OK) printf("0x%02X ok          type=%d cur=%d (0x%04X) max=%d (0x%04X)\n", c, t, cur, cur, max, max);
        else if (show_all) printf("0x%02X %s\n", c, ok == VCP_UNSUPPORTED ? "unsupported" : "no-reply");
        fflush(stdout);
    }
    return 0;
}

static int cmd_get(IOAVServiceRef sv, int code) {
    int t, cur, max;
    int ok = vcp_get(sv, (uint8_t)code, &t, &cur, &max);
    if (ok == VCP_OK) { printf("0x%02X type=%d cur=%d (0x%04X) max=%d (0x%04X)\n", code, t, cur, cur, max, max); return 0; }
    printf("0x%02X %s\n", code, ok == VCP_UNSUPPORTED ? "unsupported" : "no-reply");
    return 1;
}

static int cmd_set(IOAVServiceRef sv, int code, long value, int force, int verify) {
    if (value < 0 || value > 0xFFFF) { fprintf(stderr, "value out of range 0..65535\n"); return 2; }
    if (is_dangerous((uint8_t)code) && !force) {
        fprintf(stderr, "0x%02X can blank the screen, drop the monitor off DDC, or wipe settings. Re-run with --force.\n", code);
        return 2;
    }
    if (!vcp_set(sv, (uint8_t)code, (int)value)) { fprintf(stderr, "write failed\n"); return 1; }
    if (!verify) { printf("0x%02X <- %ld\n", code, value); return 0; }
    // The first GET after a SET often reads 0 on some monitors; give it time and retry.
    usleep(200000);
    int t, cur = -1, max;
    for (int i = 0; i < 3; i++) {
        if (vcp_get(sv, (uint8_t)code, &t, &cur, &max) == VCP_OK && cur == value) break;
        usleep(150000);
    }
    printf("0x%02X <- %ld, reads back %d\n", code, value, cur);
    return 0;
}

static int cmd_timing(IOAVServiceRef sv) {
    uint8_t q[1] = {0x07}, r[40];
    for (int attempt = 0; attempt < 4; attempt++) {
        ddc_send(sv, q, 1);
        int n = ddc_recv(sv, r, sizeof r);
        // 4E status hH hL vH vL — H frequency in 10 Hz units, V frequency in 0.01 Hz units.
        if (n >= 6 && r[0] == 0x4E) {
            int h = (r[2] << 8) | r[3], v = (r[4] << 8) | r[5];
            printf("horizontal %.2f kHz, vertical %.2f Hz (status 0x%02X)\n", h / 100.0, v / 100.0, r[1]);
            printf("  h-sync %s, v-sync %s, out-of-range %s, unstable-count %s\n",
                   (r[1] & 0x02) ? "positive" : "negative", (r[1] & 0x01) ? "positive" : "negative",
                   (r[1] & 0x80) ? "yes" : "no", (r[1] & 0x40) ? "yes" : "no");
            return 0;
        }
    }
    fprintf(stderr, "no timing reply\n");
    return 1;
}

static int cmd_save(IOAVServiceRef sv) {
    uint8_t q[1] = {0x0C};
    if (!ddc_send(sv, q, 1)) { fprintf(stderr, "write failed\n"); return 1; }
    printf("save-current-settings sent\n");
    return 0;
}

static int cmd_raw(IOAVServiceRef sv, int argc, char **argv, int expect_reply) {
    uint8_t q[32];
    int n = 0;
    for (int i = 0; i < argc && n < 30; i++) q[n++] = (uint8_t)strtol(argv[i], NULL, 16);
    int saved = verbose; verbose = 1;
    ddc_send(sv, q, n);
    if (expect_reply) {
        uint8_t r[40];
        int m = ddc_recv(sv, r, sizeof r);
        if (m < 0) printf("no valid reply\n");
        else { printf("reply:"); for (int i = 0; i < m; i++) printf(" %02X", r[i]); printf("\n"); }
    }
    verbose = saved;
    return 0;
}

// ---- HP sub-coded vendor codes (DC E1 E8 EB F5 F8 on the E27m G4) -------------
// Protocol taken from HP Display Center's tables (see docs/controls.md §HP).
// UNTESTED on hardware: every call issues a Set, even the reads.
//   write: Set(code, sub<<8 | value)
//   read : Set(code, 0x8000 | sub<<8), wait 200 ms, Get(code) -> answer in SL
//   text : Set(code, 0x8000 | sub<<8 | chunk), Get -> 4 ASCII bytes in MH ML SH SL, until 0x00
static int hp_select(IOAVServiceRef sv, uint8_t code, int sub, int chunk) {
    if (!vcp_set(sv, code, 0x8000 | (sub << 8) | chunk)) return 0;
    usleep(200000);
    return 1;
}

static int cmd_hp_get(IOAVServiceRef sv, int code, int sub) {
    if (!hp_select(sv, (uint8_t)code, sub, 0)) { fprintf(stderr, "select write failed\n"); return 1; }
    int t, cur, max;
    int ok = vcp_get(sv, (uint8_t)code, &t, &cur, &max);
    if (ok != VCP_OK) { printf("0x%02X/%02X %s\n", code, sub, ok == VCP_UNSUPPORTED ? "unsupported" : "no-reply"); return 1; }
    printf("0x%02X/%02X value=%d (0x%02X)  raw cur=0x%04X max=0x%04X\n", code, sub, cur & 0xFF, cur & 0xFF, cur, max);
    return 0;
}

static int cmd_hp_set(IOAVServiceRef sv, int code, int sub, long value) {
    if (value < 0 || value > 0xFF || sub < 0 || sub > 0x7F) { fprintf(stderr, "sub must be 00-7F, value 00-FF\n"); return 2; }
    if (!vcp_set(sv, (uint8_t)code, (sub << 8) | (int)value)) { fprintf(stderr, "write failed\n"); return 1; }
    printf("0x%02X/%02X <- 0x%02lX\n", code, sub, value);
    return 0;
}

static int cmd_hp_string(IOAVServiceRef sv, int code, int sub) {
    char out[257] = {0};
    int n = 0;
    for (int chunk = 0; chunk < 64 && n < 252; chunk++) {
        if (!hp_select(sv, (uint8_t)code, sub, chunk)) break;
        int t, cur, max;
        if (vcp_get(sv, (uint8_t)code, &t, &cur, &max) != VCP_OK) break;
        uint8_t b[4] = {(uint8_t)(max >> 8), (uint8_t)max, (uint8_t)(cur >> 8), (uint8_t)cur};
        int done = 0;
        for (int k = 0; k < 4; k++) { if (!b[k]) { done = 1; break; } out[n++] = (char)b[k]; }
        if (done) break;
    }
    printf("0x%02X/%02X \"%s\"\n", code, sub, out);
    return n ? 0 : 1;
}

static void usage(void) {
    puts("glim — DDC/CI control for external monitors on Apple Silicon\n"
         "\n"
         "  glim list                      external displays reachable over DDC\n"
         "  glim caps                      MCCS capabilities string\n"
         "  glim scan [--all]              GET every VCP code 00-FF (--all also lists unsupported/no-reply)\n"
         "  glim get <code>                read one VCP code (hex like 10, or a name like brightness)\n"
         "  glim set <code> <value>        write one VCP code, then read it back\n"
         "  glim timing                    DDC/CI timing report (sync polarity, frequencies)\n"
         "  glim save                      DDC/CI 'save current settings' (0x0C)\n"
         "  glim raw <hex bytes...>        send an arbitrary DDC/CI payload and print the reply\n"
         "  glim raw-send <hex bytes...>   send an arbitrary payload, don't read a reply\n"
         "\n"
         "HP sub-coded vendor codes (UNTESTED, all need --force — even reads issue a Set):\n"
         "  glim --force hp-get <code> <sub>          e.g. hp-get E1 0F   (auto-sleep)\n"
         "  glim --force hp-set <code> <sub> <value>  e.g. hp-set E1 0F 0 (auto-sleep off)\n"
         "  glim --force hp-string <code> <sub>       e.g. hp-string F5 0D (model name)\n"
         "\n"
         "options (before the command):\n"
         "  -d N        use external display N (1-based, default 1)\n"
         "  -v          hex-dump every frame on stderr\n"
         "  --force     allow writes to codes that can blank/unreach the monitor (04 60 CA D6 DC E0-FF)\n"
         "  --no-verify don't read back after set\n"
         "\n"
         "names: brightness contrast red green blue red-black green-black blue-black color-preset\n"
         "       color-temp sharpness scaling input volume mute osd language power display-mode\n"
         "       usage-hours firmware mccs-version h-freq v-freq orientation\n"
         "\n"
         "See docs/controls.md for what every code does on the HP E27m G4.");
}

int main(int argc, char **argv) {
    int display = 1, force = 0, verify = 1, i = 1;
    for (; i < argc && argv[i][0] == '-'; i++) {
        if (!strcmp(argv[i], "-v")) verbose = 1;
        else if (!strcmp(argv[i], "--force")) force = 1;
        else if (!strcmp(argv[i], "--no-verify")) verify = 0;
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) display = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) { usage(); return 0; }
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }
    if (i >= argc || !strcmp(argv[i], "help")) { usage(); return i >= argc ? 2 : 0; }
    const char *cmd = argv[i++];

    discover();
    if (!strcmp(cmd, "list")) {
        for (int k = 0; k < n_services; k++) printf("[%d] external DCPAVServiceProxy\n", k + 1);
        if (!n_services) printf("no external display found\n");
        return 0;
    }
    if (display < 1 || display > n_services) { fprintf(stderr, "no external display %d (found %d)\n", display, n_services); return 1; }
    IOAVServiceRef sv = services[display - 1];

    if (!strcmp(cmd, "caps")) return cmd_caps(sv);
    if (!strcmp(cmd, "scan")) return cmd_scan(sv, i < argc && !strcmp(argv[i], "--all"));
    if (!strcmp(cmd, "timing")) return cmd_timing(sv);
    if (!strcmp(cmd, "save")) return cmd_save(sv);
    if (!strcmp(cmd, "raw")) return cmd_raw(sv, argc - i, argv + i, 1);
    if (!strcmp(cmd, "raw-send")) return cmd_raw(sv, argc - i, argv + i, 0);
    if (!strncmp(cmd, "hp-", 3)) {
        int need = !strcmp(cmd, "hp-set") ? 3 : 2;
        if (argc - i < need) { usage(); return 2; }
        if (!force) {
            fprintf(stderr, "%s issues a Set to an HP vendor code (untested protocol). Re-run with --force.\n", cmd);
            return 2;
        }
        int code = parse_code(argv[i]);
        int sub = (int)strtol(argv[i + 1], NULL, 16);
        if (code < 0) { fprintf(stderr, "unknown code %s\n", argv[i]); return 2; }
        if (!strcmp(cmd, "hp-get")) return cmd_hp_get(sv, code, sub);
        if (!strcmp(cmd, "hp-string")) return cmd_hp_string(sv, code, sub);
        if (!strcmp(cmd, "hp-set")) return cmd_hp_set(sv, code, sub, strtol(argv[i + 2], NULL, 16));
    }
    if ((!strcmp(cmd, "get") && i < argc) || (!strcmp(cmd, "set") && i + 1 < argc)) {
        int code = parse_code(argv[i]);
        if (code < 0) { fprintf(stderr, "unknown code %s\n", argv[i]); return 2; }
        if (!strcmp(cmd, "get")) return cmd_get(sv, code);
        return cmd_set(sv, code, parse_num(argv[i + 1]), force, verify);
    }
    usage();
    return 2;
}
