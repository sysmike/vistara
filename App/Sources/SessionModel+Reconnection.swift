import CoreGraphics
import Foundation
import RDPKit

/// Bringing a session back after its network went away (docs/DESIGN.md,
/// Session window). Every attempt is a whole new connection: the certificate
/// is checked again and the credentials come from the Keychain or the sheet.
extension SessionModel {
    /// Called for every session that ended, before the window shows why.
    /// Returns whether reconnecting took over the phase: it started, goes on,
    /// or ended and said why.
    func continueReconnecting(after reason: RDPDisconnectReason, wasConnected: Bool) -> Bool {
        if case .reconnecting(var reconnection) = phase {
            guard ReconnectionPolicy.retries(after: reason) else {
                // Answered no, or something reconnecting cannot fix.
                endReconnection()
                let cancelled = reason == .credentialsCancelled || reason == .userRequested
                phase = .disconnected(cancelled ? reconnection.lost : reason)
                return true
            }
            reconnection.isTrying = false
            phase = .reconnecting(reconnection)
            scheduleAttempt(reconnection.attempts)
            return true
        }
        guard wasConnected, !endedByUser, target.reconnectsAutomatically,
            ReconnectionPolicy.reconnects(after: reason)
        else {
            return false
        }
        lastFrame = framebuffer?.snapshot().flatMap(Self.image)
        phase = .reconnecting(Reconnection(lost: reason))
        reconnectionTriggers = ReconnectionTriggers { [weak self] in self?.reconnectNow() }
        scheduleAttempt(0)
        return true
    }

    /// Starts the next attempt now, unless one is running.
    func reconnectNow() {
        guard case .reconnecting(var reconnection) = phase, !reconnection.isTrying else { return }
        reconnectWait?.cancel()
        reconnectWait = nil
        reconnection.attempts += 1
        reconnection.isTrying = true
        phase = .reconnecting(reconnection)
        connect()
    }

    /// Stops reconnecting; the window says how the session was lost.
    func cancelReconnecting() {
        guard case .reconnecting(let reconnection) = phase else { return }
        endReconnection()
        abandonAttempt()
        phase = .disconnected(reconnection.lost)
    }

    /// Stops waiting and watching. The phase is the caller's to set.
    func endReconnection() {
        reconnectWait?.cancel()
        reconnectWait = nil
        reconnectionTriggers?.stop()
        reconnectionTriggers = nil
        lastFrame = nil
    }

    /// Waits before attempt number `index` (from zero), or gives up when the
    /// policy has no more.
    private func scheduleAttempt(_ index: Int) {
        reconnectWait?.cancel()
        guard reconnectionPolicy.delays.indices.contains(index) else {
            giveUpReconnecting()
            return
        }
        let delay = reconnectionPolicy.delays[index]
        reconnectWait = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reconnectNow()
        }
    }

    private func giveUpReconnecting() {
        guard case .reconnecting(let reconnection) = phase else { return }
        endReconnection()
        didGiveUpReconnecting = true
        phase = .disconnected(reconnection.lost)
    }

    /// The picture as an image: 32-bit BGRA, opaque.
    nonisolated static func image(_ frame: RDPFrameUpdate) -> CGImage? {
        guard let provider = CGDataProvider(data: frame.pixels as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: frame.desktopWidth, height: frame.desktopHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: frame.desktopWidth * 4, space: space,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
