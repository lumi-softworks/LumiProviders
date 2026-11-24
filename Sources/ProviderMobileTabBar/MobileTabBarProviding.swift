import Combine
import SwiftUI

/// 移动端底部标签页的一项入口。
///
/// 入口由插件自己声明：标题、图标、排序与内容闭包都属于贡献方。
/// 宿主只负责把注册表渲染成平台外壳（iOS 的 `TabView`），不关心
/// 这项能力在 macOS 上是否存在——没有插件贡献时，标签自然不出现。
@MainActor
public struct MobileTabBarItem: Identifiable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let order: Int

    /// 贡献该入口的插件 id；nil 表示宿主自带入口。
    /// 插件被禁用或卸载时，内核按 owner 撤回贡献。
    public let ownerPluginID: String?

    public let makeContent: @MainActor () -> AnyView

    public init(
        id: String,
        title: String,
        systemImage: String,
        order: Int = 0,
        ownerPluginID: String? = nil,
        makeContent: @escaping @MainActor () -> AnyView
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.order = order
        self.ownerPluginID = ownerPluginID
        self.makeContent = makeContent
    }
}

/// 移动端底部标签页注册表。
///
/// 只负责「有哪些标签」，不渲染任何视图：iOS 宿主壳观察本注册表后
/// 自行构建 `TabView`。macOS 宿主不注册本能力，插件的注册调用因此
/// 自动变成 no-op，与 `MenuBarProviding` 同构。
@MainActor
public protocol MobileTabBarProviding: AnyObject, ObservableObject
where ObjectWillChangePublisher == ObservableObjectPublisher {
    var items: [MobileTabBarItem] { get }

    func addItems(_ items: [MobileTabBarItem])
    func removeItems(ids: Set<String>)
    func removeItems(ownedBy ownerPluginID: String)
}

/// `MobileTabBarProviding` 的默认实现：按 `order` 稳定排序持有入口。
@MainActor
public final class DefaultMobileTabBarProviding: MobileTabBarProviding, ObservableObject {
    @Published public private(set) var items: [MobileTabBarItem] = []

    public init() {}

    public func addItems(_ newItems: [MobileTabBarItem]) {
        var merged = items
        for item in newItems {
            if let index = merged.firstIndex(where: { $0.id == item.id }) {
                merged[index] = item
            } else {
                merged.append(item)
            }
        }
        items = Self.sorted(merged)
    }

    public func removeItems(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
    }

    public func removeItems(ownedBy ownerPluginID: String) {
        items.removeAll { $0.ownerPluginID == ownerPluginID }
    }

    /// 同 `order` 时保持注册先后；重排不会让已有标签跳动。
    private static func sorted(_ items: [MobileTabBarItem]) -> [MobileTabBarItem] {
        items.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.order != rhs.element.order {
                    return lhs.element.order < rhs.element.order
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}