import AppKit
import SwiftUI

@main
struct AIBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 메뉴바에만 사는 앱이라 띄울 창이 없다.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock 아이콘 없이 메뉴바에만 표시한다.
        NSApp.setActivationPolicy(.accessory)

        let store = UsageStore()
        self.store = store
        statusItemController = StatusItemController(store: store)
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusItemController?.stop()
        store?.stop()
    }
}
