import Foundation

/// 磁盘缓存桶的治理策略。
///
/// 缓存是「删了也不影响」的加速数据：策略只决定何时自动清理，
/// 不提供任何持久化保证。默认水位沿用 PluginAppStoreConnect
/// 截图缓存生产验证过的 200MB → 150MB。
public struct DiskCachePolicy: Sendable, Equatable {
    /// 容量高水位（字节）。超过即触发 LRU 淘汰；nil 表示不限容量。
    public var sizeLimit: Int64?
    /// 淘汰低水位（字节）。淘汰到此值以下停止；nil 时取高水位的 3/4。
    public var targetSize: Int64?
    /// 桶默认 TTL（秒）。nil 表示条目默认不过期。
    public var defaultTTL: TimeInterval?

    public init(
        sizeLimit: Int64? = 200 * 1024 * 1024,
        targetSize: Int64? = 150 * 1024 * 1024,
        defaultTTL: TimeInterval? = nil
    ) {
        assert(sizeLimit == nil || sizeLimit! >= 0, "sizeLimit must be non-negative")
        assert(targetSize == nil || targetSize! >= 0, "targetSize must be non-negative")
        assert(defaultTTL == nil || defaultTTL! >= 0, "defaultTTL must be non-negative")
        let limit = sizeLimit.map { max(0, $0) }
        var target = targetSize.map { max(0, $0) }
        if let limit {
            if target == nil || target! >= limit {
                target = limit / 4 * 3
            }
        } else {
            target = nil
        }
        self.sizeLimit = limit
        self.targetSize = target
        self.defaultTTL = defaultTTL.map { max(0, $0) }
    }

    /// 200MB 高水位 → 150MB 低水位，无默认 TTL。
    public static let `default` = DiskCachePolicy()

    /// 不限容量、不过期（仍受显式清理约束）。
    public static let unlimited = DiskCachePolicy(sizeLimit: nil, targetSize: nil, defaultTTL: nil)
}