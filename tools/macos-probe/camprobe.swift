// camprobe.swift — read-only AVFoundation inventory of video capture devices:
// identity, transport, connection/suspension state, every format (size, pixel
// format, frame-rate ranges, Center Stage / Portrait support) and which focus / exposure / white-balance modes macOS exposes.
//
// It never creates a capture session, never calls lockForConfiguration, and never
// sets a property — so no camera LED turns on and nothing about the device changes.
// Device discovery itself does not need camera (TCC) permission.
//
// What AVFoundation does NOT expose for a UVC webcam: brightness, contrast,
// saturation, sharpness, gain, power-line frequency, pan/tilt, absolute zoom
// in UVC units, privacy shutter, vendor extension units. Those are UVC class
// controls; see usbdescprobe (which controls the camera advertises) and a UVC
// control tool such as uvc-util / CameraController for their values.
//
// Build:  swiftc -O camprobe.swift -o camprobe
// Run:    ./camprobe

import AVFoundation
import CoreMedia
import Foundation

func fourCC(_ v: FourCharCode) -> String {
    let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
    return b.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? String(bytes: b, encoding: .ascii)! : String(format: "0x%08x", v)
}

var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
if #available(macOS 14.0, *) { types += [.continuityCamera, .deskViewCamera] }

let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
print("camprobe — \(session.devices.count) video device(s); camera authorization status: \(AVCaptureDevice.authorizationStatus(for: .video).rawValue) (0 notDetermined, 1 restricted, 2 denied, 3 authorized)")
if #available(macOS 12.0, *) {
    print("system-wide effects: centerStage enabled=\(AVCaptureDevice.isCenterStageEnabled) controlMode=\(AVCaptureDevice.centerStageControlMode.rawValue); portrait enabled=\(AVCaptureDevice.isPortraitEffectEnabled)")
}

for d in session.devices {
    print("\n== \(d.localizedName)")
    print("    uniqueID      \(d.uniqueID)")
    print("    modelID       \(d.modelID)")
    print("    manufacturer  \(d.manufacturer)")
    print("    type          \(d.deviceType.rawValue)  transport \(fourCC(FourCharCode(bitPattern: d.transportType)))")
    print("    connected=\(d.isConnected) suspended=\(d.isSuspended) inUseByAnotherApp=\(d.isInUseByAnotherApplication)")
    print("    focus modes   locked=\(d.isFocusModeSupported(.locked)) auto=\(d.isFocusModeSupported(.autoFocus)) continuous=\(d.isFocusModeSupported(.continuousAutoFocus)) poi=\(d.isFocusPointOfInterestSupported)")
    print("    exposure      locked=\(d.isExposureModeSupported(.locked)) auto=\(d.isExposureModeSupported(.autoExpose)) continuous=\(d.isExposureModeSupported(.continuousAutoExposure)) poi=\(d.isExposurePointOfInterestSupported)")
    print("    white balance locked=\(d.isWhiteBalanceModeSupported(.locked)) auto=\(d.isWhiteBalanceModeSupported(.autoWhiteBalance)) continuous=\(d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance))")
    print("    torch=\(d.hasTorch) flash=\(d.hasFlash)")
    if #available(macOS 12.0, *) {
        print("    centerStage active=\(d.isCenterStageActive) portrait active=\(d.isPortraitEffectActive)")
    }
    let active = d.activeFormat
    for f in d.formats {
        let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let sub = fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription))
        let fps = f.videoSupportedFrameRateRanges.map { r in
            r.minFrameRate == r.maxFrameRate ? String(format: "%.0f", r.maxFrameRate) : String(format: "%.0f–%.0f", r.minFrameRate, r.maxFrameRate)
        }.joined(separator: ",")
        // Zoom, field of view and video HDR are iOS-only AVFoundation API; macOS exposes none of them.
        var extras: [String] = []
        if #available(macOS 12.0, *) {
            if f.isCenterStageSupported { extras.append("centerStage") }
            if f.isPortraitEffectSupported { extras.append("portrait") }
        }
        print("    \(f == active ? "*" : " ") \(dims.width)x\(dims.height) \(sub) @ \(fps) fps  [\(extras.joined(separator: ", "))]")
    }
}
