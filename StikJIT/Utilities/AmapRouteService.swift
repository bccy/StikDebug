//
//  AmapRouteService.swift
//  StikJIT
//
//  高德开放平台驾车路径规划(Web 服务,免费个人开发者配额)。
//  坐标系:GCJ-02,与地图坐标系一致,免转换。
//  返回逐段距离/耗时,可直接得到逐段真实行驶速度用于播放。
//

import Foundation
import CoreLocation

enum AmapRouteService {
    // 高德 Web 服务 Key(用户自备,可在高德开放平台申请)
    private static let apiKey = "813fae382adc447ef9ee9f08d95950f4"

    private static let endpoint = "https://restapi.amap.com/v3/direction/driving"

    struct Step {
        let distance: CLLocationDistance
        let duration: TimeInterval

        var speed: CLLocationSpeed {
            distance / max(duration, 1)
        }
    }

    struct Route {
        let coordinates: [CLLocationCoordinate2D]
        let steps: [Step]
        let totalDistance: CLLocationDistance
        let totalDuration: TimeInterval
    }

    static func fetchDrivingRoute(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) async throws -> Route {
        var components = URLComponents(string: endpoint)!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "origin", value: "\(start.longitude),\(start.latitude)"),
            URLQueryItem(name: "destination", value: "\(end.longitude),\(end.latitude)"),
            URLQueryItem(name: "extensions", value: "all"),
            URLQueryItem(name: "strategy", value: "0")
        ]
        guard let url = components.url else {
            throw NSError(domain: "AmapRoute", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法构造高德请求。"])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "AmapRoute", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "高德接口 HTTP \(http.statusCode)。"])
        }

        let decoded = try JSONDecoder().decode(AmapResponse.self, from: data)
        guard decoded.status == "1", let path = decoded.route?.paths?.first else {
            throw NSError(domain: "AmapRoute", code: -2, userInfo: [NSLocalizedDescriptionKey: "高德未返回路线：\(decoded.info ?? "未知错误")"])
        }

        var coordinates: [CLLocationCoordinate2D] = []
        var steps: [Step] = []
        var totalDistance: CLLocationDistance = 0
        var totalDuration: TimeInterval = 0

        for step in path.steps ?? [] {
            let distance = Double(step.distance ?? "0") ?? 0
            let duration = Double(step.duration ?? "0") ?? 0
            let stepCoords = parsePolyline(step.polyline)
            if stepCoords.isEmpty { continue }

            if coordinates.isEmpty {
                coordinates = stepCoords
            } else if let last = coordinates.last, let first = stepCoords.first,
                      abs(last.latitude - first.latitude) < 1e-6,
                      abs(last.longitude - first.longitude) < 1e-6 {
                // 相邻 step 首尾相连,去掉重复点
                coordinates.append(contentsOf: stepCoords.dropFirst())
            } else {
                coordinates.append(contentsOf: stepCoords)
            }

            totalDistance += distance
            totalDuration += duration
            steps.append(Step(distance: distance, duration: duration))
        }

        guard !coordinates.isEmpty else {
            throw NSError(domain: "AmapRoute", code: -3, userInfo: [NSLocalizedDescriptionKey: "路线坐标为空。"])
        }
        return Route(
            coordinates: coordinates,
            steps: steps,
            totalDistance: totalDistance,
            totalDuration: totalDuration
        )
    }

    /// 把采样点序列映射到高德各 step 的真实行驶速度
    static func segmentSpeeds(
        for sampled: [CLLocationCoordinate2D],
        rawPath: [CLLocationCoordinate2D],
        steps: [Step]
    ) -> [CLLocationSpeed] {
        guard sampled.count > 1, !rawPath.isEmpty, !steps.isEmpty else { return [] }

        // 原始路径各点的累计里程
        var cumDist: [CLLocationDistance] = [0]
        for i in 1..<rawPath.count {
            let d = CLLocation(latitude: rawPath[i - 1].latitude, longitude: rawPath[i - 1].longitude)
                .distance(from: CLLocation(latitude: rawPath[i].latitude, longitude: rawPath[i].longitude))
            cumDist.append(cumDist[i - 1] + d)
        }

        // 各 step 的累计里程边界
        var stepBounds: [CLLocationDistance] = []
        var accumulated: CLLocationDistance = 0
        for step in steps {
            accumulated += step.distance
            stepBounds.append(accumulated)
        }

        // 采样段中点 → 原始路径最近点 → 里程 → 所在 step 的速度
        var speeds: [CLLocationSpeed] = []
        for (a, b) in zip(sampled, sampled.dropFirst()) {
            let mid = CLLocationCoordinate2D(
                latitude: (a.latitude + b.latitude) / 2,
                longitude: (a.longitude + b.longitude) / 2
            )
            let idx = nearestIndex(to: mid, in: rawPath)
            let distanceAlong = cumDist[min(idx, cumDist.count - 1)]
            speeds.append(speedFor(distanceAlong: distanceAlong, steps: steps, stepBounds: stepBounds))
        }
        return speeds
    }

    private static func speedFor(
        distanceAlong: CLLocationDistance,
        steps: [Step],
        stepBounds: [CLLocationDistance]
    ) -> CLLocationSpeed {
        for (i, bound) in stepBounds.enumerated() where distanceAlong <= bound {
            return steps[i].speed
        }
        return steps.last?.speed ?? 13.4
    }

    private static func nearestIndex(
        to coordinate: CLLocationCoordinate2D,
        in points: [CLLocationCoordinate2D]
    ) -> Int {
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, point) in points.enumerated() {
            let dLat = point.latitude - coordinate.latitude
            let dLng = point.longitude - coordinate.longitude
            let d = dLat * dLat + dLng * dLng
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    private static func parsePolyline(_ polyline: String?) -> [CLLocationCoordinate2D] {
        guard let polyline else { return [] }
        return polyline.split(separator: ";").compactMap { token in
            let parts = token.split(separator: ",")
            guard parts.count >= 2,
                  let lng = Double(parts[0]),
                  let lat = Double(parts[1]) else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
    }
}

// MARK: - 高德响应模型

private struct AmapResponse: Decodable {
    let status: String
    let info: String?
    let route: Route?

    struct Route: Decodable {
        let paths: [Path]?
    }

    struct Path: Decodable {
        let steps: [Step]?
    }

    struct Step: Decodable {
        let distance: String?
        let duration: String?
        let polyline: String?
    }
}
