import Foundation

public enum WAVWriter {
    public static func writePCM16Mono(samples: [Int16], sampleRate: Int, to url: URL) throws {
        let dataByteCount = samples.count * MemoryLayout<Int16>.size
        guard dataByteCount <= Int(UInt32.max) - 36 else {
            throw WAVWriterError.recordingTooLarge
        }

        var output = Data()
        output.reserveCapacity(44 + dataByteCount)
        output.append(contentsOf: "RIFF".utf8)
        appendLittleEndian(UInt32(36 + dataByteCount), to: &output)
        output.append(contentsOf: "WAVE".utf8)
        output.append(contentsOf: "fmt ".utf8)
        appendLittleEndian(UInt32(16), to: &output)
        appendLittleEndian(UInt16(1), to: &output)
        appendLittleEndian(UInt16(1), to: &output)
        appendLittleEndian(UInt32(sampleRate), to: &output)
        appendLittleEndian(UInt32(sampleRate * 2), to: &output)
        appendLittleEndian(UInt16(2), to: &output)
        appendLittleEndian(UInt16(16), to: &output)
        output.append(contentsOf: "data".utf8)
        appendLittleEndian(UInt32(dataByteCount), to: &output)
        for sample in samples {
            appendLittleEndian(UInt16(bitPattern: sample), to: &output)
        }

        try output.write(to: url, options: .atomic)
    }

    private static func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

public enum WAVWriterError: Error {
    case recordingTooLarge
}
