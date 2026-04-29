//
//  MapSelectionView.swift
//  StikJIT
//
//  Created by Stephen on 11/3/25.
//

import SwiftUI
import MapKit
import Network
import UIKit

private struct CoordinateSnapshot: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct RouteSearchSelection {
    let title: String
    let coordinate: CLLocationCoordinate2D
}

private enum RouteSearchField {
    case start
    case end
}

private struct RouteSimulationPlan {
    let displayCoordinates: [CLLocationCoordinate2D]
    let distance: CLLocationDistance
    let expectedTravelTime: TimeInterval
}

private enum RouteSimulationDefaults {
    static let pathSamplingDistance: CLLocationDistance = 10
    static let playbackTickInterval: TimeInterval = 0.5
    static let minimumSpeedMetersPerSecond: CLLocationSpeed = 1.0
}

private struct RoutePlaybackSample {
    let coordinate: CLLocationCoordinate2D
    let delayFromPrevious: TimeInterval
}

private struct OpenStreetMapWay {
    let geometry: [CLLocationCoordinate2D]
    let speedLimitMetersPerSecond: CLLocationSpeed
}

private enum OpenStreetMapSpeedLimitService {
    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    static let copyrightURL = URL(string: "https://www.openstreetmap.org/copyright")!
    static let boundingBoxPaddingDegrees = 0.0015
    static let nearestWayThreshold: CLLocationDistance = 40
}

private struct OverpassResponse: Decodable {
    let elements: [Element]

    struct Element: Decodable {
        let tags: [String: String]?
        let geometry: [Coordinate]?
    }

    struct Coordinate: Decodable {
        let lat: Double
        let lon: Double
    }
}

private extension MKPolyline {
    var coordinateArray: [CLLocationCoordinate2D] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

private func interpolateCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    fraction: Double
) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: start.latitude + ((end.latitude - start.latitude) * fraction),
        longitude: start.longitude + ((end.longitude - start.longitude) * fraction)
    )
}

private func sampledRouteCoordinates(
    from coordinates: [CLLocationCoordinate2D],
    targetDistance: CLLocationDistance
) -> [CLLocationCoordinate2D] {
    guard coordinates.count > 1 else { return coordinates }

    var sampled = [coordinates[0]]
    for (start, end) in zip(coordinates, coordinates.dropFirst()) {
        let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        let segmentCount = max(1, Int(ceil(distance / targetDistance)))
        for index in 1...segmentCount {
            let point = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentCount)
            )
            if sampled.last.map(CoordinateSnapshot.init) != CoordinateSnapshot(point) {
                sampled.append(point)
            }
        }
    }

    return sampled
}

private func midpointCoordinate(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D
) -> CLLocationCoordinate2D {
    interpolateCoordinate(from: start, to: end, fraction: 0.5)
}

private func distanceFromPoint(
    _ point: MKMapPoint,
    toSegmentFrom start: MKMapPoint,
    to end: MKMapPoint
) -> CLLocationDistance {
    let dx = end.x - start.x
    let dy = end.y - start.y

    guard dx != 0 || dy != 0 else {
        return point.distance(to: start)
    }

    let projection = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / ((dx * dx) + (dy * dy))))
    let projectedPoint = MKMapPoint(
        x: start.x + (dx * projection),
        y: start.y + (dy * projection)
    )
    return point.distance(to: projectedPoint)
}

private func parseSpeedLimitMetersPerSecond(from rawValue: String) -> CLLocationSpeed? {
    let normalized = rawValue
        .lowercased()
        .split(separator: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !normalized.isEmpty else { return nil }
    guard normalized != "none",
          normalized != "signals",
          normalized != "implicit",
          normalized != "walk" else {
        return nil
    }

    let scanner = Scanner(string: normalized)
    guard let numericValue = scanner.scanDouble() else { return nil }

    if normalized.contains("mph") {
        return numericValue * 0.44704
    }
    if normalized.contains("knot") {
        return numericValue * 0.514444
    }

    return numericValue / 3.6
}

private func speedLimitMetersPerSecond(from tags: [String: String]) -> CLLocationSpeed? {
    if let maxspeed = tags["maxspeed"],
       let parsed = parseSpeedLimitMetersPerSecond(from: maxspeed) {
        return parsed
    }

    let directionalValues = [
        tags["maxspeed:forward"],
        tags["maxspeed:backward"]
    ]
        .compactMap { $0 }
        .compactMap(parseSpeedLimitMetersPerSecond(from:))

    guard !directionalValues.isEmpty else { return nil }
    return directionalValues.min()
}

private func overpassQuery(for coordinates: [CLLocationCoordinate2D]) -> String? {
    guard let first = coordinates.first else { return nil }

    var minLatitude = first.latitude
    var maxLatitude = first.latitude
    var minLongitude = first.longitude
    var maxLongitude = first.longitude

    for coordinate in coordinates.dropFirst() {
        minLatitude = min(minLatitude, coordinate.latitude)
        maxLatitude = max(maxLatitude, coordinate.latitude)
        minLongitude = min(minLongitude, coordinate.longitude)
        maxLongitude = max(maxLongitude, coordinate.longitude)
    }

    let padding = OpenStreetMapSpeedLimitService.boundingBoxPaddingDegrees
    let south = minLatitude - padding
    let west = minLongitude - padding
    let north = maxLatitude + padding
    let east = maxLongitude + padding

    let bbox = String(format: "%.6f,%.6f,%.6f,%.6f", south, west, north, east)

    return """
    [out:json][timeout:20];
    (
      way(\(bbox))[highway][maxspeed];
      way(\(bbox))[highway]["maxspeed:forward"];
      way(\(bbox))[highway]["maxspeed:backward"];
    );
    out tags geom;
    """
}

private func fetchOpenStreetMapWays(for coordinates: [CLLocationCoordinate2D]) async throws -> [OpenStreetMapWay] {
    guard let query = overpassQuery(for: coordinates) else { return [] }

    var components = URLComponents(url: OpenStreetMapSpeedLimitService.endpoint, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "data", value: query)]
    guard let url = components?.url else { return [] }

    var request = URLRequest(url: url)
    request.timeoutInterval = 6
    let (data, response) = try await URLSession.shared.data(for: request)

    if let httpResponse = response as? HTTPURLResponse,
       !(200...299).contains(httpResponse.statusCode) {
        throw NSError(
            domain: "OpenStreetMapSpeedLimits",
            code: httpResponse.statusCode,
            userInfo: [NSLocalizedDescriptionKey: "Overpass 返回 HTTP \(httpResponse.statusCode)。"]
        )
    }

    let decoded = try JSONDecoder().decode(OverpassResponse.self, from: data)
    return decoded.elements.compactMap { element in
        guard let tags = element.tags,
              let speedLimit = speedLimitMetersPerSecond(from: tags),
              let geometry = element.geometry?.map({ CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }),
              geometry.count > 1 else {
            return nil
        }

        return OpenStreetMapWay(
            geometry: geometry,
            speedLimitMetersPerSecond: speedLimit
        )
    }
}

private func nearestSpeedLimit(
    forSegmentFrom start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    using ways: [OpenStreetMapWay]
) -> CLLocationSpeed? {
    let midpoint = MKMapPoint(midpointCoordinate(from: start, to: end))
    var bestMatch: (speed: CLLocationSpeed, distance: CLLocationDistance)?

    for way in ways {
        for (wayStart, wayEnd) in zip(way.geometry, way.geometry.dropFirst()) {
            let candidateDistance = distanceFromPoint(
                midpoint,
                toSegmentFrom: MKMapPoint(wayStart),
                to: MKMapPoint(wayEnd)
            )

            if bestMatch == nil || candidateDistance < bestMatch!.distance {
                bestMatch = (way.speedLimitMetersPerSecond, candidateDistance)
            }
        }
    }

    guard let bestMatch,
          bestMatch.distance <= OpenStreetMapSpeedLimitService.nearestWayThreshold else {
        return nil
    }

    return bestMatch.speed
}

private func buildPlaybackSamples(
    from displayCoordinates: [CLLocationCoordinate2D],
    speedWays: [OpenStreetMapWay],
    fallbackSpeedMetersPerSecond: CLLocationSpeed
) -> [RoutePlaybackSample] {
    guard let firstCoordinate = displayCoordinates.first else { return [] }

    var samples = [RoutePlaybackSample(coordinate: firstCoordinate, delayFromPrevious: 0)]

    for (start, end) in zip(displayCoordinates, displayCoordinates.dropFirst()) {
        let segmentDistance = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        guard segmentDistance > 0 else { continue }

        let speedLimit = nearestSpeedLimit(forSegmentFrom: start, to: end, using: speedWays) ?? fallbackSpeedMetersPerSecond
        let clampedSpeed = max(speedLimit, RouteSimulationDefaults.minimumSpeedMetersPerSecond)
        let segmentTravelTime = segmentDistance / clampedSpeed
        let segmentStepCount = max(1, Int(ceil(segmentTravelTime / RouteSimulationDefaults.playbackTickInterval)))
        let stepDelay = segmentTravelTime / Double(segmentStepCount)

        for index in 1...segmentStepCount {
            let coordinate = interpolateCoordinate(
                from: start,
                to: end,
                fraction: Double(index) / Double(segmentStepCount)
            )
            if samples.last.map({ CoordinateSnapshot($0.coordinate) }) != CoordinateSnapshot(coordinate) {
                samples.append(RoutePlaybackSample(coordinate: coordinate, delayFromPrevious: stepDelay))
            }
        }
    }

    return samples
}

// MARK: - Bookmark Model

struct LocationBookmark: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Search Completer

@MainActor
final class LocationSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = query
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in self.results = results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
    }
}

@MainActor
final class CurrentLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var completion: ((CLLocationCoordinate2D?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestCurrentLocation(completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        self.completion = completion

        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            completion(nil)
            self.completion = nil
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let status = self.manager.authorizationStatus
            if status == .authorizedAlways || status == .authorizedWhenInUse {
                self.manager.requestLocation()
            } else if status != .notDetermined {
                completion?(nil)
                completion = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in
            completion?(coordinate)
            completion = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            completion?(nil)
            completion = nil
        }
    }
}

@MainActor
final class NetworkPathObserver: ObservableObject {
    @Published private(set) var usesCellular = false
    @Published private(set) var usesWiFi = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.stik.network-path")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let cellular = path.usesInterfaceType(.cellular)
            let wifi = path.usesInterfaceType(.wifi)
            Task { @MainActor in
                self?.usesCellular = cellular
                self?.usesWiFi = wifi
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

struct LocationSimulationView: View {
    // Serial queue: the location simulation helpers share process-wide state, so
    // serialising all calls avoids handle lifetime races.
    private static let locationQueue = DispatchQueue(label: "com.stik.location-sim",
                                                     qos: .userInitiated)
    private static let activeSimulationLatitudeKey = "activeSimulationLatitude"
    private static let activeSimulationLongitudeKey = "activeSimulationLongitude"

    @State private var coordinate: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    @State private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @State private var resendTimer: Timer?
    @State private var routeLoadTask: Task<Void, Never>?
    @State private var routeSpeedPrefetchTask: Task<Void, Never>?
    @State private var routeSpeedProgressTask: Task<Void, Never>?
    @State private var routePlaybackTask: Task<Void, Never>?
    @State private var isBusy = false
    @State private var isLoadingRoute = false
    @State private var isPrefetchingRouteSpeeds = false
    @State private var routeSpeedPrefetchProgress = 0.0
    @State private var showAlert = false
    @State private var showCellularNetworkWarning = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    @State private var searchText = ""
    @StateObject private var searchCompleter = LocationSearchCompleter()
    @StateObject private var currentLocationProvider = CurrentLocationProvider()
    @StateObject private var networkPathObserver = NetworkPathObserver()
    @State private var showRouteSearch = false
    @State private var routeStartSelection: RouteSearchSelection?
    @State private var routeEndSelection: RouteSearchSelection?
    @State private var routePlan: RouteSimulationPlan?
    @State private var routePlaybackSamples: [RoutePlaybackSample] = []
    @State private var routePlaybackCoordinate: CLLocationCoordinate2D?
    @State private var simulatedCoordinate: CLLocationCoordinate2D?
    @State private var routeRequestID = UUID()

    // Bookmarks
    @State private var bookmarks: [LocationBookmark] = []
    @State private var showBookmarks = false
    @State private var showSaveBookmark = false
    @State private var newBookmarkName = ""

    private var pairingFilePath: String {
        PairingFileStore.prepareURL().path()
    }

    private var pairingExists: Bool {
        FileManager.default.fileExists(atPath: pairingFilePath)
    }

    private var deviceIP: String {
        DeviceConnectionContext.targetIPAddress
    }

    private var routePolyline: MKPolyline? {
        guard let routePlan, routePlan.displayCoordinates.count > 1 else { return nil }
        return routePlan.displayCoordinates.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return MKPolyline(coordinates: baseAddress, count: buffer.count)
        }
    }

    private var routeStartCoordinate: CLLocationCoordinate2D? {
        routeStartSelection?.coordinate
    }

    private var routeEndCoordinate: CLLocationCoordinate2D? {
        routeEndSelection?.coordinate
    }

    private var hasActiveSimulation: Bool {
        simulatedCoordinate != nil || routePlaybackTask != nil
    }

    private var isRouteRunning: Bool {
        routePlaybackTask != nil
    }

    private var isCellularBlockingSimulation: Bool {
        networkPathObserver.usesCellular && !networkPathObserver.usesWiFi
    }

    private var isLikelyAirplaneMode: Bool {
        !networkPathObserver.usesCellular && !networkPathObserver.usesWiFi
    }

    private var hasRouteContext: Bool {
        routeStartSelection != nil ||
        routeEndSelection != nil ||
        routePlan != nil ||
        isLoadingRoute ||
        isPrefetchingRouteSpeeds ||
        routePlaybackCoordinate != nil
    }

    private var routeSummaryText: String? {
        guard let routePlan else { return nil }
        let distanceText = Measurement(
            value: routePlan.distance / 1000,
            unit: UnitLength.kilometers
        ).formatted(.measurement(width: .abbreviated, usage: .road))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        let durationText = formatter.string(from: routePlan.expectedTravelTime)
        if let durationText, !durationText.isEmpty {
            return "\(distanceText) • 预计 \(durationText)"
        }
        return distanceText
    }

    private var routeStatusText: String {
        if isLoadingRoute {
            return "正在计算路线…"
        }
        if isPrefetchingRouteSpeeds {
            return "正在读取道路限速… \(Int(routeSpeedPrefetchProgress * 100))%"
        }
        if routePlan != nil {
            return "路线已就绪。"
        }
        if routeStartSelection != nil || routeEndSelection != nil {
            return "请选择起点和终点来生成路线。"
        }
        return "可从工具栏规划路线。"
    }

    private var routeAttributionLink: some View {
        Link(
            "限速数据 © OpenStreetMap 贡献者 (ODbL)",
            destination: OpenStreetMapSpeedLimitService.copyrightURL
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var searchResultsListBase: some View {
        List(searchCompleter.results.prefix(5), id: \.self) { result in
            Button {
                selectSearchResult(result)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.subheadline)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .frame(maxHeight: 350)
        .scrollDisabled(true)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        searchResultsListBase
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
    }

    private var cellularNetworkWarningOverlay: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(.orange.opacity(0.18))
                        .frame(width: 78, height: 78)
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.orange)
                }

                Text("当前网络不可修改位置")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text("移动数据下使用位置模拟需要先开启飞行模式，位置修改完毕后关闭飞行模式即可。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                Button {
                    showCellularNetworkWarning = false
                } label: {
                    Text("我知道了")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 28, x: 0, y: 12)
            .padding(.horizontal, 24)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            MapReader { proxy in
                Map(position: $position) {
                    UserAnnotation()

                    if hasRouteContext {
                        if let routePolyline {
                            MapPolyline(routePolyline)
                                .stroke(.blue.opacity(0.8), lineWidth: 5)
                        }
                        if let routeStartCoordinate {
                            Marker("起点", coordinate: routeStartCoordinate)
                                .tint(.green)
                        }
                        if let routeEndCoordinate {
                            Marker("终点", coordinate: routeEndCoordinate)
                                .tint(.red)
                        }
                        if let routePlaybackCoordinate {
                            Marker("当前位置", coordinate: routePlaybackCoordinate)
                                .tint(.blue)
                        }
                    } else if let coordinate {
                        Marker("标记", coordinate: coordinate)
                            .tint(.red)
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .onTapGesture { point in
                    if let loc = proxy.convert(point, from: .local) {
                        applySelection(loc)
                    }
                }
                .mapControls {
                    MapCompass()
                }
            }
                .ignoresSafeArea()
                .onChange(of: coordinate.map(CoordinateSnapshot.init)) { _, new in
                    if let new {
                        position = .region(
                            MKCoordinateRegion(
                                center: new.coordinate,
                                latitudinalMeters: 1000,
                                longitudinalMeters: 1000
                            )
                        )
                    }
                }

            VStack(spacing: 0) {
                if !searchCompleter.results.isEmpty {
                    searchResultsList
                }

                Spacer()

                VStack(spacing: 12) {
                    if hasRouteContext {
                        routeControls
                    } else {
                        pinControls
                    }
                }
                .padding(.bottom, 24)
                .padding(.horizontal, 16)
                .padding(.horizontal, 16)
            }

        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    playButtonHaptic()
                    showBookmarks = true
                } label: {
                    Image(systemName: "bookmark.fill")
                }

                Button {
                    playButtonHaptic()
                    showRouteSearch = true
                } label: {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .disabled(isBusy || isRouteRunning)
            }
            ToolbarItem(placement: .topBarTrailing) {
                TextField("搜索位置…", text: $searchText)
                    .padding(.leading, 6)
                    .autocorrectionDisabled()
                    .onChange(of: searchText) { _, newValue in
                        searchCompleter.update(query: newValue)
                    }
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("保存书签", isPresented: $showSaveBookmark) {
            TextField("名称", text: $newBookmarkName)
            Button("保存") { addBookmark() }
            Button("取消", role: .cancel) { newBookmarkName = "" }
        } message: {
            Text("为这个位置输入一个名称。")
        }
        .fullScreenCover(isPresented: $showCellularNetworkWarning) {
            cellularNetworkWarningOverlay
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(bookmarks: $bookmarks) { bookmark in
                applySelection(bookmark.coordinate)
                showBookmarks = false
            } onDelete: { offsets in
                bookmarks.remove(atOffsets: offsets)
                saveBookmarks()
            }
        }
        .sheet(isPresented: $showRouteSearch) {
            RouteSearchSheet(
                initialStart: routeStartSelection,
                initialEnd: routeEndSelection
            ) { startSelection, endSelection in
                routeStartSelection = startSelection
                routeEndSelection = endSelection
                refreshRoute()
            }
        }
        .onAppear {
            loadBookmarks()
            restoreActiveSimulationState()
        }
        .onDisappear {
            routeLoadTask?.cancel()
            routeLoadTask = nil
            routeSpeedPrefetchTask?.cancel()
            resetRouteSpeedPrefetchState()
            if isRouteRunning {
                cancelRoutePlayback(resetMarker: false)
            }
            if backgroundTaskID != .invalid {
                BackgroundLocationManager.shared.requestStop()
            }
            endBackgroundTask()
        }
    }

    // MARK: - Bookmarks

    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: "locationBookmarks"),
              let decoded = try? JSONDecoder().decode([LocationBookmark].self, from: data) else { return }
        bookmarks = decoded
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "locationBookmarks")
        }
    }

    private func addBookmark() {
        guard let coord = coordinate else { return }
        let name = newBookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = LocationBookmark(
            name: name.isEmpty ? String(format: "%.4f, %.4f", coord.latitude, coord.longitude) : name,
            latitude: coord.latitude,
            longitude: coord.longitude
        )
        bookmarks.append(bookmark)
        saveBookmarks()
        newBookmarkName = ""
    }

    // MARK: - Location

    private func selectSearchResult(_ result: MKLocalSearchCompletion) {
        searchText = ""
        searchCompleter.results = []

        let request = MKLocalSearch.Request(completion: result)
        MKLocalSearch(request: request).start { response, _ in
            if let item = response?.mapItems.first {
                applySelection(item.placemark.coordinate)
            }
        }
    }

    private func centerOnCurrentLocation() {
        currentLocationProvider.requestCurrentLocation { coordinate in
            if let coordinate {
                position = .region(
                    MKCoordinateRegion(
                        center: coordinate,
                        latitudinalMeters: 1000,
                        longitudinalMeters: 1000
                    )
                )
            } else {
                position = .userLocation(fallback: .automatic)
                alertTitle = "无法获取当前位置"
                alertMessage = "请确认已允许 StikDebug 访问定位，并在系统设置中开启定位服务。"
                showAlert = true
            }
        }
    }

    private func playButtonHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.85)
    }

    @ViewBuilder
    private var pinControls: some View {
        if let coord = coordinate {
            Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if hasActiveSimulation {
                    Button {
                        playButtonHaptic()
                        clear()
                    } label: {
                        Text("停止")
                    }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(!pairingExists || isBusy)
                }

                Button {
                    playButtonHaptic()
                    simulate()
                } label: {
                    Text("模拟位置")
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!pairingExists || isBusy || isLoadingRoute)

                Button {
                    playButtonHaptic()
                    showSaveBookmark = true
                } label: {
                    Image(systemName: "bookmark")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(isRouteRunning)
            }
        } else {
            Text("点击地图选择定位")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var routeControls: some View {
        VStack(spacing: 10) {
            Text(routeStatusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isLoadingRoute {
                ProgressView()
                    .controlSize(.small)
            } else if isPrefetchingRouteSpeeds {
                ProgressView(value: routeSpeedPrefetchProgress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
            } else if let routeSummaryText {
                Text(routeSummaryText)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
            }

            routeAttributionLink

            HStack(spacing: 12) {
                if hasActiveSimulation {
                    Button {
                        playButtonHaptic()
                        clear()
                    } label: {
                        Text("停止")
                    }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(!pairingExists || isBusy)
                }

                Button {
                    playButtonHaptic()
                    simulateRoute()
                } label: {
                    Text("开始模拟路线")
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !pairingExists ||
                        isBusy ||
                        isLoadingRoute ||
                        isPrefetchingRouteSpeeds ||
                        routePlan == nil ||
                        routePlaybackSamples.isEmpty
                    )

                Button {
                    playButtonHaptic()
                    resetRouteSelection()
                } label: {
                    Text("重置")
                }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || isRouteRunning)
            }
        }
    }

    private func simulate() {
        guard pairingExists, let coord = coordinate, !isBusy else { return }
        guard canStartSimulationOnCurrentNetwork() else { return }

        Task { @MainActor in
            guard await ensureLocationServiceConnected() else { return }
            runLocationCommand(
                errorTitle: "模拟失败",
                errorMessage: { code in
                    "无法模拟位置（错误 \(code)）。请确认设备已连接且 DDI 已挂载。"
                },
                operation: { locationUpdateCode(for: coord) }
            ) {
                routePlaybackCoordinate = nil
                beginBackgroundTask()
                startResendLoop(with: coord)
                BackgroundLocationManager.shared.requestStart()
                showAirplaneModeSuccessIfNeeded()
            }
        }
    }

    private func simulateRoute() {
        guard pairingExists,
              routePlan != nil,
              let firstCoordinate = routePlaybackSamples.first?.coordinate,
              !isBusy,
              !isRouteRunning else {
            return
        }
        guard canStartSimulationOnCurrentNetwork() else { return }
        Task { @MainActor in
            guard await ensureLocationServiceConnected() else { return }
            stopResendLoop()
            cancelRoutePlayback(resetMarker: false)
            runLocationCommand(
                errorTitle: "路线模拟失败",
                errorMessage: { code in
                    "无法开始路线模拟（错误 \(code)）。请确认设备已连接且虚拟定位服务正在运行。"
                },
                operation: { locationUpdateCode(for: firstCoordinate) }
            ) {
                beginBackgroundTask()
                BackgroundLocationManager.shared.requestStart()
                simulatedCoordinate = firstCoordinate
                persistActiveSimulation(firstCoordinate)
                routePlaybackCoordinate = firstCoordinate
                startRoutePlayback()
                showAirplaneModeSuccessIfNeeded()
            }
        }
    }

    private func showAirplaneModeSuccessIfNeeded() {
        guard isLikelyAirplaneMode else { return }
        alertTitle = "定位修改成功"
        alertMessage = "已成功修改定位，请关闭飞行模式。"
        showAlert = true
    }

    private func canStartSimulationOnCurrentNetwork() -> Bool {
        guard !isCellularBlockingSimulation else {
            showCellularNetworkWarning = true
            return false
        }
        return true
    }

    private func runLocationCommand(
        errorTitle: String,
        errorMessage: @escaping (Int32) -> String,
        operation: @escaping () -> Int32,
        onSuccess: @escaping () -> Void
    ) {
        isBusy = true
        Self.locationQueue.async {
            let code = operation()
            DispatchQueue.main.async {
                isBusy = false
                if code == 0 {
                    onSuccess()
                } else {
                    alertTitle = errorTitle
                    alertMessage = errorMessage(code)
                    showAlert = true
                }
            }
        }
    }

    private func ensureLocationServiceConnected() async -> Bool {
        let status = await BuiltInVPNManager.shared.refreshStatus()
        if status == .connected {
            return true
        }

        alertTitle = "定位服务未连接"
        alertMessage = "虚拟定位服务当前未连接，请先在设置中连接定位服务后再开始模拟。"
        showAlert = true
        return false
    }

    private func clear() {
        guard pairingExists, !isBusy else { return }
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        routeSpeedPrefetchTask = nil
        routeSpeedProgressTask?.cancel()
        routeSpeedProgressTask = nil
        isLoadingRoute = false
        isPrefetchingRouteSpeeds = false
        routeSpeedPrefetchProgress = 0.0
        cancelRoutePlayback(resetMarker: true)
        runLocationCommand(
            errorTitle: "清除失败",
            errorMessage: { code in "无法清除模拟位置（错误 \(code)）。" },
            operation: clear_simulated_location
        ) {
            stopResendTimer()
            simulatedCoordinate = nil
            clearPersistedActiveSimulation()
            centerOnCurrentLocation()
            endBackgroundTask()
            BackgroundLocationManager.shared.requestStop()
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func startResendLoop(with coordinate: CLLocationCoordinate2D) {
        simulatedCoordinate = coordinate
        persistActiveSimulation(coordinate)
        resendTimer?.invalidate()
        resendTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            guard let simulatedCoordinate else { return }
            Self.locationQueue.async {
                _ = locationUpdateCode(for: simulatedCoordinate)
            }
        }
    }

    private func stopResendLoop() {
        stopResendTimer()
        simulatedCoordinate = nil
        clearPersistedActiveSimulation()
    }

    private func stopResendTimer() {
        resendTimer?.invalidate()
        resendTimer = nil
    }

    private func persistActiveSimulation(_ coordinate: CLLocationCoordinate2D) {
        UserDefaults.standard.set(coordinate.latitude, forKey: Self.activeSimulationLatitudeKey)
        UserDefaults.standard.set(coordinate.longitude, forKey: Self.activeSimulationLongitudeKey)
    }

    private func clearPersistedActiveSimulation() {
        UserDefaults.standard.removeObject(forKey: Self.activeSimulationLatitudeKey)
        UserDefaults.standard.removeObject(forKey: Self.activeSimulationLongitudeKey)
    }

    private func restoreActiveSimulationState() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.activeSimulationLatitudeKey) != nil,
              defaults.object(forKey: Self.activeSimulationLongitudeKey) != nil else {
            return
        }

        let restoredCoordinate = CLLocationCoordinate2D(
            latitude: defaults.double(forKey: Self.activeSimulationLatitudeKey),
            longitude: defaults.double(forKey: Self.activeSimulationLongitudeKey)
        )
        simulatedCoordinate = restoredCoordinate
        coordinate = coordinate ?? restoredCoordinate
        if resendTimer == nil && !isCellularBlockingSimulation {
            startResendLoop(with: restoredCoordinate)
        }
    }

    private func cancelRoutePlayback(resetMarker: Bool) {
        routePlaybackTask?.cancel()
        routePlaybackTask = nil
        if resetMarker {
            routePlaybackCoordinate = nil
        }
    }

    private func applySelection(_ coordinate: CLLocationCoordinate2D) {
        guard !isRouteRunning else { return }
        if hasRouteContext {
            resetRouteSelection()
        }
        self.coordinate = coordinate
    }

    private func resetRouteSelection() {
        routeLoadTask?.cancel()
        routeLoadTask = nil
        routeSpeedPrefetchTask?.cancel()
        resetRouteSpeedPrefetchState()
        routeRequestID = UUID()
        routePlan = nil
        routeStartSelection = nil
        routeEndSelection = nil
        routePlaybackSamples = []
        routePlaybackCoordinate = nil
        isLoadingRoute = false
    }

    private func refreshRoute() {
        routeLoadTask?.cancel()
        routeSpeedPrefetchTask?.cancel()
        resetRouteSpeedPrefetchState()
        routePlan = nil
        routePlaybackSamples = []

        guard let routeStart = routeStartSelection?.coordinate,
              let routeEnd = routeEndSelection?.coordinate else {
            isLoadingRoute = false
            isPrefetchingRouteSpeeds = false
            routeSpeedPrefetchProgress = 0.0
            return
        }

        let requestID = UUID()
        routeRequestID = requestID
        isLoadingRoute = true
        isPrefetchingRouteSpeeds = false
        routeSpeedPrefetchProgress = 0.0

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: routeStart))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: routeEnd))
        request.requestsAlternateRoutes = false
        request.transportType = .automobile

        routeLoadTask = Task {
            do {
                let response = try await MKDirections(request: request).calculate()
                guard !Task.isCancelled else { return }
                guard let route = response.routes.first else {
                    throw NSError(
                        domain: "RouteSimulation",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "未返回可驾驶路线。"]
                    )
                }

                let displayCoordinates = sampledRouteCoordinates(
                    from: route.polyline.coordinateArray,
                    targetDistance: RouteSimulationDefaults.pathSamplingDistance
                )
                let routePlan = RouteSimulationPlan(
                    displayCoordinates: displayCoordinates,
                    distance: route.distance,
                    expectedTravelTime: route.expectedTravelTime
                )

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    self.routePlan = routePlan
                    isLoadingRoute = false
                    isPrefetchingRouteSpeeds = true
                    startRouteSpeedProgressAnimation(requestID: requestID)
                    if let routePolyline {
                        position = .rect(routePolyline.boundingMapRect)
                    }
                }

                let fallbackSpeed = route.expectedTravelTime > 0
                    ? route.distance / route.expectedTravelTime
                    : 13.4

                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    routeSpeedPrefetchTask?.cancel()
                    routeSpeedPrefetchTask = Task(priority: .utility) {
                        await MainActor.run {
                            guard routeRequestID == requestID else { return }
                            routeSpeedPrefetchProgress = max(routeSpeedPrefetchProgress, 0.25)
                        }
                        let speedWays = (try? await fetchOpenStreetMapWays(for: displayCoordinates)) ?? []
                        await MainActor.run {
                            guard routeRequestID == requestID else { return }
                            routeSpeedPrefetchProgress = max(routeSpeedPrefetchProgress, 0.85)
                        }
                        let playbackSamples = buildPlaybackSamples(
                            from: displayCoordinates,
                            speedWays: speedWays,
                            fallbackSpeedMetersPerSecond: fallbackSpeed
                        )
                        guard !Task.isCancelled else {
                            await MainActor.run {
                                guard routeRequestID == requestID else { return }
                                resetRouteSpeedPrefetchState()
                            }
                            return
                        }
                        await MainActor.run {
                            guard routeRequestID == requestID else { return }
                            routeSpeedPrefetchProgress = 1.0
                            routePlaybackSamples = playbackSamples
                            resetRouteSpeedPrefetchState(keepProgressComplete: true)
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    resetRouteSpeedPrefetchState()
                }
            } catch {
                await MainActor.run {
                    guard routeRequestID == requestID else { return }
                    isLoadingRoute = false
                    resetRouteSpeedPrefetchState()
                    alertTitle = "路线失败"
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func startRouteSpeedProgressAnimation(requestID: UUID) {
        routeSpeedProgressTask?.cancel()
        routeSpeedPrefetchProgress = 0.08
        routeSpeedProgressTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(180))
                guard routeRequestID == requestID, isPrefetchingRouteSpeeds else { return }
                guard routeSpeedPrefetchProgress < 0.7 else { continue }
                let remaining = 0.7 - routeSpeedPrefetchProgress
                let increment = max(0.01, remaining * 0.08)
                routeSpeedPrefetchProgress = min(0.7, routeSpeedPrefetchProgress + increment)
            }
        }
    }

    private func resetRouteSpeedPrefetchState(keepProgressComplete: Bool = false) {
        routeSpeedProgressTask?.cancel()
        routeSpeedProgressTask = nil
        routeSpeedPrefetchTask = nil
        isPrefetchingRouteSpeeds = false
        routeSpeedPrefetchProgress = keepProgressComplete ? 1.0 : 0.0
    }

    private func startRoutePlayback() {
        routePlaybackTask = Task {
            var lastSuccessfulCoordinate = routePlaybackSamples.first?.coordinate

            for sample in routePlaybackSamples.dropFirst() {
                try? await Task.sleep(for: .seconds(sample.delayFromPrevious))
                guard !Task.isCancelled else { return }

                let code = await sendLocationUpdate(for: sample.coordinate)
                guard code == 0 else {
                    await MainActor.run {
                        routePlaybackTask = nil
                        routePlaybackCoordinate = lastSuccessfulCoordinate
                        if let lastSuccessfulCoordinate {
                            startResendLoop(with: lastSuccessfulCoordinate)
                        }
                        alertTitle = "路线模拟失败"
                        alertMessage = "无法继续路线模拟（错误 \(code)）。"
                        showAlert = true
                    }
                    return
                }

                lastSuccessfulCoordinate = sample.coordinate
                await MainActor.run {
                    routePlaybackCoordinate = sample.coordinate
                }
            }

            await MainActor.run {
                routePlaybackTask = nil
                if let lastSuccessfulCoordinate {
                    routePlaybackCoordinate = lastSuccessfulCoordinate
                    startResendLoop(with: lastSuccessfulCoordinate)
                }
            }
        }
    }

    private func sendLocationUpdate(for coordinate: CLLocationCoordinate2D) async -> Int32 {
        await withCheckedContinuation { continuation in
            Self.locationQueue.async {
                continuation.resume(returning: locationUpdateCode(for: coordinate))
            }
        }
    }

    private func locationUpdateCode(for coordinate: CLLocationCoordinate2D) -> Int32 {
        // Apple MapKit returns GCJ-02 coordinates in mainland China, but the
        // iOS location-simulation service expects WGS-84.  Convert here so
        // the simulated position matches the pin the user dropped on the map.
        let corrected = ChinaCoordinateConverter.gcj02ToWGS84Exact(coordinate)
        return simulate_location(deviceIP, corrected.latitude, corrected.longitude, pairingFilePath)
    }
}

private struct RouteSearchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialStart: RouteSearchSelection?
    let initialEnd: RouteSearchSelection?
    let onApply: (RouteSearchSelection, RouteSearchSelection) -> Void

    @StateObject private var startCompleter = LocationSearchCompleter()
    @StateObject private var endCompleter = LocationSearchCompleter()
    @State private var startQuery: String
    @State private var endQuery: String
    @State private var startSelection: RouteSearchSelection?
    @State private var endSelection: RouteSearchSelection?
    @State private var isResolvingSelection = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: RouteSearchField?

    init(
        initialStart: RouteSearchSelection?,
        initialEnd: RouteSearchSelection?,
        onApply: @escaping (RouteSearchSelection, RouteSearchSelection) -> Void
    ) {
        self.initialStart = initialStart
        self.initialEnd = initialEnd
        self.onApply = onApply
        _startQuery = State(initialValue: initialStart?.title ?? "")
        _endQuery = State(initialValue: initialEnd?.title ?? "")
        _startSelection = State(initialValue: initialStart)
        _endSelection = State(initialValue: initialEnd)
    }

    private var activeResults: [MKLocalSearchCompletion] {
        switch focusedField {
        case .start:
            return startCompleter.results
        case .end:
            return endCompleter.results
        case .none:
            return []
        }
    }

    private var canApply: Bool {
        startSelection != nil && endSelection != nil && !isResolvingSelection
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                routeField(
                    title: "起点",
                    icon: "circle.fill",
                    tint: .green,
                    text: $startQuery,
                    selection: startSelection,
                    field: .start
                )

                routeField(
                    title: "终点",
                    icon: "flag.checkered.circle.fill",
                    tint: .red,
                    text: $endQuery,
                    selection: endSelection,
                    field: .end
                )

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                if isResolvingSelection {
                    ProgressView("正在解析位置…")
                        .font(.footnote)
                } else if !activeResults.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(activeResults.enumerated()), id: \.offset) { index, result in
                                Button {
                                    resolve(result)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(result.title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if !result.subtitle.isEmpty {
                                            Text(result.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 12)
                                }
                                .buttonStyle(.plain)

                                if index < activeResults.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                } else {
                    Text("搜索起点和终点来生成路线。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .navigationTitle("模拟路线")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("使用路线") {
                        guard let startSelection, let endSelection else { return }
                        onApply(startSelection, endSelection)
                        dismiss()
                    }
                    .disabled(!canApply)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            if startSelection == nil {
                focusedField = .start
            } else if endSelection == nil {
                focusedField = .end
            }
        }
    }

    private func routeField(
        title: String,
        icon: String,
        tint: Color,
        text: Binding<String>,
        selection: RouteSearchSelection?,
        field: RouteSearchField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(tint)

                TextField(title, text: text)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: field)
                    .submitLabel(field == .start ? .next : .done)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        errorMessage = nil
                        update(query: newValue, for: field)
                    }
                    .onSubmit {
                        if field == .start {
                            focusedField = .end
                        } else {
                            focusedField = nil
                        }
                    }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)

            if let selection {
                Text(String(format: "%.5f, %.5f", selection.coordinate.latitude, selection.coordinate.longitude))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func update(query: String, for field: RouteSearchField) {
        switch field {
        case .start:
            if query != startSelection?.title {
                startSelection = nil
            }
            startCompleter.update(query: query)
        case .end:
            if query != endSelection?.title {
                endSelection = nil
            }
            endCompleter.update(query: query)
        }
    }

    private func resolve(_ completion: MKLocalSearchCompletion) {
        let field = focusedField ?? .start
        let request = MKLocalSearch.Request(completion: completion)
        isResolvingSelection = true
        errorMessage = nil

        MKLocalSearch(request: request).start { response, error in
            DispatchQueue.main.async {
                isResolvingSelection = false

                guard let item = response?.mapItems.first else {
                    errorMessage = error?.localizedDescription ?? "无法解析该位置。"
                    return
                }

                let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = name.isEmpty ? completion.title : name
                let selection = RouteSearchSelection(title: title, coordinate: item.placemark.coordinate)

                switch field {
                case .start:
                    startSelection = selection
                    startQuery = title
                    startCompleter.results = []
                    focusedField = .end
                case .end:
                    endSelection = selection
                    endQuery = title
                    endCompleter.results = []
                    focusedField = nil
                }
            }
        }
    }
}

// MARK: - Bookmarks Sheet

struct BookmarksView: View {
    @Binding var bookmarks: [LocationBookmark]
    let onSelect: (LocationBookmark) -> Void
    let onDelete: (IndexSet) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if bookmarks.isEmpty {
                    ContentUnavailableView(
                        "暂无书签",
                        systemImage: "bookmark.slash",
                        description: Text("在地图上放置标记，然后点击书签图标保存位置。")
                    )
                } else {
                    List {
                        ForEach(bookmarks) { bookmark in
                            Button {
                                onSelect(bookmark)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.name)
                                        .foregroundStyle(.primary)
                                    Text(String(format: "%.6f, %.6f", bookmark.latitude, bookmark.longitude))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: onDelete)
                    }
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !bookmarks.isEmpty {
                    EditButton()
                }
            }
        }
    }
}
