//  SettingsView.swift
//  StikJIT
//
//  Created by Stephen on 3/27/25.

import SwiftUI
import UIKit

struct SettingsView: View {

    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true

    @StateObject private var builtInVPN = BuiltInVPNManager.shared
    @State private var isShowingPairingFilePicker = false
    @State private var showPairingFileMessage = false
    @State private var isImportingFile = false
    @State private var importProgress: Float = 0.0

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
    }

    private var vpnStatusText: String {
        switch builtInVPN.status {
        case .connected:
            return "已连接"
        case .connecting, .reasserting:
            return "连接中"
        case .disconnecting:
            return "断开中"
        case .disconnected:
            return "未连接"
        case .invalid:
            return "未配置"
        @unknown default:
            return "未知"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // App Header
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Image("StikDebug")
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Text("StikDebug").font(.title2.weight(.semibold))
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }

                // Pairing File
                Section("配对文件") {
                    HStack {
                        Label(hasPairingFile ? "已导入配对文件" : "未导入配对文件", systemImage: hasPairingFile ? "checkmark.seal.fill" : "exclamationmark.triangle")
                            .foregroundStyle(hasPairingFile ? .green : .orange)
                        Spacer()
                    }
                    Text(hasPairingFile ? "配对文件已准备就绪，可用于连接设备和模拟位置。" : "请先导入配对文件，否则无法连接设备。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button { isShowingPairingFilePicker = true } label: {
                        Label(hasPairingFile ? "重新导入配对文件" : "导入配对文件", systemImage: "doc.badge.plus")
                    }
                    if hasPairingFile {
                        ShareLink(item: PairingFileStore.prepareURL()) {
                            Label("导出配对文件", systemImage: "square.and.arrow.up")
                        }
                    }
                    if showPairingFileMessage && !isImportingFile {
                        Label("导入成功", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Section("虚拟定位服务") {
                    HStack {
                        Label("虚拟定位服务", systemImage: "location.viewfinder")
                        Spacer()
                        Text(vpnStatusText)
                            .foregroundStyle(.secondary)
                    }

                    if builtInVPN.status == .connected || builtInVPN.status == .connecting || builtInVPN.status == .reasserting {
                        Button(role: .destructive) {
                            builtInVPN.stop()
                        } label: {
                            Label("断开定位服务", systemImage: "lock.slash")
                        }
                    } else {
                        Button {
                            Task { _ = await builtInVPN.ensureConnected() }
                        } label: {
                            Label("连接定位服务", systemImage: "lock.shield")
                        }
                    }
                }

                // Background Keep-Alive
                Section {
                    Toggle(isOn: $keepAliveAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("静音音频")
                            Text("播放无声频以让 iOS 持续保留应用运行。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveAudio) { _, enabled in
                        if enabled { BackgroundAudioManager.shared.start() }
                        else { BackgroundAudioManager.shared.stop() }
                    }

                    Toggle(isOn: $keepAliveLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("后台定位")
                            Text("在需要保持活动时使用低精度定位维持后台运行。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveLocation) { _, enabled in
                        if !enabled { BackgroundLocationManager.shared.stop() }
                    }
                } header: {
                    Text("后台保活")
                }

                // Help
                Section("帮助") {
                    Link(destination: URL(string: "https://github.com/StephenDev0/StikDebug-Guide/blob/main/pairing_file.md")!) {
                        Label("配对文件指南", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://github.com/jkcoxson/LocalDevVPN")!) {
                        Label("虚拟定位服务基于 LocalDevVPN", systemImage: "network.badge.shield.half.filled")
                    }
                }

                // Version footer
                Section {
                    Text("版本 \(appVersion) • iOS \(UIDevice.current.systemVersion)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("设置")
            .task {
                _ = await builtInVPN.refreshStatus()
            }
        }
        .fileImporter(
            isPresented: $isShowingPairingFilePicker,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }

                do {
                    try PairingFileStore.importFromPicker(url, fileManager: .default)
                    DispatchQueue.main.async {
                        isImportingFile = true
                        importProgress = 0.0
                        showPairingFileMessage = false
                    }

                    let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
                        DispatchQueue.main.async {
                            if importProgress < 1.0 {
                                importProgress += 0.05
                            } else {
                                timer.invalidate()
                                isImportingFile = false
                                showPairingFileMessage = true
                            }
                        }
                    }

                    RunLoop.current.add(progressTimer, forMode: .common)
                    DispatchQueue.main.async {
                        startTunnelInBackground()
                    }
                } catch {
                    break
                }
            case .failure:
                break
            }
        }
        .overlay { if isImportingFile { importBusyOverlay } }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowPairingFilePicker"))) { _ in
            isShowingPairingFilePicker = true
        }
    }

    @ViewBuilder
    private var importBusyOverlay: some View {
        Color.black.opacity(0.35).ignoresSafeArea()
        VStack(spacing: 12) {
            ProgressView("正在处理配对文件…")
            VStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(UIColor.tertiarySystemFill))
                            .frame(height: 8)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.green)
                            .frame(width: geometry.size.width * CGFloat(importProgress), height: 8)
                            .animation(.linear(duration: 0.3), value: importProgress)
                    }
                }
                .frame(height: 8)
                Text("\(Int(importProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 4)
    }

}
