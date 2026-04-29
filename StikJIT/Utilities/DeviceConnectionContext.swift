//
//  DeviceConnectionContext.swift
//  StikJIT
//
//  Created by Stephen.
//

import Foundation

enum DeviceConnectionContext {
    static let localTunnelIPAddress = "198.18.0.2"
    static let defaultTargetIPAddress = "198.18.0.1"

    static var targetIPAddress: String {
        defaultTargetIPAddress
    }
}
