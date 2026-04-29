//
//  PacketTunnelProvider.swift
//  PacketTunnel
//
//  Minimal local loopback VPN adapted from LocalDevVPN/StosVPN.
//

import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var tunnelDeviceIP = "10.7.0.0"
    private var tunnelFakeIP = "10.7.0.1"
    private var tunnelSubnetMask = "255.255.255.0"
    private var tunnelRouteIP = "10.7.0.0"

    private var deviceIPValue: UInt32 = 0
    private var fakeIPValue: UInt32 = 0

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        if let deviceIP = options?["TunnelDeviceIP"] as? String {
            tunnelDeviceIP = deviceIP
        }
        if let fakeIP = options?["TunnelFakeIP"] as? String {
            tunnelFakeIP = fakeIP
        }
        if let subnetMask = options?["TunnelSubnetMask"] as? String {
            tunnelSubnetMask = subnetMask
        }

        deviceIPValue = ipToUInt32(tunnelDeviceIP)
        fakeIPValue = ipToUInt32(tunnelFakeIP)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: tunnelDeviceIP)
        let ipv4 = NEIPv4Settings(addresses: [tunnelDeviceIP], subnetMasks: [tunnelSubnetMask])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: tunnelRouteIP, subnetMask: tunnelSubnetMask)]
        ipv4.excludedRoutes = [.default()]
        settings.ipv4Settings = ipv4

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }
            guard error == nil else {
                completionHandler(error)
                return
            }

            self.forwardPackets()
            completionHandler(nil)
        }
    }

    private func forwardPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }

            let fakeIP = self.fakeIPValue
            let deviceIP = self.deviceIPValue
            var modifiedPackets = packets

            for index in modifiedPackets.indices where protocols[index].int32Value == AF_INET && modifiedPackets[index].count >= 20 {
                modifiedPackets[index].withUnsafeMutableBytes { bytes in
                    guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }

                    let source = UInt32(bigEndian: pointer[3])
                    let destination = UInt32(bigEndian: pointer[4])

                    if source == deviceIP {
                        pointer[3] = fakeIP.bigEndian
                    }
                    if destination == fakeIP {
                        pointer[4] = deviceIP.bigEndian
                    }
                }
            }

            self.packetFlow.writePackets(modifiedPackets, withProtocols: protocols)
            self.forwardPackets()
        }
    }

    private func ipToUInt32(_ ipString: String) -> UInt32 {
        let components = ipString.split(separator: ".")
        guard components.count == 4,
              let first = UInt32(components[0]),
              let second = UInt32(components[1]),
              let third = UInt32(components[2]),
              let fourth = UInt32(components[3]) else {
            return 0
        }
        return (first << 24) | (second << 16) | (third << 8) | fourth
    }
}
