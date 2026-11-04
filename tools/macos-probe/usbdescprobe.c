/*
 * usbdescprobe.c — read-only USB configuration-descriptor dump for one vendor's
 * devices, with class-specific decoding for:
 *   - USB Audio Class 1/2 (terminals, feature units → which mute/volume/… controls
 *     exist per channel, streaming formats and sample rates)
 *   - USB Video Class (camera-terminal and processing-unit control bitmaps,
 *     extension-unit GUIDs, stream formats and frame sizes) — what a UVC webcam
 *     such as the HP E27m G4 pop-up camera advertises
 *   - HID (report-descriptor length) and IADs / endpoints for everything else
 *
 * It obtains the descriptor with IOUSBDeviceInterface::GetConfigurationDescriptorPtr,
 * which returns the copy the host already cached at enumeration. It never calls
 * USBDeviceOpen, never issues a control request, never changes a configuration
 * or alternate setting. Nothing is sent to the device.
 *
 * Build:  clang -O1 -Wall -o usbdescprobe usbdescprobe.c -framework IOKit -framework CoreFoundation
 * Run:    ./usbdescprobe            # vendor 0x03f0 (HP)
 *         ./usbdescprobe 0x046d     # another vendor ID
 *         ./usbdescprobe all        # every USB device
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------- small helpers ---------- */

static unsigned le16(const UInt8 *p) { return p[0] | (p[1] << 8); }
static unsigned le24(const UInt8 *p) { return p[0] | (p[1] << 8) | (p[2] << 16); }
static unsigned le32(const UInt8 *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((unsigned)p[3] << 24); }

/* Print the names of the set bits of a little-endian bitmap of `size` bytes. */
static void print_bits(const UInt8 *bm, int size, const char *const *names, int nnames) {
    int any = 0;
    for (int bit = 0; bit < size * 8; bit++) {
        if (!(bm[bit / 8] & (1 << (bit % 8)))) continue;
        printf("%s%s", any ? ", " : "", bit < nnames && names[bit] ? names[bit] : "?");
        if (bit >= nnames || !names[bit]) printf("(bit %d)", bit);
        any = 1;
    }
    printf("%s\n", any ? "" : "none");
}

static void print_guid(const UInt8 *g) {
    /* USB GUIDs are stored little-endian in the first three groups. */
    printf("{%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x}", le32(g), le16(g + 4), le16(g + 6),
           g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15]);
}

/* ---------- control-name tables ---------- */

static const char *const uac1_feature[] = {"mute", "volume", "bass", "mid", "treble", "graphic-EQ",
                                           "AGC", "delay", "bass-boost", "loudness"};
static const char *const uac2_feature[] = {"mute", "volume", "bass", "mid", "treble", "graphic-EQ", "AGC", "delay",
                                           "bass-boost", "loudness", "input-gain", "input-gain-pad", "phase-inverter",
                                           "underflow", "overflow"};
static const char *const uvc_camera[] = {
    "scanning-mode", "auto-exposure-mode", "auto-exposure-priority", "exposure-time-abs", "exposure-time-rel",
    "focus-abs", "focus-rel", "iris-abs", "iris-rel", "zoom-abs", "zoom-rel", "pan-tilt-abs", "pan-tilt-rel",
    "roll-abs", "roll-rel", NULL, NULL, "focus-auto", "privacy", "focus-simple", "window", "region-of-interest"};
static const char *const uvc_processing[] = {
    "brightness", "contrast", "hue", "saturation", "sharpness", "gamma", "white-balance-temperature",
    "white-balance-component", "backlight-compensation", "gain", "power-line-frequency", "hue-auto",
    "white-balance-temperature-auto", "white-balance-component-auto", "digital-multiplier",
    "digital-multiplier-limit", "analog-video-standard", "analog-video-lock-status", "contrast-auto"};

static const char *terminal_type(unsigned t) {
    switch (t) {
    case 0x0101: return "USB streaming";
    case 0x0201: return "microphone";
    case 0x0202: return "desktop microphone";
    case 0x0205: return "microphone array";
    case 0x0301: return "speaker";
    case 0x0302: return "headphones";
    case 0x0304: return "desktop speaker";
    case 0x0402: return "headset";
    case 0x0403: return "speakerphone";
    case 0x0405: return "echo-cancelling speakerphone";
    case 0x0603: return "line connector";
    default: return "other";
    }
}

static const char *class_name(int c) {
    switch (c) {
    case 0x01: return "Audio";
    case 0x02: return "CDC control";
    case 0x03: return "HID";
    case 0x08: return "Mass storage";
    case 0x09: return "Hub";
    case 0x0A: return "CDC data";
    case 0x0E: return "Video";
    case 0x0F: return "Personal healthcare";
    case 0x10: return "Audio/Video";
    case 0x11: return "Billboard";
    case 0x12: return "USB-C bridge";
    case 0xDC: return "Diagnostic";
    case 0xE0: return "Wireless";
    case 0xEF: return "Misc";
    case 0xFE: return "Application specific (DFU/IrDA/test)";
    case 0xFF: return "Vendor specific";
    default: return "?";
    }
}

/* ---------- class-specific decoders ---------- */

static unsigned uac_version; /* bcdADC of the current audio function */

static void audio_control(const UInt8 *d) {
    int len = d[0];
    switch (d[2]) {
    case 0x01:
        uac_version = le16(d + 3);
        printf("        AC header: UAC %x.%02x\n", uac_version >> 8, uac_version & 0xFF);
        break;
    case 0x02:
        printf("        input terminal %u: type 0x%04x (%s), %u ch\n", d[3], le16(d + 4), terminal_type(le16(d + 4)),
               uac_version >= 0x200 ? d[8] : d[7]);
        break;
    case 0x03:
        printf("        output terminal %u: type 0x%04x (%s), source %u\n", d[3], le16(d + 4), terminal_type(le16(d + 4)),
               d[7]);
        break;
    case 0x06:
        if (uac_version >= 0x200) { /* UAC2: 4-byte bmaControls, 2 bits per control (01 read, 11 read/write) */
            int n = (len - 6) / 4;
            printf("        feature unit %u (source %u):\n", d[3], d[4]);
            for (int ch = 0; ch < n; ch++) {
                unsigned bm = le32(d + 5 + ch * 4);
                printf("          %s: ", ch ? "channel" : "master ");
                if (ch) printf("%d ", ch);
                int any = 0;
                for (int c = 0; c < 15; c++) {
                    unsigned v = (bm >> (c * 2)) & 3;
                    if (v) { printf("%s%s(%s)", any ? ", " : "", uac2_feature[c], v == 3 ? "rw" : "ro"); any = 1; }
                }
                printf("%s\n", any ? "" : "none");
            }
        } else { /* UAC1: bControlSize bytes per channel, master first */
            int sz = d[5], n = sz ? (len - 7) / sz : 0;
            printf("        feature unit %u (source %u):\n", d[3], d[4]);
            for (int ch = 0; ch < n; ch++) {
                printf("          %s", ch ? "channel " : "master: ");
                if (ch) printf("%d: ", ch);
                print_bits(d + 6 + ch * sz, sz, uac1_feature, 10);
            }
        }
        break;
    case 0x04:
    case 0x05: /* mixer / selector: bNrInPins then baSourceID[] */
        printf("        %s unit %u, inputs from:", d[2] == 0x04 ? "mixer" : "selector", d[3]);
        for (int i = 0; i < d[4]; i++) printf(" %u", d[5 + i]);
        printf("\n");
        break;
    case 0x07: printf("        processing unit %u, process type 0x%04x\n", d[3], le16(d + 4)); break;
    case 0x08: printf("        extension unit %u, code 0x%04x\n", d[3], le16(d + 4)); break;
    case 0x0A: printf("        clock source %u (UAC2)\n", d[3]); break;
    default: printf("        AC subtype 0x%02x\n", d[2]);
    }
}

static void audio_streaming(const UInt8 *d) {
    switch (d[2]) {
    case 0x01:
        printf("        AS general: terminal link %u, format tag 0x%04x\n", d[3], uac_version >= 0x200 ? d[5] : le16(d + 5));
        break;
    case 0x02:
        if (uac_version >= 0x200) {
            printf("        format type %u: subslot %u bytes, %u bits\n", d[3], d[4], d[5]);
        } else {
            printf("        format type %u: %u ch, %u-byte subframe, %u bits, rates:", d[3], d[4], d[5], d[6]);
            if (d[7] == 0) printf(" continuous %u–%u Hz", le24(d + 8), le24(d + 11));
            for (int i = 0; i < d[7]; i++) printf(" %u", le24(d + 8 + i * 3));
            printf("\n");
        }
        break;
    default: printf("        AS subtype 0x%02x\n", d[2]);
    }
}

static void video_control(const UInt8 *d) {
    switch (d[2]) {
    case 0x01: printf("        VC header: UVC %x.%02x, clock %u Hz\n", d[4], d[3], le32(d + 7)); break;
    case 0x02: {
        unsigned type = le16(d + 4);
        printf("        input terminal %u: type 0x%04x%s\n", d[3], type, type == 0x0201 ? " (camera)" : "");
        if (type == 0x0201) {
            printf("          camera controls: ");
            print_bits(d + 15, d[14], uvc_camera, 22);
        }
        break;
    }
    case 0x03: printf("        output terminal %u: type 0x%04x, source %u\n", d[3], le16(d + 4), d[7]); break;
    case 0x04: printf("        selector unit %u, %u inputs\n", d[3], d[4]); break;
    case 0x05:
        printf("        processing unit %u (source %u), max digital multiplier %u\n", d[3], d[4], le16(d + 5));
        printf("          processing controls: ");
        print_bits(d + 8, d[7], uvc_processing, 19);
        break;
    case 0x06: {
        printf("        extension unit %u GUID ", d[3]);
        print_guid(d + 4);
        int nin = d[21], csize = d[22 + nin];
        printf(", %u controls, bitmap", d[20]);
        for (int i = 0; i < csize; i++) printf(" %02x", d[23 + nin + i]);
        printf("\n");
        break;
    }
    case 0x07: printf("        encoding unit %u (UVC 1.5)\n", d[3]); break;
    default: printf("        VC subtype 0x%02x\n", d[2]);
    }
}

static void video_streaming(const UInt8 *d) {
    switch (d[2]) {
    case 0x01: printf("        VS input header: %u formats, endpoint 0x%02x\n", d[3], d[6]); break;
    case 0x04:
        printf("        format %u uncompressed '%.4s', %u bpp, %u frames\n", d[3], (const char *)(d + 5), d[21], d[4]);
        break;
    case 0x06: printf("        format %u MJPEG, %u frames\n", d[3], d[4]); break;
    case 0x10: printf("        format %u frame-based '%.4s', %u frames\n", d[3], (const char *)(d + 5), d[4]); break;
    case 0x05: case 0x07: case 0x11: {
        /* Uncompressed/MJPEG frames: default interval @21, interval count @25.
           Frame-based (H.264 etc.): default @17, count @21. Intervals start @26 in both. */
        unsigned w = le16(d + 5), h = le16(d + 7);
        int frame_based = d[2] == 0x11;
        unsigned def = le32(d + (frame_based ? 17 : 21));
        int ni = d[frame_based ? 21 : 25];
        printf("          frame %u: %ux%u, default %.2f fps", d[3], w, h, def ? 1e7 / def : 0);
        if (ni == 0) {
            printf(", continuous %.2f–%.2f fps", 1e7 / le32(d + 30), 1e7 / le32(d + 26));
        } else {
            printf(", fps:");
            for (int i = 0; i < ni; i++) printf(" %.2f", 1e7 / le32(d + 26 + i * 4));
        }
        printf("\n");
        break;
    }
    case 0x0D: printf("        colour matching: primaries %u, transfer %u, matrix %u\n", d[3], d[4], d[5]); break;
    default: printf("        VS subtype 0x%02x\n", d[2]);
    }
}

/* ---------- configuration walk ---------- */

static void walk(const UInt8 *p, unsigned total) {
    int cls = -1, sub = -1;
    for (unsigned off = 0; off + 2 <= total && p[off] >= 2; off += p[off]) {
        const UInt8 *d = p + off;
        switch (d[1]) {
        case 0x02:
            printf("    configuration %u: %u interfaces, attributes 0x%02x (%s%s), max power %u mA\n", d[5], d[4], d[7],
                   d[7] & 0x40 ? "self-powered" : "bus-powered", d[7] & 0x20 ? ", remote wakeup" : "", d[8] * 2);
            break;
        case 0x0B:
            printf("    IAD: interfaces %u–%u, function class 0x%02x (%s) sub 0x%02x\n", d[2], d[2] + d[3] - 1, d[4],
                   class_name(d[4]), d[5]);
            break;
        case 0x04:
            cls = d[5]; sub = d[6];
            printf("    interface %u alt %u: class 0x%02x (%s) subclass 0x%02x protocol 0x%02x, %u endpoint(s)\n", d[2],
                   d[3], d[5], class_name(d[5]), d[6], d[7], d[4]);
            break;
        case 0x05: {
            static const char *const types[] = {"control", "isochronous", "bulk", "interrupt"};
            printf("      endpoint 0x%02x %s %s, max packet %u, interval %u\n", d[2], d[2] & 0x80 ? "IN" : "OUT",
                   types[d[3] & 3], le16(d + 4) & 0x7FF, d[6]);
            break;
        }
        case 0x21:
            if (cls == 0x03) printf("      HID descriptor: HID %x.%02x, report descriptor %u bytes\n", d[3], d[2], le16(d + 7));
            break;
        case 0x24:
            if (cls == 0x01 && sub == 0x01) audio_control(d);
            else if (cls == 0x01 && sub == 0x02) audio_streaming(d);
            else if (cls == 0x0E && sub == 0x01) video_control(d);
            else if (cls == 0x0E && sub == 0x02) video_streaming(d);
            else printf("      class-specific interface descriptor, subtype 0x%02x, %u bytes\n", d[2], d[0]);
            break;
        case 0x25:
            if (cls == 0x01 && d[2] == 0x01) printf("        AS endpoint: attributes 0x%02x\n", d[3]);
            break;
        default:
            printf("      descriptor type 0x%02x, %u bytes\n", d[1], d[0]);
        }
    }
}

static void probe(io_service_t svc) {
    IOCFPlugInInterface **plugin = NULL;
    IOUSBDeviceInterface **dev = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score) != KERN_SUCCESS || !plugin) {
        printf("    (could not create device plug-in)\n");
        return;
    }
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
    (*plugin)->Release(plugin);
    if (!dev) { printf("    (no device interface)\n"); return; }
    UInt8 nconf = 0;
    (*dev)->GetNumberOfConfigurations(dev, &nconf);
    for (UInt8 i = 0; i < nconf; i++) {
        IOUSBConfigurationDescriptorPtr cfg = NULL;
        if ((*dev)->GetConfigurationDescriptorPtr(dev, i, &cfg) == kIOReturnSuccess && cfg)
            walk((const UInt8 *)cfg, USBToHostWord(cfg->wTotalLength));
        else
            printf("    (configuration %u descriptor unavailable)\n", i);
    }
    (*dev)->Release(dev);
}

static long num_prop(io_service_t s, const char *key) {
    long v = -1;
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef r = IORegistryEntryCreateCFProperty(s, k, NULL, 0);
    if (r && CFGetTypeID(r) == CFNumberGetTypeID()) CFNumberGetValue(r, kCFNumberLongType, &v);
    if (r) CFRelease(r);
    CFRelease(k);
    return v;
}

int main(int argc, char **argv) {
    long want = 0x03f0;
    if (argc > 1) want = strcmp(argv[1], "all") == 0 ? -1 : strtol(argv[1], NULL, 0);
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) != KERN_SUCCESS) return 1;
    io_service_t s;
    int found = 0;
    while ((s = IOIteratorNext(it))) {
        long vid = num_prop(s, "idVendor"), pid = num_prop(s, "idProduct");
        if (want >= 0 && vid != want) { IOObjectRelease(s); continue; }
        io_name_t name;
        IORegistryEntryGetName(s, name);
        printf("\n== %s  %04lx:%04lx  location 0x%08lx  USB %lx.%02lx  speed %ld\n", name, vid, pid,
               num_prop(s, "locationID"), num_prop(s, "bcdUSB") >> 8, num_prop(s, "bcdUSB") & 0xFF, num_prop(s, "USBSpeed"));
        probe(s);
        IOObjectRelease(s);
        found++;
    }
    IOObjectRelease(it);
    if (!found) printf("no matching USB device\n");
    return 0;
}
