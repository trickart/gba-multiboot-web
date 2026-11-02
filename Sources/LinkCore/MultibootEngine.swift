// GBA Multiboot (Normal mode, 32bit) のマスタ側プロトコルを I/O 非依存の状態機械として実装する。
//
// 使い方 (ドライバ側):
//   var engine = MultibootEngine(romSize: n, config: cfg)
//   var action = engine.start()
//   loop:
//     switch action {
//     case .transfer(let w):  let r = リンクポートで 32bit 交換(w); action = engine.step(response: r, data: &src)
//     case .wait(let us):     us マイクロ秒待つ;                      action = engine.step(response: nil, data: &src)
//     case .needData:         src にデータが増えるのを待つ;          action = engine.step(response: nil, data: &src)
//     case .finished, .failed: 終了
//     }
//
// ドライバはこの他に、各転送の後に 36µs 以上の間隔 (config.gapUs) を空ける責任を持つ。
// 同じコードを RP2040 ファームウェア、ブラウザ (wasm, ホスト駆動モード)、ホストのテストで使う。

public protocol MultibootDataSource {
    /// 読み出し可能なバイト数
    var available: Int { get }
    /// 1 バイト取り出す (available > 0 のときだけ呼ばれる)
    mutating func readByte() -> UInt8
}

public enum MultibootPhase: UInt8, Sendable, CaseIterable {
    case idle = 0
    /// 6202h を送って GBA の応答 (720xh) を待っている
    case connecting = 1
    /// ヘッダ C0h バイトを 16bit 単位で送信中
    case header = 2
    /// パレット送信・クライアントデータ取得
    case palette = 3
    /// 長さ情報送信
    case length = 4
    /// 暗号化本体転送中
    case payload = 5
    /// CRC 交換
    case crc = 6
    case done = 7
    case failed = 8
}

public enum MultibootErrorCode: UInt8, Sendable, CaseIterable {
    case none = 0
    /// romSize が制約を満たさない
    case badSize = 1
    /// GBA が見つからない (接続タイムアウト)
    case connectTimeout = 2
    /// 認識応答が Normal mode の単一スレーブ (x=2) でない
    case badClientBit = 3
    /// master/slave 情報交換 (610y) の応答不一致
    case masterInfo = 4
    /// ヘッダ転送中の応答不一致
    case headerAck = 5
    /// ヘッダ完了通知 (6200) の応答不一致
    case headerDone = 6
    /// パレット応答 (73cc) が得られない
    case paletteTimeout = 7
    /// ハンドシェイク (64hh) の応答不一致
    case handshakeAck = 8
    /// 長さ情報の応答不一致
    case lengthAck = 9
    /// 本体転送中の応答 (宛先アドレス下位 16bit) 不一致
    case payloadAck = 10
    /// 本体転送完了通知 (0065) の応答不一致
    case transferDoneAck = 11
    /// CRC 準備待ち (0074/0075) で想定外の値
    case crcReadyAck = 12
    /// CRC 転送予告 (0066) の応答不一致
    case crcAnnounceAck = 13
    /// CRC 不一致
    case crcMismatch = 14
    /// ホストから中止された
    case aborted = 15
}

public struct MultibootFailure: Equatable, Sendable {
    public var code: MultibootErrorCode
    public var phase: MultibootPhase
    public var expected: UInt32
    public var got: UInt32

    public init(code: MultibootErrorCode, phase: MultibootPhase, expected: UInt32 = 0, got: UInt32 = 0) {
        self.code = code
        self.phase = phase
        self.expected = expected
        self.got = got
    }
}

public struct MultibootResult: Equatable, Sendable {
    public var crc: UInt16
    public var palette: UInt8
    public var clientData: UInt8
    public var handshake: UInt8
    public var randomData: UInt8
}

public struct MultibootConfig: Equatable, Sendable {
    /// 63pp で送るパレット値。81h+color*10h+direction*8+speed*2 または F1h+color*2
    public var palette: UInt8 = 0xD1
    /// 接続試行の間隔 (µs)。GBATEK: 1/16 秒
    public var pollIntervalUs: UInt32 = 62_500
    /// 接続試行回数の上限。0 で無制限
    public var connectAttempts: UInt32 = 480   // ≒ 30 秒
    /// 63pp の再送回数上限
    public var paletteAttempts: UInt32 = 2_000
    /// 0065 の CRC 準備待ち回数上限
    public var crcReadyAttempts: UInt32 = 2_000

    public init() {}
}

public struct MultibootEngine {
    public enum Action: Equatable, Sendable {
        /// 32bit ワードを 1 回交換し、応答を step(response:) に渡す
        case transfer(UInt32)
        /// 指定 µs 待ってから step(response: nil) を呼ぶ
        case wait(UInt32)
        /// データソースに最低 n バイト溜まるのを待ってから step(response: nil) を呼ぶ
        case needData(Int)
        case finished(MultibootResult)
        case failed(MultibootFailure)
    }

    private enum State {
        case idle
        case connectPoll
        case masterInfo
        case header(index: Int)
        case headerDone
        case masterInfo2
        case palettePoll
        case handshake
        case length
        case payload(ptr: UInt32)
        case transferDone
        case crcReadyPoll
        case crcAnnounce
        case crcExchange
        case finished(MultibootResult)
        case failed(MultibootFailure)
    }

    public let romSize: Int
    public let config: MultibootConfig

    private var state: State = .idle
    /// 次の emit の前に挟む待ち時間 (µs)
    private var pendingWaitUs: UInt32 = 0
    private var attempts: UInt32 = 0
    private var okCount: UInt32 = 0

    private var clientData: UInt8 = 0
    private var handshake: UInt8 = 0
    private var randomData: UInt8 = 0
    private var cipher = MultibootCipher(palette: 0, clientData: 0, handshake: 0, randomData: 0)
    private var crc: UInt16 = 0

    /// 消費した ROM バイト数 (ヘッダ含む)
    public private(set) var bytesConsumed: Int = 0

    public init(romSize: Int, config: MultibootConfig = MultibootConfig()) {
        self.romSize = romSize
        self.config = config
    }

    public var phase: MultibootPhase {
        switch state {
        case .idle: return .idle
        case .connectPoll: return .connecting
        case .masterInfo, .header, .headerDone, .masterInfo2: return .header
        case .palettePoll, .handshake: return .palette
        case .length: return .length
        case .payload: return .payload
        case .transferDone, .crcReadyPoll, .crcAnnounce, .crcExchange: return .crc
        case .finished: return .done
        case .failed: return .failed
        }
    }

    public var isTerminal: Bool {
        switch state {
        case .finished, .failed: return true
        default: return false
        }
    }

    // MARK: - 駆動 API

    /// 開始。最初のアクションを返す。
    public mutating func start<D: MultibootDataSource>(data: inout D) -> Action {
        guard ROMImage.isValidTotalSize(romSize) else {
            return fail(.badSize, expected: UInt32(ROMImage.maxTotalSize), got: UInt32(truncatingIfNeeded: romSize))
        }
        state = .connectPoll
        attempts = 0
        okCount = 0
        bytesConsumed = 0
        return emit(data: &data)
    }

    /// ホストからの中止
    public mutating func abort() -> Action {
        fail(.aborted)
    }

    /// `.transfer` の後は応答を、`.wait` / `.needData` の後は nil を渡す。
    public mutating func step<D: MultibootDataSource>(response: UInt32?, data: inout D) -> Action {
        if let r = response {
            handle(response: r, data: &data)
        }
        return emit(data: &data)
    }

    // MARK: - 内部

    /// 16bit 転送の応答 (上位 16bit がスレーブ側データ)
    @inline(__always)
    private func r16(_ r: UInt32) -> UInt32 { r >> 16 }

    @inline(__always)
    private func t16(_ w: UInt16) -> Action { .transfer(UInt32(w)) }

    @discardableResult
    private mutating func fail(_ code: MultibootErrorCode, expected: UInt32 = 0, got: UInt32 = 0) -> Action {
        let f = MultibootFailure(code: code, phase: phase, expected: expected, got: got)
        state = .failed(f)
        return .failed(f)
    }

    private mutating func readWord16<D: MultibootDataSource>(_ data: inout D) -> UInt16 {
        let b0 = data.readByte()
        let b1 = data.readByte()
        bytesConsumed += 2
        return UInt16(b0) | UInt16(b1) << 8
    }

    private mutating func readWord32<D: MultibootDataSource>(_ data: inout D) -> UInt32 {
        let b0 = data.readByte()
        let b1 = data.readByte()
        let b2 = data.readByte()
        let b3 = data.readByte()
        bytesConsumed += 4
        return UInt32(b0) | UInt32(b1) << 8 | UInt32(b2) << 16 | UInt32(b3) << 24
    }

    /// 現在の状態に対応する次アクションを返す (転送内容の決定)
    private mutating func emit<D: MultibootDataSource>(data: inout D) -> Action {
        if pendingWaitUs != 0 {
            let w = pendingWaitUs
            pendingWaitUs = 0
            return .wait(w)
        }
        switch state {
        case .idle:
            return .wait(config.pollIntervalUs)
        case .connectPoll:
            return t16(0x6202)
        case .masterInfo, .masterInfo2:
            // 610y / 620y : y = client_bit (スレーブ 1 → bit1)
            if case .masterInfo = state { return t16(0x6102) }
            return t16(0x6202)
        case .header:
            if data.available < 2 { return .needData(2) }
            return t16(readWord16(&data))
        case .headerDone:
            return t16(0x6200)
        case .palettePoll:
            return t16(0x6300 | UInt16(config.palette))
        case .handshake:
            return t16(0x6400 | UInt16(handshake))
        case .length:
            return t16(MultibootCipher.lengthWord(romSize: romSize))
        case .payload(let ptr):
            if data.available < 4 { return .needData(4) }
            let plain = readWord32(&data)
            return .transfer(cipher.encode(word: plain, address: ptr))
        case .transferDone, .crcReadyPoll:
            return t16(0x0065)
        case .crcAnnounce:
            return t16(0x0066)
        case .crcExchange:
            return t16(crc)
        case .finished(let r):
            return .finished(r)
        case .failed(let f):
            return .failed(f)
        }
    }

    /// 直前の転送に対する応答を解釈して状態遷移する
    private mutating func handle<D: MultibootDataSource>(response raw: UInt32, data: inout D) {
        switch state {
        case .idle, .finished, .failed:
            return

        case .connectPoll:
            let r = r16(raw)
            if r & 0xFFF0 == 0x7200 {
                // Normal mode ではスレーブは 1 台 (bit1) のみ
                if r & 0x000F != 0x0002 {
                    fail(.badClientBit, expected: 0x7202, got: r)
                    return
                }
                okCount += 1
                // GBATEK: 認識後 15 回繰り返して安定を確認
                if okCount >= 16 { state = .masterInfo }
            } else {
                okCount = 0
                attempts += 1
                if config.connectAttempts != 0 && attempts >= config.connectAttempts {
                    fail(.connectTimeout, expected: 0x7202, got: r)
                    return
                }
                pendingWaitUs = config.pollIntervalUs
            }

        case .masterInfo:
            let r = r16(raw)
            guard r == 0x7202 else { fail(.masterInfo, expected: 0x7202, got: r); return }
            state = .header(index: 0)

        case .header(let index):
            // 応答: 上位 8bit = 残り回数 (60h..01h)、下位 8bit = client bit
            let r = r16(raw)
            let expectedCount = UInt32(0x60 - index)
            let expected = expectedCount << 8 | 0x02
            guard r == expected else { fail(.headerAck, expected: expected, got: r); return }
            if index + 1 >= 0x60 {
                state = .headerDone
            } else {
                state = .header(index: index + 1)
            }

        case .headerDone:
            let r = r16(raw)
            guard r == 0x0002 else { fail(.headerDone, expected: 0x0002, got: r); return }
            state = .masterInfo2

        case .masterInfo2:
            let r = r16(raw)
            guard r == 0x7202 else { fail(.masterInfo, expected: 0x7202, got: r); return }
            state = .palettePoll
            attempts = 0

        case .palettePoll:
            let r = r16(raw)
            if r & 0xFF00 == 0x7300 {
                clientData = UInt8(truncatingIfNeeded: r)
                handshake = MultibootCipher.handshakeData(clientData: clientData)
                state = .handshake
            } else {
                attempts += 1
                if attempts >= config.paletteAttempts {
                    fail(.paletteTimeout, expected: 0x7300, got: r)
                }
            }

        case .handshake:
            let r = r16(raw)
            guard r & 0xFF00 == 0x7300 else { fail(.handshakeAck, expected: 0x7300, got: r); return }
            // GBATEK: SWI 25h はここで 1/16 秒待つ
            pendingWaitUs = config.pollIntervalUs
            state = .length

        case .length:
            let r = r16(raw)
            guard r & 0xFF00 == 0x7300 else { fail(.lengthAck, expected: 0x7300, got: r); return }
            randomData = UInt8(truncatingIfNeeded: r)
            cipher = MultibootCipher(
                palette: config.palette, clientData: clientData, handshake: handshake, randomData: randomData)
            state = .payload(ptr: UInt32(ROMImage.headerSize))

        case .payload(let ptr):
            // 応答の上位 16bit = 宛先アドレスの下位 16bit
            let r = raw >> 16
            let expected = ptr & 0xFFFF
            guard r == expected else { fail(.payloadAck, expected: expected, got: r); return }
            let next = ptr + 4
            if Int(next) >= romSize {
                crc = cipher.finish()
                state = .transferDone
                attempts = 0
            } else {
                state = .payload(ptr: next)
            }

        case .transferDone:
            let r = r16(raw)
            let expected = UInt32(romSize & 0xFFFF)
            guard r == expected else { fail(.transferDoneAck, expected: expected, got: r); return }
            state = .crcReadyPoll

        case .crcReadyPoll:
            let r = r16(raw)
            if r == 0x0075 {
                state = .crcAnnounce
            } else if r == 0x0074 {
                attempts += 1
                if attempts >= config.crcReadyAttempts { fail(.crcReadyAck, expected: 0x0075, got: r) }
            } else {
                fail(.crcReadyAck, expected: 0x0075, got: r)
            }

        case .crcAnnounce:
            let r = r16(raw)
            guard r == 0x0075 else { fail(.crcAnnounceAck, expected: 0x0075, got: r); return }
            state = .crcExchange

        case .crcExchange:
            let r = r16(raw)
            guard r == UInt32(crc) else { fail(.crcMismatch, expected: UInt32(crc), got: r); return }
            state = .finished(MultibootResult(
                crc: crc, palette: config.palette, clientData: clientData, handshake: handshake, randomData: randomData))
        }
    }
}
