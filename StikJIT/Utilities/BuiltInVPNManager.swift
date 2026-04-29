//
//  BuiltInVPNManager.swift
//  StikDebug
//

import Foundation
import Combine
import NetworkExtension

@MainActor
final class BuiltInVPNManager: ObservableObject {
    static let shared = BuiltInVPNManager()

    private let tunnelBundleID = "com.stik.stikdebug.PacketTunnel"
    private let vpnDescription = "StikDebug Loopback"
    private let tunnelDeviceIP = "10.7.0.0"
    private let tunnelFakeIP = "10.7.0.1"
    private let tunnelSubnetMask = "255.255.255.0"

    @Published private(set) var status: NEVPNStatus = .invalid
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var hasLoadedPreferences = false

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.status = self?.manager?.connection.status ?? .invalid
            }
        }
        loadTask = Task { await loadFromPreferences() }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    var isConnected: Bool {
        status == .connected
    }

    func ensureConnected(timeout: TimeInterval = 8) async -> Bool {
        await ensurePreferencesLoaded()

        do {
            if manager == nil {
                try await install()
            }
            guard let manager else { return false }

            if manager.connection.status == .connected {
                status = .connected
                return true
            }

            if manager.connection.status != .connecting {
                try await start(manager)
            }

            return await waitForConnection(timeout: timeout)
        } catch {
            LogManager.shared.addErrorLog("内置 VPN 启动失败：\(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    private func loadFromPreferences() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { candidate in
                guard let proto = candidate.protocolConfiguration as? NETunnelProviderProtocol else { return false }
                return proto.providerBundleIdentifier == tunnelBundleID
            }
            if let manager {
                status = manager.connection.status
            }
            hasLoadedPreferences = true
        } catch {
            LogManager.shared.addErrorLog("加载内置 VPN 配置失败：\(error.localizedDescription)")
            hasLoadedPreferences = true
        }
    }

    private func install() async throws {
        let newManager = NETunnelProviderManager()
        newManager.localizedDescription = vpnDescription

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = tunnelBundleID
        proto.serverAddress = "StikDebug 本地网络隧道"
        newManager.protocolConfiguration = proto

        let onDemandRule = NEOnDemandRuleEvaluateConnection()
        onDemandRule.interfaceTypeMatch = .any
        onDemandRule.connectionRules = [
            NEEvaluateConnectionRule(matchDomains: [tunnelDeviceIP, tunnelFakeIP], andAction: .connectIfNeeded)
        ]

        newManager.onDemandRules = [onDemandRule]
        newManager.isOnDemandEnabled = true
        newManager.isEnabled = true

        try await newManager.saveToPreferences()
        try await newManager.loadFromPreferences()
        manager = newManager
        status = newManager.connection.status
    }

    private func start(_ manager: NETunnelProviderManager) async throws {
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        let options: [String: NSObject] = [
            "TunnelDeviceIP": tunnelDeviceIP as NSObject,
            "TunnelFakeIP": tunnelFakeIP as NSObject,
            "TunnelSubnetMask": tunnelSubnetMask as NSObject
        ]
        try manager.connection.startVPNTunnel(options: options)
        status = manager.connection.status
    }

    private func waitForConnection(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let currentStatus = manager?.connection.status ?? .invalid
            status = currentStatus
            if currentStatus == .connected { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return manager?.connection.status == .connected
    }

    private func ensurePreferencesLoaded() async {
        if hasLoadedPreferences { return }
        if let loadTask {
            await loadTask.value
            return
        }
        await loadFromPreferences()
    }
}
