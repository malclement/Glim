// uacprobe — USB Audio Class 1.0 feature-unit requests the HAL doesn't expose
// (the HP E27m G4's mic-to-speaker sidetone is feature unit 9).
// It needs no USBDeviceOpen, so it works while usbaudiod owns the device.
//
//   uacprobe <vid> <pid> <unit> <control> <channel> <len>         GET_CUR/MIN/MAX/RES
//   uacprobe <vid> <pid> <unit> <control> <channel> <len> <raw>   SET_CUR, then GET_CUR
//
// control: 1 = mute (len 1), 2 = volume (len 2, raw is 1/256 dB, signed).
// Example: uacprobe 0x03f0 0x0b86 9 2 0 2      -> sidetone volume and its range
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 7) { fprintf(stderr, "usage: uacprobe <vid> <pid> <unit> <control> <channel> <len> [raw]\n"); return 2; }
    long vid = strtol(argv[1], 0, 0), pid = strtol(argv[2], 0, 0);
    int unit = (int)strtol(argv[3], 0, 0), cs = (int)strtol(argv[4], 0, 0), cn = (int)strtol(argv[5], 0, 0), len = (int)strtol(argv[6], 0, 0);
    CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
    int v = (int)vid, p = (int)pid;
    CFNumberRef nv = CFNumberCreate(0, kCFNumberIntType, &v), np = CFNumberCreate(0, kCFNumberIntType, &p);
    CFDictionarySetValue(m, CFSTR(kUSBVendorID), nv); CFDictionarySetValue(m, CFSTR(kUSBProductID), np);
    io_service_t dev = IOServiceGetMatchingService(kIOMainPortDefault, m);
    if (!dev) { fprintf(stderr, "device not found\n"); return 1; }
    IOCFPlugInInterface **plug = NULL; SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(dev, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    if (kr || !plug) { fprintf(stderr, "plugin failed 0x%x\n", kr); return 1; }
    IOUSBDeviceInterface **d = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&d);
    (*plug)->Release(plug);
    if (argc > 7) {
        long raw = strtol(argv[7], 0, 0);
        UInt8 out[2] = {(UInt8)(raw & 0xFF), (UInt8)((raw >> 8) & 0xFF)};
        IOUSBDevRequest w = { .bmRequestType = 0x21, .bRequest = 0x01, .wValue = (UInt16)((cs << 8) | cn),
                              .wIndex = (UInt16)(unit << 8), .wLength = (UInt16)len, .pData = out };
        printf("  SET_CUR %ld: rc 0x%08x\n", raw, (*d)->DeviceRequest(d, &w));
        usleep(200000);
    }
    const char *names[] = {"GET_CUR", "GET_MIN", "GET_MAX", "GET_RES"};
    for (int i = 0; i < 4; i++) {
        UInt8 buf[8] = {0};
        IOUSBDevRequest r = { .bmRequestType = 0xA1, .bRequest = (UInt8)(0x81 + i), .wValue = (UInt16)((cs << 8) | cn),
                              .wIndex = (UInt16)(unit << 8), .wLength = (UInt16)len, .pData = buf };
        IOReturn rc = (*d)->DeviceRequest(d, &r);
        if (rc) { printf("  %s: error 0x%08x\n", names[i], rc); continue; }
        if (len == 1) printf("  %s: %u\n", names[i], buf[0]);
        else { short s = (short)(buf[0] | (buf[1] << 8)); printf("  %s: %d (%.2f dB)\n", names[i], s, s / 256.0); }
        if (len == 1) break;   // mute has GET_CUR only
    }
    (*d)->Release(d);
    return 0;
}
