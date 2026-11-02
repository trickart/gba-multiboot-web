// LinkCore の定義から TypeScript の定数ファイルを生成する。
//   swift run ProtocolGen > web/src/protocol.generated.ts
import LinkCore

func emitEnum<T: CaseIterable & RawRepresentable>(_ name: String, _ type: T.Type) where T.RawValue == UInt8 {
    print("export const \(name) = {")
    for c in T.allCases {
        print("  \(String(describing: c)): 0x\(String(c.rawValue, radix: 16, uppercase: true).leftPad(2)),")
    }
    print("} as const;")
    print("export type \(name) = (typeof \(name))[keyof typeof \(name)];")
    print("export const \(name)Name: Record<number, string> = {")
    for c in T.allCases {
        print("  0x\(String(c.rawValue, radix: 16, uppercase: true).leftPad(2)): \"\(String(describing: c))\",")
    }
    print("};")
    print("")
}

extension String {
    func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}

print("// このファイルは `swift run ProtocolGen` により Sources/LinkCore から生成されます。手で編集しないでください。")
print("/* eslint-disable */")
print("")
print("export const PROTOCOL_VERSION = \(LinkProtocol.version);")
print("export const FRAME_HEADER_SIZE = \(LinkProtocol.frameHeaderSize);")
print("export const MAX_PAYLOAD = \(LinkProtocol.maxPayload);")
print("export const DEFAULT_RING_CAPACITY = \(LinkProtocol.defaultRingCapacity);")
print("export const ROM_HEADER_SIZE = 0x\(String(ROMImage.headerSize, radix: 16, uppercase: true));")
print("export const ROM_MIN_TOTAL_SIZE = 0x\(String(ROMImage.minTotalSize, radix: 16, uppercase: true));")
print("export const ROM_MAX_TOTAL_SIZE = 0x\(String(ROMImage.maxTotalSize, radix: 16, uppercase: true));")
print("export const ROM_BODY_ALIGNMENT = 0x\(String(ROMImage.bodyAlignment, radix: 16, uppercase: true));")
print("")
emitEnum("Command", CommandType.self)
emitEnum("Event", EventType.self)
emitEnum("MultibootPhase", MultibootPhase.self)
emitEnum("MultibootErrorCode", MultibootErrorCode.self)
print("export const RomCheck = {")
print("  sizeOK: 0x\(String(ROMImage.Check.sizeOK.rawValue, radix: 16)),")
print("  headerChecksumOK: 0x\(String(ROMImage.Check.headerChecksumOK.rawValue, radix: 16)),")
print("  logoOK: 0x\(String(ROMImage.Check.logoOK.rawValue, radix: 16)),")
print("  multibootEntryOK: 0x\(String(ROMImage.Check.multibootEntryOK.rawValue, radix: 16)),")
print("} as const;")
