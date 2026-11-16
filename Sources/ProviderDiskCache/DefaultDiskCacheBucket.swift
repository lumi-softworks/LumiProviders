import Foundation
import os
import LumiLoggingKit

/// `DiskCacheBucket` 的默认实现：actor 串行化全部磁盘 IO。
///
/// 布局：`<bucket>/objects/<sha256(key)>.bin` + `<bucket>/manifest.json`
/// 不变量：索引可丢，目录才是真相。manifest 损坏/滞后时按目录扫描重建。
/// 结构性写入（store/remove/invalidate/clear）立即落盘索引；
/// 高频的读取访问时间更新合并延迟落盘，避免每次命中都同步写盘。
public actor DefaultDiskCacheBucket: DiskCacheBucket, SuperLog {
    nonisolated public static let emoji = "📦"
    nonisolated static let logger = Logger(subsystem: "com.coffic.lumi.provider-disk-cache", category: "DiskCacheBucket")
    nonisolated static let verbose = false

    public nonisolated let pluginID: String
    private let directory: URL
    private let objectsDirectory: URL
    private let manifestURL: URL
    private var policy: DiskCachePolicy
    private var entries: [String: DiskCacheEntry] = [:]
    private var totalBytes: Int64 = 0
    private var loaded = false
    private var invalidated = false
    private var accessSaveTask: Task<Void, Never>?

    init(pluginID: String, directory: URL, policy: DiskCachePolicy) {
        self.pluginID = pluginID
        self.directory = directory.standardizedFileURL
        self.objectsDirectory = self.directory.appendingPathComponent("objects", isDirectory: true)
        self.manifestURL = self.directory.appendingPathComponent("manifest.json")
        self.policy = policy
    }

    // MARK: - Policy / Lifecycle

    func updatePolicy(_ newPolicy: DiskCachePolicy) {
        policy = newPolicy
        guard loaded, !invalidated else { return }
        purgeExpired()
        enforceBudget()
        persistManifest()
    }

    /// clearAll 后作废旧句柄：后续写入返回 false、读取返回 nil。
    func markInvalidated() {
        invalidated = true
        accessSaveTask?.cancel()
        entries.removeAll()
        totalBytes = 0
    }

    /// 立即落盘索引（测试与诊断用；正常路径由结构性写入自动落盘）。
    func flushManifest() {
        accessSaveTask?.cancel()
        guard loaded, !invalidated else { return }
        persistManifest()
    }

    // MARK: - Store

    @discardableResult
    public func store(_ data: Data, forKey key: String, options: DiskCacheStoreOptions) -> Bool {
        guard !invalidated else { return false }
        ensureLoaded()
        guard !invalidated else { return false }
        let hashed = DiskCacheKey.hashed(key)
        do {
            try ensureObjectsDirectory()
            try data.write(to: objectURL(hashed), options: .atomic)
        } catch {
            Self.logger.error("\(Self.t)store failed for \(self.pluginID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        recordEntry(hashed, byteCount: Int64(data.count), options: options)
        purgeExpired()
        enforceBudget()
        persistManifest()
        return true
    }

    @discardableResult
    public func store(fileAt sourceURL: URL, forKey key: String, options: DiskCacheStoreOptions) -> Bool {
        guard !invalidated else { return false }
        ensureLoaded()
        guard !invalidated else { return false }
        let fm = FileManager.default
        let hashed = DiskCacheKey.hashed(key)
        let dest = objectURL(hashed)
        let tmp = objectsDirectory.appendingPathComponent("\(hashed).import-\(UUID().uuidString)")
        do {
            try ensureObjectsDirectory()
            var copied = false
            do {
                try fm.moveItem(at: sourceURL, to: tmp)
            } catch {
                try fm.copyItem(at: sourceURL, to: tmp)
                copied = true
            }
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
            if copied {
                try? fm.removeItem(at: sourceURL)
            }
            let size = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            recordEntry(hashed, byteCount: size, options: options)
            purgeExpired()
            enforceBudget()
            persistManifest()
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            Self.logger.error("\(Self.t)file import failed for \(self.pluginID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Read

    public func data(forKey key: String) -> Data? {
        guard !invalidated else { return nil }
        ensureLoaded()
        guard !invalidated else { return nil }
        let hashed = DiskCacheKey.hashed(key)
        guard let entry = entries[hashed] else { return nil }
        if isExpired(entry) {
            deleteEntry(hashed)
            persistManifest()
            return nil
        }
        guard let data = try? Data(contentsOf: objectURL(hashed)) else {
            deleteEntry(hashed)
            persistManifest()
            return nil
        }
        touch(hashed)
        return data
    }

    public func fileURL(forKey key: String) -> URL? {
        guard !invalidated else { return nil }
        ensureLoaded()
        guard !invalidated else { return nil }
        let hashed = DiskCacheKey.hashed(key)
        guard let entry = entries[hashed] else { return nil }
        if isExpired(entry) {
            deleteEntry(hashed)
            persistManifest()
            return nil
        }
        let url = objectURL(hashed)
        guard FileManager.default.fileExists(atPath: url.path) else {
            deleteEntry(hashed)
            persistManifest()
            return nil
        }
        touch(hashed)
        return url
    }

    // MARK: - Remove / Clear

    public func remove(forKey key: String) {
        guard !invalidated else { return }
        ensureLoaded()
        let hashed = DiskCacheKey.hashed(key)
        guard entries[hashed] != nil else { return }
        deleteEntry(hashed)
        persistManifest()
    }

    public func invalidate(tag: String) {
        guard !invalidated else { return }
        ensureLoaded()
        let victims = entries.filter { $0.value.tags.contains(tag) }.map(\.key)
        guard !victims.isEmpty else { return }
        for hashed in victims {
            deleteEntry(hashed)
        }
        persistManifest()
    }

    public func clear() {
        guard !invalidated else { return }
        ensureLoaded()
        accessSaveTask?.cancel()
        try? FileManager.default.removeItem(at: objectsDirectory)
        try? FileManager.default.removeItem(at: manifestURL)
        entries.removeAll()
        totalBytes = 0
    }

    public func diskUsage() -> Int64 {
        guard !invalidated else { return 0 }
        ensureLoaded()
        return totalBytes
    }

    // MARK: - Index

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard validatePaths() else {
            invalidated = true
            Self.logger.error("\(Self.t)bucket path escapes cache root, invalidated: \(self.directory.path, privacy: .public)")
            return
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: objectsDirectory, withIntermediateDirectories: true)

        var manifestEntries: [String: DiskCacheEntry] = [:]
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(DiskCacheManifest.self, from: data),
           manifest.version == DiskCacheManifest.currentVersion {
            manifestEntries = manifest.entries
        }

        var rebuilt: [String: DiskCacheEntry] = [:]
        let files = (try? fm.contentsOfDirectory(
            at: objectsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        )) ?? []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasSuffix(".bin") else {
                // crash 残留的临时文件
                try? fm.removeItem(at: file)
                continue
            }
            let hashed = String(name.dropLast(4))
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let mtime = values?.contentModificationDate ?? Date()
            if var entry = manifestEntries[hashed] {
                entry.byteCount = size
                rebuilt[hashed] = entry
            } else {
                rebuilt[hashed] = DiskCacheEntry(
                    byteCount: size, createdAt: mtime, lastAccess: mtime,
                    expiresAt: nil, tags: [], pinned: false
                )
            }
        }
        entries = rebuilt
        totalBytes = rebuilt.values.reduce(0) { $0 + $1.byteCount }
        purgeExpired()
        enforceBudget()
        persistManifest()
    }

    private func recordEntry(_ hashed: String, byteCount: Int64, options: DiskCacheStoreOptions) {
        let now = Date()
        let old = entries[hashed]
        totalBytes -= old?.byteCount ?? 0
        totalBytes += byteCount
        entries[hashed] = DiskCacheEntry(
            byteCount: byteCount,
            createdAt: old?.createdAt ?? now,
            lastAccess: now,
            expiresAt: resolveExpiry(options.ttl, from: now),
            tags: options.tags,
            pinned: options.pinned
        )
    }

    private func resolveExpiry(_ ttl: DiskCacheTTL, from now: Date) -> Date? {
        switch ttl {
        case .useDefault:
            return policy.defaultTTL.map { now.addingTimeInterval($0) }
        case .never:
            return nil
        case .seconds(let seconds):
            return now.addingTimeInterval(max(0, seconds))
        }
    }

    private func touch(_ hashed: String) {
        guard var entry = entries[hashed] else { return }
        entry.lastAccess = Date()
        entries[hashed] = entry
        scheduleAccessSave()
    }

    private func deleteEntry(_ hashed: String) {
        guard let entry = entries.removeValue(forKey: hashed) else { return }
        totalBytes -= entry.byteCount
        try? FileManager.default.removeItem(at: objectURL(hashed))
    }

    private func isExpired(_ entry: DiskCacheEntry, now: Date = Date()) -> Bool {
        guard !entry.pinned, let expiresAt = entry.expiresAt else { return false }
        return expiresAt <= now
    }

    private func purgeExpired() {
        let now = Date()
        let victims = entries.filter { isExpired($0.value, now: now) }.map(\.key)
        for hashed in victims {
            deleteEntry(hashed)
        }
    }

    private func enforceBudget() {
        guard let limit = policy.sizeLimit, totalBytes > limit else { return }
        let target = policy.targetSize ?? limit / 4 * 3
        let candidates = entries.filter { !$0.value.pinned }
            .sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (hashed, _) in candidates {
            guard totalBytes > target else { break }
            deleteEntry(hashed)
        }
    }

    // MARK: - Persistence

    private func persistManifest() {
        let manifest = DiskCacheManifest(version: DiskCacheManifest.currentVersion, entries: entries)
        do {
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            Self.logger.error("\(Self.t)manifest persist failed for \(self.pluginID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleAccessSave() {
        accessSaveTask?.cancel()
        accessSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistManifest()
        }
    }

    // MARK: - Paths

    private func objectURL(_ hashed: String) -> URL {
        objectsDirectory.appendingPathComponent("\(hashed).bin")
    }

    private func ensureObjectsDirectory() throws {
        try FileManager.default.createDirectory(at: objectsDirectory, withIntermediateDirectories: true)
    }

    /// 桶目录与 objects 目录解析符号链接后必须仍在缓存根内，
    /// 防止外部 symlink 把写入/清理引到缓存根之外。
    private func validatePaths() -> Bool {
        let resolvedDir = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedRoot = directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedDir.hasPrefix(resolvedRoot + "/") else { return false }
        let resolvedObjects = objectsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedObjects.hasPrefix(resolvedDir + "/")
    }
}