// Web (ブラウザ) 向けエクスポート層。Embedded Swift で wasm32-unknown-none-wasm にビルドする。
//
// ブラウザ側 (web/src/wasm/core.ts) はここで公開した関数だけを呼ぶ。
// ヒープは使わず、ROM 用の静的バッファ (256 KiB) とエンジン状態をグローバルに持つ。
//
// 提供する機能:
//   - ROM 検査 / パディングサイズ計算 (LinkCore.ROMImage)
//   - 完了後の CRC 照合用計算 (LinkCore.MultibootCipher)
//   - Multiboot エンジンのホスト駆動 (ファームの XFER32 コマンド経由で 1 ワードずつ送る診断モード)
import LinkCore

#if hasFeature(Embedded)

// MARK: - 静的ストレージ

nonisolated(unsafe) private var romStorage = InlineArray<262144, UInt8>(repeating: 0)
nonisolated(unsafe) private var engine: MultibootEngine? = nil
nonisolated(unsafe) private var romSize: Int = 0
nonisolated(unsafe) private var source = BufferSource(base: UnsafePointer(bitPattern: 4)!, count: 0)
nonisolated(unsafe) private var lastAction: MultibootEngine.Action = .wait(0)

private func romBase() -> UnsafeMutablePointer<UInt8> {
    withUnsafeMutablePointer(to: &romStorage) {
        UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt8.self)
    }
}

private func romBuffer(_ len: Int) -> UnsafeBufferPointer<UInt8> {
    UnsafeBufferPointer(start: UnsafePointer(romBase()), count: len)
}

// MARK: - 基本情報

@_expose(wasm, "lc_protocol_version") @_cdecl("lc_protocol_version")
public func lc_protocol_version() -> UInt32 { UInt32(LinkProtocol.version) }

@_expose(wasm, "lc_rom_buffer") @_cdecl("lc_rom_buffer")
public func lc_rom_buffer() -> UnsafeMutableRawPointer { UnsafeMutableRawPointer(romBase()) }

@_expose(wasm, "lc_rom_capacity") @_cdecl("lc_rom_capacity")
public func lc_rom_capacity() -> UInt32 { 262144 }

// MARK: - ROM 検査

/// ROMImage.Check のビットフラグを返す
@_expose(wasm, "lc_rom_check") @_cdecl("lc_rom_check")
public func lc_rom_check(_ len: UInt32) -> UInt32 {
    ROMImage.check(romBuffer(Int(len))).rawValue
}

@_expose(wasm, "lc_rom_padded_size") @_cdecl("lc_rom_padded_size")
public func lc_rom_padded_size(_ len: UInt32) -> UInt32 {
    UInt32(ROMImage.paddedSize(Int(len)))
}

@_expose(wasm, "lc_rom_min_size") @_cdecl("lc_rom_min_size")
public func lc_rom_min_size() -> UInt32 { UInt32(ROMImage.minTotalSize) }

@_expose(wasm, "lc_rom_max_size") @_cdecl("lc_rom_max_size")
public func lc_rom_max_size() -> UInt32 { UInt32(ROMImage.maxTotalSize) }

/// バッファ先頭 len バイト (パディング済み) に対する Multiboot CRC
@_expose(wasm, "lc_crc") @_cdecl("lc_crc")
public func lc_crc(_ len: UInt32, _ palette: UInt32, _ clientData: UInt32, _ handshake: UInt32, _ randomData: UInt32) -> UInt32 {
    UInt32(MultibootCipher.crc(
        rom: romBuffer(Int(len)),
        palette: UInt8(truncatingIfNeeded: palette),
        clientData: UInt8(truncatingIfNeeded: clientData),
        handshake: UInt8(truncatingIfNeeded: handshake),
        randomData: UInt8(truncatingIfNeeded: randomData)))
}

// MARK: - エンジン (ホスト駆動モード)
//
// アクション種別: 1=transfer(value=送るワード) 2=wait(value=µs) 3=needData(value=バイト数)
//                4=finished 5=failed

private func kind(of a: MultibootEngine.Action) -> UInt32 {
    switch a {
    case .transfer: return 1
    case .wait: return 2
    case .needData: return 3
    case .finished: return 4
    case .failed: return 5
    }
}

@_expose(wasm, "lc_engine_start") @_cdecl("lc_engine_start")
public func lc_engine_start(_ size: UInt32, _ palette: UInt32, _ connectAttempts: UInt32) -> UInt32 {
    var cfg = MultibootConfig()
    cfg.palette = UInt8(truncatingIfNeeded: palette)
    cfg.connectAttempts = connectAttempts
    romSize = Int(size)
    source = BufferSource(base: UnsafePointer(romBase()), count: romSize)
    var e = MultibootEngine(romSize: romSize, config: cfg)
    lastAction = e.start(data: &source)
    engine = e
    return kind(of: lastAction)
}

@_expose(wasm, "lc_engine_step") @_cdecl("lc_engine_step")
public func lc_engine_step(_ hasResponse: UInt32, _ response: UInt32) -> UInt32 {
    guard var e = engine else { return 0 }
    lastAction = e.step(response: hasResponse != 0 ? response : nil, data: &source)
    engine = e
    return kind(of: lastAction)
}

@_expose(wasm, "lc_engine_abort") @_cdecl("lc_engine_abort")
public func lc_engine_abort() -> UInt32 {
    guard var e = engine else { return 0 }
    lastAction = e.abort()
    engine = e
    return kind(of: lastAction)
}

@_expose(wasm, "lc_action_value") @_cdecl("lc_action_value")
public func lc_action_value() -> UInt32 {
    switch lastAction {
    case .transfer(let w): return w
    case .wait(let us): return us
    case .needData(let n): return UInt32(n)
    case .finished(let r): return UInt32(r.crc)
    case .failed(let f): return UInt32(f.code.rawValue)
    }
}

@_expose(wasm, "lc_engine_phase") @_cdecl("lc_engine_phase")
public func lc_engine_phase() -> UInt32 { UInt32(engine?.phase.rawValue ?? 0) }

@_expose(wasm, "lc_engine_consumed") @_cdecl("lc_engine_consumed")
public func lc_engine_consumed() -> UInt32 { UInt32(engine?.bytesConsumed ?? 0) }

/// finished 時: 0=crc 1=palette 2=clientData 3=handshake 4=randomData
@_expose(wasm, "lc_result_field") @_cdecl("lc_result_field")
public func lc_result_field(_ index: UInt32) -> UInt32 {
    guard case .finished(let r) = lastAction else { return 0 }
    switch index {
    case 0: return UInt32(r.crc)
    case 1: return UInt32(r.palette)
    case 2: return UInt32(r.clientData)
    case 3: return UInt32(r.handshake)
    default: return UInt32(r.randomData)
    }
}

/// failed 時: 0=code 1=phase 2=expected 3=got
@_expose(wasm, "lc_failure_field") @_cdecl("lc_failure_field")
public func lc_failure_field(_ index: UInt32) -> UInt32 {
    guard case .failed(let f) = lastAction else { return 0 }
    switch index {
    case 0: return UInt32(f.code.rawValue)
    case 1: return UInt32(f.phase.rawValue)
    case 2: return f.expected
    default: return f.got
    }
}

#else
// ホスト (macOS/Linux) で `swift build` したときのダミー。実体は wasm ビルドのみ。
@main
struct LinkCoreWasmHostStub {
    static func main() {
        print("LinkCoreWasm は wasm 専用です。scripts/build-wasm.sh を使ってください。")
    }
}
#endif
