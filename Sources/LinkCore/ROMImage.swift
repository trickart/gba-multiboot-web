// Multiboot で送る ROM イメージのサイズ制約とヘッダ検査。

public enum ROMImage {
    /// ヘッダ長 (Nintendo ロゴ等、2000000h..20000BFh に書かれる)
    public static let headerSize = 0xC0
    /// 本体 (ヘッダ除く) の最小長・最大長・境界 (GBATEK)
    public static let minBodySize = 0x100
    public static let maxBodySize = 0x3FF40
    public static let bodyAlignment = 0x10
    public static let maxTotalSize = headerSize + maxBodySize   // 0x40000 = 256 KiB

    public static let minTotalSize = headerSize + minBodySize

    /// 送信時の全長 (16 バイト境界へ切り上げ、最小長を保証)
    public static func paddedSize(_ size: Int) -> Int {
        var s = size
        if s < minTotalSize { s = minTotalSize }
        let rem = (s - headerSize) % bodyAlignment
        if rem != 0 { s += bodyAlignment - rem }
        return s
    }

    /// 全長が Multiboot で送れる形になっているか
    public static func isValidTotalSize(_ size: Int) -> Bool {
        size >= minTotalSize && size <= maxTotalSize && (size - headerSize) % bodyAlignment == 0
    }

    /// ヘッダ補数チェックサム (0xA0..0xBC の和の補数 - 0x19) が 0xBD と一致するか
    public static func headerChecksumValid(_ rom: UnsafeBufferPointer<UInt8>) -> Bool {
        guard rom.count >= headerSize else { return false }
        var sum: UInt8 = 0
        for i in 0xA0...0xBC { sum = sum &- rom[i] }
        sum = sum &- 0x19
        return sum == rom[0xBD]
    }

    /// 0x04 に Nintendo ロゴの先頭 4 バイト (24 FF AE 51) があるか
    public static func hasNintendoLogo(_ rom: UnsafeBufferPointer<UInt8>) -> Bool {
        guard rom.count >= 8 else { return false }
        return rom[4] == 0x24 && rom[5] == 0xFF && rom[6] == 0xAE && rom[7] == 0x51
    }

    /// Multiboot エントリ (0xC0 の分岐命令) が入っているか。
    /// 0xC0 の ARM 命令が B (条件コード AL, 0xEA) かで判定する。
    public static func hasMultibootEntry(_ rom: UnsafeBufferPointer<UInt8>) -> Bool {
        guard rom.count >= 0xC4 else { return false }
        return rom[0xC3] == 0xEA
    }

    public struct Check: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let sizeOK = Check(rawValue: 1 << 0)
        public static let headerChecksumOK = Check(rawValue: 1 << 1)
        public static let logoOK = Check(rawValue: 1 << 2)
        public static let multibootEntryOK = Check(rawValue: 1 << 3)
    }

    /// Web/ホスト側で ROM を選んだときの一括検査
    public static func check(_ rom: UnsafeBufferPointer<UInt8>) -> Check {
        var r: Check = []
        if rom.count >= minTotalSize - 0x100 && rom.count <= maxTotalSize && rom.count > headerSize { r.insert(.sizeOK) }
        if headerChecksumValid(rom) { r.insert(.headerChecksumOK) }
        if hasNintendoLogo(rom) { r.insert(.logoOK) }
        if hasMultibootEntry(rom) { r.insert(.multibootEntryOK) }
        return r
    }
}
