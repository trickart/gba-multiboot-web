// USB (WebUSB ベンダーインターフェース) 上でホストとファームウェアが交換するフレームの定義。
//
// フレーム形式 (双方向共通、バイトストリーム上に連続):
//   [type: UInt8][length: UInt16 LE][payload: length bytes]
//
// ホスト→デバイスは CommandType、デバイス→ホストは EventType を type に使う。
// 数値はすべてリトルエンディアン。

public enum LinkProtocol {
    /// ホストとファームウェアで一致していなければならないプロトコル版。
    public static let version: UInt8 = 1
    public static let frameHeaderSize: Int = 3
    /// 1 フレームのペイロード上限。MB_DATA 以外のフレームはこれより小さい。
    public static let maxPayload: Int = 2048
    /// ファームウェア側 ROM リングバッファの既定容量 (バイト)。INFO イベントで実際の値を通知する。
    public static let defaultRingCapacity: Int = 32768
}

/// ホスト → デバイス
public enum CommandType: UInt8, CaseIterable {
    /// 機能情報を要求する。payload なし → `info`
    case getInfo = 0x01
    /// 転送設定。payload: clockHz u32, gapUs u16, palette u8, connectTimeoutMs u32 → `info`
    case setConfig = 0x02
    /// Multiboot 開始。payload: romSize u32 (ヘッダ 0xC0 を含む全長、16 バイト境界)
    case mbStart = 0x10
    /// ROM データ (先頭から順に)。payload: bytes
    case mbData = 0x11
    /// 進行中の Multiboot を中止
    case mbAbort = 0x12
    /// 32bit 1 ワードを生で交換。payload: word u32 → `xferResult`
    case xfer32 = 0x20
    /// 16bit 1 ワードを交換 (上位 16bit を 0 で送り、応答の上位 16bit を返す)。payload: word u16 → `xferResult`
    case xfer16 = 0x21
    /// 状態を初期化し、バッファを捨てる
    case reset = 0x30
    /// RP2040 を UF2 ブートローダ (BOOTSEL) で再起動する
    case bootsel = 0x7F
}

/// デバイス → ホスト
public enum EventType: UInt8, CaseIterable {
    /// payload: protoVer u8, fwMajor u8, fwMinor u8, fwPatch u8, ringCapacity u32, clockHz u32, gapUs u16, palette u8, connectTimeoutMs u32
    case info = 0x80
    /// payload: UTF-8 テキスト
    case log = 0x81
    /// payload: phase u8 (MultibootPhase), detail u32
    case mbStatus = 0x90
    /// payload: consumed u32 (GBA へ送り終えた ROM バイト数), total u32
    case mbProgress = 0x91
    /// payload: crc u16, elapsedMs u32, clientData u8, handshake u8, randomData u8, palette u8
    case mbDone = 0x92
    /// payload: code u8 (MultibootErrorCode), phase u8, expected u32, got u32
    case mbError = 0x93
    /// payload: word u32
    case xferResult = 0xA0
    /// 不正なコマンドを受けた。payload: type u8
    case nak = 0xFE
}

public struct FrameHeader: Equatable, Sendable {
    public var type: UInt8
    public var length: UInt16

    public init(type: UInt8, length: UInt16) {
        self.type = type
        self.length = length
    }

    /// 3 バイトのヘッダを書き込む
    public func write(to out: UnsafeMutablePointer<UInt8>) {
        out[0] = type
        out[1] = UInt8(truncatingIfNeeded: length)
        out[2] = UInt8(truncatingIfNeeded: length >> 8)
    }

    public static func read(from p: UnsafePointer<UInt8>) -> FrameHeader {
        FrameHeader(type: p[0], length: UInt16(p[1]) | UInt16(p[2]) << 8)
    }
}

/// バイトストリームからフレームヘッダを切り出す状態機械。
/// ペイロードは呼び出し側が `remaining` バイト読み取り、`consumePayload` で通知する。
/// (MB_DATA のように大きなペイロードをバッファせずリングバッファへ直接流すための設計)
public struct FrameParser: Sendable {
    private var headerBytes: (UInt8, UInt8, UInt8) = (0, 0, 0)
    private var headerCount: Int = 0
    /// 現在ペイロード受信中のフレーム。nil ならヘッダ待ち。
    public private(set) var current: FrameHeader? = nil
    /// 現在のフレームで未受信のペイロードバイト数
    public private(set) var remaining: Int = 0

    public init() {}

    public var isReceivingPayload: Bool { current != nil }

    /// ヘッダ待ち状態で 1 バイト与える。ヘッダが完成したらそれを返す。
    /// (ペイロード受信中に呼ぶと nil を返し、バイトは捨てられる)
    public mutating func feedHeaderByte(_ b: UInt8) -> FrameHeader? {
        if current != nil { return nil }
        switch headerCount {
        case 0: headerBytes.0 = b
        case 1: headerBytes.1 = b
        default: headerBytes.2 = b
        }
        headerCount += 1
        if headerCount < 3 { return nil }
        headerCount = 0
        let h = FrameHeader(type: headerBytes.0, length: UInt16(headerBytes.1) | UInt16(headerBytes.2) << 8)
        remaining = Int(h.length)
        if remaining == 0 {
            // 空ペイロードは即完了
            return h
        }
        current = h
        return h
    }

    /// ペイロードを n バイト受け取ったことを通知する。フレーム完了で true。
    @discardableResult
    public mutating func consumePayload(_ n: Int) -> Bool {
        guard current != nil else { return true }
        remaining -= n
        if remaining <= 0 {
            remaining = 0
            current = nil
            return true
        }
        return false
    }

    public mutating func reset() {
        headerCount = 0
        current = nil
        remaining = 0
    }
}

/// リトルエンディアンの読み書きヘルパ (Foundation 非依存)
public enum LE {
    @inline(__always)
    public static func u16(_ p: UnsafePointer<UInt8>) -> UInt16 {
        UInt16(p[0]) | UInt16(p[1]) << 8
    }

    @inline(__always)
    public static func u32(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
    }

    @inline(__always)
    public static func put16(_ v: UInt16, _ p: UnsafeMutablePointer<UInt8>) {
        p[0] = UInt8(truncatingIfNeeded: v)
        p[1] = UInt8(truncatingIfNeeded: v >> 8)
    }

    @inline(__always)
    public static func put32(_ v: UInt32, _ p: UnsafeMutablePointer<UInt8>) {
        p[0] = UInt8(truncatingIfNeeded: v)
        p[1] = UInt8(truncatingIfNeeded: v >> 8)
        p[2] = UInt8(truncatingIfNeeded: v >> 16)
        p[3] = UInt8(truncatingIfNeeded: v >> 24)
    }
}
