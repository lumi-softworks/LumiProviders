import Foundation

/// 条目过期策略。
public enum DiskCacheTTL: Sendable, Equatable {
    /// 使用桶默认 TTL（`DiskCachePolicy.defaultTTL`）。
    case useDefault
    /// 永不过期（仍可被 LRU 淘汰，除非 pinned）。
    case never
    /// 指定秒数。
    case seconds(TimeInterval)
}

/// 单次写入的可选参数。
public struct DiskCacheStoreOptions: Sendable {
    public var ttl: DiskCacheTTL
    public var tags: [String]
    /// 固定条目：豁免 TTL 过期与 LRU 淘汰；
    /// 显式 `remove` / `invalidate(tag:)` / `clear` 仍可删除。
    public var pinned: Bool

    public init(ttl: DiskCacheTTL = .useDefault, tags: [String] = [], pinned: Bool = false) {
        self.ttl = ttl
        self.tags = tags
        self.pinned = pinned
    }
}

/// 一个插件独占的缓存桶。
///
/// 所有方法都是 best-effort：写入失败返回 false，读取未命中返回 nil，
/// 不抛错——缓存失效是常态，不是事故。
public protocol DiskCacheBucket: AnyObject, Sendable {
    /// 桶所属插件 id。
    var pluginID: String { get }

    /// 写入数据。key 为任意字符串，内部哈希落盘，不会路径穿越。
    /// 同 key 重复写入为覆盖。
    @discardableResult
    func store(_ data: Data, forKey key: String, options: DiskCacheStoreOptions) async -> Bool

    /// 导入现成文件（move 语义：成功后源文件不再存在）。
    /// 跨卷时自动降级为 copy + 删除源文件。
    @discardableResult
    func store(fileAt sourceURL: URL, forKey key: String, options: DiskCacheStoreOptions) async -> Bool

    /// 读取数据；未命中/已过期返回 nil，并顺手清理失效条目。
    func data(forKey key: String) async -> Data?

    /// 读取文件 URL（交给 AsyncImage 等直接使用，避免读进内存）。
    /// URL 仅当次使用有效：条目随后可能被淘汰，不要长期持有。
    func fileURL(forKey key: String) async -> URL?

    /// 删除单条缓存。
    func remove(forKey key: String) async

    /// 按标签批量失效（账号切换等场景）。pinned 条目同样会被移除。
    func invalidate(tag: String) async

    /// 清空整个桶。
    func clear() async

    /// 桶内缓存逻辑字节数。
    func diskUsage() async -> Int64
}

public extension DiskCacheBucket {
    @discardableResult
    func store(_ data: Data, forKey key: String) async -> Bool {
        await store(data, forKey: key, options: DiskCacheStoreOptions())
    }

    @discardableResult
    func store(fileAt sourceURL: URL, forKey key: String) async -> Bool {
        await store(fileAt: sourceURL, forKey: key, options: DiskCacheStoreOptions())
    }
}