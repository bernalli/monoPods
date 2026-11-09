import Foundation
import MonoPodsCore

public struct SelfCheckResult: Sendable {
  public let succeeded: Bool
  public let output: String
}

@MainActor public enum BundleSelfCheck {
  /// Read-only. No login item, audio engine, Play, listener, audio or preference writes.
  public static func run(bundle: Bundle) async -> SelfCheckResult {
    let audio = await AudioModeAdapter.diagnostics()
    return report(
      bundle: bundle, audio: audio, now: Date(), mediaAvailable: MediaAdapter().symbolsAvailable(),
      environment: try? RuntimeEnvironment.current())
  }

  static func run(
    bundle: Bundle, hardware: any AudioHardware, now: Date, mediaAvailable: Bool,
    environment: RuntimeEnvironment
  ) async -> SelfCheckResult {
    let audio = await AudioModeAdapter.diagnostics(hardware: hardware)
    return report(
      bundle: bundle, audio: audio, now: now, mediaAvailable: mediaAvailable,
      environment: environment)
  }

  private static func report(
    bundle: Bundle, audio: AudioDiagnosticReading, now: Date, mediaAvailable: Bool,
    environment: RuntimeEnvironment?
  ) -> SelfCheckResult {
    var succeeded = audio.status == 0 && mediaAvailable
    let preference =
      audio.systemMono == .unreadable
      ? "unreadable (treated as off)" : audio.systemMono.rawValue
    var fields = [
      "Timestamp": ISO8601DateFormatter().string(from: now),
      "Audio OSStatus": String(audio.status),
      "Audio Raw": audio.rawValue.map(String.init) ?? "unknown",
      "Audio Mode": audio.mode?.rawValue ?? "unknown",
      "System Mono Audio": preference,
      "Bundle Path": bundle.bundleURL.path,
      "Bundle Validation": "unknown", "Bundle Build": "unknown",
      "Runtime Directory": "unknown", "Runtime State": "unknown", "Journal": "unknown",
      "Preferences": "unknown",
      "Run": "unknown", "Build": "unknown", "Phase": "unknown",
      "Restore Required": "unknown", "Last Target": "unknown", "Last Outcome": "unknown",
      "MediaRemote": mediaAvailable ? "available" : "unavailable",
    ]
    do {
      guard let environment,
        let manifestURL = bundle.url(forResource: "Manifest", withExtension: "json")
      else { throw RuntimeError.invalid }
      let location = try RuntimeLocation.resolve(bundle: bundle, environment: environment)
      let manifest = try ContractValidation.decode(
        BundleManifest.self, data: Data(contentsOf: manifestURL))
      try manifest.verify(bundle: bundle.bundleURL)
      fields["Bundle Validation"] = "valid"
      fields["Bundle Build"] = manifest.build
      fields["Runtime Directory"] = location.runtimeDirectory
      // Never created here: a missing directory is reported, not repaired.
      if let files = try RuntimeDirectory.openExisting(location) {
        fields["Runtime State"] = "present"
        fields["Runtime Directory"] = files.directory.path
        try inspect(files, into: &fields, succeeded: &succeeded)
      } else {
        fields["Runtime State"] = "missing"
        fields["Journal"] = "missing"
        fields["Preferences"] = "missing"
      }
    } catch { succeeded = false }
    // Only selected, validated fields are emitted; never include file contents or error dumps.
    let order = [
      "Timestamp", "Audio OSStatus", "Audio Raw", "Audio Mode", "System Mono Audio",
      "Bundle Path", "Bundle Validation", "Bundle Build", "Runtime Directory", "Runtime State",
      "Journal", "Preferences", "Run", "Build", "Phase", "Restore Required", "Last Target",
      "Last Outcome", "MediaRemote",
    ]
    let output = order.map { "\($0): \(fields[$0] ?? "unknown")\n" }.joined()
    return SelfCheckResult(succeeded: succeeded, output: output)
  }

  private static func inspect(
    _ files: AtomicRuntimeFiles, into fields: inout [String: String], succeeded: inout Bool
  ) throws {
    switch files.load() {
    case .missing: fields["Journal"] = "missing"
    case .blocked: succeeded = false
    case .record(let record):
      fields["Journal"] = "valid"
      fields["Run"] = String(record.lifecycle.run)
      fields["Build"] = record.lifecycle.build
      fields["Phase"] = record.audio.phase.rawValue
      fields["Restore Required"] = String(record.audio.restoreRequired)
      fields["Last Target"] = record.audio.lastCompleted?.target.rawValue ?? "unknown"
      fields["Last Outcome"] = record.audio.lastCompleted.map { String($0.exitCode) } ?? "unknown"
    }
    if let data = try files.read("preferences.json") {
      _ = try ControlPreferences.decode(data)
      fields["Preferences"] = "valid"
    } else {
      fields["Preferences"] = "missing"
    }
  }
}
