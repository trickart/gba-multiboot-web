// UI。フレームワークなしの素の DOM で組む。
import { MultibootErrorCode, MultibootPhase, ROM_BODY_ALIGNMENT, ROM_HEADER_SIZE } from "./protocol.generated";
import { describeChecks, readROMInfo } from "./rom";
import { LinkDevice, MultibootError, type DeviceInfo, type TransferOptions, type TransferProgress } from "./multiboot";
import { LinkTransport } from "./serial/transport";
import { LinkCore } from "./wasm/core";

const PHASE_TEXT: Record<number, string> = {
  [MultibootPhase.idle]: "待機中",
  [MultibootPhase.connecting]: "GBA を探しています (GBA の電源を入れてください)",
  [MultibootPhase.header]: "ヘッダを送信中",
  [MultibootPhase.palette]: "パレット/ハンドシェイク",
  [MultibootPhase.length]: "長さ情報を送信",
  [MultibootPhase.payload]: "本体を転送中",
  [MultibootPhase.crc]: "CRC を照合中",
  [MultibootPhase.done]: "完了",
  [MultibootPhase.failed]: "失敗",
};

const ERROR_TEXT: Record<number, string> = {
  [MultibootErrorCode.badSize]: "ROM サイズが不正です",
  [MultibootErrorCode.connectTimeout]: "GBA が見つかりませんでした。ケーブル接続と、カートリッジなしで電源を入れたか確認してください",
  [MultibootErrorCode.badClientBit]: "GBA が Normal mode の単一スレーブとして応答しませんでした",
  [MultibootErrorCode.masterInfo]: "マスタ/スレーブ情報交換で応答が一致しません",
  [MultibootErrorCode.headerAck]: "ヘッダ転送中に応答が一致しません (配線や通信速度を確認)",
  [MultibootErrorCode.headerDone]: "ヘッダ完了通知の応答が一致しません",
  [MultibootErrorCode.paletteTimeout]: "パレット応答が得られませんでした",
  [MultibootErrorCode.handshakeAck]: "ハンドシェイクの応答が一致しません",
  [MultibootErrorCode.lengthAck]: "長さ情報の応答が一致しません",
  [MultibootErrorCode.payloadAck]: "本体転送中に応答が一致しません (通信速度を下げてみてください)",
  [MultibootErrorCode.transferDoneAck]: "転送完了通知の応答が一致しません",
  [MultibootErrorCode.crcReadyAck]: "CRC 準備待ちで想定外の応答",
  [MultibootErrorCode.crcAnnounceAck]: "CRC 予告の応答が一致しません",
  [MultibootErrorCode.crcMismatch]: "CRC が一致しません (転送データが壊れています)",
  [MultibootErrorCode.aborted]: "中止しました",
};

const hex = (v: number, digits = 4) => "0x" + (v >>> 0).toString(16).toUpperCase().padStart(digits, "0");
const kib = (n: number) => `${(n / 1024).toFixed(n % 1024 === 0 ? 0 : 1)} KiB`;

function el<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attrs: Partial<HTMLElementTagNameMap[K]> & { class?: string } = {},
  ...children: (Node | string)[]
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  const { class: cls, ...rest } = attrs;
  if (cls) e.className = cls;
  Object.assign(e, rest);
  for (const c of children) e.append(c);
  return e;
}

/** ROM を Multiboot の制約 (本体 16 バイト境界、最小長) に合わせてパディングする */
function padROM(rom: Uint8Array, paddedSize: number): Uint8Array {
  if (paddedSize === rom.length) return rom;
  const out = new Uint8Array(paddedSize);
  out.set(rom);
  return out;
}

class App {
  private core: LinkCore | null = null;
  private device: LinkDevice | null = null;
  private rom: Uint8Array | null = null;
  private romName = "";
  private abort: AbortController | null = null;

  // DOM
  private readonly root = document.getElementById("app")!;
  private readonly connectBtn = el("button", { class: "primary", textContent: "デバイスに接続" });
  private readonly disconnectBtn = el("button", { textContent: "切断", disabled: true });
  private readonly bootselBtn = el("button", { textContent: "BOOTSEL で再起動 (ファーム更新)", disabled: true });
  private readonly deviceInfo = el("dl", { class: "kv" });
  private readonly drop = el("div", { class: "drop", textContent: "ここに .gba / .mb ファイルをドロップ、またはクリックして選択" });
  private readonly fileInput = el("input", { type: "file", accept: ".gba,.mb,.bin,application/octet-stream", hidden: true });
  private readonly romInfo = el("dl", { class: "kv" });
  private readonly checks = el("div", { class: "row" });
  private readonly clockSel = el("select");
  private readonly gapInput = el("input", { type: "number", min: "36", max: "1000", value: "40" });
  private readonly paletteInput = el("input", { type: "number", min: "0", max: "255", value: String(0xd1) });
  private readonly timeoutInput = el("input", { type: "number", min: "0", max: "600", value: "30" });
  private readonly modeSel = el("select");
  private readonly startBtn = el("button", { class: "primary", textContent: "転送開始", disabled: true });
  private readonly abortBtn = el("button", { textContent: "中止", disabled: true });
  private readonly progress = el("progress", { max: 1, value: 0 });
  private readonly phaseText = el("div", { class: "phase", textContent: "—" });
  private readonly resultBox = el("dl", { class: "kv" });
  private readonly logBox = el("pre", { class: "log" });

  constructor() {
    this.build();
    void this.init();
  }

  private log(line: string): void {
    const t = new Date().toLocaleTimeString("ja-JP", { hour12: false });
    this.logBox.textContent += `[${t}] ${line}\n`;
    this.logBox.scrollTop = this.logBox.scrollHeight;
  }

  private build(): void {
    for (const [hz, label] of [
      [256_000, "256 kHz (標準・安定)"],
      [512_000, "512 kHz"],
      [1_000_000, "1 MHz"],
      [2_000_000, "2 MHz (不安定な場合あり)"],
    ] as const) {
      this.clockSel.append(el("option", { value: String(hz), textContent: label }));
    }
    this.modeSel.append(
      el("option", { value: "firmware", textContent: "ファーム駆動 (標準)" }),
      el("option", { value: "host", textContent: "ホスト駆動 (診断用・非常に遅い)" }),
    );

    this.connectBtn.onclick = () => void this.connect();
    this.disconnectBtn.onclick = () => void this.disconnect();
    this.bootselBtn.onclick = () => void this.bootsel();
    this.startBtn.onclick = () => void this.start();
    this.abortBtn.onclick = () => this.abort?.abort();
    this.drop.onclick = () => this.fileInput.click();
    this.fileInput.onchange = () => {
      const f = this.fileInput.files?.[0];
      if (f) void this.loadFile(f);
    };
    this.drop.ondragover = (e) => {
      e.preventDefault();
      this.drop.classList.add("over");
    };
    this.drop.ondragleave = () => this.drop.classList.remove("over");
    this.drop.ondrop = (e) => {
      e.preventDefault();
      this.drop.classList.remove("over");
      const f = e.dataTransfer?.files[0];
      if (f) void this.loadFile(f);
    };

    const supported = LinkTransport.isSupported();

    this.root.append(
      el("h1", { textContent: "GBA Multiboot Web" }),
      el("p", { class: "sub", textContent: "GBA-PICO-LINK (RP2040) を Web Serial で制御し、ブラウザから GBA に Multiboot ROM を転送します。" }),
      supported
        ? ""
        : el("p", { class: "unsupported", textContent: "このブラウザは Web Serial に対応していません。デスクトップ版の Chrome / Edge をお使いください。" }),
      el(
        "section",
        { class: "card" },
        el("h2", { textContent: "1. デバイス" }),
        el("div", { class: "row" }, this.connectBtn, this.disconnectBtn, this.bootselBtn),
        this.deviceInfo,
        el("p", { class: "hint", textContent: "ファームウェア未書き込みの場合: 基板のボタンを押しながら USB を挿すと RPI-RP2 ドライブが現れるので、firmware の UF2 をコピーしてください。" }),
      ),
      el(
        "section",
        { class: "card" },
        el("h2", { textContent: "2. ROM" }),
        this.drop,
        this.fileInput,
        this.romInfo,
        this.checks,
      ),
      el(
        "section",
        { class: "card" },
        el("h2", { textContent: "3. 設定" }),
        el(
          "div",
          { class: "row" },
          el("label", {}, "通信速度 (SC)", this.clockSel),
          el("label", {}, "転送間隔 (µs)", this.gapInput),
          el("label", {}, "パレット (0-255)", this.paletteInput),
          el("label", {}, "GBA 待ち時間 (秒, 0=無制限)", this.timeoutInput),
          el("label", {}, "モード", this.modeSel),
        ),
      ),
      el(
        "section",
        { class: "card" },
        el("h2", { textContent: "4. 転送" }),
        el("p", { class: "hint", textContent: "GBA はカートリッジを抜いた状態で電源を入れ、Nintendo ロゴの画面で待たせてください。" }),
        el("div", { class: "row" }, this.startBtn, this.abortBtn),
        this.progress,
        this.phaseText,
        this.resultBox,
      ),
      el("section", { class: "card" }, el("h2", { textContent: "ログ" }), this.logBox),
    );
    this.connectBtn.disabled = !supported;
  }

  private async init(): Promise<void> {
    try {
      this.core = await LinkCore.load(`${import.meta.env.BASE_URL}core.wasm`);
      this.log(`LinkCore (wasm) 読み込み完了: protocol v${this.core.protocolVersion}`);
    } catch (e) {
      this.log(`LinkCore (wasm) の読み込みに失敗: ${String(e)}。ROM 検査と CRC 照合は無効になります。`);
    }
    if (LinkTransport.isSupported()) {
      const t = await LinkTransport.reconnect().catch(() => null);
      if (t) {
        this.log("許可済みのポートを検出。再接続します。");
        await this.attach(t);
      }
    }
  }

  private async connect(): Promise<void> {
    try {
      const t = await LinkTransport.request();
      await this.attach(t);
    } catch (e) {
      if (e instanceof DOMException && e.name === "NotFoundError") return; // ダイアログキャンセル
      if (e instanceof DOMException && e.name === "InvalidStateError") {
        this.log("ポートが他のアプリで開かれています。ターミナル等を閉じてから再試行してください。");
        return;
      }
      this.log(`接続に失敗: ${String(e)}`);
    }
  }

  private async attach(t: LinkTransport): Promise<void> {
    try {
      await t.open();
      const dev = new LinkDevice(t, this.core);
      dev.onLog = (s) => this.log(`[fw] ${s}`);
      const info = await dev.handshake();
      this.device = dev;
      dev.onDisconnect = () => {
        this.log("デバイスが切断されました");
        this.device = null;
        this.renderDevice(null);
        this.updateButtons();
      };
      this.renderDevice(info);
      this.log(`接続: fw v${info.firmwareVersion}, ${t.label}, リング ${kib(info.ringCapacity)}`);
    } catch (e) {
      this.log(`初期化に失敗: ${String(e)}`);
      await t.close().catch(() => {});
    }
    this.updateButtons();
  }

  private async disconnect(): Promise<void> {
    await this.device?.transport.close();
    this.device = null;
    this.renderDevice(null);
    this.updateButtons();
    this.log("切断しました");
  }

  private async bootsel(): Promise<void> {
    if (!this.device) return;
    if (!window.confirm("UF2 ブートローダ (BOOTSEL) で再起動します。RPI-RP2 ドライブに新しい UF2 をコピーしてください。")) return;
    await this.device.rebootToBootsel().catch(() => {});
    this.log("BOOTSEL へ再起動を要求しました");
  }

  private renderDevice(info: DeviceInfo | null): void {
    this.deviceInfo.replaceChildren();
    if (!info) return;
    const rows: [string, string][] = [
      ["ファームウェア", `v${info.firmwareVersion} (protocol v${info.protocolVersion})`],
      ["受信バッファ", kib(info.ringCapacity)],
      ["現在の通信速度", `${(info.clockHz / 1000).toFixed(0)} kHz / 間隔 ${info.gapUs} µs`],
    ];
    for (const [k, v] of rows) this.deviceInfo.append(el("dt", { textContent: k }), el("dd", { textContent: v }));
  }

  private async loadFile(f: File): Promise<void> {
    const raw = new Uint8Array(await f.arrayBuffer());
    this.romName = f.name;
    this.rom = null;
    const info = readROMInfo(raw);
    this.romInfo.replaceChildren();
    const rows: [string, string][] = [
      ["ファイル", `${f.name} (${kib(raw.length)}, ${raw.length} bytes)`],
      ["タイトル", info.title || "(なし)"],
      ["ゲームコード", `${info.gameCode || "----"} / メーカー ${info.makerCode || "--"} / v${info.version}`],
    ];
    for (const [k, v] of rows) this.romInfo.append(el("dt", { textContent: k }), el("dd", { textContent: v }));

    this.checks.replaceChildren();
    let usable = raw.length > ROM_HEADER_SIZE;
    if (this.core) {
      if (raw.length > this.core.romMaxSize) {
        this.checks.append(el("span", { class: "badge err", textContent: `サイズ超過 (最大 ${kib(this.core.romMaxSize)})` }));
        usable = false;
      } else {
        this.core.loadROM(raw);
        const padded = this.core.paddedSize(raw.length);
        for (const c of describeChecks(this.core.romCheck(raw.length))) {
          this.checks.append(el("span", { class: `badge ${c.level}`, title: c.note, textContent: `${c.label}: ${c.ok ? "OK" : "NG"}` }));
          if (c.level === "err" && !c.ok) usable = false;
        }
        if (padded !== raw.length) {
          this.checks.append(el("span", { class: "badge", textContent: `${padded - raw.length} バイトをパディング` }));
        }
        this.rom = padROM(raw, padded);
      }
    } else {
      // wasm なし: 最低限のパディングだけ行う
      const body = Math.max(0x100, raw.length - ROM_HEADER_SIZE);
      const padded = ROM_HEADER_SIZE + Math.ceil(body / ROM_BODY_ALIGNMENT) * ROM_BODY_ALIGNMENT;
      this.rom = padROM(raw, padded);
    }
    if (!usable) this.rom = null;
    this.log(usable ? `ROM 読み込み: ${f.name}` : `ROM を使用できません: ${f.name}`);
    this.updateButtons();
  }

  private options(): TransferOptions {
    return {
      clockHz: Number(this.clockSel.value),
      gapUs: Math.max(36, Number(this.gapInput.value) || 40),
      palette: Math.min(255, Math.max(0, Number(this.paletteInput.value) || 0xd1)),
      connectTimeoutMs: Math.max(0, Number(this.timeoutInput.value) || 0) * 1000,
    };
  }

  private updateButtons(): void {
    const connected = this.device !== null;
    const busy = this.abort !== null;
    this.connectBtn.disabled = connected || busy || !LinkTransport.isSupported();
    this.disconnectBtn.disabled = !connected || busy;
    this.bootselBtn.disabled = !connected || busy;
    this.startBtn.disabled = !connected || busy || this.rom === null;
    this.abortBtn.disabled = !busy;
  }

  private onProgress(p: TransferProgress): void {
    this.phaseText.textContent = `${PHASE_TEXT[p.phase] ?? `phase ${p.phase}`} — ${kib(p.consumed)} / ${kib(p.total)}`;
    this.progress.value = p.total ? p.consumed / p.total : 0;
  }

  private async start(): Promise<void> {
    if (!this.device || !this.rom) return;
    this.abort = new AbortController();
    this.resultBox.replaceChildren();
    this.progress.value = 0;
    this.updateButtons();
    const opts = this.options();
    const hostDriven = this.modeSel.value === "host";
    this.log(`転送開始: ${this.romName} (${this.rom.length} bytes), ${opts.clockHz / 1000} kHz, ${hostDriven ? "ホスト駆動" : "ファーム駆動"}`);
    const t0 = performance.now();
    try {
      const run = hostDriven ? this.device.uploadHostDriven.bind(this.device) : this.device.upload.bind(this.device);
      const r = await run(this.rom, opts, (p) => this.onProgress(p), this.abort.signal);
      const elapsed = r.elapsedMs || Math.round(performance.now() - t0);
      const rows: [string, string][] = [
        ["結果", "転送完了。GBA 側でプログラムが起動します。"],
        ["CRC", `${hex(r.crc)}${r.crcVerified === undefined ? "" : r.crcVerified ? " (wasm 側の再計算と一致)" : " (wasm 側の再計算と不一致!)"}`],
        ["所要時間", `${(elapsed / 1000).toFixed(1)} 秒 (${((this.rom.length / 1024) / (elapsed / 1000)).toFixed(1)} KiB/s)`],
        ["交換した値", `palette ${hex(r.palette, 2)}, client ${hex(r.clientData, 2)}, handshake ${hex(r.handshake, 2)}, random ${hex(r.randomData, 2)}`],
      ];
      for (const [k, v] of rows) this.resultBox.append(el("dt", { textContent: k }), el("dd", { textContent: v }));
      this.log(`完了: CRC ${hex(r.crc)}, ${(elapsed / 1000).toFixed(1)} 秒`);
    } catch (e) {
      if (e instanceof MultibootError) {
        const text = ERROR_TEXT[e.code] ?? `エラーコード ${e.code}`;
        this.phaseText.textContent = `失敗: ${text}`;
        this.log(`失敗: ${text} (phase ${PHASE_TEXT[e.phase] ?? e.phase}, expected ${hex(e.expected)}, got ${hex(e.got)})`);
      } else {
        this.phaseText.textContent = `失敗: ${String(e)}`;
        this.log(`失敗: ${String(e)}`);
      }
    } finally {
      this.abort = null;
      this.updateButtons();
    }
  }
}

new App();
