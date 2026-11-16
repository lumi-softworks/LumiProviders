import Foundation
import os
import LumiLoggingKit

/// `DiskCacheProviding` 的默认实现。
///
/// 目录结构：`~/Library/Caches/<bundleID>/DiskCache/<pluginID>/`
/// 该位置已被 `ProviderUninstall` 的卸载清理覆盖；
/// debug/production 由 bundleID 天然隔离。
public actor DefaultDiskCacheProvider: DiskCacheProviding, SuperLog {
    nonisolated public static let emoji = "📦"
    nonisolated static let logger = Logger(subsystem: "com.coffic.lumi.provider-disk-cache", category: "ProviderDiskCache")
    nonisolated static let verbose = false

    /// 缓存根目录。
    public nonisolated let cacheRootDirectory: URL
    private var buckets: [String: DefaultDiskCacheBucket] = [:]

    /// - Parameter cacheRootDirectory: 缓存根目录；不传时自动计算
    ///   （`~/Library/Caches/<bundleID>/DiskCache/`）。测试注入临时目录。
    public init(cacheRootDirectory: URL? = nil) {
        if let cacheRootDirectory {
            let root = cacheRootDirectory.standardizedFileURL
            Self.ensureDirectory(root)
            self.cacheRootDirectory = root
        } else {
            self.cacheRootDirectory = Self.makeDefaultCacheRootDirectory()
        }
    }

    public func bucket(for pluginID: String, policy: DiskCachePolicy) async -> any DiskCacheBucket {
        let dirName = DiskCacheKey.bucketDirectoryName(for: pluginID)
        if let existing = buckets[dirName] {
            await existing.updatePolicy(policy)
            return existing
        }
        let bucket = DefaultDiskCacheBucket(
            pluginID: pluginID,
            directory: cacheRootDirectory.appendingPathComponent(dirName, isDirectory: true),
            policy: policy
        )
        buckets[dirName] = bucket
        if Self.verbose {
            Self.logger.info("\(Self.t)bucket created for \(pluginID, privacy: .public)")
        }
        return bucket
    }

    public func usageReport() async -> DiskCacheUsageReport {
        let rootPath = cacheRootDirectory.path
        let buckets = await Task.detached(priority: .utility) {
            DiskCacheUsageScanner.scan(rootPath: rootPath)
        }.value
        let total = buckets.reduce(Int64(0)) { $0 + $1.byteCount }
        return DiskCacheUsageReport(buckets: buckets, totalBytes: total)
    }

    public func clearBucket(pluginID: String) async {
        let dirName = DiskCacheKey.bucketDirectoryName(for: pluginID)
        if let existing = buckets[dirName] {
            await existing.clear()
            return
        }
        let dirPath = cacheRootDirectory.appendingPathComponent(dirName, isDirectory: true).path
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(atPath: dirPath)
        }.value
    }

    public func clearAll() async {
        for bucket in buckets.values {
            await bucket.markInvalidated()
        }
        buckets.removeAll()
        let rootPath = cacheRootDirectory.path
        await Task.detached(priority: .utility) {
            DiskCacheUsageScanner.removeAllContents(rootPath: rootPath)
        }.value
        if Self.verbose {
            Self.logger.info("\(Self.t)cleared all disk cache at \(rootPath, privacy: .public)")
        }
    }

    /// 默认缓存根目录：`<Caches>/<bundleID>/DiskCache/`。
    public static func makeDefaultCacheRootDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "com.coffic.Lumi"
        let root = caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("DiskCache", isDirectory: true)
        ensureDirectory(root)
        return root
    }

    private static func ensureDirectory(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            logger.error("\(t)Failed to create directory \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// 纯文件系统扫描，不实例化桶 actor；在 detached utility 任务中运行。
enum DiskCacheUsageScanner {
    static func scan(rootPath: String) -> [DiskCacheBucketUsage] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: rootPath)
        guard let names = try? fm.contentsOfDirectory(atPath: rootPath) else { return [] }
        var result: [DiskCacheBucketUsage] = []
        for name in names.sorted() {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let objects = dir.appendingPathComponent("objects", isDirectory: true)
            var bytes: Int64 = 0
            var count = 0
            let files = (try? fm.contentsOfDirectory(
                at: objects,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            )) ?? []
            for file in files {
                let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                bytes += Int64(values?.fileSize ?? 0)
                count += 1
            }
            result.append(DiskCacheBucketUsage(pluginID: name, byteCount: bytes, entryCount: count))
        }
        return result
    }

    static func removeAllContents(rootPath: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: rootPath) else { return }
        for name in names {
            // removeItem 对 symlink 只删链接本身，不会跟随到外部目标。
            try? fm.removeItem(atPath: (rootPath as NSString).appendingPathComponent(name))
        }
    }
}