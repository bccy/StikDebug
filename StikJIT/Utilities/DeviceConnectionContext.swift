//
//  DeviceConnectionContext.swift
//  StikJIT
//
//  Created by Stephen.
//

import Foundation

enum DeviceConnectionContext {
    static let localTunnelIPAddress = "10.7.0.0"
    static let defaultTargetIPAddress = "10.7.0.1"

    static var targetIPAddress: String {
        defaultTargetIPAddress
    }
}
