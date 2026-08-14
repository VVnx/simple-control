import Foundation
import RC001SharedAudio
import XCTest
@testable import RC001Core

final class RC001CoreTests: XCTestCase {
    func testDecoderUsesHighNibbleFirst() {
        var decoder = IMAADPCMDecoder()
        XCTAssertEqual(decoder.decode(Data([0x11])), [1, 2])
    }

    func testDecoderHandlesNegativeNibbles() {
        var decoder = IMAADPCMDecoder()
        XCTAssertEqual(decoder.decode(Data([0xFF])), [-11, -41])
    }

    func testCapabilityResponseParsing() {
        let data = Data([0x0B, 0x01, 0x00, 0x03, 0x00, 0x00, 0xA0, 0x01, 0x00, 0x12, 0x34])
        let result = ATVCapabilities(controlData: data)
        XCTAssertEqual(result?.version, 0x0100)
        XCTAssertEqual(result?.codecs, 0x03)
        XCTAssertEqual(result?.interactionModel, 0x00)
        XCTAssertEqual(result?.audioFrameSize, 160)
        XCTAssertEqual(result?.firmwareData, Data([0x12, 0x34]))
    }

    func testWAVWriterProducesPCMHeader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WAVWriter.writePCM16Mono(samples: [0, 1, -1], sampleRate: 16_000, to: url)
        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 50)
    }

    func testSharedAudioRingUpsamplesAndDuplicatesMono() throws {
        let writer = try XCTUnwrap(
            RC001AudioRingWriterCreate(),
            "shared audio errno=\(RC001AudioRingLastError())"
        )
        defer { RC001AudioRingWriterDestroy(writer) }

        RC001AudioRingWriterBeginStream(writer)
        let source: [Int16] = [0, 16_384, -16_384]
        XCTAssertTrue(source.withUnsafeBufferPointer { buffer in
            RC001AudioRingWriterWritePCM16(writer, buffer.baseAddress, buffer.count, 16_000)
        })

        let reader = try XCTUnwrap(RC001AudioRingReaderOpen())
        defer { RC001AudioRingReaderClose(reader) }
        var stereo = Array(repeating: Float.zero, count: 18)
        let framesRead = stereo.withUnsafeMutableBufferPointer { buffer in
            RC001AudioRingReaderReadStereoFloat32(reader, buffer.baseAddress, 9)
        }

        XCTAssertEqual(framesRead, 9)
        XCTAssertEqual(stereo[0...5], [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(stereo[6...11], [0.5, 0.5, 0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(stereo[12...17], [-0.5, -0.5, -0.5, -0.5, -0.5, -0.5])
    }
}
