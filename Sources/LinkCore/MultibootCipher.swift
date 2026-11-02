// GBA BIOS (SWI 25h MultiBoot) が行うチェックサム計算と暗号化。
// 出典: GBATEK "Multiboot Transfer Protocol" の擬似コード (Normal mode, 32bit 転送)。
//
//   if normal_mode then c=C387h : x=C37Bh : k=43202F2Fh
//   m=dword(pp,cc,cc,cc) : f=dword(hh,rr,rr,rr)
//   for ptr=C0h to size-4 step 4
//     c = c xor data ; 32 回 { c = c shr 1 ; if carry then c = c xor x }
//     m = 6F646573h*m + 1
//     send( data xor (-2000000h-ptr) xor m xor k )
//   c = c xor f ; 32 回同上
//
// Normal mode ではスレーブは 1 台なので client_data[2,3] / random_data[2,3] は FFh。

public struct MultibootCipher: Sendable {
    public static let crcInit: UInt32 = 0xC387
    public static let crcXor: UInt32 = 0xC37B
    public static let keyXor: UInt32 = 0x4320_2F2F
    public static let keyMul: UInt32 = 0x6F64_6573

    private var c: UInt32
    private var m: UInt32
    private let f: UInt32

    /// - Parameters:
    ///   - palette: pp (63pp で送ったパレット値)
    ///   - clientData: cc (73cc として GBA が返した乱数)
    ///   - handshake: hh (64hh で送った値 = 11h + cc + FFh + FFh)
    ///   - randomData: rr (長さ送信時に 73rr として GBA が返した乱数)
    public init(palette: UInt8, clientData: UInt8, handshake: UInt8, randomData: UInt8) {
        c = Self.crcInit
        m = 0xFFFF_0000 | UInt32(clientData) << 8 | UInt32(palette)
        f = 0xFFFF_0000 | UInt32(randomData) << 8 | UInt32(handshake)
    }

    /// GBA が計算する handshake_data (hh)
    public static func handshakeData(clientData: UInt8) -> UInt8 {
        UInt8(truncatingIfNeeded: 0x11 &+ UInt32(clientData) &+ 0xFF &+ 0xFF)
    }

    /// 長さ情報 llll = (size - C0h) / 4 - 34h
    public static func lengthWord(romSize: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: (romSize - 0xC0) / 4 - 0x34)
    }

    @inline(__always)
    private mutating func crcStep(_ v: UInt32) {
        c ^= v
        for _ in 0..<32 {
            let carry = c & 1
            c >>= 1
            if carry != 0 { c ^= Self.crcXor }
        }
    }

    /// ptr (0xC0 以降、4 の倍数) に置かれる平文ワードを暗号化し、CRC を更新する。
    public mutating func encode(word: UInt32, address ptr: UInt32) -> UInt32 {
        crcStep(word)
        m = Self.keyMul &* m &+ 1
        let complement = (0 &- 0x200_0000) &- ptr
        return word ^ complement ^ m ^ Self.keyXor
    }

    /// 全ワード送信後に呼ぶ。GBA と照合する 16bit CRC を返す。
    public mutating func finish() -> UInt16 {
        crcStep(f)
        return UInt16(truncatingIfNeeded: c)
    }

    /// 検証用: 一括計算 (Web 側でファームの報告値と照合するのに使う)
    public static func crc(
        rom: UnsafeBufferPointer<UInt8>, palette: UInt8, clientData: UInt8, handshake: UInt8, randomData: UInt8
    ) -> UInt16 {
        var cipher = MultibootCipher(palette: palette, clientData: clientData, handshake: handshake, randomData: randomData)
        var ptr = 0xC0
        while ptr + 4 <= rom.count {
            let w = LE.u32(rom.baseAddress! + ptr)
            _ = cipher.encode(word: w, address: UInt32(ptr))
            ptr += 4
        }
        return cipher.finish()
    }
}
