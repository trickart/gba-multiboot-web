// Web Serial (USB CDC-ACM) でファームウェアに接続し、フレーム単位で送受信する。
import { FRAME_HEADER_SIZE } from "../protocol.generated";

/** ファームウェア (firmware/CMakeLists.txt の USB_VID / USB_PID) と合わせる。
 *  Raspberry Pi が RP2040 の CDC デバイス向けに公開している共通 ID (pico-sdk stdio_usb と同じ)。 */
export const SERIAL_FILTERS: SerialPortFilter[] = [{ usbVendorId: 0x2e8a, usbProductId: 0x000a }];

/** USB CDC では意味を持たないが open() に必須。1200 はファーム側で BOOTSEL 再起動の合図に使うので避ける。 */
const BAUD_RATE = 115200;

export interface Frame {
  type: number;
  payload: Uint8Array;
}

/** バイトストリームからフレームを切り出す */
export class FrameDecoder {
  private buf = new Uint8Array(0);

  push(chunk: Uint8Array): Frame[] {
    const merged = new Uint8Array(this.buf.length + chunk.length);
    merged.set(this.buf);
    merged.set(chunk, this.buf.length);
    this.buf = merged;

    const frames: Frame[] = [];
    let offset = 0;
    while (this.buf.length - offset >= FRAME_HEADER_SIZE) {
      const type = this.buf[offset]!;
      const length = this.buf[offset + 1]! | (this.buf[offset + 2]! << 8);
      if (this.buf.length - offset < FRAME_HEADER_SIZE + length) break;
      frames.push({
        type,
        payload: this.buf.slice(offset + FRAME_HEADER_SIZE, offset + FRAME_HEADER_SIZE + length),
      });
      offset += FRAME_HEADER_SIZE + length;
    }
    this.buf = this.buf.slice(offset);
    return frames;
  }

  reset(): void {
    this.buf = new Uint8Array(0);
  }
}

export function encodeFrame(type: number, payload: Uint8Array = new Uint8Array(0)): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(FRAME_HEADER_SIZE + payload.length);
  out[0] = type;
  out[1] = payload.length & 0xff;
  out[2] = (payload.length >> 8) & 0xff;
  out.set(payload, FRAME_HEADER_SIZE);
  return out;
}

export type FrameHandler = (frame: Frame) => void;

export class LinkTransport {
  private readonly decoder = new FrameDecoder();
  private reader: ReadableStreamDefaultReader<Uint8Array> | null = null;
  private writer: WritableStreamDefaultWriter<Uint8Array> | null = null;
  private closed = false;

  onFrame: FrameHandler | null = null;
  onDisconnect: (() => void) | null = null;

  private constructor(readonly port: SerialPort) {}

  static isSupported(): boolean {
    return typeof navigator !== "undefined" && "serial" in navigator;
  }

  /** ユーザー操作からポート選択ダイアログを開く */
  static async request(): Promise<LinkTransport> {
    const port = await navigator.serial.requestPort({ filters: SERIAL_FILTERS });
    return new LinkTransport(port);
  }

  /** 以前に許可済みのポートがあればダイアログなしで返す */
  static async reconnect(): Promise<LinkTransport | null> {
    const ports = await navigator.serial.getPorts();
    const port = ports.find((p) => {
      const info = p.getInfo();
      return SERIAL_FILTERS.some((f) => info.usbVendorId === f.usbVendorId && info.usbProductId === f.usbProductId);
    });
    return port ? new LinkTransport(port) : null;
  }

  /** Web Serial は製品名やシリアル番号を返さないので、識別は GET_INFO に任せる */
  get label(): string {
    const info = this.port.getInfo();
    const vid = info.usbVendorId?.toString(16).padStart(4, "0") ?? "????";
    const pid = info.usbProductId?.toString(16).padStart(4, "0") ?? "????";
    return `USB ${vid}:${pid}`;
  }

  async open(): Promise<void> {
    // bufferSize: 既定 255 バイトでは読み取りが細切れになるので大きくする
    await this.port.open({ baudRate: BAUD_RATE, bufferSize: 65536 });
    // Chrome は open() で DTR/RTS を立てるが、明示しておく (ファームは DTR を接続中の印に使う)
    await this.port.setSignals({ dataTerminalReady: true, requestToSend: true }).catch(() => {});
    if (!this.port.readable || !this.port.writable) throw new Error("シリアルポートのストリームを取得できません");
    this.reader = this.port.readable.getReader();
    this.writer = this.port.writable.getWriter();
    this.closed = false;
    this.decoder.reset();
    void this.readLoop();
    navigator.serial.addEventListener("disconnect", this.handleDisconnect);
  }

  private handleDisconnect = (ev: Event) => {
    if ((ev as Event & { target: EventTarget | null }).target === this.port) {
      this.markClosed();
    }
  };

  private markClosed(): void {
    if (this.closed) return;
    this.closed = true;
    this.onDisconnect?.();
  }

  private async readLoop(): Promise<void> {
    const reader = this.reader;
    if (!reader) return;
    try {
      while (!this.closed) {
        const { value, done } = await reader.read();
        if (done) break;
        if (value && value.length > 0) {
          for (const frame of this.decoder.push(value)) this.onFrame?.(frame);
        }
      }
    } catch (e) {
      if (!this.closed) console.warn("serial read loop ended:", e);
    } finally {
      reader.releaseLock();
      this.reader = null;
      this.markClosed();
    }
  }

  async send(type: number, payload?: Uint8Array): Promise<void> {
    await this.sendRaw(encodeFrame(type, payload));
  }

  async sendRaw(bytes: Uint8Array<ArrayBuffer>): Promise<void> {
    if (this.closed || !this.writer) throw new Error("シリアルポートは閉じています");
    await this.writer.write(bytes);
  }

  async close(): Promise<void> {
    this.closed = true;
    navigator.serial.removeEventListener("disconnect", this.handleDisconnect);
    try {
      await this.reader?.cancel();
    } catch {
      /* 既に閉じている */
    }
    try {
      this.writer?.releaseLock();
      this.writer = null;
      await this.port.setSignals({ dataTerminalReady: false }).catch(() => {});
      await this.port.close();
    } catch {
      /* 既に閉じている */
    }
  }
}
