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
            .tabItem { Label("Location", systemImage: "location") }
            .tag("location")

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag("settings")
        }
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
