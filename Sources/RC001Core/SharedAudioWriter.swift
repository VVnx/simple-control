import Foundation
import RC001SharedAudio

public final class SharedAudioWriter {
    private let handle: OpaquePointer

    public init?() {
        guard let handle = RC001AudioRingWriterCreate() else { return nil }
        self.handle = handle
    }

    deinit {
        RC001AudioRingWriterDestroy(handle)
    }

    public func beginStream() {
        RC001AudioRingWriterBeginStream(handle)
    }

    @discardableResult
    public func write(samples: [Int16], sampleRate: Int) -> Bool {
        guard sampleRate > 0 else { return false }
        return samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return samples.isEmpty }
            return RC001AudioRingWriterWritePCM16(
                handle,
                baseAddress,
                buffer.count,
                UInt32(sampleRate)
            )
        }
    }
}
