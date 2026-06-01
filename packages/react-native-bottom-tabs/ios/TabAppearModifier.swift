import SwiftUI

struct TabAppearContext {
  let index: Int
  let tabData: TabInfo
  let props: TabViewProps
  let updateTabBarAppearance: () -> Void
  let onSelect: (_ key: String) -> Void
}

struct TabAppearModifier: ViewModifier {
  let context: TabAppearContext

  func body(content: Content) -> some View {
    content.onAppear {
      #if !os(macOS)
        context.updateTabBarAppearance()
      #endif

      #if os(iOS)
        // UIKit only moves tabs into the system "More" navigation controller
        // when there are MORE than 5 tab items. With <= 5 visible tabs there is
        // no "More" tab, and the tab at index 4 is a normal, directly-selectable
        // tab — force-selecting it on appear would hijack the user's navigation.
        // `filteredItems` is the set of tabs actually handed to UITabBarController.
        if context.props.filteredItems.count > 5,
           context.index >= 4,
           context.props.selectedPage != context.tabData.key {
          context.onSelect(context.tabData.key)
        }
      #endif
    }
  }
}

extension View {
  func tabAppear(using context: TabAppearContext) -> some View {
    self.modifier(TabAppearModifier(context: context))
  }
}
