import ApplicationServices
import AppKit
import IOKit.hid

enum RC001HIDAccessStatus: Equatable {
    case checking
    case ready
    case inputMonitoringRequired
    case occupiedByAnotherApp
    case failed(String)
}

final class RC001HIDMapper {
    private static let vendorID = 0x2717
    private static let productID = 0x32B8
    private static let keyboardUsagePage: UInt32 = 0x07
    private static let f5Usage: UInt32 = 0x3E
    private static let powerUsage: UInt32 = 0x66
    private static let rightControlVirtualKey: CGKeyCode = 62

    private let log: (String) -> Void
    private let onAccessStatus: (RC001HIDAccessStatus) -> Void
    private var manager: IOHIDManager?
    private var arraySlotValues: [IOHIDElementCookie: UInt32] = [:]
    private var rightControlDown = false
    private(set) var accessStatus: RC001HIDAccessStatus = .checking

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
        guard manager == nil else { return }
        updateAccessStatus(.checking)

        log("Accessibility permission: \(AXIsProcessTrusted() ? "granted" : "required")")
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            log("HID access requires Input Monitoring permission")
            updateAccessStatus(.inputMonitoringRequired)
            return
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.vendorID,
            kIOHIDProductIDKey as String: Self.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, rc001DeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, rc001DeviceRemoved, context)
        IOHIDManagerRegisterInputValueCallback(manager, rc001InputValue, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if openResult == kIOReturnSuccess {
            log("HID mapper started with exclusive access")
            updateAccessStatus(.ready)
        } else if openResult == kIOReturnNotPermitted {
            log("HID access requires Input Monitoring permission")
            updateAccessStatus(.inputMonitoringRequired)
        } else if openResult == kIOReturnExclusiveAccess {
            log("HID device is owned by another app; make Karabiner ignore RC001")
            updateAccessStatus(.occupiedByAnotherApp)
        } else {
            let code = "0x\(String(UInt32(bitPattern: openResult), radix: 16))"
            log("HID exclusive access failed: \(code)")
            updateAccessStatus(.failed(code))
        }

        if openResult != kIOReturnSuccess {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }
    }

    func restart() {
        log("Retrying HID exclusive access")
        stop()
        start()
    }

    func stop() {
        if rightControlDown {
            postRightControl(isDown: false)
        }
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    fileprivate func deviceMatched(_ device: IOHIDDevice) {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        log("HID connected: \(name ?? "RC001")")
    }

    fileprivate func deviceRemoved(_ device: IOHIDDevice) {
        arraySlotValues.removeAll()
        setRightControl(isDown: false)
        log("HID disconnected")
    }

    fileprivate func inputValue(_ value: IOHIDValue) {
        guard accessStatus == .ready else { return }
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        guard usagePage == Self.keyboardUsagePage else { return }

        let usage = IOHIDElementGetUsage(element)
        let integerValue = IOHIDValueGetIntegerValue(value)
        if usage > 0xE7 {
            handleKeyboardArraySlot(
                cookie: IOHIDElementGetCookie(element),
                newUsage: integerValue > 0 ? UInt32(integerValue) : 0
            )
        } else {
            handleKeyboardUsage(usage, isDown: integerValue != 0)
        }
    }

    private func handleKeyboardArraySlot(cookie: IOHIDElementCookie, newUsage: UInt32) {
        let voiceWasDown = arraySlotValues.values.contains(Self.f5Usage)
        let powerWasDown = arraySlotValues.values.contains(Self.powerUsage)
        arraySlotValues[cookie] = newUsage
        let voiceIsDown = arraySlotValues.values.contains(Self.f5Usage)
        let powerIsDown = arraySlotValues.values.contains(Self.powerUsage)

        if voiceWasDown != voiceIsDown {
            setRightControl(isDown: voiceIsDown)
        }
        if !powerWasDown && powerIsDown {
            openCodex()
        }

        if newUsage != 0 && newUsage != Self.f5Usage && newUsage != Self.powerUsage {
            log("Unmapped HID keyboard usage: 0x\(String(newUsage, radix: 16))")
        }
    }

    private func handleKeyboardUsage(_ usage: UInt32, isDown: Bool) {
        switch usage {
        case Self.f5Usage:
            setRightControl(isDown: isDown)
        case Self.powerUsage where isDown:
            openCodex()
        default:
            break
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
}

private func rc001DeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<RC001HIDMapper>.fromOpaque(context).takeUnretainedValue().deviceMatched(device)
}

private func rc001DeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<RC001HIDMapper>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
}

private func rc001InputValue(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard result == kIOReturnSuccess, let context else { return }
    Unmanaged<RC001HIDMapper>.fromOpaque(context).takeUnretainedValue().inputValue(value)
}
