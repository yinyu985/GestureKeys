import Foundation
import GestureCore

// Local builds only. Use exactly the same archive decoder and validation as the app.
do {
    guard CommandLine.arguments.count == 3 else { throw ConfigError.invalid("Usage: GestureSeed INPUT.BABPreset OUTPUT.json") }
    MainActor.assumeIsolated { _ = KeyboardLayoutLabels.refresh() }
    let result = try BABImport.read(from: URL(fileURLWithPath: CommandLine.arguments[1]))
    var seed = result.configuration
    seed.addDefaultMissionControlGestureIfMissing()
    try ConfigStorage.export(seed, to: URL(fileURLWithPath: CommandLine.arguments[2]))
    for warning in result.warnings { print(warning) }
    print("Seed: \(result.configuration.rules.count) imported, \(seed.rules.count) packaged")
} catch {
    fputs("GestureSeed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
