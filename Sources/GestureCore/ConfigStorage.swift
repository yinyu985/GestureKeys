import Foundation

public struct ConfigStorage {
    public let url: URL
    public init(_ url: URL) { self.url = url }
    public var folder: URL { url.deletingLastPathComponent() }
    public var savedAt: Date? { Self.modifiedAt(url) }
    private static let backupPrefix = "config-backup-"
    private var legacyPrevious: URL { folder.appendingPathComponent("config.previous.json") }

    public static func datedName(_ prefix: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return prefix + formatter.string(from: date) + ".json"
    }
    private static func modifiedAt(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    private func backupURL(for date: Date) -> URL {
        let name = Self.datedName(Self.backupPrefix, date: date)
        let target = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: target.path) { return target }
        return folder.appendingPathComponent(String(name.dropLast(5)) + "-\(UUID().uuidString.prefix(8)).json")
    }
    public func migrateLegacyBackup() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyPrevious.path) else { return }
        try fm.moveItem(at: legacyPrevious, to: backupURL(for: Self.modifiedAt(legacyPrevious) ?? Date()))
    }
    // A native configuration can hold 500 × 4,096 points, unlike a small BAB archive.
    // Use one byte budget for native persistence, export and import, including pretty-print overhead.
    private static let nativeByteLimit = 256_000_000
    private static var nativeSizeError: ConfigError { .invalid(L10n.text("配置文件超过 %1$@ MB。", "\(nativeByteLimit / 1_000_000)")) }

    static func readBounded(_ url: URL, limit: Int, oversize: @autoclosure () -> ConfigError) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size <= UInt64(limit) else { throw oversize() }
        try file.seek(toOffset: 0)
        var data = Data(capacity: Int(size))
        while let chunk = try file.read(upToCount: min(1_048_576, limit - data.count + 1)), !chunk.isEmpty {
            guard data.count + chunk.count <= limit else { throw oversize() }
            data.append(chunk)
        }
        return data
    }
    public static func importFile(at url: URL) throws -> (Configuration, [String]) {
        if url.pathExtension.lowercased() == "babpreset" {
            let imported = try BABImport.read(from: url)
            return (imported.configuration, imported.warnings)
        }
        let data = try readBounded(url, limit: nativeByteLimit, oversize: nativeSizeError)
        var config = try JSONDecoder().decode(Configuration.self, from: data)
        try config.validate()
        let oldCount = config.rules.count
        config.removeLegacyPlaceholders()
        let skipped = oldCount - config.rules.count
        return (config, skipped == 0 ? [] : [L10n.text("已跳过 %1$@ 条旧版占位规则。", "\(skipped)")])
    }
    public static func export(_ configuration: Configuration, to url: URL) throws {
        var copy = configuration
        copy.rules = copy.rules.map(\.withoutUnusedActionFields)
        try writePrivate(encode(copy), to: url)
    }
    public static func encode(_ configuration: Configuration) throws -> Data {
        try configuration.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        guard data.count <= nativeByteLimit else { throw nativeSizeError }
        return data
    }
    public func save(_ configuration: Configuration) throws {
        let data = try Self.encode(configuration)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var backup: URL?
        if fm.fileExists(atPath: url.path) {
            let old = try Data(contentsOf: url)
            if old == data || (try? JSONDecoder().decode(Configuration.self, from: old)) == configuration { return }
            let date = savedAt ?? Date()
            let target = backupURL(for: date)
            try Self.writePrivate(old, to: target, modifiedAt: date)
            backup = target
        }
        try Self.writePrivate(data, to: url)
        // Keep the latest automatic backup; never remove older manually made/import-era archives.
        if let backup, let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let generated = #"^config-backup-\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-\d{3}(-[A-F0-9]{8})?\.json$"#
            for entry in entries where entry.lastPathComponent != backup.lastPathComponent && entry.lastPathComponent.range(of: generated, options: .regularExpression) != nil {
                if (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { try? fm.removeItem(at: entry) }
            }
        }
    }
    private static func writePrivate(_ data: Data, to target: URL, modifiedAt: Date? = nil) throws {
        let fm = FileManager.default
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".config-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fm.removeItem(at: temporary) }
        if let modifiedAt { try fm.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: temporary.path) }
        // Same directory: rename replaces the destination atomically and keeps the temporary file's permissions.
        if rename(temporary.path, target.path) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
