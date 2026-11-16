import Foundation
import Testing
@testable import ProviderDiskCache

/// ProviderDiskCache 行为验证。
///
/// 核心不变量：
/// - 缓存 best-effort：miss = nil，写入失败 = false，不抛错。
/// - 索引可丢，目录才是真相：manifest 损坏后按目录重建。
/// - key/pluginID 任意字符串都不能穿越出缓存根。
@Suite("ProviderDiskCache")
struct ProviderDiskCacheTests {

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeProvider() -> DefaultDiskCacheProvider {
        DefaultDiskCacheProvider(cacheRootDirectory: makeRoot())
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - 读写往返

    @Test("存取往返")
    func storeAndReadRoundtrip() async {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a")
        let payload = Data(repeating: 0x5A, count: 4096)

        let stored = await bucket.store(payload, forKey: "image-1")
        let loaded = await bucket.data(forKey: "image-1")

        #expect(stored)
        #expect(loaded == payload)
    }

    @Test("未命中返回 nil，不抛错")
    func missReturnsNil() async {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a")

        #expect(await bucket.data(forKey: "absent") == nil)
        #expect(await bucket.fileURL(forKey: "absent") == nil)
    }

    @Test("fileURL 指向真实文件且内容一致")
    func fileURLPointsAtRealFile() async throws {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a")
        let payload = Data("hello".utf8)
        await bucket.store(payload, forKey: "k")

        let url = try #require(await bucket.fileURL(forKey: "k"))

        #expect(try Data(contentsOf: url) == payload)
    }

    @Test("同 key 覆盖写入，体积不翻倍")
    func overwriteUpdatesSize() async {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a", policy: .unlimited)

        await bucket.store(Data(repeating: 1, count: 100), forKey: "k")
        await bucket.store(Data(repeating: 2, count: 50), forKey: "k")

        #expect(await bucket.data(forKey: "k")?.count == 50)
        #expect(await bucket.diskUsage() == 50)
    }

    // MARK: - 文件导入

    @Test("导入现成文件为 move 语义，源文件被消费")
    func fileImportMovesSource() async throws {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a")
        let source = makeRoot().appendingPathComponent("source.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data(repeating: 0x77, count: 2048)
        try payload.write(to: source)

        let stored = await bucket.store(fileAt: source, forKey: "download-1")

        #expect(stored)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(await bucket.data(forKey: "download-1") == payload)
    }

    @Test("导入覆盖已有条目")
    func fileImportOverwritesExisting() async throws {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a", policy: .unlimited)
        await bucket.store(Data(repeating: 1, count: 100), forKey: "k")

        let source = makeRoot().appendingPathComponent("source2.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 2, count: 30).write(to: source)
        let stored = await bucket.store(fileAt: source, forKey: "k")

        #expect(stored)
        #expect(await bucket.data(forKey: "k") == Data(repeating: 2, count: 30))
        #expect(await bucket.diskUsage() == 30)
    }

    @Test("导入不存在的文件返回 false，不破坏已有条目")
    func fileImportMissingSourceFails() async {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a")
        await bucket.store(Data("old".utf8), forKey: "k")

        let stored = await bucket.store(fileAt: makeRoot().appendingPathComponent("nope.bin"), forKey: "k")

        #expect(!stored)
        #expect(await bucket.data(forKey: "k") == Data("old".utf8))
    }

    // MARK: - 路径安全

    @Test("恶意 key 被哈希，不会路径穿越")
    func maliciousKeyIsHashed() async throws {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a")
        let payload = Data("safe".utf8)

        let stored = await bucket.store(payload, forKey: "../../escape")

        #expect(stored)
        #expect(await bucket.data(forKey: "../../escape") == payload)
        let objects = provider.cacheRootDirectory
            .appendingPathComponent("plugin.a/objects", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: objects.path)
        #expect(names.allSatisfy { $0.hasSuffix(".bin") })
    }

    @Test("恶意 pluginID 清洗后仍留在缓存根内且不碰撞")
    func maliciousPluginIDStaysInRoot() async {
        #expect(!DiskCacheKey.bucketDirectoryName(for: "../evil").contains("/"))
        #expect(DiskCacheKey.bucketDirectoryName(for: "..") != "..")
        #expect(DiskCacheKey.bucketDirectoryName(for: "") != "")
        #expect(DiskCacheKey.bucketDirectoryName(for: "a/b") != DiskCacheKey.bucketDirectoryName(for: "a-b"))
        #expect(DiskCacheKey.bucketDirectoryName(for: "com.coffic.lumi.plugin.x") == "com.coffic.lumi.plugin.x")

        let provider = makeProvider()
        let bucket = await provider.bucket(for: "../evil")
        await bucket.store(Data("x".utf8), forKey: "k")
        let report = await provider.usageReport()
        #expect(report.buckets.count == 1)
        #expect(!report.buckets[0].pluginID.contains("/"))
    }

    // MARK: - 淘汰策略

    @Test("超过高水位触发 LRU 淘汰到低水位")
    func lruEvictionRespectsWatermarks() async {
        let provider = makeProvider()
        let policy = DiskCachePolicy(sizeLimit: 300, targetSize: 200)
        let bucket = await provider.bucket(for: "plugin.a", policy: policy)

        await bucket.store(Data(repeating: 1, count: 100), forKey: "a")
        await sleep(0.01)
        await bucket.store(Data(repeating: 2, count: 100), forKey: "b")
        await sleep(0.01)
        await bucket.store(Data(repeating: 3, count: 100), forKey: "c")
        await sleep(0.01)
        _ = await bucket.data(forKey: "a") // a 变为最近访问
        await sleep(0.01)
        await bucket.store(Data(repeating: 4, count: 100), forKey: "d") // 400 > 300 → 淘汰 b、c

        #expect(await bucket.data(forKey: "a") != nil)
        #expect(await bucket.data(forKey: "d") != nil)
        #expect(await bucket.data(forKey: "b") == nil)
        #expect(await bucket.data(forKey: "c") == nil)
        #expect(await bucket.diskUsage() == 200)
    }

    @Test("TTL 到期后读取为 nil 且文件被清理")
    func ttlExpiry() async throws {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a")
        await bucket.store(Data("x".utf8), forKey: "k", options: DiskCacheStoreOptions(ttl: .seconds(0.05)))

        #expect(await bucket.data(forKey: "k") != nil)
        await sleep(0.15)

        #expect(await bucket.data(forKey: "k") == nil)
        #expect(await bucket.diskUsage() == 0)
        let objects = provider.cacheRootDirectory.appendingPathComponent("plugin.a/objects", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: objects.path)
        #expect(names.isEmpty)
    }

    @Test("桶默认 TTL 生效，.never 覆盖为不过期")
    func bucketDefaultTTL() async {
        let provider = makeProvider()
        let policy = DiskCachePolicy(sizeLimit: nil, targetSize: nil, defaultTTL: 0.05)
        let bucket = await provider.bucket(for: "plugin.a", policy: policy)

        await bucket.store(Data("x".utf8), forKey: "default-ttl")
        await bucket.store(Data("y".utf8), forKey: "never", options: DiskCacheStoreOptions(ttl: .never))
        await sleep(0.15)

        #expect(await bucket.data(forKey: "default-ttl") == nil)
        #expect(await bucket.data(forKey: "never") != nil)
    }

    @Test("pinned 豁免 LRU 与 TTL，但显式失效仍可删除")
    func pinnedExemptFromAutomaticRemoval() async {
        let provider = makeProvider()
        let policy = DiskCachePolicy(sizeLimit: 150, targetSize: 100)
        let bucket = await provider.bucket(for: "plugin.a", policy: policy)

        await bucket.store(
            Data(repeating: 1, count: 100), forKey: "pinned",
            options: DiskCacheStoreOptions(ttl: .seconds(0.05), tags: ["account"], pinned: true)
        )
        await bucket.store(Data(repeating: 2, count: 100), forKey: "normal")
        await sleep(0.15)

        // normal 被 LRU 淘汰，pinned 虽超 TTL 仍存活
        #expect(await bucket.data(forKey: "pinned") != nil)
        #expect(await bucket.data(forKey: "normal") == nil)

        await bucket.invalidate(tag: "account")
        #expect(await bucket.data(forKey: "pinned") == nil)
    }

    @Test("按 tag 批量失效，其他 tag 不受影响")
    func tagInvalidation() async {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a", policy: .unlimited)

        await bucket.store(Data("1".utf8), forKey: "a", options: DiskCacheStoreOptions(tags: ["account-1"]))
        await bucket.store(Data("2".utf8), forKey: "b", options: DiskCacheStoreOptions(tags: ["account-1", "shared"]))
        await bucket.store(Data("3".utf8), forKey: "c", options: DiskCacheStoreOptions(tags: ["account-2"]))

        await bucket.invalidate(tag: "account-1")

        #expect(await bucket.data(forKey: "a") == nil)
        #expect(await bucket.data(forKey: "b") == nil)
        #expect(await bucket.data(forKey: "c") != nil)
    }

    @Test("不限容量策略不淘汰")
    func unlimitedPolicyNeverEvicts() async {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a", policy: .unlimited)

        for i in 0..<10 {
            await bucket.store(Data(repeating: UInt8(i), count: 1000), forKey: "k\(i)")
        }

        #expect(await bucket.diskUsage() == 10_000)
        #expect(await bucket.data(forKey: "k0") != nil)
    }

    @Test("策略钳制：target 不低于 limit 时取 3/4；limit 为 nil 时 target 归 nil")
    func policyClamping() {
        let derived = DiskCachePolicy(sizeLimit: 100, targetSize: 500)
        #expect(derived.targetSize == 75)

        let noLimit = DiskCachePolicy(sizeLimit: nil, targetSize: 50)
        #expect(noLimit.targetSize == nil)

        let defaultPolicy = DiskCachePolicy.default
        let expectedLimit: Int64 = 200 * 1024 * 1024
        let expectedTarget: Int64 = 150 * 1024 * 1024
        #expect(defaultPolicy.sizeLimit == expectedLimit)
        #expect(defaultPolicy.targetSize == expectedTarget)
    }

    // MARK: - 清理

    @Test("remove 删除单条")
    func removeSingleEntry() async {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a")
        await bucket.store(Data("1".utf8), forKey: "a")
        await bucket.store(Data("2".utf8), forKey: "b")

        await bucket.remove(forKey: "a")

        #expect(await bucket.data(forKey: "a") == nil)
        #expect(await bucket.data(forKey: "b") != nil)
        #expect(await bucket.diskUsage() == 1)
    }

    @Test("clear 清空本桶，不影响其他桶")
    func clearBucket() async {
        let provider = makeProvider()
        let a = await provider.bucket(for: "plugin.a")
        let b = await provider.bucket(for: "plugin.b")
        await a.store(Data("1".utf8), forKey: "k")
        await b.store(Data("2".utf8), forKey: "k")

        await a.clear()

        #expect(await a.diskUsage() == 0)
        #expect(await a.data(forKey: "k") == nil)
        #expect(await b.data(forKey: "k") != nil)
        // clear 后仍可继续写入
        #expect(await a.store(Data("3".utf8), forKey: "k2"))
    }

    @Test("clearAll 清空全部并作废旧句柄")
    func clearAllInvalidatesHandles() async {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a")
        await bucket.store(Data("1".utf8), forKey: "k")

        await provider.clearAll()

        #expect(await bucket.store(Data("2".utf8), forKey: "k2") == false)
        #expect(await bucket.data(forKey: "k") == nil)
        let report = await provider.usageReport()
        #expect(report.totalBytes == 0)

        let fresh = await provider.bucket(for: "plugin.a")
        #expect(await fresh.store(Data("3".utf8), forKey: "k3"))
    }

    // MARK: - 索引重建

    @Test("manifest 损坏后按目录重建，数据仍可读")
    func manifestRebuildAfterCorruption() async throws {
        let root = makeRoot()
        let provider1 = DefaultDiskCacheProvider(cacheRootDirectory: root)
        let bucket1 = await provider1.bucket(for: "plugin.a")
        let payload = Data("survive".utf8)
        await bucket1.store(payload, forKey: "k")

        let manifest = root.appendingPathComponent("plugin.a/manifest.json")
        try Data("not json".utf8).write(to: manifest)

        let provider2 = DefaultDiskCacheProvider(cacheRootDirectory: root)
        let bucket2 = await provider2.bucket(for: "plugin.a")

        #expect(await bucket2.data(forKey: "k") == payload)
        #expect(await bucket2.diskUsage() == Int64(payload.count))
    }

    @Test("manifest 完好时元数据跨实例保留（pinned 仍豁免淘汰）")
    func manifestPreservesMetadataAcrossInstances() async {
        let root = makeRoot()
        let policy = DiskCachePolicy(sizeLimit: 150, targetSize: 100)
        let provider1 = DefaultDiskCacheProvider(cacheRootDirectory: root)
        let bucket1 = await provider1.bucket(for: "plugin.a", policy: policy)
        await bucket1.store(Data(repeating: 1, count: 100), forKey: "pinned", options: DiskCacheStoreOptions(pinned: true))

        let provider2 = DefaultDiskCacheProvider(cacheRootDirectory: root)
        let bucket2 = await provider2.bucket(for: "plugin.a", policy: policy)
        await bucket2.store(Data(repeating: 2, count: 100), forKey: "normal")

        #expect(await bucket2.data(forKey: "pinned") != nil)
        #expect(await bucket2.data(forKey: "normal") == nil)
    }

    @Test("manifest 中已丢失文件的条目被剔除")
    func manifestEntryWithoutFileIsDropped() async throws {
        let root = makeRoot()
        let provider1 = DefaultDiskCacheProvider(cacheRootDirectory: root)
        let bucket1 = await provider1.bucket(for: "plugin.a")
        await bucket1.store(Data("1".utf8), forKey: "a")
        await bucket1.store(Data("2".utf8), forKey: "b")

        let objects = root.appendingPathComponent("plugin.a/objects", isDirectory: true)
        let hashed = DiskCacheKey.hashed("a")
        try FileManager.default.removeItem(at: objects.appendingPathComponent("\(hashed).bin"))

        let provider2 = DefaultDiskCacheProvider(cacheRootDirectory: root)
        let bucket2 = await provider2.bucket(for: "plugin.a")

        #expect(await bucket2.data(forKey: "a") == nil)
        #expect(await bucket2.data(forKey: "b") != nil)
        #expect(await bucket2.diskUsage() == 1)
    }

    // MARK: - 统计与句柄

    @Test("usageReport 汇总全部桶")
    func usageReportAggregates() async {
        let provider = makeProvider()
        let a = await provider.bucket(for: "plugin.a")
        let b = await provider.bucket(for: "plugin.b")
        await a.store(Data(repeating: 1, count: 100), forKey: "k1")
        await a.store(Data(repeating: 2, count: 200), forKey: "k2")
        await b.store(Data(repeating: 3, count: 300), forKey: "k1")

        let report = await provider.usageReport()

        #expect(report.buckets.count == 2)
        #expect(report.totalBytes == 600)
        let usageA = report.buckets.first { $0.pluginID == "plugin.a" }
        #expect(usageA?.byteCount == 300)
        #expect(usageA?.entryCount == 2)
    }

    @Test("同一 pluginID 返回同一句柄，policy 以最新为准")
    func bucketIdentityAndPolicyUpdate() async {
        let provider = makeProvider()
        let b1 = await provider.bucket(for: "plugin.a", policy: .unlimited)
        let b2 = await provider.bucket(for: "plugin.a", policy: .unlimited)
        #expect(b1 === b2)

        await b1.store(Data(repeating: 1, count: 100), forKey: "a")
        await b1.store(Data(repeating: 2, count: 100), forKey: "b")
        // 收紧策略后立即执行新预算
        _ = await provider.bucket(for: "plugin.a", policy: DiskCachePolicy(sizeLimit: 150, targetSize: 100))

        #expect(await b1.diskUsage() == 100)
    }

    @Test("并发写入全部落盘且体积一致")
    func concurrentStores() async {
        let provider = makeProvider()
        let bucket = await provider.bucket(for: "plugin.a", policy: .unlimited)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    await bucket.store(Data(repeating: UInt8(i), count: 100), forKey: "k\(i)")
                }
            }
        }

        #expect(await bucket.diskUsage() == 4000)
        for i in 0..<40 {
            #expect(await bucket.data(forKey: "k\(i)") != nil)
        }
    }

    @Test("clearBucket 清空已注册桶且保留其自定义策略")
    func clearBucketPreservesPolicy() async {
        let provider = makeProvider()
        let policy = DiskCachePolicy(sizeLimit: 150, targetSize: 100)
        let bucket = await provider.bucket(for: "plugin.a", policy: policy)
        await bucket.store(Data(repeating: 1, count: 100), forKey: "a")

        await provider.clearBucket(pluginID: "plugin.a")
        #expect(await bucket.diskUsage() == 0)

        // 策略若被重置为默认 200MB，下面 200B 不会淘汰；保留 150B 高水位则淘汰到 100B。
        await bucket.store(Data(repeating: 2, count: 100), forKey: "b")
        await bucket.store(Data(repeating: 3, count: 100), forKey: "c")
        #expect(await bucket.diskUsage() == 100)
    }

    @Test("clearBucket 清理未注册的桶目录")
    func clearBucketUnregistered() async {
        let root = makeRoot()
        let provider1 = DefaultDiskCacheProvider(cacheRootDirectory: root)
        let bucket = await provider1.bucket(for: "plugin.a")
        await bucket.store(Data("x".utf8), forKey: "k")

        let provider2 = DefaultDiskCacheProvider(cacheRootDirectory: root)
        await provider2.clearBucket(pluginID: "plugin.a")

        let report = await provider2.usageReport()
        #expect(report.totalBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("plugin.a").path))
    }

    @Test("默认缓存根位于 Caches/<bundleID>/DiskCache")
    func defaultRootLocation() {
        let root = DefaultDiskCacheProvider.makeDefaultCacheRootDirectory()
        #expect(root.pathComponents.contains("DiskCache"))
        #expect(root.pathComponents.contains("Caches"))
    }
}