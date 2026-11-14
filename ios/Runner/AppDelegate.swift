import Flutter
import UIKit
import UserNotifications
#if canImport(FoundationModels)
import FoundationModels
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // flutter_local_notifications: show the trial reminder even if the app is open.
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppleSummarizerPlugin") {
      AppleSummarizerPlugin.register(with: registrar)
    }
  }
}

// MARK: - Apple Intelligence summarizer (UNTESTED: never compiled; written
// without Xcode). Kept in this file so no Xcode project edits are needed.
//
// Channel "longnote/apple_summarizer":
//   isAvailable        -> Bool
//   unavailableReason  -> String? (nil when available)
//   summarize {instructions, prompt} -> String (model's raw text; Dart parses JSON)
//
// Every path that cannot run returns false / a FlutterError, and the Dart side
// falls back to another summary engine.
public class AppleSummarizerPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "longnote/apple_summarizer",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(AppleSummarizerPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(AppleSummarizerPlugin.unavailableReason() == nil)
    case "unavailableReason":
      result(AppleSummarizerPlugin.unavailableReason())
    case "summarize":
      guard let args = call.arguments as? [String: Any],
            let instructions = args["instructions"] as? String,
            let prompt = args["prompt"] as? String else {
        result(FlutterError(code: "bad_args", message: "instructions and prompt are required", details: nil))
        return
      }
      AppleSummarizerPlugin.summarize(instructions: instructions, prompt: prompt, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// nil when the on-device model can be used right now.
  static func unavailableReason() -> String? {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available:
        return nil
      case .unavailable(.deviceNotEligible):
        return "This iPhone does not support Apple Intelligence."
      case .unavailable(.appleIntelligenceNotEnabled):
        return "Apple Intelligence is turned off in iPhone Settings."
      case .unavailable(.modelNotReady):
        return "Apple Intelligence is still downloading. Try again later."
      case .unavailable(_):
        return "Apple Intelligence is not available right now."
      @unknown default:
        return "Apple Intelligence is not available right now."
      }
    }
    return "Needs iOS 26 or later."
    #else
    return "Needs iOS 26 or later."
    #endif
  }

  static func summarize(instructions: String, prompt: String, result: @escaping FlutterResult) {
    #if canImport(FoundationModels)
    if #available(iOS 26.0, *) {
      guard unavailableReason() == nil else {
        result(FlutterError(code: "unavailable", message: unavailableReason(), details: nil))
        return
      }
      Task {
        do {
          let session = LanguageModelSession(instructions: instructions)
          let options = GenerationOptions(temperature: 0.2)
          let response = try await session.respond(to: prompt, options: options)
          let text = response.content
          DispatchQueue.main.async { result(text) }
        } catch {
          let message = String(describing: error)
          DispatchQueue.main.async {
            result(FlutterError(code: "generation_failed", message: message, details: nil))
          }
        }
      }
      return
    }
    #endif
    result(FlutterError(code: "unavailable", message: "Needs iOS 26 or later.", details: nil))
  }
}
