import Foundation

/// 磁盘缓存能力协议——管理「删了也不影响」的加速数据（图片、文件等）。
///
/// 与 `StorageProviding` 的边界：Storage 的根在 Application Support，
/// 会被跨版本迁移、计入数据体积；DiskCache 的根在 `~/Library/Caches`，
/// 不迁移、不保证存活、系统磁盘紧张时可回收。
///
/// 协议刻意不标 `@MainActor`（照 `NetworkProviding` 先例）：
/// 磁盘 IO 不应占用主线程，调用方本就在后台 await。
public protocol DiskCacheProviding: AnyObject, Sendable {
    /// 取得插件专属缓存桶。同一 pluginID 返回同一句柄；policy 以最新一次为准。
    func bucket(for pluginID: String, policy: DiskCachePolicy) async -> any DiskCacheBucket

    /// 扫描全部桶的磁盘占用（后台 utility 优先级，不阻塞主线程）。
    func usageReport() async -> DiskCacheUsageReport

    /// 清空指定插件的缓存桶，不改变该桶已注册的治理策略。
    /// 管理界面专用：避免经 `bucket(for:)` 取句柄时把生产者的自定义策略重置为默认。
    func clearBucket(pluginID: String) async

    /// 清空全部缓存。已发出的桶句柄随即失效（写入返回 false、读取返回 nil）。
    func clearAll() async
}

public extension DiskCacheProviding {
    /// 以默认策略取得缓存桶。
    func bucket(for pluginID: String) async -> any DiskCacheBucket {
        await bucket(for: pluginID, policy: .default)
    }
}

/// 单个桶的占用快照。pluginID 即桶目录名（规范 pluginID 下两者一致）。
public struct DiskCacheBucketUsage: Sendable, Equatable, Identifiable {
    public let pluginID: String
    public let byteCount: Int64
    public let entryCount: Int
    public var id: String { pluginID }

    public init(pluginID: String, byteCount: Int64, entryCount: Int) {
        self.pluginID = pluginID
        self.byteCount = byteCount
        self.entryCount = entryCount
    }
}

/// 全部桶的占用快照。
public struct DiskCacheUsageReport: Sendable, Equatable {
    public let buckets: [DiskCacheBucketUsage]
    public let totalBytes: Int64

    public init(buckets: [DiskCacheBucketUsage], totalBytes: Int64) {
        self.buckets = buckets
        self.totalBytes = totalBytes
    }

    public static let empty = DiskCacheUsageReport(buckets: [], totalBytes: 0)
}