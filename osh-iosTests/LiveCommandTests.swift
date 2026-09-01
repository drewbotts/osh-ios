import Testing
import Foundation
@testable import osh_ios

// MARK: - LiveCommandTests
//
// Commanding a real camera. Disabled unless OSH_NODE is set, like every other
// live test — and unlike them, this one *moves something*, which is why it is
// written the way it is.
//
// The movement is deliberately small and it is undone. Three degrees of
// relative pan is enough to prove the command reached the gimbal and not enough
// to lose whatever the camera was pointed at; the return move is issued even
// when the assertions in between fail, so a red test never leaves a camera
// somewhere nobody asked for.
//
// Set OSH_ALLOW_COMMANDS=1 to let it move the camera at all. A read-only live
// run is the default because "the test suite turned the yard camera around" is
// not a surprise anybody should have.
//
//   OSH_NODE=http://host:8080/sensorhub/api OSH_ALLOW_COMMANDS=1 \
//     xcodebuild test -scheme osh-ios \
//       -destination 'platform=iOS Simulator,name=iPhone 16' \
//       -only-testing:osh-iosTests/LiveCommandTests

@Suite("Live commands", .enabled(if: LiveNode.isConfigured))
struct LiveCommandTests {

    // MARK: Discovery

    /// The read half, which is safe to run on every live pass.
    @Test("Control streams on the node decode, and a PTZ camera is recognised")
    func detectsPTZ() async throws {
        let client = try LiveNode.readClient()
        let loader = RemoteSystemLoader()
        let serverId = UUID()

        var commandable = 0
        var ptz: (system: RemoteSystem, capability: PTZCapability)?
        var failures: [String] = []

        for summary in try await client.listSystems(limit: 20) {
            guard case .success(let system) = await loader.load(systemId: summary.id,
                                                                using: client,
                                                                serverId: serverId) else { continue }
            for stream in system.controlStreams {
                commandable += 1
                if let error = stream.schemaError {
                    failures.append("\(stream.id) (\(stream.name)): \(error)")
                }
            }
            if let capability = system.ptzCapability, ptz == nil {
                ptz = (system, capability)
            }
        }

        LiveNode.report("Control streams found: \(commandable)")
        #expect(failures.isEmpty, "control schemas that failed to decode: \(failures.joined(separator: "; "))")

        guard let ptz else {
            LiveNode.report("No PTZ camera on this node; nothing to command.")
            return
        }

        LiveNode.report("PTZ camera: \(ptz.system.name) [\(ptz.system.id)] "
                        + "control stream \(ptz.capability.controlStreamId)")
        LiveNode.report("  D-pad \(ptz.capability.supportsDPad), "
                        + "absolute \(ptz.capability.supportsAbsolute), "
                        + "preset \(ptz.capability.preset?.itemName ?? "none")")

        // The reference camera is an Axis: relative pan and tilt, absolute pan
        // bounded to ±180°. A node whose PTZ camera offers less than a pair
        // would not have been detected at all.
        #expect(ptz.capability.supportsDPad || ptz.capability.supportsAbsolute)
    }

    // MARK: Commanding

    /// Sends `rpan +3`, checks the camera moved, and puts it back.
    @Test("A relative pan reaches the camera and can be undone",
          .enabled(if: LiveNode.commandsAllowed))
    func relativePanRoundTrip() async throws {
        let client = try LiveNode.readClient()
        let connection = try await MainActor.run { try NodeConnection(server: LiveNode.server()) }
        let commandClient = await connection.commandClient

        let loader = RemoteSystemLoader()
        let serverId = UUID()

        var target: (system: RemoteSystem, capability: PTZCapability)?
        for summary in try await client.listSystems(limit: 20) {
            guard case .success(let system) = await loader.load(systemId: summary.id,
                                                                using: client,
                                                                serverId: serverId),
                  let capability = system.ptzCapability,
                  capability.relativePan != nil else { continue }
            target = (system, capability)
            break
        }

        guard let target else {
            LiveNode.report("No relative-pan camera on this node; skipping the move.")
            return
        }
        let panItem = try #require(target.capability.relativePan).itemName

        // The camera's own position output, when it has one. Without it the
        // test can still assert on the HTTP status, but it cannot prove the
        // gimbal moved — which is the only thing worth proving here.
        let position = await Self.positionReader(system: target.system, client: client)

        // Two readings a few seconds apart, because a camera may be running a
        // guard tour of its own — the reference node's second Axis pans
        // continuously for minutes at a time with no command behind it. A
        // camera that is already moving cannot be used to prove that *this*
        // command moved it, so the position assertions are skipped and said to
        // be skipped rather than turned into an intermittent failure.
        let before = await position?.read()
        try? await Task.sleep(for: .seconds(3))
        let stationary = await position?.read() == before
        if position != nil && !stationary {
            LiveNode.report("Camera is moving on its own (guard tour?); "
                            + "asserting on the HTTP status only.")
        }
        LiveNode.report("Start position: \(before.map(String.init(describing:)) ?? "unknown")")

        // The return move is scheduled before the outbound one is sent, so an
        // assertion failure in between cannot leave the camera turned.
        var needsReturn = false
        defer {
            if needsReturn {
                let json = CommandBody.choice(item: panItem, value: .number(-Self.step))
                Task.detached {
                    _ = try? await commandClient.sendCommand(
                        controlStreamId: target.capability.controlStreamId, parameters: json)
                }
            }
        }

        let outbound = CommandBody.choice(item: panItem, value: .number(Self.step))
        LiveNode.report("POST \(outbound)")
        needsReturn = true
        let receipt = try await commandClient.sendCommand(
            controlStreamId: target.capability.controlStreamId, parameters: outbound)

        LiveNode.report("→ HTTP \(receipt.statusCode) \(receipt.bodyText)")
        #expect(receipt.isSuccess, "the node refused the command: \(receipt.bodyText)")

        if let position, let before {
            try? await Task.sleep(for: .seconds(3))
            let after = await position.read()
            LiveNode.report("Position after +\(Self.step)°: \(after.map(String.init(describing:)) ?? "unknown")")
            if let after, stationary {
                #expect(abs(after - before - Self.step) < 1.0,
                        "pan moved from \(before) to \(after), expected +\(Self.step)°")
            }
        }

        // The return, awaited this time so the test does not finish with the
        // camera still turned.
        needsReturn = false
        let inbound = CommandBody.choice(item: panItem, value: .number(-Self.step))
        LiveNode.report("POST \(inbound)")
        let back = try await commandClient.sendCommand(
            controlStreamId: target.capability.controlStreamId, parameters: inbound)
        #expect(back.isSuccess)

        if let position, let before {
            try? await Task.sleep(for: .seconds(3))
            let restored = await position.read()
            LiveNode.report("Position after return: \(restored.map(String.init(describing:)) ?? "unknown")")
            if let restored, stationary {
                #expect(abs(restored - before) < 1.0,
                        "camera did not return: started \(before), ended \(restored)")
            }
        }

        // Status is only readable through the collection — there is no
        // per-command resource — and the reference node retains exactly one
        // command per control stream, so only the *last* one sent can be looked
        // up at all. Asserted softly for that reason: a nil here is the node
        // having already rolled the record over, not a bug. See COMMANDS.md.
        if let id = back.id {
            let status = try await commandClient.getCommandStatus(
                controlStreamId: target.capability.controlStreamId, commandId: id)
            LiveNode.report("Command \(id) status: \(status ?? "not retained")")
            if let status {
                #expect(!status.isEmpty)
                #expect(status.uppercased() != "FAILED", "the camera rejected the return move")
            }
        }
    }

    /// Degrees per move. Well inside the ±5° this run is authorised for.
    static let step: Double = 3

    // MARK: Position reader

    /// Reads a PTZ camera's reported pan, when it publishes one.
    ///
    /// A `ptzOutput`-style datastream is not required by anything in the app —
    /// it is a plain `.status` or `.timeseries` record like any other — so it
    /// is found the same way everything else is: by looking for a pan-ish field
    /// in a decoded schema rather than by matching an output name.
    private actor PositionReader {
        let datastreamId: String
        let decoder: DatastreamDecoder
        let path: FieldPath
        let client: ConnectedSystemsReadClient

        init(datastreamId: String,
             decoder: DatastreamDecoder,
             path: FieldPath,
             client: ConnectedSystemsReadClient) {
            self.datastreamId = datastreamId
            self.decoder = decoder
            self.path = path
            self.client = client
        }

        /// The datastream summary is re-fetched on every read, not cached.
        ///
        /// `fetchMostRecent` searches backwards from the range end the summary
        /// reports, and this test exists to make an observation appear *after*
        /// that end. A summary captured when the system loaded would send every
        /// read to a window that closes before the move it is looking for, and
        /// the test would fail while the camera was doing exactly the right
        /// thing.
        func read() async -> Double? {
            guard let summary = try? await client.getDatastream(id: datastreamId)
            else { return nil }
            let observations = try? await client.fetchMostRecent(datastream: summary,
                                                                 limit: 5,
                                                                 decoder: decoder)
            return observations?
                .max { $0.phenomenonTime < $1.phenomenonTime }?
                .values[path]?.asDouble
        }
    }

    private static func positionReader(system: RemoteSystem,
                                       client: ConnectedSystemsReadClient) async
        -> PositionReader? {
        for datastream in system.datastreams {
            guard let record = datastream.recordSchema,
                  let decoder = datastream.decoder else { continue }
            let leaf = SchemaWalker.leaves(of: record).first { leaf in
                leaf.component is Quantity
                    && (leaf.component.definition?.localizedCaseInsensitiveContains("Pan") == true
                        || leaf.path.lastComponent.lowercased() == "pan")
            }
            guard let leaf else { continue }
            return PositionReader(datastreamId: datastream.id,
                                  decoder: decoder,
                                  path: leaf.path,
                                  client: client)
        }
        return nil
    }
}

// MARK: - LiveNode command gate

extension LiveNode {
    /// Commands move real hardware, so they need a second, explicit opt-in on
    /// top of OSH_NODE.
    static var commandsAllowed: Bool {
        isConfigured && ProcessInfo.processInfo.environment["OSH_ALLOW_COMMANDS"] == "1"
    }
}
