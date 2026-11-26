// Ultralytics 🚀 AGPL-3.0 License - https://ultralytics.com/license

import AVFoundation
import Flutter
import UIKit

// Canonical Flutter 3.41 UIScene setup. Plugins are registered against the implicit engine that `FlutterSceneDelegate`
// runs (via `didInitializeImplicitFlutterEngine`), NOT against a hand-rolled engine — the previous manual engine +
// window creation in `SceneDelegate` worked under the Xcode debugger but crashed on a cold relaunch from the home
// screen. See https://flutter.dev/to/uiscene-migration.
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "roadchitra/video_frames",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "getVideoDurationMs":
        guard let path = args?["path"] as? String, !path.isEmpty else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing video path", details: nil))
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          let asset = AVURLAsset(url: URL(fileURLWithPath: path))
          let durationMs = Int64(CMTimeGetSeconds(asset.duration) * 1000.0)
          let codec = asset.tracks(withMediaType: .video)
            .first?.formatDescriptions
            .compactMap { $0 as? CMFormatDescription }
            .first
            .map { CMFormatDescriptionGetMediaSubType($0) }
            .map { subtype -> String in
              let bytes: [UInt8] = [
                UInt8((subtype >> 24) & 0xff),
                UInt8((subtype >> 16) & 0xff),
                UInt8((subtype >> 8) & 0xff),
                UInt8(subtype & 0xff),
              ]
              return String(bytes: bytes, encoding: .ascii) ?? "unknown"
            }
          let mime = codec.map { ["hvc1", "hev1"].contains($0) ? "video/hevc" : "video/\($0)" } ?? "unknown"
          DispatchQueue.main.async {
            result(["durationMs": max(0, durationMs), "mimeType": mime])
          }
        }

      case "extractFrame":
        guard let path = args?["path"] as? String, !path.isEmpty else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing video path", details: nil))
          return
        }
        let timeMs = (args?["timeMs"] as? NSNumber)?.int64Value ?? 0
        let maxWidth = (args?["maxWidth"] as? NSNumber)?.doubleValue ?? 1280.0
        DispatchQueue.global(qos: .userInitiated).async {
          let asset = AVURLAsset(url: URL(fileURLWithPath: path))
          let generator = AVAssetImageGenerator(asset: asset)
          generator.appliesPreferredTrackTransform = true
          generator.requestedTimeToleranceBefore = .zero
          generator.requestedTimeToleranceAfter = .zero
          if maxWidth > 0 {
            generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
          }
          let time = CMTime(value: timeMs, timescale: 1000)
          do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            let uiImage = UIImage(cgImage: cgImage)
            let data = uiImage.jpegData(compressionQuality: 0.88)
            DispatchQueue.main.async {
              result(data.map { FlutterStandardTypedData(bytes: $0) })
            }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "VIDEO_FRAME_ERROR", message: error.localizedDescription, details: nil))
            }
          }
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
