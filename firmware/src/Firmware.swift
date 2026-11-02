// ファームウェアのアプリケーション層。
//   - USB から来るフレームを解釈してコマンドを実行する
//   - ROM データをリングバッファに溜め、LinkCore の MultibootEngine を駆動して GBA へ送る
//   - 進捗・結果をイベントとしてホストへ返す
//
// Multiboot プロトコルそのものは ../Sources/LinkCore/MultibootEngine.swift (共有コード) にある。

struct Firmware {
    private var port: LinkPort
    private let usb = UsbLink()
    private var ring: ByteRing
    private var parser = FrameParser()

    private let scratch: UnsafeMutablePointer<UInt8>
    private let scratchSize: Int
    private let cmd: UnsafeMutablePointer<UInt8>
    private let cmdSize: Int
    private var cmdFill = 0
    /// 受け付けられないペイロード (停止中の MB_DATA など) を読み捨て中
    private var discardPayload = false

    // 設定
    private var palette: UInt8 = 0xD1
    private var connectTimeoutMs: UInt32 = 30_000

    // Multiboot 実行状態
    private var engine: MultibootEngine? = nil
    private var action: MultibootEngine.Action = .wait(0)
    private var waitDeadlineUs: UInt64 = 0
    private var startUs: UInt64 = 0
    private var romSize = 0
    private var lastPhase: MultibootPhase = .idle
    private var lastReportedConsumed = 0

    /// 進捗イベントの間隔 (消費バイト数)。ホストはこれを見てフロー制御する。
    private static let progressInterval = 1024
    /// 1 回の poll で行う転送回数の上限 (USB 処理を止めないため)
    private static let transfersPerPoll = 32

    init() {
        port = LinkPort(
            sck: UInt32(LINK_PIN_SC), mosi: UInt32(LINK_PIN_SO), miso: UInt32(LINK_PIN_SI), sd: UInt32(LINK_PIN_SD),
            clockHz: 256_000, gapUs: 40)
        ring = ByteRing(storage: glue_rom_ring(), capacity: Int(ROM_RING_CAPACITY))
        scratch = glue_usb_scratch()
        scratchSize = Int(glue_usb_scratch_size())
        cmd = glue_cmd_buffer()
        cmdSize = Int(glue_cmd_buffer_size())
    }

    /// メインループから繰り返し呼ぶ
    mutating func poll() {
        pumpUSB()
        stepMultiboot()
    }

    // MARK: - USB 受信

    private mutating func pumpUSB() {
        var iterations = 0
        while tud_cdc_available() > 0 && iterations < 64 {
            iterations += 1
            if let header = parser.current {
                let isData = header.type == CommandType.mbData.rawValue
                if isData && !discardPayload && engine != nil {
                    // ROM データ: リングバッファへ直接。満杯なら USB 側 (NAK) で待たせる。
                    var want = parser.remaining
                    if want > ring.free { want = ring.free }
                    if want > scratchSize { want = scratchSize }
                    if want == 0 { return }
                    let n = Int(tud_cdc_read(UnsafeMutableRawPointer(scratch), UInt32(want)))
                    if n == 0 { return }
                    ring.write(UnsafePointer(scratch), count: n)
                    parser.consumePayload(n)
                } else if discardPayload || isData {
                    // 停止中・終了後に届いた ROM データは読み捨ててストリームの同期を保つ
                    var want = parser.remaining
                    if want > scratchSize { want = scratchSize }
                    let n = Int(tud_cdc_read(UnsafeMutableRawPointer(scratch), UInt32(want)))
                    if n == 0 { return }
                    if parser.consumePayload(n) { discardPayload = false }
                } else {
                    var want = parser.remaining
                    if want > cmdSize - cmdFill { want = cmdSize - cmdFill }
                    let n = Int(tud_cdc_read(UnsafeMutableRawPointer(cmd + cmdFill), UInt32(want)))
                    if n == 0 { return }
                    cmdFill += n
                    if parser.consumePayload(n) {
                        handleCommand(header, length: cmdFill)
                        cmdFill = 0
                    }
                }
            } else {
                var b: UInt8 = 0
                let n = tud_cdc_read(&b, 1)
                if n == 0 { return }
                if let header = parser.feedHeaderByte(b) {
                    cmdFill = 0
                    if header.length == 0 {
                        handleCommand(header, length: 0)
                    } else if header.type == CommandType.mbData.rawValue {
                        discardPayload = (engine == nil)
                    } else if Int(header.length) > cmdSize {
                        discardPayload = true
                    }
                }
            }
        }
    }

    private mutating func handleCommand(_ header: FrameHeader, length: Int) {
        guard let type = CommandType(rawValue: header.type) else {
            sendNak(header.type)
            return
        }
        switch type {
        case .getInfo:
            sendInfo()

        case .setConfig:
            guard length >= 11 else { sendNak(header.type); return }
            let clockHz = LE.u32(cmd)
            var gap = UInt32(LE.u16(cmd + 4))
            if gap < LinkPort.minGapUs { gap = LinkPort.minGapUs }
            palette = cmd[6]
            connectTimeoutMs = LE.u32(cmd + 7)
            port.setClock(hz: clockHz)
            port.gapUs = gap
            sendInfo()

        case .mbStart:
            guard length >= 4, engine == nil else { sendNak(header.type); return }
            startMultiboot(size: Int(LE.u32(cmd)))

        case .mbData:
            break  // pumpUSB で処理済み

        case .mbAbort:
            if var e = engine {
                action = e.abort()
                engine = e
            }

        case .xfer32:
            guard length >= 4 else { sendNak(header.type); return }
            let r = port.exchange(LE.u32(cmd))
            sendXferResult(r)

        case .xfer16:
            guard length >= 2 else { sendNak(header.type); return }
            let r = port.exchange(UInt32(LE.u16(cmd)))
            sendXferResult(r >> 16)

        case .reset:
            engine = nil
            ring.clear()
            discardPayload = false
            lastPhase = .idle
            sendStatus(.idle, detail: 0)

        case .bootsel:
            glue_reset_to_bootsel()
        }
    }

    // MARK: - Multiboot

    private mutating func startMultiboot(size: Int) {
        romSize = size
        ring.clear()
        var cfg = MultibootConfig()
        cfg.palette = palette
        if connectTimeoutMs == 0 {
            cfg.connectAttempts = 0
        } else {
            var attempts = (connectTimeoutMs &* 1000) / cfg.pollIntervalUs
            if attempts == 0 { attempts = 1 }
            cfg.connectAttempts = attempts
        }
        var e = MultibootEngine(romSize: size, config: cfg)
        action = e.start(data: &ring)
        engine = e
        startUs = time_us_64()
        waitDeadlineUs = 0
        lastReportedConsumed = 0
        lastPhase = .idle
        reportPhaseIfChanged(e)
    }

    private mutating func stepMultiboot() {
        guard var e = engine else { return }
        var budget = Self.transfersPerPoll
        loop: while budget > 0 {
            switch action {
            case .transfer(let word):
                let r = port.exchange(word)
                action = e.step(response: r, data: &ring)
                budget -= 1

            case .wait(let us):
                let now = time_us_64()
                if waitDeadlineUs == 0 {
                    waitDeadlineUs = now + UInt64(us)
                    break loop
                }
                if now < waitDeadlineUs { break loop }
                waitDeadlineUs = 0
                action = e.step(response: nil, data: &ring)

            case .needData(let n):
                if ring.available < n { break loop }
                action = e.step(response: nil, data: &ring)

            case .finished(let result):
                sendProgress(consumed: e.bytesConsumed)
                sendDone(result)
                engine = nil
                return

            case .failed(let failure):
                sendError(failure)
                engine = nil
                return
            }
            reportPhaseIfChanged(e)
            if e.bytesConsumed - lastReportedConsumed >= Self.progressInterval {
                sendProgress(consumed: e.bytesConsumed)
            }
        }
        engine = e
    }

    private mutating func reportPhaseIfChanged(_ e: MultibootEngine) {
        let phase = e.phase
        if phase != lastPhase {
            lastPhase = phase
            sendStatus(phase, detail: UInt32(ROM_RING_CAPACITY))
        }
    }

    // MARK: - イベント送信

    private func sendNak(_ type: UInt8) {
        usb.send(.nak) { p in
            p[0] = type
            return 1
        }
    }

    private func sendInfo() {
        usb.send(.info, important: true) { p in
            p[0] = LinkProtocol.version
            p[1] = UInt8(FW_VERSION_MAJOR)
            p[2] = UInt8(FW_VERSION_MINOR)
            p[3] = UInt8(FW_VERSION_PATCH)
            LE.put32(UInt32(ROM_RING_CAPACITY), p + 4)
            LE.put32(port.clockHz, p + 8)
            LE.put16(UInt16(truncatingIfNeeded: port.gapUs), p + 12)
            p[14] = palette
            LE.put32(connectTimeoutMs, p + 15)
            return 19
        }
    }

    private func sendStatus(_ phase: MultibootPhase, detail: UInt32) {
        usb.send(.mbStatus, important: true) { p in
            p[0] = phase.rawValue
            LE.put32(detail, p + 1)
            return 5
        }
    }

    private mutating func sendProgress(consumed: Int) {
        lastReportedConsumed = consumed
        let total = romSize
        usb.send(.mbProgress, important: true) { p in
            LE.put32(UInt32(consumed), p)
            LE.put32(UInt32(total), p + 4)
            return 8
        }
    }

    private func sendDone(_ r: MultibootResult) {
        let elapsedMs = UInt32(truncatingIfNeeded: (time_us_64() - startUs) / 1000)
        usb.send(.mbDone, important: true) { p in
            LE.put16(r.crc, p)
            LE.put32(elapsedMs, p + 2)
            p[6] = r.clientData
            p[7] = r.handshake
            p[8] = r.randomData
            p[9] = r.palette
            return 10
        }
    }

    private func sendError(_ f: MultibootFailure) {
        usb.send(.mbError, important: true) { p in
            p[0] = f.code.rawValue
            p[1] = f.phase.rawValue
            LE.put32(f.expected, p + 2)
            LE.put32(f.got, p + 6)
            return 10
        }
    }

    private func sendXferResult(_ word: UInt32) {
        usb.send(.xferResult, important: true) { p in
            LE.put32(word, p)
            return 4
        }
    }
}
