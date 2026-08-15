//
//  MainTabView.swift
//  StikJIT
//
//  Created by Stephen on 3/27/25.
//

import SwiftUI

struct MainTabView: View {
    @State private var selection: String = "location"

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                LocationSimulationView()
            }
            .tabItem { Label("位置", systemImage: "location") }
            .tag("location")

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag("settings")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ShowPairingFilePicker"))) { _ in
            guard selection != "settings" else { return }
            // SettingsView may not exist yet (lazy TabView); switch to it and
            // re-post once it is on screen so its picker can react.
            selection = "settings"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.post(name: NSNotification.Name("ShowPairingFilePicker"), object: nil)
            }
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
