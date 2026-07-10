import XCTest
@testable import ClaudeProfilesCore

final class UsageReaderTests: XCTestCase {
    let fm = FileManager.default
    var home: URL!

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("usage-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    // {"five_hour":{"utilization":42.0,"resets_at":"2099-01-01T12:00:00.000000+00:00"},
    //  "seven_day":{"utilization":7.0,"resets_at":"2099-01-02T00:00:00.000000+00:00"}}
    // compressed with zstd 1.5.7 — same shape claude.ai serves.
    let zstdBody = Data(base64Encoded:
        "KLUv/QRYFQMAUoUTGpC3OdBV1iSbdsqHN4hT/biaI5EJtMjWfykBjXEBAxOsI5dsPo2Jpx9/PGWoI3VU"
        + "FD+jl6222TLxeToA+kB02UELuooZdKIghJWLDswEBgDgQIgWpVjYKcyHKWy4QBR4ufjv")!

    let org = "b9589ac7-88be-4169-803d-df4e9199cb77"
    let otherOrg = "1d97db2f-3b3c-4d9c-bbd4-85bc56a22df8"

    /// A Chromium simple-cache entry: 24-byte header (magic, version, key
    /// length, key hash + alignment padding), key, body, trailing EOF record.
    func cacheEntry(org: String, body: Data) -> Data {
        let key = "1/0/https://claude.ai/api/organizations/\(org)/usage"
        var data = Data(UsageReader.entryMagic)
        for value in [UInt32(5), UInt32(key.utf8.count), UInt32(0)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: [0, 0, 0, 0]) // header padding to 24 bytes
        data.append(key.data(using: .utf8)!)
        data.append(body)
        data.append(Data(repeating: 0xAB, count: 32)) // fake EOF record
        return data
    }

    func writeEntry(_ name: String, org: String, body: Data, mtime: Date? = nil) throws -> URL {
        let dir = home.appendingPathComponent("Cache/Cache_Data")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(name)
        try cacheEntry(org: org, body: body).write(to: file)
        if let mtime {
            try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
        return file
    }

    func testReadsZstdCompressedUsageEntry() throws {
        _ = try writeEntry("aa_0", org: org, body: zstdBody)
        let usage = try XCTUnwrap(UsageReader.usage(inProfileDir: home))
        XCTAssertEqual(usage.orgID, org)
        XCTAssertEqual(usage.fiveHour?.percent, 42.0)
        XCTAssertEqual(usage.sevenDay?.percent, 7.0)
        XCTAssertEqual(usage.fiveHour?.expired, false) // resets in 2099
        XCTAssertNotNil(usage.fiveHour?.resetsAt)
    }

    func testReadsUncompressedBodyToo() throws {
        let plain = #"{"five_hour":{"utilization":13.0,"resets_at":null},"seven_day":null}"#
        _ = try writeEntry("bb_0", org: org, body: plain.data(using: .utf8)!)
        let usage = try XCTUnwrap(UsageReader.usage(inProfileDir: home))
        XCTAssertEqual(usage.fiveHour?.percent, 13.0)
        XCTAssertNil(usage.sevenDay)
    }

    func testPrefersMatchingOrgThenNewest() throws {
        // Newer entry for a foreign org, older entry for "our" org.
        _ = try writeEntry("new_0", org: otherOrg, body: zstdBody, mtime: Date())
        _ = try writeEntry("old_0", org: org, body: zstdBody, mtime: Date(timeIntervalSinceNow: -3600))
        XCTAssertEqual(UsageReader.usage(inProfileDir: home, orgIDs: [org])?.orgID, org)
        // No org hint → newest wins.
        XCTAssertEqual(UsageReader.usage(inProfileDir: home)?.orgID, otherOrg)
        // Hint that matches nothing → fall back to newest.
        XCTAssertEqual(UsageReader.usage(inProfileDir: home, orgIDs: ["nope"])?.orgID, otherOrg)
    }

    func testGarbageAndForeignEntriesAreIgnored() throws {
        _ = try writeEntry("ok_0", org: org, body: zstdBody)
        // Truncated entry, wrong magic, corrupt zstd body.
        let dir = home.appendingPathComponent("Cache/Cache_Data")
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("tiny_0"))
        try Data(repeating: 7, count: 100).write(to: dir.appendingPathComponent("junk_0"))
        try cacheEntry(org: org, body: Data([0x28, 0xB5, 0x2F, 0xFD, 0xFF, 0xFF]))
            .write(to: dir.appendingPathComponent("corrupt_0"))
        let usage = UsageReader.usage(inProfileDir: home)
        XCTAssertEqual(usage?.fiveHour?.percent, 42.0)
    }

    func testExpiredWindowIsFlagged() {
        let past = ProfileUsage.Window(percent: 90, resetsAt: Date(timeIntervalSinceNow: -60))
        let future = ProfileUsage.Window(percent: 90, resetsAt: Date(timeIntervalSinceNow: 60))
        let never = ProfileUsage.Window(percent: 90, resetsAt: nil)
        XCTAssertTrue(past.expired)
        XCTAssertFalse(future.expired)
        XCTAssertFalse(never.expired)
    }

    func testNoCacheDirMeansNil() {
        XCTAssertNil(UsageReader.usage(inProfileDir: home.appendingPathComponent("missing")))
    }
}
