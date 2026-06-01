# Bug: iOS force-selects the 5th tab (index ≥ 4) on appear, hijacking navigation

## Summary

On iOS, a `TabView` with **exactly 5 tabs** (or any app where a tab ends up at
array index ≥ 4 **without** a real UIKit *"More"* tab) suffers from the 5th tab
**selecting itself** whenever its SwiftUI content view runs `onAppear`. This
overrides the user's navigation: tapping or programmatically navigating to *any*
other tab gets bounced back to the index-4 tab.

- **Affected version:** `1.2.0` (and current `main` — the code is unchanged).
- **Platform:** iOS only (`#if os(iOS)` block). Android/macOS/tvOS unaffected.
- **Introduced in:** commit `c1a0dd7` — PR #364 *"feat: add Tab api support on
  newer OS"* (2025-07-13).
- **Affects both** `LegacyTabView` (iOS < 18) and `NewTabView` (iOS ≥ 18): both
  attach `.tabAppear(using:)`, so every iOS version is impacted.

## Symptoms (real-world reproduction)

App layout with 5 native bottom tabs in this order:

| index | tab       |
|------:|-----------|
| 0     | search    |
| 1     | openings  |
| 2     | bookmarks |
| 3     | alerts    |
| 4     | **profile** |

Observed behavior:

1. From the `openings` tab, push a nested screen (`openings/[slug]`). As soon as
   the detail screen mounts, the app jumps to the **profile** tab.
2. Tapping the `openings` tab again immediately bounces to **profile** again.

Both are the same root cause: the **profile** tab is at index 4, and its
`onAppear` force-selects it.

> Note: the issue reproduces **even when an earlier tab is hidden**
> (e.g. `alerts` hidden via `tabBarItemHidden`, leaving 4 *visible* tabs),
> because the index used is the **raw `children` index**, which still counts
> hidden tabs — see "Secondary issue" below.

## Root cause

`ios/TabAppearModifier.swift`:

```swift
func body(content: Content) -> some View {
  content.onAppear {
    #if !os(macOS)
      context.updateTabBarAppearance()
    #endif

    #if os(iOS)
      if context.index >= 4, context.props.selectedPage != context.tabData.key {
        context.onSelect(context.tabData.key)   // ← force-selects this tab
      }
    #endif
  }
}
```

This `onAppear` hook exists to work around UIKit's **"More"** tab: when a
`UITabBarController` has **more than 5** view controllers, UIKit hides tabs at
index ≥ 4 behind a system-managed *"More"* navigation controller. SwiftUI's
`selection` binding (`$props.selectedPage`) is **not** reliably updated for tabs
living inside *"More"*, so the workaround force-syncs the selection when such a
tab's content appears.

The condition is too broad in two independent ways:

### Primary issue — the guard fires when there is no "More" tab

UIKit only creates the *"More"* tab when there are **> 5** tab view controllers.
With **≤ 5** tabs there is no *"More"* tab at all, and the tab at index 4 is a
**normal, directly-selectable** tab. Force-selecting it on `onAppear` therefore
hijacks legitimate navigation:

- `onAppear` for an index-4 tab fires not only on first mount but on **re-renders
  / re-layouts** of the `TabView` (e.g. when consumers toggle the `tabBar`
  render prop to hide the bar, when an item's `hidden`/badge/appearance changes,
  or on tab re-selection). Each time, if that tab is not currently selected, it
  selects itself — which propagates through `onPageSelected → jumpTo →
  onIndexChange` and dispatches a real navigation in `@bottom-tabs/react-navigation`.

The number of view controllers UIKit actually receives equals the **rendered**
tabs, i.e. `TabViewProps.filteredItems`:

```swift
// ios/TabViewProps.swift
var filteredItems: [TabInfo] {
  items.filter { !$0.hidden || $0.key == selectedPage }
}
```

So the workaround should only run when `filteredItems.count > 5`.

### Secondary issue — `context.index` is the raw, hidden-inclusive index

`context.index` is the position in `props.children` (computed via
`props.children.firstIndex(of: child)` in both `LegacyTabView` and `NewTabView`),
which **includes hidden tabs**. A tab can therefore have `index >= 4` while being
only the 4th (or earlier) **visible** tab. The "is this tab inside More?" decision
should be based on the tab's position among the **visible** (`filteredItems`)
tabs, not its raw children index.

## Proposed fix

Minimal, behavior-preserving for real *"More"*-tab apps; resolves the reported
bug for all apps with ≤ 5 visible tabs. Gate the workaround on a *"More"* tab
actually existing:

```diff
--- a/packages/react-native-bottom-tabs/ios/TabAppearModifier.swift
+++ b/packages/react-native-bottom-tabs/ios/TabAppearModifier.swift
@@ func body(content: Content) -> some View {
       #if os(iOS)
-        if context.index >= 4, context.props.selectedPage != context.tabData.key {
+        // UIKit only moves tabs into the system "More" navigation controller
+        // when there are MORE than 5 tab items. With <= 5 visible tabs there is
+        // no "More" tab, and the tab at index 4 is a normal, directly-selectable
+        // tab — force-selecting it on appear would hijack the user's navigation.
+        // `filteredItems` is the set of tabs actually handed to UITabBarController.
+        if context.props.filteredItems.count > 5,
+           context.index >= 4,
+           context.props.selectedPage != context.tabData.key {
           context.onSelect(context.tabData.key)
         }
       #endif
```

### Stronger (optional) variant — also fix the index basis

For full correctness when hidden tabs precede the index-4 tab, base the decision
on the **visible** position rather than the raw children index, e.g. compute the
index of `context.tabData.key` within `context.props.filteredItems` and compare
that to 4. The `filteredItems.count > 5` guard alone already eliminates the
reported regression; the visible-index refinement only matters for apps that
both have a real *"More"* tab **and** hidden tabs before index 4.

## Impact / affected configurations

Any iOS app using `react-native-bottom-tabs` with a tab at array index ≥ 4 and
**no** *"More"* tab (i.e. ≤ 5 visible tabs, the common case for a 5-tab bar) will
have that tab steal selection on appear. This makes the 5th tab effectively
"sticky" and breaks navigation to/from it.

## Environment

- `react-native-bottom-tabs` / `@bottom-tabs/react-navigation` `1.2.0`
- Expo Router (`withLayoutContext` native bottom tabs)
- iOS (reproduced on both the iOS 18+ `Tab` API path and the legacy path)
