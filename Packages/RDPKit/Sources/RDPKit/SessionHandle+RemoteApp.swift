internal import CFreeRDP
import Foundation

extension SessionHandle {
    /// The windows that changed since the last call, each as it is now.
    func takeRemoteWindows() -> [RDPRemoteWindow] {
        var windows: UnsafeMutablePointer<vistara_remote_window>?
        var count = 0
        guard vistara_session_take_remote_windows(session, &windows, &count) else { return [] }
        defer { vistara_remote_windows_free(windows, count) }
        return UnsafeBufferPointer(start: windows, count: count).map(RDPRemoteWindow.init)
    }

    /// What the RemoteApp channel said since the last call, in order.
    func takeRemoteAppEvents() -> [RDPRemoteAppEvent] {
        var events: UnsafeMutablePointer<vistara_remote_app_event>?
        var count = 0
        guard vistara_session_take_remote_app_events(session, &events, &count) else { return [] }
        defer { free(events) }
        return UnsafeBufferPointer(start: events, count: count).map(RDPRemoteAppEvent.init)
    }

    func send(_ order: RDPRemoteAppOrder) -> Bool {
        switch order {
        case .start(let program):
            vistara_session_start_program(session, program.path, program.arguments.isEmpty ? nil : program.arguments)
        case .activate(let id, let isActive):
            vistara_session_activate_window(session, id, isActive)
        case .move(let id, let frame):
            vistara_session_move_window(session, id, frame.cRect)
        case .command(let command, let id):
            vistara_session_window_command(session, id, vistara_window_command(UInt32(command.rawValue)))
        case .workArea(let area):
            vistara_session_set_work_area(session, area.cRect)
        }
    }
}

extension RDPRect {
    var cRect: vistara_rect {
        vistara_rect(
            x: Int32(clamping: x), y: Int32(clamping: y), width: Int32(clamping: width), height: Int32(clamping: height)
        )
    }

    init(_ rect: vistara_rect) {
        self.init(x: Int(rect.x), y: Int(rect.y), width: Int(rect.width), height: Int(rect.height))
    }
}

extension RDPRemoteWindow {
    init(_ window: vistara_remote_window) {
        let frame = RDPRect(x: Int(window.x), y: Int(window.y), width: Int(window.width), height: Int(window.height))
        // The visible parts, moved to the desktop; all of the frame if none were sent.
        let rects = UnsafeBufferPointer(start: window.visible_rects, count: window.visible_rect_count)
        let region = rects.map { rect in
            RDPRect(
                x: Int(window.visible_x) + Int(rect.x), y: Int(window.visible_y) + Int(rect.y),
                width: Int(rect.width), height: Int(rect.height)
            )
        }
        var icon: RDPImage?
        if let pixels = window.icon_pixels, window.icon_width > 0, window.icon_height > 0 {
            let width = Int(window.icon_width)
            let height = Int(window.icon_height)
            icon = RDPImage(width: width, height: height, pixels: Data(bytes: pixels, count: width * height * 4))
        }
        self.init(
            id: window.id,
            ownerID: window.owner_id == 0 ? nil : window.owner_id,
            style: window.style,
            extendedStyle: window.extended_style,
            showState: ShowState(window.show_state),
            title: window.title.map { String(cString: $0) } ?? "",
            frame: frame,
            visibleRegion: region.isEmpty ? [frame] : region,
            icon: icon,
            isDeleted: window.deleted
        )
    }
}

extension RDPRemoteWindow.ShowState {
    /// Windows' show states: 0 hidden, 2 minimized, 3 maximized, others shown.
    init(_ value: UInt32) {
        self = switch value {
        case 0: .hidden
        case 2: .minimized
        case 3: .maximized
        default: .shown
        }
    }
}

extension RDPRemoteAppEvent {
    init(_ event: vistara_remote_app_event) {
        switch event.kind {
        case VISTARA_REMOTE_APP_STARTED:
            self = RDPProgramFailure(code: event.code).map { .programFailed($0) } ?? .programStarted
        case VISTARA_REMOTE_APP_MOVE_SIZE_BEGAN:
            self = .moveSizeBegan(
                windowID: event.window_id, kind: RDPMoveSizeKind(rawValue: event.code) ?? .move,
                x: Int(event.x), y: Int(event.y)
            )
        case VISTARA_REMOTE_APP_MOVE_SIZE_ENDED:
            self = .moveSizeEnded(windowID: event.window_id, x: Int(event.x), y: Int(event.y))
        default:
            let maximized = RDPRect(
                x: Int(event.x), y: Int(event.y), width: Int(event.width), height: Int(event.height)
            )
            let limits = RDPWindowSizeLimits(
                maximized: maximized,
                minimumWidth: Int(event.min_width), minimumHeight: Int(event.min_height),
                maximumWidth: Int(event.max_width), maximumHeight: Int(event.max_height)
            )
            self = .sizeLimits(windowID: event.window_id, limits)
        }
    }
}

/// The shim's window bookkeeping on its own, as window orders reach it. For tests.
final class RemoteAppWindows {
    private let app: OpaquePointer

    struct Fields: OptionSet {
        let rawValue: UInt32
        static let owner = Fields(rawValue: VISTARA_WINDOW_FIELD_OWNER.rawValue)
        static let style = Fields(rawValue: VISTARA_WINDOW_FIELD_STYLE.rawValue)
        static let show = Fields(rawValue: VISTARA_WINDOW_FIELD_SHOW.rawValue)
        static let title = Fields(rawValue: VISTARA_WINDOW_FIELD_TITLE.rawValue)
        static let offset = Fields(rawValue: VISTARA_WINDOW_FIELD_OFFSET.rawValue)
        static let size = Fields(rawValue: VISTARA_WINDOW_FIELD_SIZE.rawValue)
        static let visibleOffset = Fields(rawValue: VISTARA_WINDOW_FIELD_VISIBLE_OFFSET.rawValue)
        static let visibility = Fields(rawValue: VISTARA_WINDOW_FIELD_VISIBILITY.rawValue)
        static let new = Fields(rawValue: VISTARA_WINDOW_FIELD_NEW.rawValue)
    }

    init?() {
        guard let app = vistara_remote_app_new() else { return nil }
        self.app = app
    }

    deinit {
        vistara_remote_app_free(app)
    }

    /// An order carrying `fields`, taken from `window`; `visible` is relative
    /// to `visibleOffset`.
    func apply(
        _ window: RDPRemoteWindow, fields: Fields, visibleOffset: (x: Int32, y: Int32) = (0, 0),
        visible: [RDPRect] = []
    ) {
        var rects = visible.map(\.cRect)
        window.title.withCString { title in
            rects.withUnsafeMutableBufferPointer { buffer in
                var values = vistara_remote_window()
                values.owner_id = window.ownerID ?? 0
                values.style = window.style
                values.extended_style = window.extendedStyle
                values.show_state = switch window.showState {
                case .hidden: 0
                case .minimized: 2
                case .maximized: 3
                case .shown: 5
                }
                values.title = UnsafeMutablePointer(mutating: title)
                values.x = Int32(window.frame.x)
                values.y = Int32(window.frame.y)
                values.width = UInt32(window.frame.width)
                values.height = UInt32(window.frame.height)
                values.visible_x = visibleOffset.x
                values.visible_y = visibleOffset.y
                values.visible_rects = buffer.baseAddress
                values.visible_rect_count = buffer.count
                vistara_remote_app_apply(app, window.id, fields.rawValue, &values)
            }
        }
    }

    /// An icon as the remote computer sends one: 32-bit pixels, bottom row first.
    func applyIcon(to id: UInt32, width: UInt32, height: UInt32, bottomUp pixels: [UInt8]) {
        vistara_remote_app_apply_icon(app, id, width, height, pixels)
    }

    func delete(_ id: UInt32) {
        vistara_remote_app_delete(app, id)
    }

    func take() -> [RDPRemoteWindow] {
        var windows: UnsafeMutablePointer<vistara_remote_window>?
        var count = 0
        guard vistara_remote_app_take_windows(app, &windows, &count) else { return [] }
        defer { vistara_remote_windows_free(windows, count) }
        return UnsafeBufferPointer(start: windows, count: count).map(RDPRemoteWindow.init)
    }
}
