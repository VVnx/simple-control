import Foundation

/// Google ATV Voice uses standard IMA ADPCM and decodes the high nibble first.
public struct IMAADPCMDecoder {
    private static let indexTable = [
        -1, -1, -1, -1, 2, 4, 6, 8,
        -1, -1, -1, -1, 2, 4, 6, 8,
    ]

    private static let stepTable = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17,
        19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    private var predictor: Int = 0
    private var stepIndex: Int = 0

    public init(predictor: Int16 = 0, stepIndex: Int = 0) {
        reset(predictor: predictor, stepIndex: stepIndex)
    }

    public mutating func reset(predictor: Int16 = 0, stepIndex: Int = 0) {
        self.predictor = Int(predictor)
        self.stepIndex = min(max(stepIndex, 0), Self.stepTable.count - 1)
    }

    public mutating func decode(_ data: Data) -> [Int16] {
        var samples: [Int16] = []
        samples.reserveCapacity(data.count * 2)

        for byte in data {
            samples.append(decodeNibble(Int(byte >> 4)))
            samples.append(decodeNibble(Int(byte & 0x0F)))
        }
        return samples
    }

    private mutating func decodeNibble(_ nibble: Int) -> Int16 {
        let step = Self.stepTable[stepIndex]
        var difference = step >> 3

        if nibble & 0x04 != 0 { difference += step }
        if nibble & 0x02 != 0 { difference += step >> 1 }
        if nibble & 0x01 != 0 { difference += step >> 2 }

        predictor += nibble & 0x08 != 0 ? -difference : difference
        predictor = min(max(predictor, Int(Int16.min)), Int(Int16.max))

        stepIndex += Self.indexTable[nibble]
        stepIndex = min(max(stepIndex, 0), Self.stepTable.count - 1)
        return Int16(predictor)
    }
}
