// Embedded Swift でビルドした LinkCore (core.wasm) のローダと薄いラッパ。
// エクスポート関数の一覧は Sources/LinkCoreWasm/Exports.swift を参照。

interface CoreExports {
  memory: WebAssembly.Memory;
  lc_protocol_version(): number;
  lc_rom_buffer(): number;
  lc_rom_capacity(): number;
  lc_rom_check(len: number): number;
  lc_rom_padded_size(len: number): number;
  lc_rom_min_size(): number;
  lc_rom_max_size(): number;
  lc_crc(len: number, palette: number, cc: number, hh: number, rr: number): number;
  lc_engine_start(size: number, palette: number, connectAttempts: number): number;
  lc_engine_step(hasResponse: number, response: number): number;
  lc_engine_abort(): number;
  lc_action_value(): number;
  lc_engine_phase(): number;
  lc_engine_consumed(): number;
  lc_result_field(index: number): number;
  lc_failure_field(index: number): number;
}

export const ActionKind = {
  transfer: 1,
  wait: 2,
  needData: 3,
  finished: 4,
  failed: 5,
} as const;
export type ActionKind = (typeof ActionKind)[keyof typeof ActionKind];

export interface EngineResult {
  crc: number;
  palette: number;
  clientData: number;
  handshake: number;
  randomData: number;
}

export interface EngineFailure {
  code: number;
  phase: number;
  expected: number;
  got: number;
}

/** Embedded Swift (wasip1 ターゲット) が要求する WASI インポートの最小スタブ */
function wasiStubs(getMemory: () => WebAssembly.Memory) {
  const ENOSYS = 52;
  return {
    args_get: () => 0,
    args_sizes_get: (argc: number, argvBufSize: number) => {
      const view = new DataView(getMemory().buffer);
      view.setUint32(argc, 0, true);
      view.setUint32(argvBufSize, 0, true);
      return 0;
    },
    fd_close: () => 0,
    fd_fdstat_get: () => ENOSYS,
    fd_seek: () => ENOSYS,
    fd_write: (_fd: number, _iovs: number, _iovsLen: number, nwritten: number) => {
      new DataView(getMemory().buffer).setUint32(nwritten, 0, true);
      return 0;
    },
    proc_exit: (code: number) => {
      throw new Error(`wasm proc_exit(${code})`);
    },
  };
}

export class LinkCore {
  private constructor(private readonly ex: CoreExports) {}

  static async load(url: string): Promise<LinkCore> {
    let memory: WebAssembly.Memory | undefined;
    const imports = { wasi_snapshot_preview1: wasiStubs(() => memory!) };
    const { instance } = await WebAssembly.instantiateStreaming(fetch(url), imports);
    const ex = instance.exports as unknown as CoreExports;
    memory = ex.memory;
    return new LinkCore(ex);
  }

  get protocolVersion(): number {
    return this.ex.lc_protocol_version();
  }

  get romCapacity(): number {
    return this.ex.lc_rom_capacity();
  }

  get romMinSize(): number {
    return this.ex.lc_rom_min_size();
  }

  get romMaxSize(): number {
    return this.ex.lc_rom_max_size();
  }

  /** ROM を wasm メモリへコピーする (容量超過は例外) */
  loadROM(bytes: Uint8Array): void {
    if (bytes.length > this.romCapacity) {
      throw new Error(`ROM が大きすぎます: ${bytes.length} > ${this.romCapacity}`);
    }
    const base = this.ex.lc_rom_buffer();
    const mem = new Uint8Array(this.ex.memory.buffer, base, this.romCapacity);
    mem.fill(0);
    mem.set(bytes);
  }

  /** loadROM 済みの先頭 len バイトを検査し、RomCheck のビットフラグを返す */
  romCheck(len: number): number {
    return this.ex.lc_rom_check(len);
  }

  paddedSize(len: number): number {
    return this.ex.lc_rom_padded_size(len);
  }

  /** loadROM 済み (パディング後の長さ len) に対する Multiboot CRC */
  crc(len: number, palette: number, clientData: number, handshake: number, randomData: number): number {
    return this.ex.lc_crc(len, palette, clientData, handshake, randomData) & 0xffff;
  }

  // ---- ホスト駆動モード用エンジン -------------------------------------------------

  engineStart(size: number, palette: number, connectAttempts: number): ActionKind {
    return this.ex.lc_engine_start(size, palette, connectAttempts) as ActionKind;
  }

  engineStep(response: number | null): ActionKind {
    return this.ex.lc_engine_step(response === null ? 0 : 1, response ?? 0) as ActionKind;
  }

  engineAbort(): ActionKind {
    return this.ex.lc_engine_abort() as ActionKind;
  }

  /** 直前のアクションの値 (transfer: ワード、wait: µs、needData: バイト数) */
  actionValue(): number {
    return this.ex.lc_action_value() >>> 0;
  }

  enginePhase(): number {
    return this.ex.lc_engine_phase();
  }

  engineConsumed(): number {
    return this.ex.lc_engine_consumed();
  }

  result(): EngineResult {
    return {
      crc: this.ex.lc_result_field(0),
      palette: this.ex.lc_result_field(1),
      clientData: this.ex.lc_result_field(2),
      handshake: this.ex.lc_result_field(3),
      randomData: this.ex.lc_result_field(4),
    };
  }

  failure(): EngineFailure {
    return {
      code: this.ex.lc_failure_field(0),
      phase: this.ex.lc_failure_field(1),
      expected: this.ex.lc_failure_field(2) >>> 0,
      got: this.ex.lc_failure_field(3) >>> 0,
    };
  }
}
