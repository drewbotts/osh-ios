import Foundation
import Combine

// MARK: - SurveyInController
//
// One survey-in, from "stand here" to "written", as an explicit state machine.
//
//   idle → aligning → capturing → reviewing → committing → done
//                ↑         │           │           │
//                └─────────┴───────────┴───── failed ──┘ (retry)
//
// The states are the screens: the view switches on them and nothing else, so
// there is no way to show a review of numbers that were never captured or a
// spinner for a request that already returned. Every path that leaves
// `capturing` or `committing` is fenced with a `defer` that puts the machine
// somewhere the user can act from, because a survey happens in a field with
// one bar of signal and "stuck on the spinner" is the failure mode that
// actually occurs.
//
// Nothing is written until `commit()`. The review step exists so the user can
// correct the heading by eye — the compass is the least trustworthy sensor on
// a phone held next to a steel camera mount — and so that HAE and MSL sit
// side by side, labelled, before one of them goes on the wire.

@MainActor
final class SurveyInController: ObservableObject {

    // MARK: Types

    enum State: Equatable {
        case idle
        case aligning
        /// `progress` in [0, 1] over `captureDuration`.
        case capturing(progress: Double)
        case reviewing
        case committing
        case done
        case failed(SurveyFailure)

        var isCapturing: Bool { if case .capturing = self { return true } else { return false } }
        var isCommitting: Bool { self == .committing }
    }

    /// What went wrong, in enough detail to diagnose without the log.
    struct SurveyFailure: Equatable, Sendable {
        var title: String
        var detail: String
        /// The request as sent — method, URL, body — when one was.
        var request: String?
        /// The node's response body, when there was one.
        var response: String?
        /// Where "try again" leads: back to the review for a commit problem,
        /// back to alignment for a capture problem.
        var resumesAtReview: Bool
    }

    /// Which height goes on the wire.
    ///
    /// The slot it goes into is defined as ellipsoidal height in both write
    /// paths — EPSG 4979 in the GeoPose, HeightAboveEllipsoid in the driver's
    /// location vector — so HAE is the default and the correct choice. MSL is
    /// offered because that is what people type from a map or a GPS app, and a
    /// value that matches its neighbours can matter more than one that matches
    /// its datum; the review screen says out loud which is being written.
    enum HeightDatum: String, CaseIterable, Equatable, Sendable {
        case hae
        case msl

        var label: String {
            switch self {
            case .hae: return "HAE (EPSG 4979)"
            case .msl: return "MSL"
            }
        }
    }

    /// The captured figures and the user's adjustments to them.
    struct Review: Equatable {
        let position: PositionEstimate
        let heading: HeadingEstimate
        let attitude: AttitudeEstimate?

        /// Degrees added to the measured heading, ±`headingAdjustmentRange`.
        var headingAdjustment: Double = 0

        /// Editable base heights, seeded from the averaged fixes.
        var heightAboveEllipsoid: Double
        var altitudeMSL: Double
        var heightDatum: HeightDatum = .hae
        /// Metres from where the phone was held to the mount itself — positive
        /// when the camera sits above the phone. Added to whichever base is
        /// chosen.
        var mountOffset: Double = 0

        /// Written as the mount's pitch and roll. Zero by default: a phone
        /// sighting along a lens is not level, and a camera base usually is.
        var pitch: Double = 0
        var roll: Double = 0

        init(position: PositionEstimate, heading: HeadingEstimate, attitude: AttitudeEstimate?) {
            self.position = position
            self.heading = heading
            self.attitude = attitude
            self.heightAboveEllipsoid = position.heightAboveEllipsoid
            self.altitudeMSL = position.altitudeMSL
        }

        var finalHeading: Double {
            SurveyMath.normalizedDegrees(heading.heading + headingAdjustment)
        }

        /// The base for the chosen datum, before the offset.
        var baseHeight: Double {
            heightDatum == .hae ? heightAboveEllipsoid : altitudeMSL
        }

        /// What goes on the wire: base plus mount offset.
        var writtenHeight: Double { baseHeight + mountOffset }

        /// True when an MSL value is about to be stored in a slot defined as
        /// ellipsoidal — deliberate, but worth a warning.
        var writesMSLIntoEllipsoidalSlot: Bool { heightDatum == .msl }

        var pose: SurveyedPose {
            SurveyedPose(latitude: position.latitude,
                         longitude: position.longitude,
                         heightAboveEllipsoid: writtenHeight,
                         yaw: finalHeading,
                         pitch: pitch,
                         roll: roll)
        }
    }

    enum HomeOutcome: Equatable {
        case sending
        case sent(status: String?)
        case failed(String)
    }

    // MARK: Configuration

    /// How long a capture averages for.
    static let captureDuration: TimeInterval = 5
    static let captureTick: Duration = .milliseconds(100)

    static let headingAdjustmentRange: ClosedRange<Double> = -30...30
    static let headingAdjustmentStep: Double = 0.5
    static let attitudeStep: Double = 0.5
    static let mountOffsetRange: ClosedRange<Double> = -50...50
    static let mountOffsetStep: Double = 0.1

    /// CLHeading accuracy above which the compass is called poor.
    static let poorHeadingAccuracy: Double = 15
    /// Horizontal accuracy above which a fix is called poor, in metres.
    static let poorHorizontalAccuracy: Double = 20

    // MARK: State

    let system: RemoteSystem
    let connection: NodeConnection
    let sampler = SurveySampler()
    /// How to send the camera to its base frame, when it is a PTZ camera.
    let ptzHome: PTZHomePlan?
    /// Where the pose goes on the node — see SurveyWriteStrategy.
    let strategy: SurveyWriteStrategy

    var isPTZ: Bool { system.ptzCapability != nil }

    @Published private(set) var state: State = .idle
    @Published var review: Review?
    @Published private(set) var homeOutcome: HomeOutcome?
    /// The pose read back from the node after a successful commit.
    @Published private(set) var written: SurveyedPose?

    private var captureTask: Task<Void, Never>?
    private var samplerObserver: AnyCancellable?
    private var locationSamples: [LocationSample] = []
    private var orientationSamples: [OrientationSample] = []

    // MARK: Init

    init(system: RemoteSystem, connection: NodeConnection) {
        self.system = system
        self.connection = connection
        self.ptzHome = system.ptzCapability.flatMap(PTZHomePlan.plan(for:))
        self.strategy = SurveyWriteStrategy.detect(for: system)
    }

    // MARK: Lifecycle

    /// Starts the sensors and shows the alignment screen.
    func begin() {
        guard state == .idle else { return }
        sampler.start()
        state = .aligning
        Log.client.info("Survey-in of \(self.system.id, privacy: .public) (\(self.system.name, privacy: .public)) started; PTZ \(self.isPTZ ? "yes" : "no", privacy: .public)")
    }

    /// Stops everything. Called when the screen goes away, whatever state it
    /// was in.
    func finish() {
        captureTask?.cancel()
        captureTask = nil
        samplerObserver = nil
        sampler.stop()
    }

    // MARK: Capture

    var canCapture: Bool {
        state == .aligning
            && sampler.reading.location != nil
            && sampler.reading.orientation != nil
            && sampler.failure == nil
    }

    func startCapture() {
        guard canCapture else { return }

        locationSamples.removeAll()
        orientationSamples.removeAll()
        if let location = sampler.reading.location { locationSamples.append(location) }
        if let orientation = sampler.reading.orientation { orientationSamples.append(orientation) }

        samplerObserver = sampler.$reading.sink { [weak self] reading in
            self?.record(reading)
        }
        state = .capturing(progress: 0)

        let started = Date()
        captureTask = Task { [weak self] in
            defer {
                // Whatever happens below, the screen is not left on a progress
                // bar that will never finish.
                if let self, self.state.isCapturing { self.state = .aligning }
            }
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                if elapsed >= Self.captureDuration { break }
                self?.state = .capturing(progress: min(elapsed / Self.captureDuration, 1))
                try? await Task.sleep(for: Self.captureTick)
            }
            guard let self, !Task.isCancelled else { return }
            self.samplerObserver = nil
            self.finishCapture()
        }
    }

    func cancelCapture() {
        captureTask?.cancel()
        captureTask = nil
        samplerObserver = nil
        if state.isCapturing { state = .aligning }
    }

    private func record(_ reading: SurveySampler.Reading) {
        guard state.isCapturing else { return }
        if let location = reading.location,
           location.timestamp != locationSamples.last?.timestamp {
            locationSamples.append(location)
        }
        if let orientation = reading.orientation,
           orientation.timestamp != orientationSamples.last?.timestamp {
            orientationSamples.append(orientation)
        }
    }

    private func finishCapture() {
        guard let position = SurveyMath.averagePosition(locationSamples) else {
            fail(title: "No position fix during capture",
                 detail: "CoreLocation delivered no usable fix in \(Int(Self.captureDuration)) seconds. Move to open sky and try again.",
                 resumesAtReview: false)
            return
        }
        guard let heading = SurveyMath.averageHeading(orientationSamples) else {
            fail(title: "No heading during capture",
                 detail: "The motion sensors delivered no attitude. Make sure Motion & Fitness access is allowed and try again.",
                 resumesAtReview: false)
            return
        }

        let attitude = SurveyMath.averageAttitude(orientationSamples)
        review = Review(position: position, heading: heading, attitude: attitude)
        state = .reviewing

        Log.client.info("Survey-in captured \(position.sampleCount) fixes (±\(String(format: "%.1f", position.horizontalAccuracy), privacy: .public) m) and \(heading.sampleCount) headings (\(String(format: "%.1f", heading.heading), privacy: .public)° ±\(String(format: "%.1f", heading.spread), privacy: .public)°)")
    }

    /// Back to alignment, keeping the sensors running.
    func retry() {
        review = nil
        written = nil
        state = .aligning
    }

    /// Back to the review, after a commit failure.
    func backToReview() {
        guard review != nil else { retry(); return }
        state = .reviewing
    }

    // MARK: PTZ home

    func sendPTZHome() {
        guard let plan = ptzHome, homeOutcome != .sending else { return }
        homeOutcome = .sending

        let client = connection.commandClient
        Task { [weak self] in
            var outcome: HomeOutcome = .failed("no response")
            defer { self?.homeOutcome = outcome }
            do {
                var lastStatus: String?
                for step in plan.steps {
                    let json = CommandBody.choice(item: step.item, value: step.value)
                    let receipt = try await client.sendCommand(controlStreamId: plan.controlStreamId,
                                                               parameters: json)
                    guard receipt.isSuccess else {
                        outcome = .failed(receipt.isUnauthorized
                                          ? "not authorized to control this camera"
                                          : (receipt.message ?? "HTTP \(receipt.statusCode)"))
                        return
                    }
                    lastStatus = receipt.reportedStatus
                }
                outcome = .sent(status: lastStatus)
            } catch {
                outcome = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Commit

    func commit() {
        guard let review, state == .reviewing else { return }
        let pose = review.pose
        state = .committing
        Task { [weak self] in
            await self?.performCommit(pose)
        }
    }

    private func performCommit(_ pose: SurveyedPose) async {
        defer {
            if state.isCommitting {
                fail(title: "Update ended without a result",
                     detail: "Neither a response nor an error came back. Check the node and try again.",
                     resumesAtReview: true)
            }
        }

        switch strategy {
        case .createOutputs:
            await commitCreateOutputs(pose)
        case .staticOutputs(let location, let orientation):
            await commitStaticOutputs(pose, location: location, orientation: orientation)
        }
    }

    /// The bodies the commit will send, for the review screen. Built with the
    /// current time, so the preview's timestamp differs from the real one.
    func previewBodies() -> [(title: String, body: String)] {
        guard let review else { return [] }
        let pose = review.pose
        switch strategy {
        case .createOutputs:
            let time = Date()
            var bodies: [(String, String)] = []
            if let body = try? SurveyObservationBody.location(schema: SurveyOutputSchemas.location(),
                                                              pose: pose, time: time) {
                bodies.append((SurveyOutputSchemas.locationOutputName + " (new)", body))
            }
            if let body = try? SurveyObservationBody.orientation(schema: SurveyOutputSchemas.orientation(),
                                                                 pose: pose, time: time) {
                bodies.append((SurveyOutputSchemas.orientationOutputName + " (new)", body))
            }
            return bodies
        case .staticOutputs(let location, let orientation):
            var bodies: [(String, String)] = []
            if let schema = location.recordSchema,
               let body = try? SurveyObservationBody.location(schema: schema, pose: pose, time: Date()) {
                bodies.append((location.name, body))
            }
            if let orientation, let schema = orientation.recordSchema,
               let body = try? SurveyObservationBody.orientation(schema: schema, pose: pose, time: Date()) {
                bodies.append((orientation.name, body))
            }
            return bodies
        }
    }

    // MARK: Commit — static outputs

    /// One observation on the driver's location output and, when it has one,
    /// its static orientation output; then the newest record of each is read
    /// back and compared.
    private func commitStaticOutputs(_ pose: SurveyedPose,
                                     location: RemoteDatastream,
                                     orientation: RemoteDatastream?,
                                     requestPrefix: String = "") async {
        let readClient = connection.readClient
        let writeClient = connection.writeClient
        let now = Date()
        var requestText = requestPrefix

        do {
            guard let locationSchema = location.recordSchema, let locationDecoder = location.decoder else {
                fail(title: "Location output has no usable schema",
                     detail: "The \(location.name) datastream's schema did not decode, so no observation can be built for it.",
                     resumesAtReview: true)
                return
            }
            let locationBody = try SurveyObservationBody.location(schema: locationSchema, pose: pose, time: now)
            requestText += (requestText.isEmpty ? "" : "\n\n")
                + Self.requestLine(connection: connection, datastream: location) + "\n\n" + locationBody

            let locationReceipt = try await writeClient.postObservationBody(datastreamId: location.id,
                                                                            body: Data(locationBody.utf8))
            guard locationReceipt.isSuccess else {
                fail(title: "Node refused the location observation (HTTP \(locationReceipt.statusCode))",
                     detail: [locationReceipt.message, Self.hint(for: locationReceipt.statusCode, write: .observation)]
                        .compactMap { $0 }.joined(separator: "\n\n"),
                     request: requestText,
                     response: locationReceipt.bodyText,
                     resumesAtReview: true)
                return
            }

            var orientationDecoder: DatastreamDecoder?
            if let orientation, let schema = orientation.recordSchema, let decoder = orientation.decoder {
                let body = try SurveyObservationBody.orientation(schema: schema, pose: pose, time: now)
                requestText += "\n\n" + Self.requestLine(connection: connection, datastream: orientation) + "\n\n" + body
                let receipt = try await writeClient.postObservationBody(datastreamId: orientation.id,
                                                                        body: Data(body.utf8))
                guard receipt.isSuccess else {
                    fail(title: "Location written, but the node refused the orientation observation (HTTP \(receipt.statusCode))",
                         detail: [receipt.message, Self.hint(for: receipt.statusCode, write: .observation)]
                            .compactMap { $0 }.joined(separator: "\n\n"),
                         request: requestText,
                         response: receipt.bodyText,
                         resumesAtReview: true)
                    return
                }
                orientationDecoder = decoder
            }

            // Read back. The datastream summary is re-fetched first: the one
            // loaded with the system carries the *old* phenomenon-time range,
            // and fetchMostRecent uses that range to find the newest record.
            let freshLocation = try await readClient.getDatastream(id: location.id)
            let latestLocation = try await readClient.fetchMostRecent(datastream: freshLocation,
                                                                     limit: 1,
                                                                     decoder: locationDecoder).first
            guard let latestLocation,
                  case .location(let paths, _) = location.role,
                  let latitude = latestLocation.values[paths.latitude]?.asDouble,
                  let longitude = latestLocation.values[paths.longitude]?.asDouble else {
                fail(title: "Position did not round-trip",
                     detail: "The node accepted the observation, but the newest record on \(location.name) could not be read back.",
                     request: requestText, response: nil, resumesAtReview: true)
                return
            }
            let altitude = paths.altitude.flatMap { latestLocation.values[$0]?.asDouble } ?? pose.heightAboveEllipsoid

            var stored = SurveyedPose(latitude: latitude, longitude: longitude, heightAboveEllipsoid: altitude,
                                      yaw: pose.yaw, pitch: pose.pitch, roll: pose.roll)

            if let orientation, let orientationDecoder,
               case .orientation(let orientationPaths) = orientation.role {
                let fresh = try await readClient.getDatastream(id: orientation.id)
                let latest = try await readClient.fetchMostRecent(datastream: fresh, limit: 1,
                                                                  decoder: orientationDecoder).first
                guard let latest, let heading = orientationPaths.heading(from: latest) else {
                    fail(title: "Orientation did not round-trip",
                         detail: "The node accepted the observation, but the newest record on \(orientation.name) could not be read back.",
                         request: requestText, response: nil, resumesAtReview: true)
                    return
                }
                stored.yaw = heading
                stored.pitch = orientationPaths.pitch(from: latest) ?? pose.pitch
                stored.roll = orientationPaths.roll(from: latest) ?? pose.roll
            }

            guard stored.matches(pose) else {
                fail(title: "Position did not round-trip",
                     detail: "The node accepted the observations but its newest records say \(Self.describe(stored)).",
                     request: requestText, response: nil, resumesAtReview: true)
                return
            }

            written = stored
            SystemChangeFeed.shared.publish(serverId: connection.server.id, systemId: system.id)
            Log.client.info("Survey-in posted \(Self.describe(stored), privacy: .public) to the static outputs of \(self.system.id, privacy: .public)")
            state = .done

        } catch {
            fail(title: "Update failed",
                 detail: ConnectionErrorMessage.summary(for: error),
                 request: requestText.isEmpty ? nil : requestText,
                 response: nil,
                 resumesAtReview: true)
        }
    }

    private static func requestLine(connection: NodeConnection, datastream: RemoteDatastream) -> String {
        "POST \(connection.server.url)/datastreams/\(datastream.id)/observations\nContent-Type: application/swe+json"
    }

    // MARK: Commit — create outputs

    /// Creates `sensorLocation` and `sensorOrientation` on the system, then
    /// writes to them exactly as to a driver's own.
    ///
    /// The orientation stream is created second and its failure does not undo
    /// the first: a system with a location output and no orientation one is
    /// an ordinary state (the DR-CAMERA driver, for instance), and the next
    /// survey will find the location stream and add only what is missing.
    private func commitCreateOutputs(_ pose: SurveyedPose) async {
        let readClient = connection.readClient
        let writeClient = connection.writeClient
        let systemId = system.id
        var requestText = ""

        do {
            let locationCreated = try await writeClient.createDatastream(
                systemId: systemId,
                name: SurveyOutputSchemas.locationOutputName,
                schema: SurveyOutputSchemas.location(),
                encoding: SurveyOutputSchemas.scalarEncoding(["/time", "/location/lat", "/location/lon", "/location/alt"]))
            requestText = Self.createRequestLine(connection: connection, systemId: systemId)
                + "\n\n" + locationCreated.request
            guard locationCreated.receipt.isSuccess, let locationId = locationCreated.id else {
                fail(title: "Node refused the new location output (HTTP \(locationCreated.receipt.statusCode))",
                     detail: [locationCreated.receipt.message,
                              Self.hint(for: locationCreated.receipt.statusCode, write: .datastream)]
                        .compactMap { $0 }.joined(separator: "\n\n"),
                     request: requestText,
                     response: locationCreated.receipt.bodyText,
                     resumesAtReview: true)
                return
            }

            let orientationCreated = try await writeClient.createDatastream(
                systemId: systemId,
                name: SurveyOutputSchemas.orientationOutputName,
                schema: SurveyOutputSchemas.orientation(),
                encoding: SurveyOutputSchemas.scalarEncoding(["/time", "/orientation/heading", "/orientation/pitch", "/orientation/roll"]))
            requestText += "\n\n" + Self.createRequestLine(connection: connection, systemId: systemId)
                + "\n\n" + orientationCreated.request
            guard orientationCreated.receipt.isSuccess, let orientationId = orientationCreated.id else {
                fail(title: "Location output created, but the node refused the orientation output (HTTP \(orientationCreated.receipt.statusCode))",
                     detail: [orientationCreated.receipt.message,
                              Self.hint(for: orientationCreated.receipt.statusCode, write: .datastream)]
                        .compactMap { $0 }.joined(separator: "\n\n"),
                     request: requestText,
                     response: orientationCreated.receipt.bodyText,
                     resumesAtReview: true)
                return
            }

            Log.client.info("Survey-in created outputs \(locationId, privacy: .public) and \(orientationId, privacy: .public) on \(systemId, privacy: .public)")

            // Resolved from the node rather than from the schemas just sent,
            // so the observations are built against — and read back through —
            // what the node actually stored.
            let location = try await Self.resolve(datastreamId: locationId, using: readClient)
            let orientation = try await Self.resolve(datastreamId: orientationId, using: readClient)
            await commitStaticOutputs(pose, location: location, orientation: orientation,
                                      requestPrefix: requestText)

        } catch {
            fail(title: "Creating the outputs failed",
                 detail: ConnectionErrorMessage.summary(for: error),
                 request: requestText.isEmpty ? nil : requestText,
                 response: nil,
                 resumesAtReview: true)
        }
    }

    private static func resolve(datastreamId: String,
                                using client: ConnectedSystemsReadClient) async throws -> RemoteDatastream {
        let summary = try await client.getDatastream(id: datastreamId)
        let decoder = try await client.makeDecoder(datastreamId: datastreamId)
        return RemoteDatastream(summary: summary, schema: decoder.schema, decoder: decoder)
    }

    private static func createRequestLine(connection: NodeConnection, systemId: String) -> String {
        "POST \(connection.server.url)/systems/\(systemId)/datastreams\nContent-Type: application/json"
    }

    // MARK: Failure

    private func fail(title: String,
                      detail: String,
                      request: String? = nil,
                      response: String? = nil,
                      resumesAtReview: Bool) {
        Log.client.error("Survey-in of \(self.system.id, privacy: .public) failed: \(title, privacy: .public) — \(detail, privacy: .public)\(request.map { "\nrequest: " + $0 } ?? "", privacy: .public)\(response.map { "\nresponse: " + $0 } ?? "", privacy: .public)")
        state = .failed(SurveyFailure(title: title,
                                      detail: detail,
                                      request: request,
                                      response: response,
                                      resumesAtReview: resumesAtReview))
    }

    enum WriteKind { case datastream, observation }

    /// What a status means for *this* request, where the node's own message
    /// does not say.
    ///
    /// The "not writable" family is one cause with several faces. On
    /// OpenSensorHub 2.0 the API writes to one database module, and a system
    /// a driver registered is in it only when that module's configuration
    /// lists the system's UID. Otherwise: an observation answers 400
    /// "Resource is not writable", a new datastream 404 or 500, and a node
    /// whose error page is protected turns any of them into a 302 to its
    /// admin console.
    static func hint(for statusCode: Int, write: WriteKind) -> String? {
        switch (statusCode, write) {
        case (400, .observation), (302, _), (404, _), (500, .datastream):
            return "The node's API cannot write to this system. On OpenSensorHub 2.0 that means the system is not in the API's write database: open the node's admin console, edit the \"Connected Systems Database\" module and add this system's UID (or a wildcard such as urn:axis:cam:*) to its System UIDs, then restart the node. Systems registered through the API are writable already."
        case (401, _), (403, _):
            return "The configured credentials may not write to this node."
        case (400, .datastream):
            return "The node's parser rejected the datastream document. Its message names the path it stopped at."
        case (405, _):
            return "The node does not allow this method (transactional support may be disabled in its Connected Systems API configuration)."
        default:
            return nil
        }
    }

    private static func text(_ data: Data, limit: Int = 16_384) -> String {
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
        return data.count > limit ? text + "\n… (\(data.count - limit) more bytes)" : text
    }

    static func describe(_ pose: SurveyedPose) -> String {
        String(format: "%.6f, %.6f, HAE %.1f m, heading %.1f°, pitch %.1f°, roll %.1f°",
               pose.latitude, pose.longitude, pose.heightAboveEllipsoid,
               pose.yaw, pose.pitch, pose.roll)
    }
}
