//
//  StikJITApp.swift
//  StikJIT
//
//  Created by Stephen on 3/26/25.
//

import SwiftUI
import idevice

// Register default settings before the app starts
private func registerDefaults() {
    UserDefaults.standard.register(defaults: [
        "keepAliveAudio": true,
        "keepAliveLocation": true
    ])
    UserDefaults.standard.removeObject(forKey: "customTargetIP")
}

// MARK: - Main App

var pubTunnelConnected = false
private var tunnelStartInProgress = false

@main
struct HeartbeatApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var shouldAttemptTunnelReconnect = false

    init() {
        registerDefaults()
        if UserDefaults.standard.bool(forKey: "keepAliveAudio") {
            BackgroundAudioManager.shared.start()
        }
        let fixSelector = NSSelectorFromString("fix_initForOpeningContentTypes:asCopy:")
        if let fixMethod  = class_getInstanceMethod(UIDocumentPickerViewController.self, fixSelector),
           let origMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))) {
            method_exchangeImplementations(origMethod, fixMethod)
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            shouldAttemptTunnelReconnect = true
        case .active:
            if shouldAttemptTunnelReconnect {
                shouldAttemptTunnelReconnect = false
                startTunnelInBackground(showErrorUI: false)
            }
        default:
            break
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .task {
                    _ = await BuiltInVPNManager.shared.ensureConnected()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }
}

// MARK: - Tunnel Helpers

func isPairing() -> Bool {
    let pairingpath = PairingFileStore.prepareURL().path
    var pairingFile: OpaquePointer?
    let err = rp_pairing_file_read(pairingpath, &pairingFile)
    if err != nil { return false }
    rp_pairing_file_free(pairingFile)
    return true
}

func startTunnelInBackground(showErrorUI: Bool = true) {
    assert(Thread.isMainThread, "startTunnelInBackground must be called on the main thread")
    let pairingFileURL = PairingFileStore.prepareURL()

    guard FileManager.default.fileExists(atPath: pairingFileURL.path) else {
        return
    }

    guard !tunnelStartInProgress else {
        return
    }

    tunnelStartInProgress = true

    DispatchQueue.global(qos: .userInteractive).async {
        defer {
            DispatchQueue.main.async {
                tunnelStartInProgress = false
            }
        }
        do {
            let vpnSemaphore = DispatchSemaphore(value: 0)
            var didConnectVPN = false
            Task { @MainActor in
                didConnectVPN = await BuiltInVPNManager.shared.ensureConnected()
                vpnSemaphore.signal()
            }
            vpnSemaphore.wait()

            if !didConnectVPN {
                LogManager.shared.addErrorLog("内置 VPN 未连接，继续尝试设备隧道")
            }

            try JITEnableContext.shared.startTunnel()
            LogManager.shared.addInfoLog("隧道连接成功")
            pubTunnelConnected = true
        } catch {
            let err2 = error as NSError
            let code = err2.code
            LogManager.shared.addErrorLog("\(error.localizedDescription) (Code: \(code))")
            guard showErrorUI else { return }
            DispatchQueue.main.async {
                if code == -9 {
                    do {
                        try PairingFileStore.remove()
                        LogManager.shared.addInfoLog("已移除无效配对文件")
                    } catch {
                        LogManager.shared.addErrorLog("移除无效配对文件失败：\(error.localizedDescription)")
                    }

                    showAlert(
                        title: "配对文件无效",
                        message: "配对文件无效或已过期，请选择新的配对文件。",
                        showOk: true,
                        showTryAgain: false,
                        primaryButtonText: "选择新文件"
                    ) { _ in
                        NotificationCenter.default.post(name: NSNotification.Name("ShowPairingFilePicker"), object: nil)
                    }
                } else {
                    showAlert(
                        title: "连接错误",
                        message: "\(error.localizedDescription)\n\n请确认虚拟定位服务已连接，并且设备可访问。若当前有其它 VPN、代理或 DNS 防护工具正在运行，请先断开后重试。",
                        showOk: false,
                        showTryAgain: true
                    ) { shouldTryAgain in
                        if shouldTryAgain {
                            DispatchQueue.main.async {
                                startTunnelInBackground()
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Alert Helper

public func showAlert(title: String, message: String, showOk: Bool, showTryAgain: Bool = false, primaryButtonText: String? = nil, completion: ((Bool) -> Void)? = nil) {
    DispatchQueue.main.async {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = scene.windows.first?.rootViewController else {
            return
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        if showTryAgain {
            alert.addAction(UIAlertAction(title: primaryButtonText ?? "重试", style: .default) { _ in
                completion?(true)
            })
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                completion?(false)
            })
        } else if showOk {
            alert.addAction(UIAlertAction(title: primaryButtonText ?? "确定", style: .default) { _ in
                completion?(true)
            })
        } else {
             alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
                completion?(true)
            })
        }

        var topController = rootViewController
        while let presented = topController.presentedViewController {
            topController = presented
        }
        topController.present(alert, animated: true)
    }
}
