/*
 * hidprobe.c — read-only HID inventory for one USB vendor.
 *
 * For every IOHIDDevice in the IORegistry whose VendorID matches, prints the
 * product, transport, usage pairs and report sizes, then decodes the
 * "ReportDescriptor" registry property item by item (usage pages, usages,
 * collections, report IDs, input/output/feature fields). That shows which
 * buttons a device reports (e.g. volume, mute, telephony hook/mute), which LEDs
 * the host may drive, and which vendor-defined reports exist (firmware-update or
 * configuration channels).
 *
 * Only registry properties are read: the device is never opened (so no Input
 * Monitoring permission is needed), no report is read, written or requested.
 *
 * Build:  clang -O1 -Wall -o hidprobe hidprobe.c -framework IOKit -framework CoreFoundation
 * Run:    ./hidprobe           # vendor 0x03f0 (HP)
 *         ./hidprobe 0x05ac    # another vendor
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *page_name(unsigned p) {
    switch (p) {
    case 0x01: return "Generic Desktop";
    case 0x07: return "Keyboard";
    case 0x08: return "LED";
    case 0x09: return "Button";
    case 0x0B: return "Telephony";
    case 0x0C: return "Consumer";
    case 0x0D: return "Digitizer";
    case 0x14: return "Auxiliary Display";
    case 0x80: return "Monitor";
    case 0x81: return "Monitor Enumerated";
    case 0x82: return "VESA Virtual Controls";
    case 0x84: return "Power";
    default: return p >= 0xFF00 ? "Vendor-defined" : "?";
    }
}

/* Names for the usages this kind of device (monitor audio/conferencing HID) commonly uses. */
static const char *usage_name(unsigned page, unsigned u) {
    if (page == 0x0C) switch (u) {
        case 0x01: return "Consumer Control";
        case 0xB5: return "Scan Next";
        case 0xB6: return "Scan Previous";
        case 0xCD: return "Play/Pause";
        case 0xE2: return "Mute";
        case 0xE9: return "Volume Increment";
        case 0xEA: return "Volume Decrement";
        }
    if (page == 0x0B) switch (u) {
        case 0x01: return "Phone";
        case 0x05: return "Headset";
        case 0x07: return "Programmable Button";
        case 0x20: return "Hook Switch";
        case 0x21: return "Flash";
        case 0x24: return "Redial";
        case 0x2F: return "Phone Mute";
        case 0x97: return "Line Busy Tone";
        }
    if (page == 0x08) switch (u) {
        case 0x09: return "Mute LED";
        case 0x17: return "Off-Hook LED";
        case 0x18: return "Ring LED";
        case 0x1E: return "Speaker LED";
        case 0x20: return "Hold LED";
        case 0x21: return "Microphone LED";
        case 0x2A: return "On-Line LED";
        }
    return NULL;
}

static void main_flags(unsigned v) {
    printf("%s,%s,%s%s", v & 1 ? "Const" : "Data", v & 2 ? "Var" : "Array", v & 4 ? "Rel" : "Abs",
           v & 0x20 ? ",NoPreferred" : "");
}

/* Decode HID report descriptor short items. Usages are collected and printed with each main item. */
static void decode(const UInt8 *d, CFIndex n) {
    unsigned page = 0, rsize = 0, rcount = 0, rid = 0, usages[64], nusage = 0;
    long lmin = 0, lmax = 0;
    int depth = 0;
    for (CFIndex i = 0; i < n;) {
        UInt8 pfx = d[i];
        if (pfx == 0xFE) { i += 3 + d[i + 1]; continue; } /* long item: skip */
        int size = (pfx & 3) == 3 ? 4 : (pfx & 3);
        unsigned tag = pfx & 0xFC;
        unsigned long v = 0;
        for (int b = 0; b < size && i + 1 + b < n; b++) v |= (unsigned long)d[i + 1 + b] << (8 * b);
        long sv = size == 1 ? (long)(int8_t)v : size == 2 ? (long)(int16_t)v : (long)(int32_t)v;
        i += 1 + size;
        switch (tag) {
        case 0x04: page = (unsigned)v; break;
        case 0x14: lmin = sv; break;
        case 0x24: lmax = size == 1 || size == 2 ? (long)v : sv; break;
        case 0x74: rsize = (unsigned)v; break;
        case 0x94: rcount = (unsigned)v; break;
        case 0x84: rid = (unsigned)v; break;
        case 0x08:
            if (nusage < 64) usages[nusage++] = size == 4 ? (unsigned)v : (page << 16) | (unsigned)v;
            break;
        case 0xA0: {
            static const char *const kinds[] = {"Physical", "Application", "Logical", "Report", "Named Array", "Usage Switch", "Usage Modifier"};
            unsigned u = nusage ? usages[0] : 0;
            const char *un = usage_name(u >> 16, u & 0xFFFF);
            printf("%*sCollection %s: %s page 0x%04x usage 0x%04x%s%s%s\n", depth * 2 + 4, "", v < 7 ? kinds[v] : "?",
                   page_name(u >> 16), u >> 16, u & 0xFFFF, un ? " (" : "", un ? un : "", un ? ")" : "");
            depth++;
            nusage = 0;
            break;
        }
        case 0xC0: depth--; printf("%*sEnd Collection\n", depth * 2 + 4, ""); break;
        case 0x80: case 0x90: case 0xB0: {
            const char *kind = tag == 0x80 ? "Input  " : tag == 0x90 ? "Output " : "Feature";
            printf("%*s%s report %-3u %2u x %2u bit [", depth * 2 + 4, "", kind, rid, rcount, rsize);
            main_flags((unsigned)v);
            printf("] range %ld..%ld", lmin, lmax);
            if (!(v & 1)) {
                printf(" :");
                for (unsigned k = 0; k < nusage; k++) {
                    unsigned up = usages[k] >> 16, uu = usages[k] & 0xFFFF;
                    const char *un = usage_name(up, uu);
                    if (un) printf(" %s", un);
                    else if (up == 0x09) printf(" Button %u", uu);
                    else printf(" %s(0x%04x):0x%x", page_name(up), up, uu);
                }
            } else {
                printf(" (padding)");
            }
            printf("\n");
            nusage = 0;
            break;
        }
        default: break; /* physical/unit/exponent/string/delimiter items: not needed here */
        }
    }
}

static long num(io_service_t s, CFStringRef k) {
    long v = -1;
    CFTypeRef r = IORegistryEntryCreateCFProperty(s, k, NULL, 0);
    if (r && CFGetTypeID(r) == CFNumberGetTypeID()) CFNumberGetValue(r, kCFNumberLongType, &v);
    if (r) CFRelease(r);
    return v;
}

static void str(io_service_t s, CFStringRef k, char *buf, size_t len) {
    buf[0] = 0;
    CFTypeRef r = IORegistryEntryCreateCFProperty(s, k, NULL, 0);
    if (r && CFGetTypeID(r) == CFStringGetTypeID()) CFStringGetCString(r, buf, (CFIndex)len, kCFStringEncodingUTF8);
    if (r) CFRelease(r);
}

int main(int argc, char **argv) {
    long want = argc > 1 ? strtol(argv[1], NULL, 0) : 0x03f0;
    io_iterator_t it;
    /* IOHIDInterface sits under the USB interface; one per HID function, carrying the descriptor. */
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDInterface"), &it) != KERN_SUCCESS) return 1;
    io_service_t s;
    int found = 0;
    while ((s = IOIteratorNext(it))) {
        if (num(s, CFSTR(kIOHIDVendorIDKey)) != want) { IOObjectRelease(s); continue; }
        char product[128], transport[32];
        str(s, CFSTR(kIOHIDProductKey), product, sizeof product);
        str(s, CFSTR(kIOHIDTransportKey), transport, sizeof transport);
        printf("\n== %s  %04lx:%04lx  transport %s  location 0x%08lx\n", product, num(s, CFSTR(kIOHIDVendorIDKey)),
               num(s, CFSTR(kIOHIDProductIDKey)), transport, num(s, CFSTR(kIOHIDLocationIDKey)));
        printf("    primary usage %s 0x%lx / 0x%lx; max report sizes in %ld out %ld feature %ld bytes\n",
               page_name((unsigned)num(s, CFSTR(kIOHIDPrimaryUsagePageKey))), num(s, CFSTR(kIOHIDPrimaryUsagePageKey)),
               num(s, CFSTR(kIOHIDPrimaryUsageKey)), num(s, CFSTR(kIOHIDMaxInputReportSizeKey)),
               num(s, CFSTR(kIOHIDMaxOutputReportSizeKey)), num(s, CFSTR(kIOHIDMaxFeatureReportSizeKey)));
        CFTypeRef rd = IORegistryEntryCreateCFProperty(s, CFSTR(kIOHIDReportDescriptorKey), NULL, 0);
        if (rd && CFGetTypeID(rd) == CFDataGetTypeID()) {
            printf("    report descriptor (%ld bytes):\n", CFDataGetLength(rd));
            decode(CFDataGetBytePtr(rd), CFDataGetLength(rd));
        }
        if (rd) CFRelease(rd);
        IOObjectRelease(s);
        found++;
    }
    IOObjectRelease(it);
    if (!found) printf("no HID interface with vendor 0x%04lx\n", want);
    return 0;
}
