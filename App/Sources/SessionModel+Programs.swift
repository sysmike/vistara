import Foundation
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
        windows.onProgramAnswer = { [weak self] failure in self?.programAnswered(failure) }
        windows.onWindowIcon = { [weak self] icon in self?.programIconArrived(icon) }
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

/// Why one of a session's programs did not start.
struct ProgramFailure: Equatable {
    var failure: RDPProgramFailure
    /// The program's connection, by name and identifier.
    var name: String
    var connectionID: UUID?
}

/// The programs a session starts, in order: the remote computer answers each
/// start in turn, and a program's first window brings its icon.
struct ProgramStarts {
    struct Start: Equatable {
        var name: String
        var connectionID: UUID?
        var program: RDPProgram
    }

    /// Started, waiting for the remote computer's answer.
    var awaitingAnswer: [Start] = []
    /// Waiting until the remote computer answered the session's first start;
    /// before that, it takes no more.
    var waiting: [Start] = []
    /// Started, waiting for a new window's icon.
    var awaitingIcon: [UUID] = []
    /// Icons of new windows that came before their program's answer, as PNGs:
    /// the answer comes on another channel and may be later.
    var earlyIcons: [Data] = []
    /// The saved connections whose programs run in the session.
    var running: Set<UUID> = []
    var takesMore = false

    init() {}

    init(first target: SessionTarget) {
        guard let start = Start(target) else { return }
        awaitingAnswer = [start]
        if let id = target.connectionID { running.insert(id) }
    }
}

extension ProgramStarts.Start {
    init?(_ target: SessionTarget) {
        guard let program = target.program else { return nil }
        self.init(
            name: target.name, connectionID: target.connectionID,
            program: RDPProgram(path: program.path, arguments: program.arguments)
        )
    }
}

/// Programs started and answered, and what the panel says about them.
extension SessionModel {
    func beginPrograms() {
        programStarts = ProgramStarts(first: target)
        programFailure = nil
    }

    /// Starts another program in this session, once it can take one. A
    /// program that runs already has its windows brought forward instead.
    func startProgram(_ other: SessionTarget) {
        if let id = other.connectionID, programStarts.running.contains(id) {
            programs?.bringToFront()
            return
        }
        guard let start = ProgramStarts.Start(other) else { return }
        if let id = other.connectionID { programStarts.running.insert(id) }
        if programStarts.takesMore, isConnected {
            send([.remoteApp(.start(start.program))])
            programStarts.awaitingAnswer.append(start)
        } else {
            programStarts.waiting.append(start)
        }
    }

    /// The remote computer answered the oldest start.
    func programAnswered(_ failure: RDPProgramFailure?) {
        guard !programStarts.awaitingAnswer.isEmpty else { return }
        let start = programStarts.awaitingAnswer.removeFirst()
        if !programStarts.takesMore {
            programStarts.takesMore = true
            for waiting in programStarts.waiting {
                send([.remoteApp(.start(waiting.program))])
                programStarts.awaitingAnswer.append(waiting)
            }
            programStarts.waiting = []
        }
        guard let failure else {
            guard let id = start.connectionID else { return }
            if programStarts.earlyIcons.isEmpty {
                programStarts.awaitingIcon.append(id)
            } else {
                onProgramIcon?(id, programStarts.earlyIcons.removeFirst())
            }
            return
        }
        if let id = start.connectionID { programStarts.running.remove(id) }
        programFailure = ProgramFailure(failure: failure, name: start.name, connectionID: start.connectionID)
        // Nothing runs, and nothing else is on its way: the session ends.
        if programs?.controllers.isEmpty ?? true, programStarts.awaitingAnswer.isEmpty {
            disconnect()
        }
    }

    /// A program's first window brought its icon.
    func programIconArrived(_ icon: RDPImage) {
        guard let png = ProgramWindowController.png(icon) else { return }
        if programStarts.awaitingIcon.isEmpty {
            programStarts.earlyIcons.append(png)
        } else {
            onProgramIcon?(programStarts.awaitingIcon.removeFirst(), png)
        }
    }

    /// What the panel says about a program that did not start, if one did not.
    var programFailureMessage: DisconnectMessage? {
        programFailure.map { failure in
            DisconnectMessage.programFailed(
                failure.failure, program: failure.name, computer: target.host, sessionContinues: isLive
            )
        }
    }

    /// The editor for a program that did not start, or else this session's connection.
    func editConnection() {
        if let id = programFailure?.connectionID {
            onEditConnectionWithID?(id)
        } else {
            onEditConnection?()
        }
    }
}
