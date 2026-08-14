import AppKit
import CoreBluetooth
import Foundation
import RC001Core

final class RC001VoiceProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let voiceServiceUUID = CBUUID(string: ATVVoiceProtocol.serviceUUID)
    private let transmitUUID = CBUUID(string: ATVVoiceProtocol.transmitCharacteristicUUID)
    private let audioUUID = CBUUID(string: ATVVoiceProtocol.audioCharacteristicUUID)
    private let controlUUID = CBUUID(string: ATVVoiceProtocol.controlCharacteristicUUID)
    private let hidServiceUUID = CBUUID(string: "1812")

    private lazy var central = CBCentralManager(delegate: self, queue: .main)
    private var peripheral: CBPeripheral?
    private var transmitCharacteristic: CBCharacteristic?
    private var audioCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var initialized = false

    private var decoder = IMAADPCMDecoder()
    private var samples: [Int16] = []
    private var sampleRate = 16_000
    private var streamID: UInt8 = 0
    private var recording = false
    private var audioFrameCount = 0
    private var closeWorkItem: DispatchWorkItem?
    private let sharedAudioWriter = SharedAudioWriter()

    private let recordingDuration: TimeInterval
    private let applicationSupportDirectory: URL
    private let logURL: URL
    private let timestampFormatter: DateFormatter
    private var hidMapper: RC001HIDMapper?
    private let statusMenu: RC001StatusMenu

    init(statusMenu: RC001StatusMenu) {
        self.statusMenu = statusMenu
        let duration = ProcessInfo.processInfo.environment["RC001_RECORDING_SECONDS"]
            .flatMap(Double.init) ?? 8.0
        recordingDuration = min(max(duration, 1.0), 60.0)

        applicationSupportDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/RC001MacBridge", isDirectory: true)
        logURL = applicationSupportDirectory.appendingPathComponent("probe.log")
        timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"

        super.init()
        try? FileManager.default.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log("Starting RC001-Viber; capture duration = \(recordingDuration)s")
        log("Bluetooth authorization: \(CBCentralManager.authorization.description)")
        log("Virtual microphone ring: \(sharedAudioWriter == nil ? "unavailable" : "ready")")
        hidMapper = RC001HIDMapper(
            log: { [weak self] message in self?.log(message) },
            onAccessStatus: { [weak statusMenu] status in
                statusMenu?.setHIDAccessStatus(status)
            }
        )
        hidMapper?.start()
        _ = central
    }

    func retryHIDAccess() {
        hidMapper?.restart()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Bluetooth state: \(central.state.description)")
        statusMenu.setRemoteStatus(central.state == .poweredOn ? "正在查找" : central.state.description)
        guard central.state == .poweredOn else { return }

        let voicePeripherals = central.retrieveConnectedPeripherals(withServices: [voiceServiceUUID])
        let hidPeripherals = central.retrieveConnectedPeripherals(withServices: [hidServiceUUID])
        let connected = unique(voicePeripherals + hidPeripherals)
        log("Retrieved \(connected.count) connected BLE peripheral(s)")

        if let remote = connected.first(where: isTargetRemote) ?? voicePeripherals.first {
            attach(to: remote)
        } else {
            log("Target is not retrievable yet; scanning all BLE advertisements")
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        log("Discovered name=\(advertisedName ?? peripheral.name ?? "<unknown>") id=\(peripheral.identifier) rssi=\(RSSI) services=\(serviceUUIDs)")

        if isTargetRemote(peripheral) || serviceUUIDs.contains(voiceServiceUUID) {
            central.stopScan()
            attach(to: peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("Connected to \(peripheral.name ?? "<unknown>") [\(peripheral.identifier)]")
        statusMenu.setRemoteStatus("已连接")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected: \(error?.localizedDescription ?? "no error")")
        statusMenu.setRemoteStatus("已断开，正在重连")
        initialized = false
        recording = false
        self.peripheral = nil
        self.transmitCharacteristic = nil
        self.audioCharacteristic = nil
        self.controlCharacteristic = nil
        central.scanForPeripherals(withServices: nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Service discovery failed: \(error.localizedDescription)")
            return
        }

        for service in peripheral.services ?? [] {
            log("Service \(service.uuid)")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log("Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
            return
        }

        for characteristic in service.characteristics ?? [] {
            log("  Characteristic \(characteristic.uuid) properties=\(characteristic.properties.description)")

            switch characteristic.uuid {
            case transmitUUID:
                transmitCharacteristic = characteristic
            case audioUUID:
                audioCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            case controlUUID:
                controlCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            }
        }
        initializeVoiceServiceIfReady()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            log("Notification setup failed for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            log("Notifications for \(characteristic.uuid): \(characteristic.isNotifying)")
        }
        initializeVoiceServiceIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("Value update failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }

        if characteristic.uuid == controlUUID {
            handleControl(data)
        } else if characteristic.uuid == audioUUID {
            handleAudio(data)
        } else if !data.isEmpty {
            log("Read \(characteristic.uuid): \(data.hexadecimalString)")
        }
    }

    private func attach(to peripheral: CBPeripheral) {
        guard self.peripheral == nil else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        log("Selected \(peripheral.name ?? "<unknown>") [\(peripheral.identifier)] state=\(peripheral.state.description)")

        if peripheral.state == .connected {
            peripheral.discoverServices(nil)
        } else {
            central.connect(peripheral)
        }
    }

    private func initializeVoiceServiceIfReady() {
        guard !initialized,
              let peripheral,
              let transmitCharacteristic,
              audioCharacteristic?.isNotifying == true,
              controlCharacteristic?.isNotifying == true
        else { return }

        initialized = true
        log("ATV Voice service is ready; sending GET_CAPS in On-request mode")
        write(ATVVoiceProtocol.getCapabilities, to: transmitCharacteristic, on: peripheral)
    }

    private func handleControl(_ data: Data) {
        log("Control <= \(data.hexadecimalString)")
        guard let command = data.first else { return }

        switch command {
        case 0x00:
            stopCapture(reason: "AUDIO_STOP")
        case 0x04:
            guard let start = ATVAudioStart(controlData: data) else {
                log("Malformed AUDIO_START")
                return
            }
            streamID = start.streamID
            sampleRate = start.codec.sampleRate
            samples.removeAll(keepingCapacity: true)
            decoder.reset()
            sharedAudioWriter?.beginStream()
            audioFrameCount = 0
            recording = true
            statusMenu.setMicrophoneStatus("正在接收语音")
            log("AUDIO_START reason=0x\(String(format: "%02X", start.reason)) codec=\(start.codec) stream=\(streamID)")
        case 0x08:
            log("START_SEARCH received; requesting microphone")
            requestMicrophone()
        case 0x0A:
            guard let sync = ATVAudioSync(controlData: data) else {
                log("Malformed AUDIO_SYNC")
                return
            }
            sampleRate = sync.codec.sampleRate
            decoder.reset(predictor: sync.predictor, stepIndex: sync.stepIndex)
            log("AUDIO_SYNC frame=\(sync.frameNumber) predictor=\(sync.predictor) step=\(sync.stepIndex)")
        case 0x0B:
            if let capabilities = ATVCapabilities(controlData: data) {
                log("CAPS_RESP version=0x\(String(format: "%04X", capabilities.version)) codecs=0x\(String(format: "%02X", capabilities.codecs)) model=0x\(String(format: "%02X", capabilities.interactionModel)) frame=\(capabilities.audioFrameSize) fw=\(capabilities.firmwareData.hexadecimalString)")
            }
        case 0x0C:
            log("MIC_OPEN_ERROR payload=\(data.dropFirst().map { String(format: "%02X", $0) }.joined(separator: " "))")
        default:
            log("Unknown control command 0x\(String(format: "%02X", command))")
        }
    }

    private func handleAudio(_ data: Data) {
        guard recording else {
            log("Audio frame received before AUDIO_START (\(data.count) bytes)")
            return
        }

        let decodedSamples = decoder.decode(data)
        samples.append(contentsOf: decodedSamples)
        if sharedAudioWriter?.write(samples: decodedSamples, sampleRate: sampleRate) == false {
            log("Unable to write decoded audio to the virtual microphone ring")
        }
        audioFrameCount += 1
        if audioFrameCount == 1 || audioFrameCount.isMultiple(of: 50) {
            log("Audio frames=\(audioFrameCount) samples=\(samples.count)")
        }
    }

    private func requestMicrophone() {
        guard let peripheral, let transmitCharacteristic else {
            log("Cannot request microphone before TX characteristic is ready")
            return
        }

        write(ATVVoiceProtocol.microphoneOpen(), to: transmitCharacteristic, on: peripheral)
        closeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.closeMicrophone() }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + recordingDuration, execute: item)
    }

    private func closeMicrophone() {
        guard let peripheral, let transmitCharacteristic else { return }
        log("Capture timer elapsed; sending MIC_CLOSE stream=\(streamID)")
        write(ATVVoiceProtocol.microphoneClose(streamID: streamID), to: transmitCharacteristic, on: peripheral)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.recording else { return }
            self.stopCapture(reason: "MIC_CLOSE fallback timeout")
        }
    }

    private func stopCapture(reason: String) {
        guard recording else { return }
        recording = false
        statusMenu.setMicrophoneStatus("就绪")
        closeWorkItem?.cancel()

        let fileName = "capture-\(timestampFormatter.string(from: Date()))-\(sampleRate)Hz.wav"
        let outputURL = applicationSupportDirectory.appendingPathComponent(fileName)
        do {
            try WAVWriter.writePCM16Mono(samples: samples, sampleRate: sampleRate, to: outputURL)
            log("Saved \(samples.count) samples (\(audioFrameCount) frames) to \(outputURL.path); reason=\(reason)")
        } catch {
            log("Failed to save WAV: \(error.localizedDescription)")
        }
    }

    private func write(_ data: Data, to characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse
            : .withResponse
        log("TX => \(data.hexadecimalString)")
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    private func isTargetRemote(_ peripheral: CBPeripheral) -> Bool {
        guard let name = peripheral.name?.lowercased() else { return false }
        return name.contains("小米蓝牙语音遥控器") || name.contains("xiaomi") || name.contains("remote")
    }

    private func unique(_ peripherals: [CBPeripheral]) -> [CBPeripheral] {
        var seen = Set<UUID>()
        return peripherals.filter { seen.insert($0.identifier).inserted }
    }

    private func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

private extension CBManagerState {
    var description: String {
        switch self {
        case .unknown: "unknown"
        case .resetting: "resetting"
        case .unsupported: "unsupported"
        case .unauthorized: "unauthorized"
        case .poweredOff: "poweredOff"
        case .poweredOn: "poweredOn"
        @unknown default: "future(\(rawValue))"
        }
    }
}

private extension CBManagerAuthorization {
    var description: String {
        switch self {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .allowedAlways: "allowedAlways"
        @unknown default: "future(\(rawValue))"
        }
    }
}

private extension CBPeripheralState {
    var description: String {
        switch self {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnecting: "disconnecting"
        @unknown default: "future(\(rawValue))"
        }
    }
}

private extension CBCharacteristicProperties {
    var description: String {
        var names: [String] = []
        if contains(.broadcast) { names.append("broadcast") }
        if contains(.read) { names.append("read") }
        if contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if contains(.write) { names.append("write") }
        if contains(.notify) { names.append("notify") }
        if contains(.indicate) { names.append("indicate") }
        if contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        return names.joined(separator: ",")
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let statusMenu = RC001StatusMenu()
let probe = RC001VoiceProbe(statusMenu: statusMenu)
statusMenu.retryHIDAccessHandler = { [weak probe] in
    probe?.retryHIDAccess()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    statusMenu.showPermissionsIfNeeded()
}
if CommandLine.arguments.contains("--show-permissions") {
    DispatchQueue.main.async {
        statusMenu.showPermissions()
    }
} else if CommandLine.arguments.contains("--show-settings") {
    DispatchQueue.main.async {
        statusMenu.showSettings()
    }
}
withExtendedLifetime(probe) {
    application.run()
}
