import CoreGraphics
import RDPKit
import RDPKitUI

/// A session across several displays: one remote desktop of several
/// monitors, each display showing its region (docs/DESIGN.md, Multiple
/// displays).
extension SessionModel {
    var spansDisplays: Bool {
        displayMonitors.count > 1
    }

    /// The monitors as RDPKit sends them.
    var remoteMonitors: [RDPMonitor] {
        displayMonitors.map { monitor in
            RDPMonitor(
                x: Int32(monitor.x), y: Int32(monitor.y), width: UInt32(monitor.width), height: UInt32(monitor.height),
                isPrimary: monitor.isPrimary, scalePercent: UInt32(monitor.size.scalePercent)
            )
        }
    }

    /// Connects with every monitor; the desktop is their bounding box.
    func applyDisplays(to configuration: inout RDPSessionConfiguration) {
        guard spansDisplays else { return }
        let monitors = remoteMonitors
        let box = RDPMonitor.boundingBox(of: monitors)
        configuration.monitors = monitors
        configuration.desktopWidth = UInt32(box.width)
        configuration.desktopHeight = UInt32(box.height)
        configuration.scalePercent = monitors.first?.scalePercent ?? configuration.scalePercent
    }

    /// The part of the framebuffer the display of monitor `index` shows, or
    /// nil while the session does not span displays.
    func region(forMonitor index: Int) -> CGRect? {
        guard spansDisplays, displayMonitors.indices.contains(index) else { return nil }
        let monitors = remoteMonitors
        let rect = monitors[index].framebufferRect(in: RDPMonitor.boundingBox(of: monitors))
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
