import SwiftUI
import Testing
@testable import ProviderMobileTabBar

@Suite("ProviderMobileTabBar")
@MainActor
struct MobileTabBarProvidingTests {

    private func item(
        _ id: String,
        order: Int = 0,
        owner: String? = nil
    ) -> MobileTabBarItem {
        MobileTabBarItem(
            id: id,
            title: id,
            systemImage: "circle",
            order: order,
            ownerPluginID: owner
        ) {
            AnyView(EmptyView())
        }
    }

    @Test("按 order 排序，同 order 保持注册先后")
    func itemsAreSortedStably() {
        let provider = DefaultMobileTabBarProviding()

        provider.addItems([
            item("c", order: 20),
            item("a", order: 10),
            item("b", order: 10),
        ])

        #expect(provider.items.map(\.id) == ["a", "b", "c"])
    }

    @Test("重复 id 原位替换，不产生重复标签")
    func duplicateIDReplacesInPlace() {
        let provider = DefaultMobileTabBarProviding()

        provider.addItems([item("a", order: 10), item("b", order: 20)])
        provider.addItems([item("a", order: 10)])

        #expect(provider.items.map(\.id) == ["a", "b"])
    }

    @Test("按 id 与 owner 撤回贡献")
    func removesByIDAndOwner() {
        let provider = DefaultMobileTabBarProviding()

        provider.addItems([
            item("a", owner: "plugin.a"),
            item("b", owner: "plugin.b"),
            item("c", owner: "plugin.a"),
        ])

        provider.removeItems(ids: ["b"])
        #expect(provider.items.map(\.id) == ["a", "c"])

        provider.removeItems(ownedBy: "plugin.a")
        #expect(provider.items.isEmpty)
    }

    @Test("内容闭包按需构建")
    func contentIsBuiltLazily() {
        var didBuild = false
        let provider = DefaultMobileTabBarProviding()

        provider.addItems([
            MobileTabBarItem(id: "a", title: "A", systemImage: "circle") {
                didBuild = true
                return AnyView(Text("A"))
            }
        ])

        #expect(didBuild == false)
        _ = provider.items[0].makeContent()
        #expect(didBuild == true)
    }
}