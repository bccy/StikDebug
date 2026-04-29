//
//  VPNShortcuts.swift
//  StikDebug
//

import Foundation

#if canImport(AppIntents)
import AppIntents

@available(iOS 16.0, *)
struct StartStikDebugVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "启动 StikDebug VPN"
    static var description = IntentDescription("连接 StikDebug 内置 VPN。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await BuiltInVPNManager.shared.ensureConnected()
        return .result()
    }
}

@available(iOS 16.0, *)
struct StopStikDebugVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "停止 StikDebug VPN"
    static var description = IntentDescription("断开 StikDebug 内置 VPN。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        BuiltInVPNManager.shared.stop()
        return .result()
    }
}

@available(iOS 16.0, *)
struct StikDebugVPNShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartStikDebugVPNIntent(),
            phrases: [
                "启动 \(.applicationName) VPN",
                "连接 \(.applicationName) VPN"
            ],
            shortTitle: "启动 VPN",
            systemImageName: "lock.shield"
        )
        AppShortcut(
            intent: StopStikDebugVPNIntent(),
            phrases: [
                "停止 \(.applicationName) VPN",
                "断开 \(.applicationName) VPN"
            ],
            shortTitle: "停止 VPN",
            systemImageName: "lock.shield.slash"
        )
    }
}
#endif
