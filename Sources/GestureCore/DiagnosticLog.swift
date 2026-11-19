import Foundation

/// Local JSON lines on a serial writer. Input callbacks never wait for disk I/O.
public final class DiagnosticLog: @unchecked Sendable {
    public let folder: URL
    public var file: URL { folder.appendingPathComponent("GestureKeys.log") }
    public let session = UUID().uuidString
    private let queue = DispatchQueue(label: "GestureKeys.diagnostics", qos: .utility)
    private let slots = DispatchSemaphore(value: 1024)
    private let dropLock = NSLock()
    private var dropped = 0
    private let maxBytes: Int
    private let archives: Int
    private let onFailure: (NSError) -> Void
    private var writingFailed = false
    private let encoder = JSONEncoder()
    private let clock = ISO8601DateFormatter()

    public init(folder: URL, maxBytes: Int = 1_048_576, archives: Int = 3, onFailure: @escaping (NSError) -> Void = { _ in }) {
        self.folder = folder; self.maxBytes = max(512, maxBytes); self.archives = max(1, archives); self.onFailure = onFailure
        clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }
    public func record(_ event: String, _ fields: [String: String] = [:]) {
        guard slots.wait(timeout: .now()) == .success else {
            dropLock.lock(); dropped += 1; dropLock.unlock(); return
        }
        let instant = Date()
        queue.async { [self] in
            defer { slots.signal() }
            dropLock.lock(); let lost = dropped; dropped = 0; dropLock.unlock()
            do {
                if lost > 0 { try append("diagnostic.records_dropped", ["count": String(lost)], at: instant) }
                try append(event, fields, at: instant)
                writingFailed = false
            } catch {
                if !writingFailed { onFailure(error as NSError) }
                writingFailed = true
            }
        }
    }
    public func flush() { queue.sync {} }

    private func archive(_ n: Int) -> URL { folder.appendingPathComponent("GestureKeys.\(n).log") }
    private func append(_ event: String, _ fields: [String: String], at instant: Date) throws {
        let fm = FileManager.default
        let record = Entry(time: clock.string(from: instant), session: session, event: event, fields: fields)
        var line = try encoder.encode(record); line.append(0x0a)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: file.path) {
            let size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > 0 && size + line.count > maxBytes {
                let last = archive(archives)
                if fm.fileExists(atPath: last.path) { try fm.removeItem(at: last) }
                for n in (1...archives).reversed() {
                    let source = n == 1 ? file : archive(n - 1)
                    if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: archive(n)) }
                }
            }
        }
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    private struct Entry: Encodable {
        let time: String
        let session: String
        let event: String
        let fields: [String: String]
    }
}
