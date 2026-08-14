import Foundation

public enum ATVVoiceProtocol {
    public static let serviceUUID = "AB5E0001-5A21-4F05-BC7D-AF01F617B664"
    public static let transmitCharacteristicUUID = "AB5E0002-5A21-4F05-BC7D-AF01F617B664"
    public static let audioCharacteristicUUID = "AB5E0003-5A21-4F05-BC7D-AF01F617B664"
    public static let controlCharacteristicUUID = "AB5E0004-5A21-4F05-BC7D-AF01F617B664"

    /// Google Voice over BLE 1.0, legacy constant 0x0003, On-request mode only.
    /// Keeping On-request mode allows the remote to continue emitting its HID assistant key.
    public static let getCapabilities = Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x00])

    public static func microphoneOpen(mode: UInt8 = 0x00) -> Data {
        Data([0x0C, mode])
    }

    public static func microphoneClose(streamID: UInt8) -> Data {
        Data([0x0D, streamID])
    }
}

public enum ATVAudioCodec: UInt8, Equatable {
    case adpcm8kHz = 0x01
    case adpcm16kHz = 0x02

    public var sampleRate: Int {
        switch self {
        case .adpcm8kHz: 8_000
        case .adpcm16kHz: 16_000
        }
    }
}

public struct ATVCapabilities: Equatable {
    public let version: UInt16
    public let codecs: UInt8
    public let interactionModel: UInt8
    public let audioFrameSize: UInt16
    public let extraConfiguration: UInt8
    public let firmwareData: Data

    public init?(controlData: Data) {
        guard controlData.count >= 9, controlData[0] == 0x0B else { return nil }
        version = UInt16(controlData[1]) << 8 | UInt16(controlData[2])
        codecs = controlData[3]
        interactionModel = controlData[4]
        audioFrameSize = UInt16(controlData[5]) << 8 | UInt16(controlData[6])
        extraConfiguration = controlData[7]
        firmwareData = controlData.count > 9 ? controlData.subdata(in: 9..<controlData.count) : Data()
    }
}

public struct ATVAudioStart: Equatable {
    public let reason: UInt8
    public let codec: ATVAudioCodec
    public let streamID: UInt8

    public init?(controlData: Data) {
        guard controlData.count >= 4,
              controlData[0] == 0x04,
              let codec = ATVAudioCodec(rawValue: controlData[2])
        else { return nil }
        reason = controlData[1]
        self.codec = codec
        streamID = controlData[3]
    }
}

public struct ATVAudioSync: Equatable {
    public let codec: ATVAudioCodec
    public let frameNumber: UInt16
    public let predictor: Int16
    public let stepIndex: Int

    public init?(controlData: Data) {
        guard controlData.count >= 7,
              controlData[0] == 0x0A,
              let codec = ATVAudioCodec(rawValue: controlData[1])
        else { return nil }

        self.codec = codec
        frameNumber = UInt16(controlData[2]) << 8 | UInt16(controlData[3])
        predictor = Int16(bitPattern: UInt16(controlData[4]) << 8 | UInt16(controlData[5]))
        stepIndex = Int(controlData[6])
    }
}

public extension Data {
    var hexadecimalString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
