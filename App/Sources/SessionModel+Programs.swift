import RDPKit

/// A session that opens a program in place of the desktop (docs/DESIGN.md,
/// RemoteApp): its desktop spans every display, and each of the program's
/// windows is a Mac window of its own.
extension SessionModel {
    var opensProgram: Bool {
        target.program != nil
    }

    /// Connects with the Mac's displays as they are now, as one space.
    func applyProgramSpace(to configuration: inout RDPSessionConfiguration) {
        let space = RemoteAppSpace.current(usesHiDPI: target.usesHiDPI)
        programSpace = space
        let monitors = space.monitors
        let box = space.boundingBox
        configuration.monitors = monitors.count > 1 ? monitors : []
        configuration.desktopWidth = UInt32(box.width)
        configuration.desktopHeight = UInt32(box.height)
        configuration.scalePercent = UInt32((space.scale * 100).rounded())
    }

    /// Shows the program's windows as the remote computer sends them, in
    /// place of any from before a reconnection.
    func startPrograms(for session: RDPSession) {
        guard opensProgram, let framebuffer, let space = programSpace else { return }
        programs?.closeAll()
        let send: ([RDPInputEvent]) -> Void = { [weak session] events in session?.send(events) }
        let windows = ProgramWindows(framebuffer: framebuffer, space: space, connectionName: target.name, send: send)
        windows.onLastWindowClosed = { [weak self] in self?.onLastProgramWindowClosed?() }
        windows.follow(session)
        programs = windows
    }

    /// While reconnecting, the windows stay where they are, dimmed;
    /// otherwise they go with the session.
    func programsLost(isReconnecting: Bool) {
        guard let programs else { return }
        if isReconnecting {
            programs.dim(true)
        } else {
            programs.closeAll()
            self.programs = nil
        }
    }
}
