import AVFoundation
import Flutter
import MetricKit
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
    // Crash / hang reports from iOS (delivered on a later launch); the Dart
    // CrashReporter uploads the files.
    MXMetricManager.shared.add(DiagnosticsSubscriber.shared)
    DiagnosticsSubscriber.shared.save(MXMetricManager.shared.pastDiagnosticPayloads)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppleSummarizerPlugin") {
      AppleSummarizerPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AudioEncoderPlugin") {
      AudioEncoderPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "FilesPlugin") {
      FilesPlugin.register(with: registrar)
    }
  }
}

// MARK: - Audio encoder (cloud upload format)
//
// Channel "longnote/audio_encoder":
//   encodeM4a {inputs: [path], output: path, startMs: Int, durationMs: Int?,
//              sampleRate: Double, bitRate: Int}
//     -> {durationMs: Int, bytes: Int}
//
// Joins the inputs (our 5-minute WAV parts, or an imported file) with an
// AVMutableComposition, reads the requested time range as 16 kHz mono PCM
// (AVAssetReaderAudioMixOutput resamples and mixes down), and writes AAC-LC
// in an .m4a with AVAssetWriter. Inputs are only read, never changed.
public class AudioEncoderPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "longnote/audio_encoder",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(AudioEncoderPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "encodeM4a" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
          let inputs = args["inputs"] as? [String], !inputs.isEmpty,
          let output = args["output"] as? String else {
      result(FlutterError(code: "bad_args", message: "inputs and output are required", details: nil))
      return
    }
    let startMs = (args["startMs"] as? NSNumber)?.int64Value ?? 0
    let durationMs = (args["durationMs"] as? NSNumber)?.int64Value
    let sampleRate = (args["sampleRate"] as? NSNumber)?.doubleValue ?? 16000
    let bitRate = (args["bitRate"] as? NSNumber)?.intValue ?? 32000
    Task.detached(priority: .utility) {
      do {
        let out = try await AudioEncoderPlugin.encode(
          inputs: inputs, output: output, startMs: startMs, durationMs: durationMs,
          sampleRate: sampleRate, bitRate: bitRate)
        DispatchQueue.main.async { result(out) }
      } catch {
        let message = String(describing: error)
        DispatchQueue.main.async {
          result(FlutterError(code: "encode_failed", message: message, details: nil))
        }
      }
    }
  }

  enum EncodeError: Error {
    case noAudioTrack(String)
    case empty
    case reader(String)
    case writer(String)
  }

  /// Mutable flag shared with the writer callback (a class, so the
  /// @Sendable callback captures a reference, not a mutable var).
  final class Once: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
      lock.lock(); defer { lock.unlock() }
      if done { return false }
      done = true
      return true
    }
  }

  static func encode(inputs: [String], output: String, startMs: Int64, durationMs: Int64?,
                     sampleRate: Double, bitRate: Int) async throws -> [String: Any] {
    // 1) Join the inputs.
    let composition = AVMutableComposition()
    guard let track = composition.addMutableTrack(
      withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
      throw EncodeError.writer("could not create a composition track")
    }
    var cursor = CMTime.zero
    for path in inputs {
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      let tracks = try await asset.loadTracks(withMediaType: .audio)
      guard let source = tracks.first else { throw EncodeError.noAudioTrack(path) }
      let duration = try await asset.load(.duration)
      if !(duration.seconds > 0) { continue }
      try track.insertTimeRange(
        CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
      cursor = CMTimeAdd(cursor, duration)
    }
    let start = CMTime(value: startMs, timescale: 1000)
    var end = cursor
    if let d = durationMs {
      let wanted = CMTimeAdd(start, CMTime(value: d, timescale: 1000))
      if CMTimeCompare(wanted, end) < 0 { end = wanted }
    }
    if CMTimeCompare(end, start) <= 0 { throw EncodeError.empty }
    let range = CMTimeRange(start: start, end: end)

    // 2) Reader: 16-bit PCM, mono, target rate.
    let reader = try AVAssetReader(asset: composition)
    reader.timeRange = range
    let pcm: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: pcm)
    readerOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(readerOutput) else { throw EncodeError.reader("cannot add output") }
    reader.add(readerOutput)

    // 3) Writer: AAC-LC, mono, m4a.
    let outURL = URL(fileURLWithPath: output)
    try? FileManager.default.removeItem(at: outURL)
    try FileManager.default.createDirectory(
      at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try AVAssetWriter(outputURL: outURL, fileType: .m4a)
    var layout = AudioChannelLayout()
    layout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
    let aac: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: bitRate,
      AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
    ]
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { throw EncodeError.writer("cannot add input") }
    writer.add(input)

    guard reader.startReading() else {
      throw EncodeError.reader(reader.error.map { String(describing: $0) } ?? "startReading failed")
    }
    guard writer.startWriting() else {
      reader.cancelReading()
      throw EncodeError.writer(writer.error.map { String(describing: $0) } ?? "startWriting failed")
    }
    writer.startSession(atSourceTime: range.start)

    // 4) Pump samples.
    let queue = DispatchQueue(label: "longnote.audio-encoder")
    let once = Once()
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
      input.requestMediaDataWhenReady(on: queue) {
        while input.isReadyForMoreMediaData {
          if let buffer = readerOutput.copyNextSampleBuffer() {
            if !input.append(buffer) {
              reader.cancelReading()
              input.markAsFinished()
              if once.claim() {
                cont.resume(throwing: EncodeError.writer(
                  writer.error.map { String(describing: $0) } ?? "append failed"))
              }
              return
            }
          } else {
            input.markAsFinished()
            if once.claim() {
              if reader.status == .failed {
                cont.resume(throwing: EncodeError.reader(
                  reader.error.map { String(describing: $0) } ?? "read failed"))
              } else {
                cont.resume()
              }
            }
            return
          }
        }
      }
    }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      writer.finishWriting { c.resume() }
    }
    if writer.status != .completed {
      throw EncodeError.writer(writer.error.map { String(describing: $0) } ?? "finish failed")
    }
    let attrs = try FileManager.default.attributesOfItem(atPath: output)
    let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    let ms = Int64((CMTimeGetSeconds(range.duration) * 1000).rounded())
    return ["durationMs": ms, "bytes": bytes]
  }
}

// MARK: - Files (iCloud backup flag)
//
// Channel "longnote/files":
//   setExcludedFromBackup {path, excluded} -> Bool
public class FilesPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "longnote/files",
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(FilesPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "setExcludedFromBackup" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String,
          let excluded = args["excluded"] as? Bool else {
      result(FlutterError(code: "bad_args", message: "path and excluded are required", details: nil))
      return
    }
    var url = URL(fileURLWithPath: path)
    var values = URLResourceValues()
    values.isExcludedFromBackup = excluded
    do {
      try url.setResourceValues(values)
      result(true)
    } catch {
      result(FlutterError(code: "failed", message: String(describing: error), details: nil))
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


// MARK: - Crash / hang diagnostics (MetricKit)
//
// Writes each diagnostic payload (crashes, hangs, CPU and disk-write
// exceptions, with call stacks) as JSON into
// <Application Support>/diagnostics/mx-*.json. lib/core/diagnostics/
// crash_reporter.dart uploads and deletes them.
final class DiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber {
  static let shared = DiagnosticsSubscriber()

  func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads) }

  func save(_ payloads: [MXDiagnosticPayload]) {
    guard !payloads.isEmpty,
          let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
    let dir = base.appendingPathComponent("diagnostics", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for p in payloads {
      // Same payload delivered twice (past + live) keeps one file.
      let key = Int64(p.timeStampBegin.timeIntervalSince1970 * 1000)
      let name = "mx-\(key)-\(Int64(p.timeStampEnd.timeIntervalSince1970 * 1000)).json"
      try? p.jsonRepresentation().write(
        to: dir.appendingPathComponent(name), options: .atomic)
    }
  }
}
