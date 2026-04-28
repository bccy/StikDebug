//
//  ChinaCoordinateConverter.swift
//  StikJIT
//
//  Handles coordinate system conversion between WGS-84 and GCJ-02 (China's
//  "Mars" coordinate system).  Apple MapKit returns GCJ-02 coordinates when the
//  device is in mainland China, but the iOS location-simulation service
//  (com.apple.dt.simulatelocation) expects WGS-84.  Sending GCJ-02 coordinates
//  directly causes a ~100–700 m offset on every China-region map app.
//

import CoreLocation

enum ChinaCoordinateConverter {

    // MARK: - Public

    /// Convert a GCJ-02 coordinate (as returned by MapKit in China) back to
    /// WGS-84 so it can be fed into the device's location-simulation API.
    ///
    /// If the coordinate is outside mainland China the value is returned
    /// unchanged, because MapKit uses plain WGS-84 everywhere else.
    static func gcj02ToWGS84(_ gcj: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInsideChina(gcj) else { return gcj }

        let delta = gcj02Delta(latitude: gcj.latitude, longitude: gcj.longitude)
        return CLLocationCoordinate2D(
            latitude:  gcj.latitude  - delta.dLat,
            longitude: gcj.longitude - delta.dLng
        )
    }

    /// Convert a WGS-84 coordinate to GCJ-02.
    static func wgs84ToGCJ02(_ wgs: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInsideChina(wgs) else { return wgs }

        let delta = gcj02Delta(latitude: wgs.latitude, longitude: wgs.longitude)
        return CLLocationCoordinate2D(
            latitude:  wgs.latitude  + delta.dLat,
            longitude: wgs.longitude + delta.dLng
        )
    }

    /// A more accurate inverse conversion using an iterative approach.
    /// Repeatedly applies forward transform and corrects the error.
    static func gcj02ToWGS84Exact(_ gcj: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInsideChina(gcj) else { return gcj }

        var wgs = gcj02ToWGS84(gcj)            // initial approximation
        let threshold = 1e-6                    // ~0.1 m precision

        for _ in 0..<15 {
            let test = wgs84ToGCJ02(wgs)
            let dLat = gcj.latitude  - test.latitude
            let dLng = gcj.longitude - test.longitude

            if abs(dLat) < threshold && abs(dLng) < threshold { break }

            wgs = CLLocationCoordinate2D(
                latitude:  wgs.latitude  + dLat,
                longitude: wgs.longitude + dLng
            )
        }

        return wgs
    }

    // MARK: - China Boundary Check

    /// Rough bounding-rectangle test for mainland China.
    static func isInsideChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let lat = coordinate.latitude
        let lng = coordinate.longitude
        return lat >= 0.8293 && lat <= 55.8271 && lng >= 72.004 && lng <= 137.8347
    }

    // MARK: - Internals

    private static let a: Double  = 6378245.0          // semi-major axis (Krasovsky)
    private static let ee: Double = 0.00669342162296594 // first eccentricity squared

    private struct Delta {
        let dLat: Double
        let dLng: Double
    }

    private static func gcj02Delta(latitude: Double, longitude: Double) -> Delta {
        let radLat = latitude / 180.0 * .pi
        var magic  = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)

        var dLat = transformLatitude(x: longitude - 105.0, y: latitude - 35.0)
        var dLng = transformLongitude(x: longitude - 105.0, y: latitude - 35.0)

        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * .pi)
        dLng = (dLng * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)

        return Delta(dLat: dLat, dLng: dLng)
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y
        ret += 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x
        ret += 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}
