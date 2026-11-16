import Foundation
import CryptoKit

/// 桶内一条缓存的元数据。
///
/// 索引可丢：manifest 损坏或滞后时按目录扫描重建，
/// 重建条目会丢失 ttl/tags/pinned（缓存语义下可接受）。
struct DiskCacheEntry: Codable, Sendable {
    var byteCount: Int64
    var createdAt: Date
    var lastAccess: Date
    var expiresAt: Date?
    var tags: [String]
    var pinned: Bool
}

struct DiskCacheManifest: Codable {
    static let currentVersion = 1
    var version: Int
    /// key = 哈希后的文件名 stem。
    var entries: [String: DiskCacheEntry]
}

enum DiskCacheKey {
    /// key → SHA256 hex。任意字符串安全落盘，杜绝路径穿越。
    static func hashed(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// pluginID → 桶目录名。
    ///
    /// 全安全字符（`[A-Za-z0-9._-]`）时原样使用，保持目录可读；
    /// 发生替换时追加短哈希后缀，避免不同 pluginID 清洗后碰撞到同一桶。
    static func bucketDirectoryName(for pluginID: String) -> String {
        if pluginID.count > 200 {
            return "bucket-" + String(hashed(pluginID).prefix(16))
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let sanitized = String(String.UnicodeScalarView(pluginID.unicodeScalars.map {
            allowed.contains($0) ? $0 : "-"
        }))
        if sanitized == pluginID {
            if pluginID.isEmpty || pluginID == "." || pluginID == ".." {
                return "bucket-" + String(hashed(pluginID).prefix(16))
            }
            return pluginID
        }
        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        let base = trimmed.isEmpty ? "bucket" : trimmed
        return base + "-" + String(hashed(pluginID).prefix(8))
    }
}