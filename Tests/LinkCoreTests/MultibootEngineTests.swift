import Testing
@testable import LinkCore

/// ROM らしいテストデータ (ヘッダ + 本体) を作る
func makeROM(bodySize: Int, seed: UInt32 = 12345) -> [UInt8] {
    var rom = [UInt8](repeating: 0, count: 0xC0 + bodySize)
    var s = seed
    for i in 0..<rom.count {
        s = s &* 1_103_515_245 &+ 12345
        rom[i] = UInt8(truncatingIfNeeded: s >> 16)
    }
    // Nintendo ロゴ先頭と Multiboot エントリの分岐命令、ヘッダチェックサム
    rom[4] = 0x24; rom[5] = 0xFF; rom[6] = 0xAE; rom[7] = 0x51
    rom[0xC3] = 0xEA
    var sum: UInt8 = 0
    for i in 0xA0...0xBC { sum = sum &- rom[i] }
    rom[0xBD] = sum &- 0x19
    return rom
}

/// エンジンを疑似 GBA に対して完走させる。
/// feed: needData のときに呼ばれ、データを供給できたら true
@discardableResult
func drive<D: MultibootDataSource>(
    _ engine: inout MultibootEngine, gba: FakeGBA, data: inout D, maxSteps: Int = 1_000_000,
    feed: (inout D) -> Bool = { _ in false }
) -> MultibootEngine.Action {
    var action = engine.start(data: &data)
    var steps = 0
    var waits = 0
    while steps < maxSteps {
        steps += 1
        switch action {
        case .transfer(let w):
            let r = gba.exchange(w)
            action = engine.step(response: r, data: &data)
        case .wait:
            waits += 1
            action = engine.step(response: nil, data: &data)
        case .needData:
            guard feed(&data) else { return action }
            action = engine.step(response: nil, data: &data)
        case .finished, .failed:
            return action
        }
    }
    return action
}

@Test func uploadsWholeROMAndCRCMatches() {
    let rom = makeROM(bodySize: 0x400)
    let gba = FakeGBA()
    var engine = MultibootEngine(romSize: rom.count)
    let action = rom.withUnsafeBufferPointer { buf -> MultibootEngine.Action in
        var src = BufferSource(base: buf.baseAddress!, count: buf.count)
        return drive(&engine, gba: gba, data: &src)
    }
    guard case .finished(let result) = action else {
        Issue.record("engine did not finish: \(action) gba log: \(gba.log)")
        return
    }
    #expect(gba.booted)
    #expect(Array(rom[0..<0xC0]) == gba.header)
    #expect(Array(rom[0xC0...]) == gba.body)
    #expect(result.crc == gba.ownCRC)
    #expect(result.clientData == gba.clientData)
    #expect(result.randomData == gba.randomData)
    #expect(result.handshake == MultibootCipher.handshakeData(clientData: gba.clientData))
    #expect(engine.bytesConsumed == rom.count)
    #expect(engine.phase == .done)

    // 一括 CRC 計算 (Web 側の照合用) も同じ値になる
    let crc = rom.withUnsafeBufferPointer {
        MultibootCipher.crc(rom: $0, palette: 0xD1, clientData: gba.clientData, handshake: result.handshake, randomData: gba.randomData)
    }
    #expect(crc == result.crc)
}

@Test func streamsThroughSmallRingBuffer() {
    let rom = makeROM(bodySize: 0x2000, seed: 777)
    let gba = FakeGBA(absentPolls: 5)
    var engine = MultibootEngine(romSize: rom.count)
    let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    defer { storage.deallocate() }
    var ring = ByteRing(storage: storage, capacity: 64)
    var offset = 0
    let action = rom.withUnsafeBufferPointer { buf -> MultibootEngine.Action in
        drive(&engine, gba: gba, data: &ring) { ring in
            // ホストが少量ずつ ROM を流し込む様子を模す
            let chunk = min(37, buf.count - offset, ring.free)
            if chunk <= 0 { return offset < buf.count }
            ring.write(buf.baseAddress! + offset, count: chunk)
            offset += chunk
            return true
        }
    }
    guard case .finished = action else {
        Issue.record("engine did not finish: \(action) gba log: \(gba.log)")
        return
    }
    #expect(gba.booted)
    #expect(Array(rom[0xC0...]) == gba.body)
    #expect(ring.isEmpty)
}

@Test func timesOutWhenNoGBA() {
    let rom = makeROM(bodySize: 0x100)
    let gba = FakeGBA(absentPolls: .max)
    var config = MultibootConfig()
    config.connectAttempts = 10
    var engine = MultibootEngine(romSize: rom.count, config: config)
    let action = rom.withUnsafeBufferPointer { buf -> MultibootEngine.Action in
        var src = BufferSource(base: buf.baseAddress!, count: buf.count)
        return drive(&engine, gba: gba, data: &src)
    }
    #expect(action == .failed(MultibootFailure(code: .connectTimeout, phase: .connecting, expected: 0x7202, got: 0xFFFF)))
}

@Test func rejectsBadSizes() {
    var e1 = MultibootEngine(romSize: 0xC0 + 0x104)   // 16 バイト境界でない
    var src = BufferSource(base: UnsafePointer(bitPattern: 4)!, count: 0)
    guard case .failed(let f) = e1.start(data: &src) else { Issue.record("expected failure"); return }
    #expect(f.code == .badSize)
    var e2 = MultibootEngine(romSize: ROMImage.maxTotalSize + 0x10)
    guard case .failed(let f2) = e2.start(data: &src) else { Issue.record("expected failure"); return }
    #expect(f2.code == .badSize)
}

@Test func abortReportsAborted() {
    var engine = MultibootEngine(romSize: 0xC0 + 0x100)
    var src = BufferSource(base: UnsafePointer(bitPattern: 4)!, count: 0)
    _ = engine.start(data: &src)
    #expect(engine.abort() == .failed(MultibootFailure(code: .aborted, phase: .connecting)))
    #expect(engine.isTerminal)
}

@Test func lengthWordMatchesGBATEK() {
    // llll = (size - C0h)/4 - 34h
    #expect(MultibootCipher.lengthWord(romSize: 0xC0 + 0x100) == 0x40 - 0x34)
    #expect(MultibootCipher.lengthWord(romSize: 0x40000) == UInt16(truncatingIfNeeded: 0x3FF40 / 4 - 0x34))
}

@Test func romImageHelpers() {
    #expect(ROMImage.paddedSize(0xC0 + 0x101) == 0xC0 + 0x110)
    #expect(ROMImage.paddedSize(10) == ROMImage.minTotalSize)
    #expect(ROMImage.isValidTotalSize(0x40000))
    #expect(!ROMImage.isValidTotalSize(0x40010))
    let rom = makeROM(bodySize: 0x100)
    rom.withUnsafeBufferPointer {
        let c = ROMImage.check($0)
        #expect(c.contains(.headerChecksumOK))
        #expect(c.contains(.logoOK))
        #expect(c.contains(.multibootEntryOK))
        #expect(c.contains(.sizeOK))
    }
}

@Test func frameParserSplitsHeadersAndPayload() {
    var p = FrameParser()
    // type 0x11, length 5
    #expect(p.feedHeaderByte(0x11) == nil)
    #expect(p.feedHeaderByte(0x05) == nil)
    let h = p.feedHeaderByte(0x00)
    #expect(h == FrameHeader(type: 0x11, length: 5))
    #expect(p.isReceivingPayload)
    #expect(p.remaining == 5)
    #expect(p.consumePayload(3) == false)
    #expect(p.consumePayload(2) == true)
    #expect(!p.isReceivingPayload)
    // 空ペイロード
    _ = p.feedHeaderByte(0x01); _ = p.feedHeaderByte(0); let h2 = p.feedHeaderByte(0)
    #expect(h2 == FrameHeader(type: 0x01, length: 0))
    #expect(!p.isReceivingPayload)
    // ヘッダの書き戻し
    var buf = [UInt8](repeating: 0, count: 3)
    FrameHeader(type: 0xA0, length: 0x1234).write(to: &buf)
    #expect(buf == [0xA0, 0x34, 0x12])
    #expect(FrameHeader.read(from: buf) == FrameHeader(type: 0xA0, length: 0x1234))
}
