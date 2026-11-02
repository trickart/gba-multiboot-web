// Multiboot 転送のホスト側オーケストレーション。
//
//   ファーム駆動モード (既定): ROM をストリーミングで送り、ファーム内の MultibootEngine が GBA と通信する。
//   ホスト駆動モード (診断用): wasm 内の MultibootEngine を動かし、1 ワードずつ XFER32 で送る。
//                              共有コードの動作確認用で、USB 往復が 6 万回以上になるため非常に遅い。
import { Command, Event, MultibootPhase, PROTOCOL_VERSION } from "./protocol.generated";
import type { Frame, LinkTransport } from "./serial/transport";
import { ActionKind, type LinkCore } from "./wasm/core";

export interface DeviceInfo {
  protocolVersion: number;
  firmwareVersion: string;
  ringCapacity: number;
  clockHz: number;
  gapUs: number;
  palette: number;
  connectTimeoutMs: number;
}

export interface TransferOptions {
  clockHz: number;
  gapUs: number;
  palette: number;
  connectTimeoutMs: number;
  /** 1 回の USB 転送で送る ROM バイト数 */
  chunkSize?: number;
}

export interface TransferProgress {
  phase: number;
  consumed: number;
  sent: number;
  total: number;
}

export interface TransferResult {
  crc: number;
  elapsedMs: number;
  clientData: number;
  handshake: number;
  randomData: number;
  palette: number;
  /** wasm 側で再計算した CRC と一致したか (wasm が無い場合は undefined) */
  crcVerified?: boolean;
}

export class MultibootError extends Error {
  constructor(
    readonly code: number,
    readonly phase: number,
    readonly expected: number,
    readonly got: number,
  ) {
    super(`multiboot error code=${code} phase=${phase}`);
  }
}

const u8 = (v: number) => new Uint8Array([v & 0xff]);
const le16 = (v: number) => new Uint8Array([v & 0xff, (v >> 8) & 0xff]);
const le32 = (v: number) => new Uint8Array([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >>> 24) & 0xff]);
const concat = (...parts: Uint8Array[]) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
};
const dv = (p: Uint8Array) => new DataView(p.buffer, p.byteOffset, p.byteLength);
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export function parseInfo(payload: Uint8Array): DeviceInfo {
  const v = dv(payload);
  return {
    protocolVersion: v.getUint8(0),
    firmwareVersion: `${v.getUint8(1)}.${v.getUint8(2)}.${v.getUint8(3)}`,
    ringCapacity: v.getUint32(4, true),
    clockHz: v.getUint32(8, true),
    gapUs: v.getUint16(12, true),
    palette: v.getUint8(14),
    connectTimeoutMs: v.getUint32(15, true),
  };
}

/** フレームを購読し、条件を満たすものを待てるようにする小さなイベントハブ */
class FrameHub {
  private waiters: { pred: (f: Frame) => boolean; resolve: (f: Frame) => void; reject: (e: Error) => void }[] = [];
  readonly listeners = new Set<(f: Frame) => void>();

  dispatch(frame: Frame): void {
    for (const l of this.listeners) l(frame);
    this.waiters = this.waiters.filter((w) => {
      if (!w.pred(frame)) return true;
      w.resolve(frame);
      return false;
    });
  }

  readonly failListeners = new Set<(e: Error) => void>();

  fail(error: Error): void {
    const ws = this.waiters;
    this.waiters = [];
    for (const w of ws) w.reject(error);
    for (const l of this.failListeners) l(error);
  }

  waitFor(pred: (f: Frame) => boolean, timeoutMs: number, what: string): Promise<Frame> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w.resolve !== wrapped);
        reject(new Error(`${what} の応答がありません (${timeoutMs} ms)`));
      }, timeoutMs);
      const wrapped = (f: Frame) => {
        clearTimeout(timer);
        resolve(f);
      };
      this.waiters.push({
        pred,
        resolve: wrapped,
        reject: (e) => {
          clearTimeout(timer);
          reject(e);
        },
      });
    });
  }
}

export class LinkDevice {
  private readonly hub = new FrameHub();
  info: DeviceInfo | null = null;
  onLog: ((text: string) => void) | null = null;
  onDisconnect: (() => void) | null = null;

  constructor(
    readonly transport: LinkTransport,
    readonly core: LinkCore | null,
  ) {
    transport.onFrame = (f) => {
      if (f.type === Event.log) this.onLog?.(new TextDecoder().decode(f.payload));
      this.hub.dispatch(f);
    };
    transport.onDisconnect = () => {
      this.hub.fail(new Error("シリアルポートが切断されました"));
      this.onDisconnect?.();
    };
  }

  /** ファームの状態を初期化し、前回の転送の残りデータを捨てさせる */
  async reset(): Promise<void> {
    const p = this.hub.waitFor((f) => f.type === Event.mbStatus && f.payload[0] === MultibootPhase.idle, 1500, "RESET");
    await this.transport.send(Command.reset);
    await p;
  }

  async handshake(): Promise<DeviceInfo> {
    await this.transport.send(Command.reset);
    const p = this.hub.waitFor((f) => f.type === Event.info, 1500, "GET_INFO");
    await this.transport.send(Command.getInfo);
    const info = parseInfo((await p).payload);
    if (info.protocolVersion !== PROTOCOL_VERSION) {
      throw new Error(
        `プロトコル版が一致しません (ファームウェア v${info.protocolVersion} / Web v${PROTOCOL_VERSION})。ファームウェアを更新してください。`,
      );
    }
    this.info = info;
    return info;
  }

  async configure(opts: TransferOptions): Promise<DeviceInfo> {
    const payload = concat(le32(opts.clockHz), le16(opts.gapUs), u8(opts.palette), le32(opts.connectTimeoutMs));
    const p = this.hub.waitFor((f) => f.type === Event.info, 1500, "SET_CONFIG");
    await this.transport.send(Command.setConfig, payload);
    this.info = parseInfo((await p).payload);
    return this.info;
  }

  async rebootToBootsel(): Promise<void> {
    await this.transport.send(Command.bootsel);
  }

  async exchange32(word: number): Promise<number> {
    const p = this.hub.waitFor((f) => f.type === Event.xferResult, 2000, "XFER32");
    await this.transport.send(Command.xfer32, le32(word));
    return dv((await p).payload).getUint32(0, true);
  }

  /** ファーム駆動モードで ROM を転送する */
  async upload(
    rom: Uint8Array,
    opts: TransferOptions,
    onProgress: (p: TransferProgress) => void,
    signal?: AbortSignal,
  ): Promise<TransferResult> {
    await this.reset();
    const info = await this.configure(opts);
    const total = rom.length;
    const chunkSize = opts.chunkSize ?? 1024;
    const inflightWindow = Math.max(chunkSize, info.ringCapacity);

    let consumed = 0;
    let sent = 0;
    let phase: number = MultibootPhase.idle;
    const report = () => onProgress({ phase, consumed, sent, total });

    return new Promise<TransferResult>((resolve, reject) => {
      let finished = false;
      let pump: Promise<void> | null = null;
      let wake: (() => void) | null = null;
      const notify = () => {
        wake?.();
        wake = null;
      };

      const onFail = (e: Error) => finish(() => reject(e));
      const finish = (fn: () => void) => {
        if (finished) return;
        finished = true;
        this.hub.listeners.delete(listener);
        this.hub.failListeners.delete(onFail);
        signal?.removeEventListener("abort", onAbort);
        fn();
      };

      const onAbort = () => {
        void this.transport.send(Command.mbAbort).catch(() => {});
      };

      const listener = (f: Frame) => {
        const v = dv(f.payload);
        switch (f.type) {
          case Event.mbStatus:
            phase = v.getUint8(0);
            report();
            break;
          case Event.mbProgress:
            consumed = v.getUint32(0, true);
            report();
            notify();
            break;
          case Event.mbDone: {
            const result: TransferResult = {
              crc: v.getUint16(0, true),
              elapsedMs: v.getUint32(2, true),
              clientData: v.getUint8(6),
              handshake: v.getUint8(7),
              randomData: v.getUint8(8),
              palette: v.getUint8(9),
            };
            if (this.core) {
              this.core.loadROM(rom);
              const expected = this.core.crc(rom.length, result.palette, result.clientData, result.handshake, result.randomData);
              result.crcVerified = expected === result.crc;
            }
            phase = MultibootPhase.done;
            consumed = total;
            report();
            finish(() => resolve(result));
            break;
          }
          case Event.mbError:
            phase = MultibootPhase.failed;
            report();
            finish(() => reject(new MultibootError(v.getUint8(0), v.getUint8(1), v.getUint32(2, true), v.getUint32(6, true))));
            break;
          case Event.nak:
            finish(() => reject(new Error(`ファームウェアがコマンド 0x${v.getUint8(0).toString(16)} を拒否しました`)));
            break;
        }
      };
      this.hub.listeners.add(listener);
      this.hub.failListeners.add(onFail);
      signal?.addEventListener("abort", onAbort, { once: true });

      // ROM ストリーミング: ファームが消費した量を見ながらリングバッファ分だけ先行して送る
      pump = (async () => {
        await this.transport.send(Command.mbStart, le32(total));
        while (sent < total && !finished) {
          if (sent - consumed + chunkSize > inflightWindow) {
            await new Promise<void>((r) => {
              wake = r;
              // 進捗が止まった場合の保険
              setTimeout(r, 500);
            });
            continue;
          }
          const chunk = rom.subarray(sent, Math.min(total, sent + chunkSize));
          await this.transport.send(Command.mbData, chunk);
          sent += chunk.length;
          report();
        }
      })();
      pump.catch((e) => finish(() => reject(e instanceof Error ? e : new Error(String(e)))));
    });
  }

  /** ホスト駆動 (診断) モード: wasm 内のエンジンで 1 ワードずつ送る */
  async uploadHostDriven(
    rom: Uint8Array,
    opts: TransferOptions,
    onProgress: (p: TransferProgress) => void,
    signal?: AbortSignal,
  ): Promise<TransferResult> {
    const core = this.core;
    if (!core) throw new Error("wasm (LinkCore) が読み込まれていないため、ホスト駆動モードは使えません");
    await this.reset();
    await this.configure(opts);
    core.loadROM(rom);
    const attempts = opts.connectTimeoutMs === 0 ? 0 : Math.max(1, Math.floor((opts.connectTimeoutMs * 1000) / 62_500));
    let kind = core.engineStart(rom.length, opts.palette, attempts);
    let lastReport = 0;
    for (;;) {
      if (signal?.aborted) kind = core.engineAbort();
      switch (kind) {
        case ActionKind.transfer: {
          const r = await this.exchange32(core.actionValue());
          kind = core.engineStep(r);
          break;
        }
        case ActionKind.wait:
          await sleep(core.actionValue() / 1000);
          kind = core.engineStep(null);
          break;
        case ActionKind.needData:
          throw new Error("内部エラー: ROM 全体が与えられているのに needData が返されました");
        case ActionKind.finished: {
          const r = core.result();
          onProgress({ phase: MultibootPhase.done, consumed: rom.length, sent: rom.length, total: rom.length });
          return { ...r, elapsedMs: 0, crcVerified: true };
        }
        case ActionKind.failed: {
          const f = core.failure();
          onProgress({ phase: MultibootPhase.failed, consumed: core.engineConsumed(), sent: rom.length, total: rom.length });
          throw new MultibootError(f.code, f.phase, f.expected, f.got);
        }
      }
      const consumed = core.engineConsumed();
      if (consumed - lastReport >= 512 || kind !== ActionKind.transfer) {
        lastReport = consumed;
        onProgress({ phase: core.enginePhase(), consumed, sent: rom.length, total: rom.length });
      }
    }
  }
}
