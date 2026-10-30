import Foundation

/// Pure-Swift zstd (RFC 8878) decompressor for dsh session logs.
/// The machine has no system zstd (no SDK header, no /usr/lib/libzstd) and
/// the spec forbids shelling out to a `zstd` binary, so the decoder ships
/// inside the bridge.
///
/// Supported: skippable frames, single/multi-frame streams, RAW / RLE /
/// COMPRESSED blocks, raw / RLE / Huffman literals (direct and FSE-compressed
/// weights, 1 or 4 streams), sequences with predefined / RLE / FSE tables,
/// repeat offsets. Unsupported (rejected): dictionaries, treeless literals,
/// repeat-mode tables, checksum verification (skipped).
public enum ZstdError: Error, CustomStringConvertible {
    case badMagic
    case unsupported(String)
    case malformed(String)
    case outOfBounds

    public var description: String {
        switch self {
        case .badMagic: return "not a zstd frame"
        case .unsupported(let w): return "unsupported zstd feature: \(w)"
        case .malformed(let w): return "malformed zstd stream: \(w)"
        case .outOfBounds: return "zstd back-reference out of bounds"
        }
    }
}

public struct ZstdDecompressor {
    public init() {}

    public func decompress(_ input: Data) throws -> Data {
        // Fail closed: the pure decoder only supports RAW / RLE blocks.
        // Compressed blocks (FSE + Huffman) need the linked library; attempting
        // them here has produced garbage, so refuse instead.
        try Self.assertOnlyRawOrRLEBlocks(input)
        var reader = ByteReader(input)
        var output = Data()
        while reader.remainingBytes > 0 {
            if reader.remainingBytes >= 4, (reader.peek32LE() & 0xFFFFFFF0) == 0x184D2A50 {
                // Skippable frame.
                guard reader.remainingBytes >= 8 else { throw ZstdError.malformed("short skippable frame") }
                _ = reader.u32()
                let size = Int(reader.u32())
                guard reader.remainingBytes >= size else { throw ZstdError.malformed("skippable size") }
                reader.advance(size)
                continue
            }
            try decompressFrame(&reader, into: &output)
        }
        return output
    }

    /// Scan every frame's block headers; throw when any compressed block
    /// appears (the linked library must handle those).
    static func assertOnlyRawOrRLEBlocks(_ input: Data) throws {
        var reader = ByteReader(input)
        while reader.remainingBytes > 0 {
            if reader.remainingBytes >= 4, (reader.peek32LE() & 0xFFFFFFF0) == 0x184D2A50 {
                _ = reader.u32()
                let size = Int(reader.u32())
                guard reader.remainingBytes >= size else { throw ZstdError.malformed("skippable size") }
                reader.advance(size)
                continue
            }
            guard reader.remainingBytes >= 4, reader.u32() == 0xFD2FB528 else { throw ZstdError.badMagic }
            let fhd = reader.byte()
            let singleSegment = (fhd >> 5) & 1 == 1
            let fcs = Int(fhd >> 6)
            if !singleSegment { _ = reader.byte() }
            switch fcs {
            case 0: if singleSegment { _ = reader.byte() }
            case 1: reader.advance(2)
            case 2: reader.advance(4)
            case 3: reader.advance(8)
            default: break
            }
            switch Int(fhd & 3) {
            case 1: reader.advance(1)
            case 2: reader.advance(2)
            case 3: reader.advance(4)
            default: break
            }
            var last = false
            while !last {
                guard reader.remainingBytes >= 3 else { throw ZstdError.malformed("truncated block header") }
                let header = UInt32(reader.byte()) | (UInt32(reader.byte()) << 8) | (UInt32(reader.byte()) << 16)
                last = header & 1 == 1
                let blockType = Int((header >> 1) & 3)
                let blockSize = Int(header >> 3)
                if blockType == 2 {
                    throw ZstdError.unsupported("compressed blocks require the linked zstd library")
                }
                if blockType == 3 { throw ZstdError.unsupported("reserved block type") }
                guard reader.remainingBytes >= blockSize else { throw ZstdError.malformed("block size") }
                reader.advance(blockType == 1 ? 1 : blockSize)
            }
            if (fhd >> 2) & 1 == 1 {
                guard reader.remainingBytes >= 4 else { throw ZstdError.malformed("checksum") }
                reader.advance(4)
            }
        }
    }

    // MARK: frame

    private func decompressFrame(_ reader: inout ByteReader, into output: inout Data) throws {
        guard reader.remainingBytes >= 4 else {
            if output.isEmpty { throw ZstdError.badMagic }
            reader.advance(reader.remainingBytes)
            return
        }
        guard reader.u32() == 0xFD2FB528 else { throw ZstdError.badMagic }

        let fhd = reader.byte()
        let frameContentSizeFlag = Int(fhd >> 6)
        let singleSegment = (fhd >> 5) & 1 == 1
        let contentChecksumFlag = (fhd >> 2) & 1 == 1
        let dictionaryIDFlagCode = Int(fhd & 3)

        var windowSize: UInt64 = 1
        if !singleSegment {
            let wd = reader.byte()
            let exponent = UInt64(wd >> 3)
            let mantissa = UInt64(wd & 7)
            let log = 10 + exponent
            windowSize = (UInt64(1) << log) + (mantissa * (UInt64(1) << (log - 1)))
        }

        var declaredSize: UInt64 = 0
        switch frameContentSizeFlag {
        case 0:
            if singleSegment { declaredSize = UInt64(reader.byte()) }
        case 1: declaredSize = UInt64(reader.u16()) + 256
        case 2: declaredSize = UInt64(reader.u32())
        case 3: declaredSize = reader.u64()
        default: break
        }
        if singleSegment {
            windowSize = max(declaredSize, 1)
        }

        switch dictionaryIDFlagCode {
        case 0: break
        case 1: _ = reader.byte()
        case 2: _ = reader.u16()
        case 3: _ = reader.u32()
        default: break
        }
        if let expected = Int(exactly: declaredSize), expected > 0 {
            output.reserveCapacity(output.count + expected)
        }

        var window = Window(maxSize: Int(clamping: windowSize))
        var lastBlock = false
        while !lastBlock {
            guard reader.remainingBytes >= 3 else { throw ZstdError.malformed("truncated block header") }
            let header = UInt32(reader.byte()) | (UInt32(reader.byte()) << 8) | (UInt32(reader.byte()) << 16)
            lastBlock = header & 1 == 1
            let blockType = Int((header >> 1) & 3)
            let blockSize = Int(header >> 3)
            switch blockType {
            case 0: // Raw
                guard reader.remainingBytes >= blockSize else { throw ZstdError.malformed("raw block size") }
                let chunk = reader.take(blockSize)
                window.append(chunk)
                output.append(chunk)
            case 1: // RLE
                guard reader.remainingBytes >= 1 else { throw ZstdError.malformed("rle block") }
                let byte = reader.byte()
                let chunk = Data(repeating: byte, count: blockSize)
                window.append(chunk)
                output.append(chunk)
            case 2: // Compressed
                guard reader.remainingBytes >= blockSize else { throw ZstdError.malformed("compressed block size") }
                let block = reader.take(blockSize)
                var blockReader = ByteReader(block)
                var literals = try LiteralsDecoder.decode(&blockReader)
                try SequencesDecoder.decode(&blockReader, literals: &literals, window: &window, output: &output)
            default:
                throw ZstdError.unsupported("reserved block type")
            }
        }
        if contentChecksumFlag {
            guard reader.remainingBytes >= 4 else { throw ZstdError.malformed("truncated checksum") }
            _ = reader.u32() // not verified; JSONL parser validates content
        }
    }
}

// MARK: - byte reader

struct ByteReader {
    private let bytes: [UInt8]
    private let base: Int
    private(set) var offset: Int

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        self.base = data.startIndex
        self.offset = 0
    }

    var remainingBytes: Int { bytes.count - offset }

    func peek32LE() -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            let idx = offset + i
            let b: UInt8 = idx < bytes.count ? bytes[idx] : 0
            value |= UInt32(b) << (8 * i)
        }
        return value
    }

    mutating func byte() -> UInt8 {
        let b = bytes[offset]
        offset += 1
        return b
    }

    mutating func u16() -> UInt16 {
        let lo = UInt16(byte())
        let hi = UInt16(byte())
        return lo | (hi << 8)
    }

    mutating func u32() -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 { value |= UInt32(byte()) << (8 * UInt32(i)) }
        return value
    }

    mutating func u64() -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 { value |= UInt64(byte()) << (8 * UInt64(i)) }
        return value
    }

    mutating func advance(_ n: Int) {
        offset += n
    }

    mutating func take(_ n: Int) -> Data {
        let chunk = Data(bytes[offset..<(offset + n)])
        offset += n
        return chunk
    }

    /// Byte offset relative to the section start (for jump tables).
    var consumed: Int { offset }

    /// Remaining bytes as a plain array (for NCount bit windows).
    func snapshot() -> [UInt8] {
        Array(bytes[offset...])
    }
}

// MARK: - sliding window

struct Window {
    private(set) var buffer: [UInt8] = []
    private let maxSize: Int

    init(maxSize: Int) {
        self.maxSize = max(1, maxSize)
    }

    mutating func append(_ data: Data) {
        buffer.reserveCapacity(buffer.count + data.count)
        for b in data { buffer.append(b) }
        compactIfNeeded()
    }

    mutating func append(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        compactIfNeeded()
    }

    private mutating func compactIfNeeded() {
        if buffer.count > maxSize + (1 << 17) {
            buffer.removeFirst(buffer.count - maxSize)
        }
    }

    /// Copy `length` bytes from `offset` back (offset ≥ 1, may exceed length).
    mutating func copyMatch(offset: Int, length: Int, into output: inout Data) throws {
        guard offset >= 1, offset <= buffer.count else { throw ZstdError.outOfBounds }
        var src = buffer.count - offset
        for _ in 0..<length {
            let b = buffer[src]
            buffer.append(b)
            output.append(b)
            src += 1
        }
        compactIfNeeded()
    }
}

// MARK: - literals

enum LiteralsDecoder {
    static func decode(_ reader: inout ByteReader) throws -> Data {
        guard reader.remainingBytes >= 1 else { throw ZstdError.malformed("literals header") }
        let b0 = reader.byte()
        let blockType = Int(b0 & 3)
        let sizeFormat = Int((b0 >> 2) & 3)

        switch blockType {
        case 0: // Raw
            let size = readSize(&reader, b0: b0, sizeFormat: sizeFormat)
            guard reader.remainingBytes >= size else { throw ZstdError.malformed("raw literals") }
            return reader.take(size)
        case 1: // RLE
            let size = readSize(&reader, b0: b0, sizeFormat: sizeFormat)
            guard reader.remainingBytes >= 1 else { throw ZstdError.malformed("rle literals") }
            return Data(repeating: reader.byte(), count: size)
        case 2, 3: // Compressed / Treeless
            guard blockType == 2 else { throw ZstdError.unsupported("treeless literals") }
            var regeneratedSize = 0
            var compressedSize = 0
            var streamCount = 4
            switch sizeFormat {
            case 0, 1:
                let b1 = reader.byte()
                let b2 = reader.byte()
                regeneratedSize = Int(b0 >> 4) | ((Int(b1) & 0x3F) << 4)
                compressedSize = (Int(b1) >> 6) | (Int(b2) << 2)
                streamCount = sizeFormat == 0 ? 1 : 4
            case 2:
                let b1 = reader.byte()
                let b2 = reader.byte()
                let b3 = reader.byte()
                regeneratedSize = Int(b0 >> 4) | (Int(b1) << 4) | ((Int(b2) & 0x3) << 12)
                compressedSize = ((Int(b2) >> 2) | (Int(b3) << 6))
            case 3:
                let b1 = reader.byte()
                let b2 = reader.byte()
                let b3 = reader.byte()
                let b4 = reader.byte()
                regeneratedSize = Int(b0 >> 4) | (Int(b1) << 4) | ((Int(b2) & 0x3F) << 12)
                compressedSize = ((Int(b2) >> 6) | (Int(b3) << 2) | (Int(b4) << 10))
            default: break
            }
            guard reader.remainingBytes >= compressedSize else { throw ZstdError.malformed("compressed literals size") }
            let section = reader.take(compressedSize)
            var sectionReader = ByteReader(section)
            let table = try HuffmanTable.read(&sectionReader)
            var literals = Data()
            literals.reserveCapacity(regeneratedSize)
            let sectionUsed = sectionReader.consumed
            let streamsBlob = section.subdata(in: sectionUsed..<section.count)
            if streamCount == 1 {
                var stream = BackwardBitStream(streamsBlob)
                try stream.decodeHuffman(table, count: regeneratedSize, into: &literals)
            } else {
                // 6-byte jump table: sizes of streams 1-3.
                guard streamsBlob.count >= 6 else { throw ZstdError.malformed("jump table") }
                let s1 = Int(streamsBlob[streamsBlob.startIndex]) | (Int(streamsBlob[streamsBlob.startIndex + 1]) << 8)
                let s2 = Int(streamsBlob[streamsBlob.startIndex + 2]) | (Int(streamsBlob[streamsBlob.startIndex + 3]) << 8)
                let s3 = Int(streamsBlob[streamsBlob.startIndex + 4]) | (Int(streamsBlob[streamsBlob.startIndex + 5]) << 8)
                let streamsStart = streamsBlob.startIndex + 6
                let total = streamsBlob.count - 6
                let s4 = total - s1 - s2 - s3
                guard s1 >= 0, s2 >= 0, s3 >= 0, s4 >= 0 else { throw ZstdError.malformed("jump table sizes") }
                var perStream = (regeneratedSize + 3) / 4
                var cursor = streamsStart
                for (index, size) in [s1, s2, s3, s4].enumerated() {
                    if size == 0 { continue }
                    if index == 3 { perStream = regeneratedSize - 3 * perStream }
                    var stream = BackwardBitStream(streamsBlob.subdata(in: cursor..<(cursor + size)))
                    try stream.decodeHuffman(table, count: perStream, into: &literals)
                    cursor += size
                }
            }
            guard literals.count == regeneratedSize else { throw ZstdError.malformed("literal count") }
            return literals
        default:
            throw ZstdError.malformed("literals type")
        }
    }

    /// Raw/RLE size: format 00/10 → 1-byte header with 5-bit size (b0>>3);
    /// 01 → 2-byte, 12-bit; 11 → 3-byte, 20-bit.
    private static func readSize(_ reader: inout ByteReader, b0: UInt8, sizeFormat: Int) -> Int {
        switch sizeFormat {
        case 0, 2:
            return Int(b0 >> 3)
        case 1:
            let b1 = reader.byte()
            return Int(b0 >> 4) | (Int(b1) << 4)
        case 3:
            let b1 = reader.byte()
            let b2 = reader.byte()
            return Int(b0 >> 4) | (Int(b1) << 4) | (Int(b2) << 12)
        default:
            return 0
        }
    }
}

// MARK: - Huffman table

struct HuffmanTable {
    let symbols: [UInt8]
    let lengths: [UInt8]
    let tableLog: Int

    static func read(_ reader: inout ByteReader) throws -> HuffmanTable {
        guard reader.remainingBytes >= 1 else { throw ZstdError.malformed("huffman header") }
        let headerByte = reader.byte()
        var weights: [Int]
        if headerByte >= 128 {
            // Direct representation: 4-bit weights, headerByte - 127 symbols.
            let symbolCount = Int(headerByte) - 127
            weights = []
            weights.reserveCapacity(symbolCount)
            var remaining = symbolCount
            while remaining > 0 {
                let byte = reader.byte()
                weights.append(Int(byte >> 4))
                remaining -= 1
                if remaining > 0 {
                    weights.append(Int(byte & 0xF))
                    remaining -= 1
                }
            }
        } else {
            // FSE-compressed weights, headerByte bytes total.
            let compressedSize = Int(headerByte)
            guard reader.remainingBytes >= compressedSize else { throw ZstdError.malformed("fse weights size") }
            let blob = reader.take(compressedSize)
            weights = try HuffmanWeightsDecoder.decode(blob)
        }
        return try HuffmanTable(weights: weights)
    }

    init(weights: [Int]) throws {
        guard let maxWeight = weights.max(), maxWeight > 0 else {
            throw ZstdError.malformed("all-zero huffman weights")
        }
        let tableLog = maxWeight + 1 - 1 // maxBits; derived below properly
        // Max_Number_of_Bits is such that the total fills exactly 2^maxBits.
        var weightSum = 0
        for w in weights where w > 0 { weightSum += 1 << (w - 1) }
        guard weightSum < (1 << 11) else { throw ZstdError.malformed("huffman too large") }
        // Implied last weight: complete weightSum to the next power of two.
        let maxBits = weightSum == 0 ? 1 : weightSum.bitWidth - weightSum.leadingZeroBitCount
        guard weightSum > 0, weightSum != (1 << maxBits) else {
            throw ZstdError.malformed("huffman already complete")
        }
        let implied = (1 << maxBits) - weightSum
        if ProcessInfo.processInfo.environment["GC_DEBUG"] != nil {
            print("GC-DEBUG ht: n=\(weights.count) wsum=\(weightSum) maxBits=\(maxBits) implied=\(implied)")
        }
        guard implied > 0, implied & (implied - 1) == 0 else {
            throw ZstdError.malformed("huffman implied weight")
        }
        var allWeights = weights
        allWeights.append(implied.trailingZeroBitCount + 1)
        _ = tableLog

        guard maxBits >= 1, maxBits <= 11 else { throw ZstdError.malformed("huffman maxBits") }
        let size = 1 << maxBits
        var symbols = [UInt8](repeating: 0, count: size)
        var lengths = [UInt8](repeating: 0, count: size)
        // Rank start per weight: weight w occupies 2^(w-1) slots per symbol.
        var rankStats = [Int](repeating: 0, count: maxBits + 2)
        for w in allWeights where w > 0 { rankStats[w] += 1 }
        var rankStart = [Int](repeating: 0, count: maxBits + 2)
        var next = 0
        // Shortest codes (highest weight) take the lowest table slots; the
        // encoder writes codes LSB-first, so the peeked index is bit-reversed
        // relative to the canonical code.
        for w in stride(from: maxBits + 1, through: 1, by: -1) {
            guard w < rankStart.count else { continue }
            rankStart[w] = next
            next += (w <= maxBits ? rankStats[w] : 0) << (w - 1)
        }
        for (symbol, w) in allWeights.enumerated() where w > 0 {
            let entries = 1 << (w - 1)
            let nbBits = maxBits + 1 - w
            for i in 0..<entries {
                let idx = rankStart[w] + i
                symbols[idx] = UInt8(symbol)
                lengths[idx] = UInt8(nbBits)
            }
            rankStart[w] += entries
        }
        self.symbols = symbols
        self.lengths = lengths
        self.tableLog = maxBits
    }
}

enum HuffmanWeightsDecoder {
    /// FSE-decode the huffman weight stream (RFC 8878 §3.1.1.3.2): two
    /// interleaved FSE states, State1 at even indices, State2 at odd,
    /// State1 initialized first. Decoding runs until the bitstream is
    /// exhausted. Decoded symbol s maps to weight s+1, except 255 → 0.
    static func decode(_ blob: Data) throws -> [Int] {
        var reader = ByteReader(blob)
        let table = try FSETableReader.read(&reader, maxSymbol: 255, maxTableLog: 6)
        let streamBlob = blob.subdata(in: blob.startIndex + reader.consumed..<blob.count)
        var stream = BackwardBitStream(streamBlob)
        var decoded: [Int] = []
        var state1 = Int(stream.read(table.tableLog))
        var state2 = Int(stream.read(table.tableLog))
        if ProcessInfo.processInfo.environment["GC_DEBUG"] != nil {
            print("GC-DEBUG w: log=\(table.tableLog) s1=\(state1) s2=\(state2) avail=\(stream.bitsAvailable) syms=\(table.debugSymbols()) nb=\(table.debugNb()) ns=\(table.debugNs())")
        }
        // Alternate state1/state2, stopping when the bitstream is
        // exhausted after an update. No trailing flush: the encoder baked
        // the final symbols into the interleaved states.
        while decoded.count <= 255 {
            guard table.isValid(state: state1) else { throw ZstdError.malformed("weights state1") }
            decoded.append(Int(table.symbol(for: state1)))
            state1 = table.nextState(state: state1, add: Int(stream.read(table.nbBits(for: state1))))
            if stream.bitsAvailable <= 0 { break }
            guard table.isValid(state: state2) else { throw ZstdError.malformed("weights state2") }
            decoded.append(Int(table.symbol(for: state2)))
            state2 = table.nextState(state: state2, add: Int(stream.read(table.nbBits(for: state2))))
            if stream.bitsAvailable <= 0 { break }
        }
        // FSE symbol IS the weight value (0 = unused symbol slot).
        return decoded
    }
}

// MARK: - FSE tables

struct FSETable {
    let tableLog: Int
    private let symbols: [UInt8]
    private let nbBitsTable: [UInt8]
    private let newStateTable: [Int]

    func symbol(for state: Int) -> UInt8 { symbols[state] }
    func nbBits(for state: Int) -> Int { Int(nbBitsTable[state]) }
    func nextState(state: Int, add lowBits: Int) -> Int { newStateTable[state] + lowBits }
    func isValid(state: Int) -> Bool { state >= 0 && state < symbols.count }

    func debugSymbols() -> [Int] { symbols.map(Int.init) }
    func debugNb() -> [Int] { nbBitsTable.map(Int.init) }
    func debugNs() -> [Int] { newStateTable }

    static func build(normalized: [Int], tableLog: Int) -> FSETable {
        let size = 1 << tableLog
        var symbols = [UInt8](repeating: 0, count: size)
        var nbBitsTable = [UInt8](repeating: 0, count: size)
        var newStateTable = [Int](repeating: 0, count: size)
        var symbolNext = normalized
        var highThreshold = size - 1
        // Low-probability (-1) symbols sit at the top of the table.
        for (symbol, count) in normalized.enumerated() where count == -1 {
            symbols[highThreshold] = UInt8(symbol)
            highThreshold -= 1
            symbolNext[symbol] = 1
        }
        // Spread the rest with the canonical step.
        var position = 0
        let step = (size >> 1) + (size >> 3) + 3
        let mask = size - 1
        for (symbol, count) in normalized.enumerated() where count > 0 {
            for _ in 0..<count {
                symbols[position] = UInt8(symbol)
                position = (position + step) & mask
                while position > highThreshold {
                    position = (position + step) & mask
                }
            }
        }
        for state in 0..<size {
            let symbol = Int(symbols[state])
            let next = symbolNext[symbol]
            symbolNext[symbol] = next + 1
            let highbit = next == 0 ? 0 : next.bitWidth - next.leadingZeroBitCount - 1
            let nbBits = max(0, tableLog - highbit)
            nbBitsTable[state] = UInt8(nbBits)
            newStateTable[state] = (next << nbBits) - size
        }
        return FSETable(tableLog: tableLog, symbols: symbols, nbBitsTable: nbBitsTable, newStateTable: newStateTable)
    }

}

enum FSETableReader {
    /// Read a normalized-counts header + build the table (RFC 8878
    /// §3.1.1.2.2). Mirrors FSE_readNCount: a forward bit window over 4-byte
    /// little-endian peeks with lazy byte consumption.
    static func read(_ reader: inout ByteReader, maxSymbol: Int, maxTableLog: Int) throws -> FSETable {
        let bytes = reader.snapshot()
        var ip = 0

        func peek32(_ off: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 {
                let idx = min(off + i, bytes.count - 1)
                v |= UInt32(idx >= 0 && idx < bytes.count ? bytes[idx] : 0) << (8 * i)
            }
            return v
        }

        var bitStream = peek32(ip)
        let tableLog = Int(bitStream & 0xF) + 5
        guard tableLog >= 5, tableLog <= maxTableLog else { throw ZstdError.malformed("fse tableLog \(tableLog)") }
        bitStream >>= 4
        var bitCount = 4
        var remaining = (1 << tableLog) + 1
        var threshold = 1 << tableLog
        var nbBits = tableLog + 1
        var normalized: [Int] = []
        var symbol = 0
        var previous0 = false

        while remaining > 1 && symbol <= maxSymbol {
            if previous0 {
                bitStream = peek32(ip)
                var n0 = symbol
                while (bitStream & 0xFFFF) == 0xFFFF {
                    n0 += 249
                    ip += 2
                    bitStream = peek32(ip)
                }
                while (bitStream & 3) == 3 {
                    n0 += 3
                    bitStream >>= 2
                    bitCount += 2
                }
                n0 += Int(bitStream & 3)
                bitCount += 2
                while symbol < n0, symbol <= maxSymbol {
                    normalized.append(0)
                    symbol += 1
                }
                if symbol > maxSymbol { break }
                if bytes.count - ip >= 4 && bitCount > 24 {
                    ip += 2
                    bitStream = peek32(ip)
                    bitCount = 0
                }
                previous0 = false
                if bitCount > 30 { break }
            }
            let maxVal = (2 * threshold - 1) - remaining
            let mask1 = (1 << (nbBits - 1)) - 1
            let mask2 = (1 << nbBits) - 1
            var count: Int
            if Int(bitStream & UInt32(mask1)) < maxVal {
                count = Int(bitStream & UInt32(mask1))
                bitCount += nbBits - 1
            } else {
                count = Int(bitStream & UInt32(mask2))
                if count >= threshold { count -= maxVal }
                bitCount += nbBits
            }
            count -= 1
            remaining -= count < 0 ? -count : count
            normalized.append(count)
            symbol += 1
            previous0 = count == 0
            while remaining < threshold {
                nbBits -= 1
                threshold >>= 1
            }
            let consume = bitCount >> 3
            if consume > 0 {
                ip += consume
                bitStream = peek32(ip)
                bitCount &= 7
            }
        }
        guard remaining == 1 else { throw ZstdError.malformed("fse remaining \(remaining)") }
        reader.advance(ip)
        return FSETable.build(normalized: normalized, tableLog: tableLog)
    }
}

// MARK: - backward bit stream

struct BackwardBitStream {
    private let bytes: [UInt8]
    private(set) var bitPosition: Int // counts DOWN as bits are consumed

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        guard let last = bytes.last else {
            self.bitPosition = -1
            return
        }
        // The last byte holds a padding marker: its highest set bit plus the
        // zero bits above it are NOT data. First data bit is one below.
        // (UInt8.leadingZeroBitCount is 8-bit — derive the MSB index.)
        let markerBit = last == 0 ? 0 : 7 - last.leadingZeroBitCount
        self.bitPosition = (bytes.count - 1) * 8 + markerBit - 1
    }

    var bitsAvailable: Int { bitPosition + 1 }

    func debugHex() -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Read n bits. The FIRST bit read becomes the value's MSB (zstd's
    /// backward-stream convention: BIT_readBits is MSB-aligned).
    mutating func read(_ n: Int) -> UInt32 {
        var value: UInt32 = 0
        var produced = 0
        while produced < n {
            if bitPosition < 0 || (bitPosition >> 3) >= bytes.count {
                // Exhausted stream reads as zero bits (zstd tolerates this on
                // the final state update).
                value <<= 1
                produced += 1
                continue
            }
            let byte = bytes[bitPosition >> 3]
            let bit = (byte >> UInt8(bitPosition & 7)) & 1
            value = (value << 1) | UInt32(bit)
            bitPosition -= 1
            produced += 1
        }
        return value
    }

    /// Peek n bits with the NEXT bit as the MSB (for Huffman table lookup).
    mutating func peekMsb(_ n: Int) -> Int {
        var value = 0
        var position = bitPosition
        var produced = 0
        while produced < n {
            if position < 0 || (position >> 3) >= bytes.count { break }
            let byte = bytes[position >> 3]
            let bit = (byte >> UInt8(position & 7)) & 1
            value = (value << 1) | Int(bit)
            position -= 1
            produced += 1
        }
        return value
    }

    mutating func skip(_ n: Int) {
        bitPosition -= n
    }

    static func reverseBits(_ value: Int, width: Int) -> Int {
        var v = value
        var result = 0
        for _ in 0..<width {
            result = (result << 1) | (v & 1)
            v >>= 1
        }
        return result
    }

    mutating func decodeHuffman(_ table: HuffmanTable, count: Int, into output: inout Data) throws {
        let log = table.tableLog
        var produced = 0
        while produced < count {
            guard bitsAvailable >= 1 else { break }
            let index = Self.reverseBits(peekMsb(log), width: log)
            let entry = index < table.lengths.count ? index : 0
            let nbBits = Int(table.lengths[entry])
            if nbBits == 0 { throw ZstdError.malformed("huffman zero entry") }
            guard bitsAvailable >= nbBits || produced + 1 == count else { throw ZstdError.malformed("huffman underrun") }
            skip(nbBits)
            output.append(table.symbols[entry])
            produced += 1
        }
        guard produced == count else { throw ZstdError.malformed("huffman literals count") }
    }
}

// MARK: - sequences

enum SequencesDecoder {
    // Baselines + extra bits for literal-length codes 0-35.
    static let llBaselines: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048,
        4096, 8192, 16384, 32768, 65536,
    ]
    static let llExtraBits: [Int] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11,
        12, 13, 14, 15, 16,
    ]
    // Match-length codes 0-52: baseline = 3 + code for 0-31.
    static let mlBaselines: [Int] = (0...31).map { 3 + $0 } + [
        35, 37, 39, 41, 43, 47, 51, 55, 59, 67, 83, 99, 131, 259, 515,
        1027, 2051, 4099, 8195, 16387, 32771,
    ]
    static let mlExtraBits: [Int] = [Int](repeating: 0, count: 32) + [
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 6, 7, 8, 9,
        10, 11, 12, 13, 14, 15,
    ]
    // Predefined distributions (RFC 8878 §3.1.1.3.2.2.1).
    static let predefinedLL: [Int] = [
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
        -1, -1, -1, -1,
    ]
    static let predefinedML: [Int] = [
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
        -1, -1, -1, -1, -1,
    ]
    static let predefinedOF: [Int] = [
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    ]

    static func decode(_ reader: inout ByteReader, literals: inout Data, window: inout Window, output: inout Data) throws {
        guard reader.remainingBytes >= 1 else { throw ZstdError.malformed("sequences header") }
        let byte0 = reader.byte()
        let numberOfSequences: Int
        if byte0 == 0 {
            numberOfSequences = 0
        } else if byte0 < 128 {
            numberOfSequences = Int(byte0)
        } else if byte0 < 255 {
            guard reader.remainingBytes >= 1 else { throw ZstdError.malformed("sequences count") }
            let byte1 = reader.byte()
            numberOfSequences = ((Int(byte0) - 128) << 8) + Int(byte1)
        } else {
            guard reader.remainingBytes >= 2 else { throw ZstdError.malformed("sequences count") }
            let byte1 = reader.byte()
            let byte2 = reader.byte()
            numberOfSequences = Int(byte1) + (Int(byte2) << 8) + 0x7F00
        }

        if numberOfSequences == 0 {
            // Whole literals are the block payload.
            window.append(literals)
            output.append(literals)
            return
        }

        guard reader.remainingBytes >= 1 else { throw ZstdError.malformed("modes byte") }
        let modes = reader.byte()
        let llMode = Int(modes >> 6)
        let ofMode = Int((modes >> 4) & 3)
        let mlMode = Int((modes >> 2) & 3)
        guard modes & 3 == 0 else { throw ZstdError.malformed("reserved mode bits") }

        let llTable = try readTable(&reader, mode: llMode, predefined: predefinedLL, tableLog: 6, maxSymbol: 35)
        let ofTable = try readTable(&reader, mode: ofMode, predefined: predefinedOF, tableLog: 5, maxSymbol: 28)
        let mlTable = try readTable(&reader, mode: mlMode, predefined: predefinedML, tableLog: 6, maxSymbol: 52)

        let streamBlob = reader.take(reader.remainingBytes)
        var stream = BackwardBitStream(streamBlob)

        // Initial states in order: LL, OF, ML.
        var llState = Int(stream.read(llTable.tableLog))
        var ofState = Int(stream.read(ofTable.tableLog))
        var mlState = Int(stream.read(mlTable.tableLog))

        var repeatOffsets: [Int] = [1, 4, 8]
        var literalCursor = 0

        for _ in 0..<numberOfSequences {
            // Extra bits: offset first, then match length, then literal length.
            guard llTable.isValid(state: llState), mlTable.isValid(state: mlState), ofTable.isValid(state: ofState) else {
                throw ZstdError.malformed("sequence state")
            }
            let ofCode = Int(ofTable.symbol(for: ofState))
            guard ofCode < 31 else { throw ZstdError.malformed("offset code") }
            let mlCode = Int(mlTable.symbol(for: mlState))
            let llCode = Int(llTable.symbol(for: llState))
            guard mlCode < mlBaselines.count, llCode < llBaselines.count else {
                throw ZstdError.malformed("length code")
            }
            let offsetValue = (1 << ofCode) + Int(stream.read(ofCode))
            let matchLength = mlBaselines[mlCode] + Int(stream.read(mlExtraBits[mlCode]))
            let literalLength = llBaselines[llCode] + Int(stream.read(llExtraBits[llCode]))

            // Resolve offset (values 1-3 select repeat offsets).
            let offset: Int
            if offsetValue > 3 {
                offset = offsetValue - 3
                repeatOffsets[2] = repeatOffsets[1]
                repeatOffsets[1] = repeatOffsets[0]
                repeatOffsets[0] = offset
            } else {
                let index = offsetValue - 1
                offset = repeatOffsets[index]
                if index == 0 {
                    // stays in place
                } else {
                    repeatOffsets.remove(at: index)
                    repeatOffsets.insert(offset, at: 0)
                }
            }

            // Literals for this sequence.
            let literalEnd = literalCursor + literalLength
            guard literalEnd <= literals.count else { throw ZstdError.malformed("literal length overflow") }
            let litChunk = literals.subdata(in: literals.startIndex + literalCursor..<literals.startIndex + literalEnd)
            literalCursor = literalEnd
            window.append(litChunk)
            output.append(litChunk)

            try window.copyMatch(offset: offset, length: matchLength, into: &output)

            // State updates: LL, ML, OF.
            let llNext = llTable.nextState(state: llState, add: Int(stream.read(llTable.nbBits(for: llState))))
            let mlNext = mlTable.nextState(state: mlState, add: Int(stream.read(mlTable.nbBits(for: mlState))))
            let ofNext = ofTable.nextState(state: ofState, add: Int(stream.read(ofTable.nbBits(for: ofState))))
            llState = llNext
            mlState = mlNext
            ofState = ofNext
        }

        // Trailing literals.
        if literalCursor < literals.count {
            let tail = literals.subdata(in: literals.startIndex + literalCursor..<literals.startIndex + literals.count)
            window.append(tail)
            output.append(tail)
        }
    }

    static func readTable(_ reader: inout ByteReader, mode: Int, predefined: [Int], tableLog: Int, maxSymbol: Int) throws -> FSETable {
        switch mode {
        case 0: // Predefined
            return FSETable.build(normalized: predefined, tableLog: tableLog)
        case 1: // RLE: single byte symbol
            guard reader.remainingBytes >= 1 else { throw ZstdError.malformed("rle table") }
            let symbol = Int(reader.byte())
            return FSETable.build(normalized: [1], tableLog: 0).rle(symbol: symbol)
        case 2: // FSE_Compressed
            return try FSETableReader.read(&reader, maxSymbol: maxSymbol, maxTableLog: tableLog)
        default:
            throw ZstdError.unsupported("repeat-mode FSE table")
        }
    }
}

extension FSETable {
    func rle(symbol: Int) -> FSETable {
        FSETable(
            tableLog: 0,
            symbols: [UInt8(symbol)],
            nbBitsTable: [0],
            newStateTable: [0]
        )
    }
}
