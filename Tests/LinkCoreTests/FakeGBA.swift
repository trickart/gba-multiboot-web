import LinkCore

/// GBA BIOS の Multiboot スレーブ側 (Normal mode, 32bit) を模した疑似デバイス。
/// GBATEK の表に従い、「次の転送で返す値」を前もって用意するモデルで実装している。
/// 暗号の復号・CRC は LinkCore とは独立に GBATEK の擬似コードから書き起こしてある。
final class FakeGBA {
    enum Mode { case notInSIOMode, entered, recognized, header(remaining: Int), headerDone, palette(polls: Int), handshake, length, payload(ptr: Int), done(crcBusy: Int), crcAnnounced, crcDone }

    private(set) var mode: Mode = .notInSIOMode
    private var reply: UInt16 = 0xFFFF
    private var lastMasterLow: UInt16 = 0

    /// 設定
    let clientData: UInt8
    let randomData: UInt8
    let crcBusyPolls: Int
    let palettePollsBeforeReady: Int
    /// 最初の何回を「まだ SIO モードでない」として FFFF を返すか
    let absentPolls: Int
    private var polls = 0

    /// 受け取った内容
    private(set) var header: [UInt8] = []
    private(set) var body: [UInt8] = []
    private(set) var palette: UInt8 = 0
    private(set) var receivedHandshake: UInt8 = 0
    private(set) var receivedLength: UInt16 = 0
    private(set) var masterCRC: UInt16 = 0
    private(set) var ownCRC: UInt16 = 0
    private(set) var log: [String] = []

    private var m: UInt32 = 0
    private var c: UInt32 = 0
    private var f: UInt32 = 0

    init(clientData: UInt8 = 0x5A, randomData: UInt8 = 0x3C, absentPolls: Int = 0, crcBusyPolls: Int = 3, palettePollsBeforeReady: Int = 2) {
        self.clientData = clientData
        self.randomData = randomData
        self.absentPolls = absentPolls
        self.crcBusyPolls = crcBusyPolls
        self.palettePollsBeforeReady = palettePollsBeforeReady
    }

    /// マスタの 32bit 転送に対する応答 (上位 16bit: スレーブデータ、下位 16bit: 前回マスタが送った下位 16bit)
    func exchange(_ word: UInt32) -> UInt32 {
        let response = UInt32(reply) << 16 | UInt32(lastMasterLow)
        lastMasterLow = UInt16(truncatingIfNeeded: word)
        process(word)
        return response
    }

    private func fail(_ s: String) {
        log.append("FAIL: \(s)")
        reply = 0xFFFF
        mode = .notInSIOMode
    }

    private func process(_ w: UInt32) {
        let lo = UInt16(truncatingIfNeeded: w)
        switch mode {
        case .notInSIOMode:
            polls += 1
            if polls <= absentPolls { reply = 0xFFFF; return }
            mode = .entered
            reply = 0x0000
        case .entered:
            guard lo & 0xFF00 == 0x6200 else { reply = 0x0000; return }
            mode = .recognized
            reply = 0x7202
        case .recognized:
            if lo & 0xFF00 == 0x6200 { reply = 0x7202; return }
            guard lo == 0x6102 else { fail("expected 6102, got \(String(lo, radix: 16))"); return }
            mode = .header(remaining: 0x60)
            reply = 0x6002
        case .header(let remaining):
            header.append(UInt8(truncatingIfNeeded: lo))
            header.append(UInt8(truncatingIfNeeded: lo >> 8))
            let next = remaining - 1
            if next == 0 {
                mode = .headerDone
                reply = 0x0002
            } else {
                mode = .header(remaining: next)
                reply = UInt16(next) << 8 | 0x02
            }
        case .headerDone:
            guard lo == 0x6200 else { fail("expected 6200 after header, got \(String(lo, radix: 16))"); return }
            mode = .palette(polls: 0)
            reply = 0x7202
        case .palette(let polls):
            if lo == 0x6202 { reply = 0x7202; return }
            guard lo & 0xFF00 == 0x6300 else { fail("expected 63pp, got \(String(lo, radix: 16))"); return }
            palette = UInt8(truncatingIfNeeded: lo)
            if polls + 1 >= palettePollsBeforeReady {
                mode = .handshake
                reply = 0x7300 | UInt16(clientData)
            } else {
                mode = .palette(polls: polls + 1)
                reply = 0x7202
            }
        case .handshake:
            if lo & 0xFF00 == 0x6300 { reply = 0x7300 | UInt16(clientData); return }
            guard lo & 0xFF00 == 0x6400 else { fail("expected 64hh, got \(String(lo, radix: 16))"); return }
            receivedHandshake = UInt8(truncatingIfNeeded: lo)
            let expected = UInt8(truncatingIfNeeded: 0x11 &+ UInt32(clientData) &+ 0xFF &+ 0xFF)
            guard receivedHandshake == expected else { fail("bad handshake"); return }
            mode = .length
            reply = 0x7300 | UInt16(randomData)
        case .length:
            receivedLength = lo
            // GBATEK: c=C387h, x=C37Bh, k=43202F2Fh, m=dword(pp,cc,cc,cc), f=dword(hh,rr,rr,rr)
            c = 0xC387
            m = 0xFFFF_0000 | UInt32(clientData) << 8 | UInt32(palette)
            f = 0xFFFF_0000 | UInt32(randomData) << 8 | UInt32(receivedHandshake)
            mode = .payload(ptr: 0xC0)
            reply = 0x00C0
        case .payload(let ptr):
            // 復号: data = y xor (-2000000h-ptr) xor m xor k
            m = 0x6F64_6573 &* m &+ 1
            let complement = (0 &- UInt32(0x200_0000)) &- UInt32(ptr)
            let data = w ^ complement ^ m ^ 0x4320_2F2F
            body.append(UInt8(truncatingIfNeeded: data))
            body.append(UInt8(truncatingIfNeeded: data >> 8))
            body.append(UInt8(truncatingIfNeeded: data >> 16))
            body.append(UInt8(truncatingIfNeeded: data >> 24))
            crcStep(data)
            let total = Int(receivedLength) &+ 0x34
            let endPtr = 0xC0 + total * 4
            let next = ptr + 4
            if next >= endPtr {
                crcStep(f)
                ownCRC = UInt16(truncatingIfNeeded: c)
                mode = .done(crcBusy: 0)
            } else {
                mode = .payload(ptr: next)
            }
            reply = UInt16(truncatingIfNeeded: next)
        case .done(let busy):
            guard lo == 0x0065 else { fail("expected 0065, got \(String(lo, radix: 16))"); return }
            if busy < crcBusyPolls {
                mode = .done(crcBusy: busy + 1)
                reply = 0x0074
            } else {
                mode = .crcAnnounced
                reply = 0x0075
            }
        case .crcAnnounced:
            if lo == 0x0065 { reply = 0x0075; return }
            guard lo == 0x0066 else { fail("expected 0066, got \(String(lo, radix: 16))"); return }
            mode = .crcDone
            reply = ownCRC
        case .crcDone:
            masterCRC = lo
            log.append("booted")
        }
    }

    private func crcStep(_ v: UInt32) {
        c ^= v
        for _ in 0..<32 {
            let carry = c & 1
            c >>= 1
            if carry != 0 { c ^= 0xC37B }
        }
    }

    var booted: Bool { log.contains("booted") && masterCRC == ownCRC }
}
