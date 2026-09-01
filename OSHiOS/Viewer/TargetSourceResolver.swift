import Foundation
import CoreLocation

// MARK: - TargetSourceResolver
//
// A target was observed *from* somewhere. This decides where.
//
// A laser range finder's record says where the target is and nothing at all
// about who was holding the laser — the reference node's TruPulse output is a
// timestamp and a lat/lon/alt, full stop. But the interesting drawing is the
// line from the observer to the target, and a line needs two ends.
//
// Four rules, in descending order of how much the node actually told us. Only
// the first three are things a Connected Systems node can state; the fourth is
// a fallback that reads the systems' UIDs, and it exists because on the
// reference node none of the first three fire and without it the feature draws
// nothing. It is ordered *after* every explicit signal and only ever consulted
// when the range finder's own system has no position of its own, so it can
// never override something the node said.
//
// Pure by construction: no session, no client, no clock. Everything it needs
// arrives as an argument, which is what makes "the phone moved, redraw the
// line" a matter of calling it again rather than of invalidating a cache.

enum TargetSourceResolver {

    // MARK: Types

    /// This device, expressed as a source candidate.
    ///
    /// The phone is a system on the node like any other — it registered itself
    /// — so it competes on equal terms with the systems in the list. It is
    /// passed separately only because its *position* comes from CoreLocation
    /// rather than from an observation.
    struct LocalDeviceRef: Equatable, Sendable {
        /// The system id the node minted for this device, when it has one.
        /// Only used for matching a stated identifier — the phone may have a
        /// fix long before it has registered with anything.
        let systemId: String?
        /// `urn:osh:ios:<vendor id>`.
        let uid: String?
        let name: String
        /// The id the device's own marker is drawn under, so a resolved source
        /// can be turned back into a selection on the map. Supplied rather than
        /// defaulted: the map owns that identity (`DeviceLayer.markerId`) and
        /// two spellings of it would be one bug waiting.
        let markerId: String
        /// The latest GPS fix, or nil when there is none yet.
        let coordinate: CLLocationCoordinate2D?

        init(systemId: String?,
             uid: String?,
             name: String = "This Device",
             markerId: String,
             coordinate: CLLocationCoordinate2D?) {
            self.systemId = systemId
            self.uid = uid
            self.name = name
            self.markerId = markerId
            self.coordinate = coordinate
        }

        // CLLocationCoordinate2D is not Equatable, so the synthesised
        // conformance is unavailable. Written out the same way
        // SystemMapView's inputs are.
        static func == (lhs: LocalDeviceRef, rhs: LocalDeviceRef) -> Bool {
            lhs.systemId == rhs.systemId
                && lhs.uid == rhs.uid
                && lhs.name == rhs.name
                && lhs.markerId == rhs.markerId
                && lhs.coordinate?.latitude == rhs.coordinate?.latitude
                && lhs.coordinate?.longitude == rhs.coordinate?.longitude
        }
    }

    /// Where a target's line starts, and how confident we are about it.
    struct SourceRef: Equatable, Sendable {

        /// Which rule produced this answer. Carried so a card can say how it
        /// knows, and so a test can assert on the rule rather than only on the
        /// system it happened to pick.
        enum Resolution: String, Equatable, Sendable {
            /// (i) the record named a system.
            case identifier
            /// (ii) the range finder is registered under a parent system.
            case parent
            /// (iii) the range finder's own system has a position.
            case owner
            /// (iv) another system shares a strong token with the owner's UID.
            case uidAffinity
            /// (iii) again, with nothing to draw from: the owner, positionless.
            case ownerWithoutPosition
        }

        let systemId: String
        let name: String
        /// The source's position *now*, or nil when nothing locates it — in
        /// which case the target marker is drawn and the line is not.
        let coordinate: CLLocationCoordinate2D?
        let resolution: Resolution
        /// True when the source is this device rather than a node system.
        var isLocalDevice = false

        var hasPosition: Bool { coordinate != nil }

        static func == (lhs: SourceRef, rhs: SourceRef) -> Bool {
            lhs.systemId == rhs.systemId
                && lhs.name == rhs.name
                && lhs.resolution == rhs.resolution
                && lhs.isLocalDevice == rhs.isLocalDevice
                && lhs.coordinate?.latitude == rhs.coordinate?.latitude
                && lhs.coordinate?.longitude == rhs.coordinate?.longitude
        }
    }

    // MARK: Resolution

    /// The system a target observation was taken from.
    ///
    /// - Parameters:
    ///   - observation: read only for its `sourceIdPath` value, when the role
    ///     found one.
    ///   - datastream: the target stream, for its `TargetPaths`.
    ///   - owner: the system the datastream belongs to.
    ///   - systems: every system loaded from the node, the owner included.
    ///   - localDevice: this device, when it is registered or has a fix.
    ///   - position: where a node system is *now*. Defaults to the system
    ///     resource's own geometry, which is all a caller with no observations
    ///     can know; `COPMapModel` passes its live/reported/deployed lookup.
    /// - Returns: nil only when the datastream is not a target stream.
    static func source(for observation: ParsedObservation,
                       datastream: RemoteDatastream,
                       owner: RemoteSystem,
                       systems: [RemoteSystem],
                       localDevice: LocalDeviceRef?,
                       position: (RemoteSystem) -> CLLocationCoordinate2D? = { $0.fixedLocation })
        -> SourceRef? {

        guard case .target(let paths) = datastream.role else { return nil }

        // ── i. The record names a system ─────────────────────────────────────
        if let sourceIdPath = paths.sourceIdPath,
           let stated = observation.values[sourceIdPath]?.asString,
           !stated.isEmpty {
            if let matched = systems.first(where: { matches(stated, system: $0) }) {
                return reference(matched, resolution: .identifier, position: position)
            }
            if let localDevice, matches(stated, device: localDevice) {
                return reference(localDevice, resolution: .identifier)
            }
        }

        // ── ii. The node put the range finder under a parent ─────────────────
        if let parentId = owner.summary.parentSystemId,
           let parent = systems.first(where: { $0.id == parentId }) {
            return reference(parent, resolution: .parent, position: position)
        }

        // ── iii. The range finder's own system knows where it is ─────────────
        //
        // The common shape when a driver publishes the target output on the
        // phone's own system: owner *is* the observer.
        if owner.hasPosition {
            return reference(owner, resolution: .owner, position: position)
        }

        // ── iv. A system whose UID shares a device token with the owner's ────
        if let affine = affinity(of: owner, systems: systems,
                                 localDevice: localDevice, position: position) {
            return affine
        }

        // ── iii, without a position ──────────────────────────────────────────
        return reference(owner, resolution: .ownerWithoutPosition, position: position)
    }

    // MARK: Rule i — identifier matching

    /// Whether a stated identifier names this system.
    ///
    /// Suffix matching as well as equality, because a driver that writes an
    /// identifier into a record usually writes the tail of the UID it knows —
    /// "…:android:1234" for `urn:osh:android:1234` — and an exact-match-only
    /// rule would reject every one of them.
    static func matches(_ stated: String, system: RemoteSystem) -> Bool {
        matches(stated, id: system.id, uid: system.summary.uid, name: system.name)
    }

    static func matches(_ stated: String, device: LocalDeviceRef) -> Bool {
        matches(stated, id: device.systemId, uid: device.uid, name: device.name)
    }

    private static func matches(_ stated: String,
                                id: String?,
                                uid: String?,
                                name: String?) -> Bool {
        let value = stated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }

        for candidate in [id, uid, name].compactMap({ $0 }) where !candidate.isEmpty {
            if candidate.compare(value, options: .caseInsensitive) == .orderedSame {
                return true
            }
        }
        // Suffix only against the UID: an id is opaque and short enough that a
        // suffix match would collide, and a name's tail means nothing.
        if let uid, !uid.isEmpty,
           uid.count >= value.count,
           uid.lowercased().hasSuffix(value.lowercased()) {
            return true
        }
        return false
    }

    // MARK: Rule iv — UID affinity

    /// A positioned system whose UID shares a strong token with the owner's.
    ///
    /// The reference node's range finder is `urn:lasertech:trupulse360:
    /// 7ae57419dd427e4c:replay` and the phone carrying it is
    /// `urn:osh:android:7ae57419dd427e4c:droid2:replay`. The sixteen-character
    /// device id is the only thing connecting them, and it connects them
    /// unambiguously.
    ///
    /// Ranked by how many colon-separated tokens the two UIDs share, and on a
    /// tie by which candidate's UID says the *least* beyond them. Both halves
    /// earn their place against the reference node, which carries two
    /// registrations of the same phone: the live range finder
    /// (…:7ae57419dd427e4c:replay) shares ":replay" with the live phone and
    /// wins on the first test, while the archived range finder
    /// (…:7ae57419dd427e4c) ties on one shared token and picks the archived
    /// phone, whose UID carries one fewer segment it does not share.
    ///
    /// Candidates nothing locates are skipped — a source with nowhere to draw
    /// from is no better than the owner.
    ///
    /// Locatability is read from `RemoteSystem.hasPosition` rather than from
    /// the `position` closure, so which system wins is a pure function of the
    /// list. The closure only ever fills in the coordinate of the winner.
    private static func affinity(of owner: RemoteSystem,
                                 systems: [RemoteSystem],
                                 localDevice: LocalDeviceRef?,
                                 position: (RemoteSystem) -> CLLocationCoordinate2D?)
        -> SourceRef? {

        let ownerTokens = tokens(of: owner.summary.uid)
        guard !ownerTokens.strong.isEmpty else { return nil }

        /// (shared tokens, tokens *not* shared) — more shared wins, then fewer
        /// unshared. nil when the two UIDs have no strong token in common.
        func score(_ uid: String?) -> (shared: Int, extra: Int)? {
            let candidate = tokens(of: uid)
            guard !candidate.strong.intersection(ownerTokens.strong).isEmpty else { return nil }
            let shared = candidate.all.intersection(ownerTokens.all).count
            return (shared, candidate.all.count - shared)
        }

        func beats(_ lhs: (shared: Int, extra: Int), _ rhs: (shared: Int, extra: Int)) -> Bool {
            lhs.shared != rhs.shared ? lhs.shared > rhs.shared : lhs.extra < rhs.extra
        }

        var best: (system: RemoteSystem, score: (shared: Int, extra: Int))?
        for system in systems
        where system.id != owner.id && system.hasPosition {
            guard let score = score(system.summary.uid) else { continue }
            if best == nil || beats(score, best!.score) { best = (system, score) }
        }

        if let localDevice, localDevice.coordinate != nil,
           localDevice.systemId != owner.id,
           let deviceScore = score(localDevice.uid),
           best == nil || beats(deviceScore, best!.score) {
            return reference(localDevice, resolution: .uidAffinity)
        }
        guard let best else { return nil }
        return reference(best.system, resolution: .uidAffinity, position: position)
    }

    /// A UID split on colons: every token, and the ones specific enough to
    /// identify a device.
    ///
    /// "urn" is dropped outright and anything shorter than eight characters is
    /// too generic to match on — "osh", "ios", "android" and "replay" appear in
    /// half the UIDs on a node, and matching on them would pair every system
    /// with every other. They still count towards the ranking, where a shared
    /// "replay" is exactly the tiebreak that picks the live registration.
    static func tokens(of uid: String?) -> (all: Set<String>, strong: Set<String>) {
        guard let uid, !uid.isEmpty else { return ([], []) }
        let all = Set(uid.lowercased()
            .split(whereSeparator: { $0 == ":" || $0 == "#" })
            .map(String.init)
            .filter { $0 != "urn" })
        return (all, all.filter { $0.count >= 8 })
    }

    // MARK: Building references

    private static func reference(_ system: RemoteSystem,
                                  resolution: SourceRef.Resolution,
                                  position: (RemoteSystem) -> CLLocationCoordinate2D?)
        -> SourceRef {
        SourceRef(systemId: system.id,
                  name: system.name,
                  coordinate: position(system),
                  resolution: resolution)
    }

    private static func reference(_ device: LocalDeviceRef,
                                  resolution: SourceRef.Resolution) -> SourceRef {
        SourceRef(systemId: device.markerId,
                  name: device.name,
                  coordinate: device.coordinate,
                  resolution: resolution,
                  isLocalDevice: true)
    }
}

// MARK: - TargetStyle

/// The numbers behind a drawn target. The sibling of `BearingStyle`, and it
/// borrows that type's fade rule outright: a target designation is an event, not
/// a stream, so the last one is never removed however old it gets.
enum TargetStyle {

    /// Thinner than a LOB. A bearing line is a claim about a whole direction
    /// and wants weight; a target line joins two known points and only has to
    /// be followable.
    static let lineWidth: Double = 2

    static let freshOpacity: Double = 0.7
    static let staleOpacity: Double = 0.25

    /// How many past targets the history layer draws.
    static let historyLimit = 20

    static let historyDotSize: CGFloat = 7

    /// Opacity for a line last updated at `timestamp`. Same threshold as a
    /// bearing's, so the two overlays age at the same rate on one map.
    static func opacity(at timestamp: Date, now: Date = Date()) -> Double {
        now.timeIntervalSince(timestamp) > BearingStyle.staleAfter
            ? staleOpacity : freshOpacity
    }

    /// Label for a target marker: the range and azimuth the record carried.
    /// nil when it carried neither, so the caller can fall back to a name.
    static func label(rangeMeters: Double?, azimuthDegrees: Double?) -> String? {
        var parts: [String] = []
        if let rangeMeters, rangeMeters.isFinite {
            parts.append(rangeMeters >= 1000
                ? String(format: "%.1f km", rangeMeters / 1000)
                : String(format: "%.0f m", rangeMeters))
        }
        if let azimuthDegrees, azimuthDegrees.isFinite {
            let wrapped = OrientationPaths.normalized(azimuthDegrees)
            parts.append(String(format: "@ %03.0f°", wrapped))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
