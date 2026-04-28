//  SettingsView.swift
//  StikJIT
//
//  Created by Stephen on 3/27/25.

import SwiftUI
import UIKit

struct SettingsView: View {

    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage("customTargetIP") private var customTargetIP = ""

    @State private var isShowingPairingFilePicker = false
    @State private var showPairingFileMessage = false
    @State private var isImportingFile = false
    @State private var importProgress: Float = 0.0

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
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
                Section("Pairing File") {
                    Button { isShowingPairingFilePicker = true } label: {
                        Label("Import Pairing File", systemImage: "doc.badge.plus")
                    }
                    if showPairingFileMessage && !isImportingFile {
                        Label("Imported successfully", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                // Background Keep-Alive
                Section {
                    Toggle(isOn: $keepAliveAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Silent Audio")
                            Text("Plays inaudible audio so iOS keeps the app running.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveAudio) { _, enabled in
                        if enabled { BackgroundAudioManager.shared.start() }
                        else { BackgroundAudioManager.shared.stop() }
                    }

                    Toggle(isOn: $keepAliveLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Location")
                            Text("Uses low-accuracy location to stay alive when an activity needs it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveLocation) { _, enabled in
                        if !enabled { BackgroundLocationManager.shared.stop() }
                    }
                } header: {
                    Text("Background Keep-Alive")
                }

                // Advanced
                Section("Advanced") {
                    HStack {
                        Text("Target Device IP")
                        Spacer()
                        TextField("10.7.0.1", text: $customTargetIP)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numbersAndPunctuation)
                                .submitLabel(.done)
                    }
                    Button { openAppFolder() } label: {
                        Label("App Folder", systemImage: "folder")
                    }.foregroundStyle(.primary)
                }

                // Help
                Section("Help") {
                    Link(destination: URL(string: "https://github.com/StephenDev0/StikDebug-Guide/blob/main/pairing_file.md")!) {
                        Label("Pairing File Guide", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!) {
                        Label("Download LocalDevVPN", systemImage: "arrow.down.circle")
                    }
                }

                // Version footer
                Section {
                    Text("Version \(appVersion) • iOS \(UIDevice.current.systemVersion)")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Settings")
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
            ProgressView("Processing pairing file…")
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

    private func openAppFolder() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = documentsURL.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
        if let url = URL(string: path) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
