import ApplicationServices
import AppKit
import Darwin
import Foundation
import RC001HIDBridgeProtocol

typealias RC001HIDAccessStatus = RC001HIDHelperStatus

final class RC001HIDMapper {
    private static let rightControlVirtualKey: CGKeyCode = 62

    private let log: (String) -> Void
    private let onAccessStatus: (RC001HIDAccessStatus) -> Void
    private var statusTimer: Timer?
    private var socketSource: DispatchSourceRead?
    private var socketDescriptor: Int32 = -1
    private var eventDecoder = RC001HIDEventStreamDecoder()
    private var rightControlDown = false
    private(set) var accessStatus: RC001HIDAccessStatus = .starting

    init(
        log: @escaping (String) -> Void,
        onAccessStatus: @escaping (RC001HIDAccessStatus) -> Void
    ) {
        self.log = log
        self.onAccessStatus = onAccessStatus
    }

    deinit {
        stop()
    }

    func start() {
        guard statusTimer == nil else { return }
        log("Accessibility permission: \(AXIsProcessTrusted() ? "granted" : "required")")
        refreshStatus()
        connectToHelperIfNeeded()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatus()
            self?.connectToHelperIfNeeded()
        }
    }

    func restart() {
        log("Retrying connection to root HID helper")
        disconnectFromHelper()
        refreshStatus()
        connectToHelperIfNeeded()
    }

    func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        disconnectFromHelper()
    }

    private func refreshStatus() {
        let status = readHelperStatus()
        guard status != accessStatus else { return }
        updateAccessStatus(status)
        log("HID helper status: \(status.serialized)")
    }

    private func readHelperStatus() -> RC001HIDAccessStatus {
        guard FileManager.default.isExecutableFile(atPath: RC001HIDBridgePaths.helperExecutable) else {
            return .notInstalled
        }
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: RC001HIDBridgePaths.status
        ),
              let modificationDate = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(modificationDate) < 10,
              let contents = try? String(
                contentsOfFile: RC001HIDBridgePaths.status,
                encoding: .utf8
              )
        else {
            return .starting
        }
        return RC001HIDAccessStatus(serialized: contents)
    }

    private func connectToHelperIfNeeded() {
        guard socketSource == nil,
              FileManager.default.fileExists(atPath: RC001HIDBridgePaths.socket)
        else { return }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
        var address: sockaddr_un
        do {
            address = try unixAddress(path: RC001HIDBridgePaths.socket)
        } catch {
            _ = close(descriptor)
            log("Invalid HID helper socket path")
            return
        }
        let addressLength = unixAddressLength(path: RC001HIDBridgePaths.socket)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        guard result == 0 else {
            _ = close(descriptor)
            return
        }

        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        socketDescriptor = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in self?.readAvailableEvents() }
        source.setCancelHandler { _ = close(descriptor) }
        socketSource = source
        source.resume()
        log("Connected to root HID helper")
    }

    private func disconnectFromHelper() {
        if rightControlDown { setRightControl(isDown: false) }
        socketDescriptor = -1
        socketSource?.cancel()
        socketSource = nil
        eventDecoder = RC001HIDEventStreamDecoder()
    }

    private func readAvailableEvents() {
        guard socketDescriptor >= 0 else { return }
        refreshStatus()

        var buffer = [UInt8](repeating: 0, count: 1_024)
        while socketDescriptor >= 0 {
            let count = Darwin.read(socketDescriptor, &buffer, buffer.count)
            if count > 0 {
                let events = eventDecoder.append(Data(buffer.prefix(count)))
                for event in events { handle(event) }
            } else if count == 0 {
                log("Root HID helper disconnected")
                disconnectFromHelper()
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                log("HID helper socket read failed: errno=\(errno)")
                disconnectFromHelper()
                return
            }
        }
    }

    private func handle(_ event: RC001HIDEvent) {
        guard accessStatus == .ready else { return }
        switch event {
        case .voiceDown:
            setRightControl(isDown: true)
        case .voiceUp:
            setRightControl(isDown: false)
        case .power:
            openCodex()
        }
    }

    private func setRightControl(isDown: Bool) {
        guard isDown != rightControlDown else { return }
        rightControlDown = isDown
        postRightControl(isDown: isDown)
        log("Mapping F5 -> right_control \(isDown ? "down" : "up")")
    }

    private func postRightControl(isDown: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .hidSystemState),
            virtualKey: Self.rightControlVirtualKey,
            keyDown: isDown
        ) else { return }
        event.flags = isDown ? .maskControl : []
        event.post(tap: .cghidEventTap)
    }

    private func openCodex() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            log("Cannot find Codex (com.openai.codex)")
            return
        }
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        ) { [log] _, error in
            if let error {
                log("Failed to open Codex: \(error.localizedDescription)")
            } else {
                log("Mapping power -> open Codex")
            }
        }
    }

    private func updateAccessStatus(_ status: RC001HIDAccessStatus) {
        accessStatus = status
        onAccessStatus(status)
    }

    private func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for index in 0..<bytes.count { destination[index] = bytes[index] }
            }
        }
        return address
    }

    private func unixAddressLength(path: String) -> socklen_t {
        let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) ?? 0
        return socklen_t(offset + path.utf8CString.count)
    }
}
