import Foundation

public enum RC001HIDBridgePaths {
    public static let socket = "/var/run/rc001-viber-hid.sock"
    public static let status = "/var/run/rc001-viber-hid.status"
    public static let helperApp = "/Applications/RC001-Viber HID Helper.app"
    public static let helperExecutable = helperApp + "/Contents/MacOS/rc001-hid-helper"
    public static let launchDaemon = "/Library/LaunchDaemons/com.wangxi.RC001Viber.HIDHelper.plist"
    public static let launchDaemonLabel = "com.wangxi.RC001Viber.HIDHelper"
}

public enum RC001HIDEvent: String, Equatable {
    case voiceDown = "voice_down"
    case voiceUp = "voice_up"
    case power
}

public enum RC001HIDHelperStatus: Equatable {
    case notInstalled
    case starting
    case inputMonitoringRequired
    case waitingForRemote
    case ready
    case occupiedByAnotherApp
    case failed(String)

    public init(serialized: String?) {
        guard let value = serialized?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            self = .notInstalled
            return
        }

        switch value {
        case "not_installed": self = .notInstalled
        case "starting": self = .starting
        case "input_monitoring_required": self = .inputMonitoringRequired
        case "waiting_for_remote": self = .waitingForRemote
        case "ready": self = .ready
        case "occupied": self = .occupiedByAnotherApp
        default:
            if value.hasPrefix("failed:") {
                self = .failed(String(value.dropFirst("failed:".count)))
            } else {
                self = .failed("invalid-status")
            }
        }
    }

    public var serialized: String {
        switch self {
        case .notInstalled: "not_installed"
        case .starting: "starting"
        case .inputMonitoringRequired: "input_monitoring_required"
        case .waitingForRemote: "waiting_for_remote"
        case .ready: "ready"
        case .occupiedByAnotherApp: "occupied"
        case .failed(let detail): "failed:\(detail)"
        }
    }

    public var helperIsOperational: Bool {
        self == .waitingForRemote || self == .ready
    }
}

public struct RC001HIDEventStreamDecoder {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [RC001HIDEvent] {
        guard !data.isEmpty else { return [] }
        pending.append(data)
        if pending.count > 4_096 {
            pending.removeAll(keepingCapacity: true)
            return []
        }

        var events: [RC001HIDEvent] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            guard let value = String(data: line, encoding: .utf8),
                  let event = RC001HIDEvent(rawValue: value)
            else { continue }
            events.append(event)
        }
        return events
    }
}
