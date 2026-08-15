//
//  MainTabView.swift
//  StikJIT
//
//  Created by Stephen on 3/27/25.
//

import SwiftUI

struct MainTabView: View {
    private static let locationTag = "location"
    private static let settingsTag = "settings"
    private static let actionBookmarksTag = "action-bookmarks"
    private static let actionRouteTag = "action-route"
    private static let actionImportTag = "action-import"

    @State private var selection: String = Self.locationTag
    @State private var activeTab: String = Self.locationTag

    @State private var showBookmarks = false
    @State private var showRouteSearch = false
    @State private var showCoordinateImporter = false

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                LocationSimulationView(
                    showBookmarks: $showBookmarks,
                    showRouteSearch: $showRouteSearch,
                    showCoordinateImporter: $showCoordinateImporter
                )
            }
            .tabItem { Label("位置", systemImage: "location") }
            .tag(Self.locationTag)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(Self.settingsTag)

            // Fake tabs: they never actually switch pages. Tapping them is
            // intercepted below, which fires the action and reverts the
            // selection so no visible page change happens.
            Color.clear
                .tabItem { Label("书签", systemImage: "bookmark.fill") }
                .tag(Self.actionBookmarksTag)

            Color.clear
                .tabItem { Label("路线", systemImage: "point.topleft.down.curvedto.point.bottomright.up") }
                .tag(Self.actionRouteTag)

            Color.clear
                .tabItem { Label("导入", systemImage: "square.and.arrow.down") }
                .tag(Self.actionImportTag)
        }
        .onChange(of: selection) { _, newValue in
            switch newValue {
            case Self.actionBookmarksTag:
                selection = activeTab
                playButtonHaptic()
                showBookmarks = true
            case Self.actionRouteTag:
                selection = activeTab
                playButtonHaptic()
                showRouteSearch = true
            case Self.actionImportTag:
                selection = activeTab
                showCoordinateImporter = true
            default:
                activeTab = newValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowPairingFilePicker"))) { _ in
            guard selection != Self.settingsTag else { return }
            // SettingsView may not exist yet (lazy TabView); switch to it and
            // re-post once it is on screen so its picker can react.
            selection = Self.settingsTag
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: NSNotification.Name("ShowPairingFilePicker"), object: nil)
            }
        }
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
