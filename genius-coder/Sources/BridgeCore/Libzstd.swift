import Foundation

/// Links the machine's real zstd library by absolute path (never `PATH`
/// lookup, spec: Indexer → dsh 的历史要读 zstd 日志). Candidates are probed
/// in order; CPython's framework install ships libzstd 1.5.7 on this Mac.
///
/// When no library is found the caller degrades to `session_unreadable`.
public final class Libzstd {
    public static let shared = Libzstd()

    public let handle: UnsafeMutableRawPointer?
    public private(set) var libraryPath: String?
    private let decompress: (@convention(c) (UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int) -> Int)?
    private let isError: (@convention(c) (Int) -> UInt32)?
    private let frameContentSize: (@convention(c) (UnsafeRawPointer?, Int) -> UInt64)?
    private let maxCLevel: (@convention(c) () -> Int32)?

    public static let searchPaths: [String] = {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["GENIUS_CODER_LIBZSTD"] {
            paths.append(override)
        }
        // Single-folder distribution: the dylib ships next to the binary.
        if let exe = CommandLine.arguments.first {
            let exeDir = (exe as NSString).deletingLastPathComponent
            if !exeDir.isEmpty {
                paths.append(exeDir + "/libzstd.dylib")
                paths.append(exeDir + "/libzstd.1.dylib")
            }
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("genius-coder/lib/libzstd.dylib").path
        paths.append(appSupport)
        paths.append("/Library/Frameworks/Python.framework/Versions/3.14/lib/libzstd.dylib")
        paths.append("/Library/Frameworks/Python.framework/Versions/3.13/lib/libzstd.dylib")
        paths.append("/usr/local/lib/libzstd.dylib")
        paths.append("/opt/homebrew/lib/libzstd.dylib")
        return paths
    }()

    init() {
        for path in Self.searchPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { continue }
            guard let d = dlsym(handle, "ZSTD_decompress"),
                  let e = dlsym(handle, "ZSTD_isError"),
                  let f = dlsym(handle, "ZSTD_getFrameContentSize") else {
                dlclose(handle)
                continue
            }
            self.handle = handle
            self.libraryPath = path
            self.decompress = unsafeBitCast(d, to: (@convention(c) (UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int) -> Int).self)
            self.isError = unsafeBitCast(e, to: (@convention(c) (Int) -> UInt32).self)
            self.frameContentSize = unsafeBitCast(f, to: (@convention(c) (UnsafeRawPointer?, Int) -> UInt64).self)
            self.maxCLevel = dlsym(handle, "ZSTD_maxCLevel").map { unsafeBitCast($0, to: (@convention(c) () -> Int32).self) }
            BridgeLog.dsh.info("libzstd linked from \(path, privacy: .public)")
            return
        }
        self.handle = nil
        self.decompress = nil
        self.isError = nil
        self.frameContentSize = nil
        self.maxCLevel = nil
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    public var available: Bool { handle != nil && decompress != nil }

    public func decompress(_ input: Data) throws -> Data {
        guard let decompress, let isError else {
            throw ZstdError.unsupported("no zstd library linked on this machine")
        }
        // Bound the output buffer: declared frame content size when present,
        // otherwise input size × 32 with a retry loop.
        var capacity: Int
        if let frameContentSize {
            let declared = input.withUnsafeBytes { raw -> UInt64 in
                let buffer = raw.bindMemory(to: UInt8.self)
                return frameContentSize(buffer.baseAddress, buffer.count)
            }
            // ZSTD_CONTENTSIZE_UNKNOWN = -1, ZSTD_CONTENTSIZE_ERROR = -2;
            // anything else must still fit a sane budget.
            let maxSane: UInt64 = 512 * 1024 * 1024
            if declared != 0xFFFF_FFFF_FFFF_FFFF && declared != 0xFFFF_FFFF_FFFF_FFFE && declared > 0 && declared < maxSane {
                capacity = Int(clamping: declared)
            } else {
                capacity = max(input.count * 32, 4096)
            }
        } else {
            capacity = max(input.count * 32, 4096)
        }
        for _ in 0..<8 {
            var output = Data(count: capacity)
            let written = input.withUnsafeBytes { rawIn -> Int in
                let inBuf = rawIn.bindMemory(to: UInt8.self)
                return output.withUnsafeMutableBytes { rawOut -> Int in
                    let outBuf = rawOut.bindMemory(to: UInt8.self)
                    return decompress(outBuf.baseAddress, outBuf.count, inBuf.baseAddress, inBuf.count)
                }
            }
            if isError(written) != 0 {
                throw ZstdError.malformed("ZSTD_decompress reported an error")
            }
            if written < capacity {
                return output.prefix(written)
            }
            capacity *= 4
        }
        throw ZstdError.malformed("zstd output keeps overflowing the budget")
    }
}

/// dsh history decompression entry point: real library first.
public enum DshZstd {
    public static func decompress(_ data: Data) throws -> Data {
        try Libzstd.shared.decompress(data)
    }
}
