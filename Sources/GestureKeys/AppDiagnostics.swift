import Foundation
import OSLog
import GestureCore

let diagnostics = DiagnosticLog(folder: {
    if ProcessInfo.processInfo.environment["GESTUREKEYS_SMOKE_TEST"] != nil {
        return FileManager.default.temporaryDirectory.appendingPathComponent("GestureKeys-log-test-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/GestureKeys", isDirectory: true)
}(), onFailure: { error in
    Logger(subsystem: "local.yy.GestureKeys", category: "diagnostics").error("Could not write local diagnostic log: \(error.domain, privacy: .public) \(error.code)")
})

func diagnosticError(_ error: Error) -> [String: String] {
    let ns = error as NSError
    return ["error_domain": ns.domain, "error_code": String(ns.code)]
}

func diagnosticRule(_ rule: Rule) -> [String: String] {
    ["rule": rule.id.uuidString, "kind": rule.kind.rawValue, "action": rule.action.rawValue]
}
