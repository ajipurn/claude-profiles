import Foundation
import CZstd

/// The official usage-limit numbers for one account, as last seen by Claude
/// Desktop itself. Read from the profile's own HTTP cache — the app makes no
/// network requests and touches no cookies or tokens.
public struct ProfileUsage: Equatable {
    public struct Window: Equatable {
        public let percent: Double
        public let resetsAt: Date?
        /// A window whose reset time has passed says nothing about now.
        public var expired: Bool { expired(at: Date()) }

        public func expired(at now: Date) -> Bool {
            guard let resetsAt else { return false }
            return resetsAt < now
        }
    }

    public let fiveHour: Window?
    public let sevenDay: Window?
    /// When Claude fetched these numbers (cache entry mtime).
    public let asOf: Date
    public let orgID: String
}

/// Finds the cached `GET /api/organizations/<org>/usage` response inside a
/// profile's `Cache/Cache_Data` and decodes it. Chromium "simple cache" entry
/// layout (verified against real files): 20-byte header (8 magic, 4 version,
/// 4 key length, 4 key hash), the key string, then the response body — which
/// claude.ai serves zstd-compressed.
///
/// All of this is Anthropic/Chromium internals and can change under us, so
/// every step fails soft: anything unexpected just means "no usage info".
public enum UsageReader {
    static let entryMagic: [UInt8] = [0x30, 0x5C, 0x72, 0xA7, 0x1B, 0x6D, 0xFB, 0xFC]
    // Usage responses are ~3 KB; skipping bigger files keeps the scan cheap.
    static let maxEntrySize = 64 * 1024

    /// Parse results keyed by file path, so the 60-second poll only re-reads
    /// entries whose (mtime, size) changed. `usage == nil` remembers "not a
    /// usage entry" — the common case for most cache files. Guarded by a lock:
    /// profiles are scanned concurrently.
    private struct ParsedEntry {
        let mtime: Date
        let size: Int
        let usage: ProfileUsage?
    }
    private static var parsedCache: [String: ParsedEntry] = [:]
    private static let parsedLock = NSLock()

    /// Newest cached usage snapshot in `dir`. When `orgIDs` is non-empty and
    /// any entry matches one of them, only those entries are considered — a
    /// profile's cache can retain responses for orgs it no longer uses.
    public static func usage(inProfileDir dir: URL, orgIDs: Set<String> = []) -> ProfileUsage? {
        let cacheDir = dir.appendingPathComponent("Cache/Cache_Data")
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return nil }

        var found: [ProfileUsage] = []
        var seen: Set<String> = []
        for file in files where file.lastPathComponent.hasSuffix("_0") {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize, size <= maxEntrySize,
                  let mtime = values.contentModificationDate
            else { continue }
            seen.insert(file.path)

            parsedLock.lock()
            let hit = parsedCache[file.path]
            parsedLock.unlock()
            if let hit, hit.mtime == mtime, hit.size == size {
                if let usage = hit.usage { found.append(usage) }
                continue
            }

            let parsed: ProfileUsage?
            if let data = try? Data(contentsOf: file),
               let (org, body) = parseUsageEntry(data) {
                parsed = decode(body: body, orgID: org, asOf: mtime)
            } else {
                parsed = nil
            }
            parsedLock.lock()
            parsedCache[file.path] = ParsedEntry(mtime: mtime, size: size, usage: parsed)
            parsedLock.unlock()
            if let parsed { found.append(parsed) }
        }

        // Evicted cache files must not pin stale results (or memory).
        let prefix = cacheDir.path + "/"
        parsedLock.lock()
        for key in parsedCache.keys where key.hasPrefix(prefix) && !seen.contains(key) {
            parsedCache.removeValue(forKey: key)
        }
        parsedLock.unlock()

        let matching = found.filter { orgIDs.contains($0.orgID) }
        let pool = (orgIDs.isEmpty || matching.isEmpty) ? found : matching
        return pool.max { $0.asOf < $1.asOf }
    }

    /// Returns (orgID, response body) if `data` is a cache entry for /usage.
    static func parseUsageEntry(_ data: Data) -> (String, Data)? {
        // Header: magic u64, version u32, key_length u32, key_hash u32 —
        // padded to 24 bytes on disk (struct alignment), then the key.
        let headerSize = 24
        guard data.count > headerSize, data.prefix(8).elementsEqual(entryMagic) else { return nil }
        let keyLen = Int(data[12]) | Int(data[13]) << 8 | Int(data[14]) << 16 | Int(data[15]) << 24
        guard keyLen > 0, keyLen < 4096, data.count > headerSize + keyLen,
              let key = String(data: data[headerSize ..< headerSize + keyLen], encoding: .utf8) else { return nil }
        // Key looks like "1/0/https://claude.ai/api/organizations/<uuid>/usage".
        guard key.hasSuffix("/usage"),
              let range = key.range(of: "/api/organizations/") else { return nil }
        let org = String(key[range.upperBound...].dropLast("/usage".count))
        guard org.count == 36 else { return nil }
        return (org, data.subdata(in: (headerSize + keyLen) ..< data.count))
    }

    static func decode(body: Data, orgID: String, asOf: Date) -> ProfileUsage? {
        // The body stream is followed by the entry's EOF record; the zstd
        // decoder stops at the frame end, so trailing bytes are harmless.
        // An uncompressed body (no content-encoding) starts with '{' — there
        // the trailing record must be cut off (JSON parsers reject trailers).
        let json: Data?
        if body.first == UInt8(ascii: "{") {
            json = body.lastIndex(of: UInt8(ascii: "}")).map { Data(body[...$0]) }
        } else if body.prefix(4).elementsEqual([0x28, 0xB5, 0x2F, 0xFD]) {
            json = zstdDecompress(body)
        } else {
            json = nil
        }
        guard let json,
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }

        func window(_ key: String) -> ProfileUsage.Window? {
            guard let raw = obj[key] as? [String: Any],
                  let percent = raw["utilization"] as? Double else { return nil }
            return .init(percent: percent, resetsAt: (raw["resets_at"] as? String).flatMap(parseISO))
        }
        let five = window("five_hour")
        let seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return ProfileUsage(fiveHour: five, sevenDay: seven, asOf: asOf, orgID: orgID)
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Streaming decompress of one zstd frame; trailing input is ignored.
    static func zstdDecompress(_ input: Data, maxOutput: Int = 4 << 20) -> Data? {
        guard let zds = ZSTD_createDStream() else { return nil }
        defer { _ = ZSTD_freeDStream(zds) }
        _ = ZSTD_initDStream(zds)

        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            var inBuf = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
            while true {
                var status = 0 // 0 = keep going, 1 = frame done, 2 = fail
                chunk.withUnsafeMutableBytes { ob in
                    var outBuf = ZSTD_outBuffer(dst: ob.baseAddress, size: ob.count, pos: 0)
                    let code = ZSTD_decompressStream(zds, &outBuf, &inBuf)
                    if ZSTD_isError(code) != 0 { status = 2; return }
                    out.append(ob.bindMemory(to: UInt8.self).baseAddress!, count: outBuf.pos)
                    if code == 0 { status = 1 }                                  // frame complete
                    else if outBuf.pos == 0, inBuf.pos == inBuf.size { status = 2 } // stuck
                }
                if status == 2 || out.count > maxOutput { return nil }
                if status == 1 { return out }
            }
        }
    }
}
