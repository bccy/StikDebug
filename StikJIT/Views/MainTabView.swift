//
//  MainTabView.swift
//  StikJIT
//
//  Created by Stephen on 3/27/25.
//

import SwiftUI

struct MainTabView: View {
    @State private var selection: String = "location"
    @State private var showBookmarks = false
    @State private var showRouteSearch = false
    @State private var showCoordinateImporter = false

    var body: some View {
        Group {
            if selection == "location" {
                LocationSimulationView(
                    showBookmarks: $showBookmarks,
                    showRouteSearch: $showRouteSearch,
                    showCoordinateImporter: $showCoordinateImporter
                )
            } else {
                SettingsView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowPairingFilePicker"))) { _ in
            guard selection != "settings" else { return }
            // SettingsView may not exist yet; switch to it and re-post once it
            // is on screen so its picker can react.
            selection = "settings"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: NSNotification.Name("ShowPairingFilePicker"), object: nil)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabButton(title: "位置", systemImage: "location", tag: "location")
            tabButton(title: "设置", systemImage: "gearshape", tag: "settings")

            Spacer()

            actionButton(systemImage: "bookmark.fill") {
                playButtonHaptic()
                showBookmarks = true
            }
            actionButton(systemImage: "point.topleft.down.curvedto.point.bottomright.up") {
                playButtonHaptic()
                showRouteSearch = true
            }
            actionButton(systemImage: "square.and.arrow.down") {
                showCoordinateImporter = true
            }
            .accessibilityLabel("导入坐标")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func tabButton(title: String, systemImage: String, tag: String) -> some View {
        Button {
            selection = tag
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                Text(title)
                    .font(.caption2)
            }
            .foregroundStyle(selection == tag ? Color.accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func playButtonHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.85)
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
