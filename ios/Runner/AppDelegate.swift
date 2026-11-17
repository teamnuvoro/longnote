import AVFoundation
import Flutter
import MetricKit
import StoreKit
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "StorePlugin") {
      StorePlugin.register(with: registrar)
    }
  }
}

// MARK: - App Store subscriptions (StoreKit 2)
//
// Channel "longnote/store" (all results are plain maps/lists):
//   products {ids: [String]} -> [{id, displayPrice, price: Double, currency,
//             periodUnit: day|week|month|year, periodValue: Int,
//             trialDays: Int? (free-trial intro offer), eligibleForIntro: Bool}]
//   purchase {id} -> {result: success|cancelled|pending|unverified|not_found|unknown,
//                     status: <status map, on success>}
//   status   -> {active: Bool, productId?, purchasedAtMs?, expiresAtMs?, isTrial?,
//                originalId?}
//   restore  -> AppStore.sync(), then the status map
//   renewal {productId} -> {willAutoRenew: Bool, autoRenewPreference: String?}
//             or nil when unknown (needs the network)
// Native -> Dart: "changed" (no args) whenever Transaction.updates delivers
// (renewal, Ask to Buy approval, refund, purchase on another device).
//
// Only transactions StoreKit has verified (signed by the App Store for this
// app and device) are used; unverified ones are ignored.
public class StorePlugin: NSObject, FlutterPlugin {
  private let channel: FlutterMethodChannel
  private var updates: Task<Void, Never>?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "longnote/store",
      binaryMessenger: registrar.messenger())
    let instance = StorePlugin(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.listenForUpdates()
  }

  deinit { updates?.cancel() }

  /// Apple asks apps to listen from launch, so purchases finished outside
  /// the app (renewals, Ask to Buy) are finished and noticed.
  private func listenForUpdates() {
    updates = Task.detached { [weak self] in
      for await verification in StoreKit.Transaction.updates {
        if case .verified(let transaction) = verification {
          await transaction.finish()
        }
        await MainActor.run {
          self?.channel.invokeMethod("changed", arguments: nil)
        }
      }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    Task { @MainActor in
      do {
        switch call.method {
        case "products":
          result(try await StorePlugin.products(args["ids"] as? [String] ?? []))
        case "purchase":
          guard let id = args["id"] as? String else {
            result(FlutterError(code: "bad_args", message: "id is required", details: nil))
            return
          }
          result(try await StorePlugin.purchase(id))
        case "status":
          result(await StorePlugin.status())
        case "restore":
          try await AppStore.sync()
          result(await StorePlugin.status())
        case "renewal":
          result(await StorePlugin.willAutoRenew(args["productId"] as? String ?? ""))
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "store_error", message: String(describing: error), details: nil))
      }
    }
  }

  static func products(_ ids: [String]) async throws -> [[String: Any]] {
    let products = try await Product.products(for: ids)
    var out: [[String: Any]] = []
    for product in products {
      guard let sub = product.subscription else { continue }
      var m: [String: Any] = [
        "id": product.id,
        "displayPrice": product.displayPrice,
        "price": NSDecimalNumber(decimal: product.price).doubleValue,
        "currency": product.priceFormatStyle.currencyCode,
        "periodUnit": unitName(sub.subscriptionPeriod.unit),
        "periodValue": sub.subscriptionPeriod.value,
        "eligibleForIntro": await sub.isEligibleForIntroOffer,
      ]
      if let intro = sub.introductoryOffer, intro.paymentMode == .freeTrial {
        m["trialDays"] = days(intro.period)
      }
      out.append(m)
    }
    return out
  }

  static func purchase(_ id: String) async throws -> [String: Any] {
    guard let product = try await Product.products(for: [id]).first else {
      return ["result": "not_found"]
    }
    switch try await product.purchase() {
    case .success(let verification):
      switch verification {
      case .verified(let transaction):
        await transaction.finish()
        return ["result": "success", "status": await status()]
      case .unverified(_, let error):
        return ["result": "unverified", "error": String(describing: error)]
      }
    case .userCancelled:
      return ["result": "cancelled"]
    case .pending:
      return ["result": "pending"]
    @unknown default:
      return ["result": "unknown"]
    }
  }

  /// The subscription the user is entitled to right now (verified, not
  /// revoked), the one that runs longest if there are several. Local: works
  /// offline from StoreKit's on-device cache.
  static func status() async -> [String: Any] {
    var best: StoreKit.Transaction?
    for await verification in StoreKit.Transaction.currentEntitlements {
      guard case .verified(let t) = verification,
            t.productType == .autoRenewable,
            t.revocationDate == nil else { continue }
      if best == nil || (t.expirationDate ?? .distantPast) > (best!.expirationDate ?? .distantPast) {
        best = t
      }
    }
    guard let t = best else { return ["active": false] }
    var m: [String: Any] = [
      "active": true,
      "productId": t.productID,
      "purchasedAtMs": Int64(t.purchaseDate.timeIntervalSince1970 * 1000),
      "isTrial": t.offerType == .introductory,
      "originalId": String(t.originalID),
    ]
    if let e = t.expirationDate {
      m["expiresAtMs"] = Int64(e.timeIntervalSince1970 * 1000)
    }
    return m
  }

  /// Needs the network; nil when unknown. autoRenewPreference is the plan
  /// Apple renews into (differs from productId after a plan change).
  static func willAutoRenew(_ productId: String) async -> [String: Any]? {
    guard let product = try? await Product.products(for: [productId]).first,
          let statuses = try? await product.subscription?.status else { return nil }
    var fallback: Product.SubscriptionInfo.RenewalInfo?
    for s in statuses {
      guard case .verified(let info) = s.renewalInfo else { continue }
      if info.currentProductID == productId {
        return renewalMap(info)
      }
      if fallback == nil { fallback = info }
    }
    return fallback.map(renewalMap)
  }

  static func renewalMap(_ info: Product.SubscriptionInfo.RenewalInfo) -> [String: Any] {
    var m: [String: Any] = ["willAutoRenew": info.willAutoRenew]
    if let next = info.autoRenewPreference { m["autoRenewPreference"] = next }
    return m
  }

  static func unitName(_ unit: Product.SubscriptionPeriod.Unit) -> String {
    switch unit {
    case .day: return "day"
    case .week: return "week"
    case .month: return "month"
    case .year: return "year"
    @unknown default: return "unknown"
    }
  }

  static func days(_ p: Product.SubscriptionPeriod) -> Int {
    switch p.unit {
    case .day: return p.value
    case .week: return p.value * 7
    case .month: return p.value * 30
    case .year: return p.value * 365
    @unknown default: return p.value
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
