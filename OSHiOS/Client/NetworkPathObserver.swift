import Foundation
import Network
import Combine

// MARK: - NetworkPathObserver
//
// Which kind of link this device is on, for the one decision that depends on
// it: whether the video wall starts playing streams on its own.
//
// Autoplay is not a preference in a vacuum. Opening four MJPEG streams is a few
// hundred kilobytes a second, which is free on the WiFi the node is usually
// sitting on and expensive on a phone plan — so "on WiFi" is the default and
// this is what makes it mean something.
//
// ObservationPublisher already watches an NWPathMonitor for reachability; this
// is a second, cheaper one that only cares about the interface type. Sharing
// one would tangle a publishing concern with a display concern for the sake of
// a monitor that costs almost nothing.

@MainActor
final class NetworkPathObserver: ObservableObject {

    /// The app's observer. One monitor, however many views ask.
    static let shared = NetworkPathObserver()

    /// True when the current path runs over WiFi or a wired interface.
    ///
    /// Starts true so a wall opened before the first path update does not flash
    /// every tile to "paused" and then start them a moment later.
    @Published private(set) var isUnmetered = true

    private let monitor = NWPathMonitor()
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor.pathUpdateHandler = { [weak self] path in
            // Cellular is the only metered case worth acting on: a personal
            // hotspot presents as WiFi and there is no way to tell from here,
            // and treating "unknown" as metered would disable autoplay on a
            // simulator and on Ethernet-tethered iPads.
            let unmetered = !path.usesInterfaceType(.cellular)
            Task { @MainActor [weak self] in
                guard let self, self.isUnmetered != unmetered else { return }
                self.isUnmetered = unmetered
                Log.client.info("Network path is now \(unmetered ? "unmetered" : "cellular", privacy: .public)")
            }
        }
        monitor.start(queue: DispatchQueue(label: "osh.networkpath"))
    }

    /// Whether autoplay should fire under the current setting and path.
    func shouldAutoplay(_ setting: VideoAutoplay) -> Bool {
        switch setting {
        case .always:   return true
        case .never:    return false
        case .wifiOnly: return isUnmetered
        }
    }
}
