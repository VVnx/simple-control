import Darwin
import Foundation
import IOKit.hid
import RC001HIDBridgeProtocol

private final class StatusWriter {
    private(set) var current: RC001HIDHelperStatus = .starting

    func update(_ status: RC001HIDHelperStatus) {
        current = status
        writeCurrentStatus()
        helperLog("status=\(status.serialized)")
    }

    func writeCurrentStatus() {
        let destination = RC001HIDBridgePaths.status
        let temporary = destination + ".\(getpid()).tmp"
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else {
            helperLog("status write open failed: errno=\(errno)")
            return
        }

        let data = Data((current.serialized + "\n").utf8)
        var writeSucceeded = true
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, pointer, remaining)
                if count <= 0 {
                    writeSucceeded = false
                    break
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        _ = fchmod(descriptor, 0o644)
        _ = fsync(descriptor)
        _ = close(descriptor)

        if writeSucceeded {
            if rename(temporary, destination) != 0 {
                helperLog("status rename failed: errno=\(errno)")
                _ = unlink(temporary)
            }
        } else {
            helperLog("status write failed: errno=\(errno)")
            _ = unlink(temporary)
        }
    }
}

private final class EventSocketServer {
    private var listeningDescriptor: Int32 = -1
    private var clients: Set<Int32> = []
    private var acceptSource: DispatchSourceRead?

    func start() throws {
        try removeStaleSocketIfSafe()
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("socket") }
        listeningDescriptor = descriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        var address = try unixAddress(path: RC001HIDBridgePaths.socket)
        let addressLength = unixAddressLength(path: RC001HIDBridgePaths.socket)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, addressLength)
            }
        }
        guard bindResult == 0 else {
            let error = socketError("bind")
            stop()
            throw error
        }
        guard chmod(RC001HIDBridgePaths.socket, 0o666) == 0 else {
            let error = socketError("chmod")
            stop()
            throw error
        }
        guard listen(descriptor, 8) == 0 else {
            let error = socketError("listen")
            stop()
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in self?.acceptPendingClients() }
        source.resume()
        acceptSource = source
    }

    func broadcast(_ event: RC001HIDEvent) {
        let data = Data((event.rawValue + "\n").utf8)
        var disconnected: [Int32] = []
        for client in clients {
            let result = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.write(client, baseAddress, buffer.count)
            }
            if result == data.count { continue }
            if result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            disconnected.append(client)
        }
        for client in disconnected {
            clients.remove(client)
            _ = close(client)
        }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        for client in clients { _ = close(client) }
        clients.removeAll()
        if listeningDescriptor >= 0 {
            _ = close(listeningDescriptor)
            listeningDescriptor = -1
        }
        removeOwnedSocket()
    }

    private func acceptPendingClients() {
        while listeningDescriptor >= 0 {
            let client = accept(listeningDescriptor, nil, nil)
            if client < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    helperLog("accept failed: errno=\(errno)")
                }
                return
            }
            _ = fcntl(client, F_SETFL, O_NONBLOCK)
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            if clients.count < 8 {
                clients.insert(client)
            } else {
                _ = close(client)
            }
        }
    }

    private func removeStaleSocketIfSafe() throws {
        var information = stat()
        if lstat(RC001HIDBridgePaths.socket, &information) != 0 {
            if errno == ENOENT { return }
            throw socketError("lstat")
        }
        guard information.st_uid == 0,
              information.st_mode & S_IFMT == S_IFSOCK
        else {
            throw NSError(
                domain: "RC001HIDHelper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "unsafe existing socket path"]
            )
        }
        guard unlink(RC001HIDBridgePaths.socket) == 0 else { throw socketError("unlink") }
    }

    private func removeOwnedSocket() {
        var information = stat()
        guard lstat(RC001HIDBridgePaths.socket, &information) == 0,
              information.st_uid == 0,
              information.st_mode & S_IFMT == S_IFSOCK
        else { return }
        _ = unlink(RC001HIDBridgePaths.socket)
    }

    private func socketError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }

    private func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else {
            throw NSError(
                domain: "RC001HIDHelper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "socket path is too long"]
            )
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

private final class RC001HIDHelper {
    private static let vendorID = 0x2717
    private static let productID = 0x32B8
    private static let genericDesktopUsagePage = 0x01
    private static let keyboardUsage = 0x06
    private static let keyboardUsagePage: UInt32 = 0x07
    private static let f5Usage: UInt32 = 0x3E
    private static let powerUsage: UInt32 = 0x66

    private let statusWriter = StatusWriter()
    private let socketServer = EventSocketServer()
    private var manager: IOHIDManager?
    private var retryWorkItem: DispatchWorkItem?
    private var heartbeatTimer: Timer?
    private var arraySlotValues: [IOHIDElementCookie: UInt32] = [:]
    private var voiceIsDown = false

    func start() {
        signal(SIGPIPE, SIG_IGN)
        statusWriter.update(.starting)
        do {
            try socketServer.start()
        } catch {
            statusWriter.update(.failed("socket-\((error as NSError).code)"))
            helperLog("event socket failed: \(error.localizedDescription)")
            exit(EXIT_FAILURE)
        }

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.statusWriter.writeCurrentStatus()
        }
        openHIDManager()
    }

    private func openHIDManager() {
        guard manager == nil else { return }
        retryWorkItem?.cancel()
        retryWorkItem = nil
        statusWriter.update(.starting)

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
            kIOHIDPrimaryUsagePageKey as String: Self.genericDesktopUsagePage,
            kIOHIDPrimaryUsageKey as String: Self.keyboardUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemoved, context)
        IOHIDManagerRegisterInputValueCallback(manager, hidInputValue, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result != kIOReturnSuccess else {
            statusWriter.update(.waitingForRemote)
            helperLog("exclusive HID manager opened for RC001 keyboard collection")
            return
        }

        closeHIDManager()
        if result == kIOReturnNotPermitted || result == kIOReturnNotPrivileged {
            statusWriter.update(.inputMonitoringRequired)
        } else if result == kIOReturnExclusiveAccess {
            statusWriter.update(.occupiedByAnotherApp)
        } else {
            statusWriter.update(.failed(ioReturnCode(result)))
        }
        scheduleRetry()
    }

    private func closeHIDManager() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        arraySlotValues.removeAll()
        if voiceIsDown {
            voiceIsDown = false
            socketServer.broadcast(.voiceUp)
        }
    }

    private func scheduleRetry() {
        let item = DispatchWorkItem { [weak self] in self?.openHIDManager() }
        retryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    fileprivate func deviceMatched(_ device: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        helperLog("HID connected: \(name ?? "RC001")")
        statusWriter.update(.ready)
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        arraySlotValues.removeAll()
        if voiceIsDown {
            voiceIsDown = false
            socketServer.broadcast(.voiceUp)
        }
        helperLog("HID disconnected")
        statusWriter.update(.waitingForRemote)
    }

    fileprivate func inputValue(_ value: IOHIDValue) {
        guard statusWriter.current == .ready else { return }
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == Self.keyboardUsagePage else { return }

        let usage = IOHIDElementGetUsage(element)
        let integerValue = IOHIDValueGetIntegerValue(value)
        if usage > 0xE7 {
            handleArraySlot(
                cookie: IOHIDElementGetCookie(element),
                newUsage: integerValue > 0 ? UInt32(integerValue) : 0
            )
        } else {
            handleUsage(usage, isDown: integerValue != 0)
        }
    }

    private func handleArraySlot(cookie: IOHIDElementCookie, newUsage: UInt32) {
        let voiceWasDown = arraySlotValues.values.contains(Self.f5Usage)
        let powerWasDown = arraySlotValues.values.contains(Self.powerUsage)
        arraySlotValues[cookie] = newUsage
        let voiceIsDown = arraySlotValues.values.contains(Self.f5Usage)
        let powerIsDown = arraySlotValues.values.contains(Self.powerUsage)

        if voiceWasDown != voiceIsDown { setVoice(isDown: voiceIsDown) }
        if !powerWasDown && powerIsDown { socketServer.broadcast(.power) }
    }

    private func handleUsage(_ usage: UInt32, isDown: Bool) {
        switch usage {
        case Self.f5Usage:
            setVoice(isDown: isDown)
        case Self.powerUsage where isDown:
            socketServer.broadcast(.power)
        default:
            break
        }
    }

    private func setVoice(isDown: Bool) {
        guard isDown != voiceIsDown else { return }
        voiceIsDown = isDown
        socketServer.broadcast(isDown ? .voiceDown : .voiceUp)
    }

    private func ioReturnCode(_ result: IOReturn) -> String {
        "0x\(String(UInt32(bitPattern: result), radix: 16))"
    }
}

private func hidDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<RC001HIDHelper>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
}

private func hidDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<RC001HIDHelper>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
}

private func hidInputValue(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<RC001HIDHelper>.fromOpaque(context).takeUnretainedValue().inputValue(value)
}

private func helperLog(_ message: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

guard getuid() == 0 else {
    helperLog("refusing to run without root privileges")
    exit(EX_NOPERM)
}

private let helper = RC001HIDHelper()
helper.start()
withExtendedLifetime(helper) {
    RunLoop.main.run()
}
