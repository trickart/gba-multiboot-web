#!/usr/bin/env node
// 開発用 CLI: ブラウザなしで ROM を Multiboot 転送する (Web と同じシリアルプロトコル)。
//   cd tools/cli && npm install && node upload.mjs <rom.gba> [--port /dev/cu.usbmodemXXXX] [--timeout 秒] [--clock Hz] [--gap µs]
//   node upload.mjs --bootsel          ファームを UF2 ブートローダで再起動 (1200 bps を開くだけ)
import { readFileSync } from "node:fs";
import { SerialPort } from "serialport";

const USB_VID = "2e8a";
const USB_PID = "000a";

const args = process.argv.slice(2);
const opt = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const romPath = args.find((a, i) => !a.startsWith("--") && (i === 0 || !args[i - 1].startsWith("--")));

async function findPort() {
  const explicit = opt("--port", null);
  if (explicit) return explicit;
  const ports = (await SerialPort.list()).filter((p) => (p.vendorId ?? "").toLowerCase() === USB_VID && (p.productId ?? "").toLowerCase() === USB_PID);
  if (ports.length === 0) { console.error("デバイスが見つかりません (VID 2E8A / PID 000A)。--port で指定してください。"); process.exit(1); }
  if (ports.length > 1) { console.error("複数見つかりました。--port で指定してください:\n  " + ports.map((p) => p.path).join("\n  ")); process.exit(1); }
  // macOS: tty.* は DCD 待ちの挙動があるので cu.* を使う
  return ports[0].path.replace(/^\/dev\/tty\./, "/dev/cu.");
}

const path = await findPort();

if (args.includes("--bootsel")) {
  // 1200 bps で開くとファームが BOOTSEL へ再起動する
  const p = new SerialPort({ path, baudRate: 1200, autoOpen: false });
  await new Promise((res, rej) => p.open((e) => (e ? rej(e) : res())));
  await new Promise((r) => setTimeout(r, 200));
  p.close(() => {});
  console.log(`${path}: BOOTSEL 再起動を要求しました`);
  process.exit(0);
}

if (!romPath) { console.error("usage: upload.mjs <rom.gba> [--port dev] [--timeout sec] [--clock hz] [--gap us] | --bootsel"); process.exit(2); }
const timeoutMs = Number(opt("--timeout", 60)) * 1000;
const clockHz = Number(opt("--clock", 256000));
const gapUs = Number(opt("--gap", 40));

const CMD = { getInfo: 0x01, setConfig: 0x02, mbStart: 0x10, mbData: 0x11, mbAbort: 0x12, reset: 0x30 };
const EVT = { info: 0x80, log: 0x81, status: 0x90, progress: 0x91, done: 0x92, error: 0x93, nak: 0xfe };
const PHASE = ["idle", "GBA 待ち", "ヘッダ", "パレット", "長さ", "本体", "CRC", "完了", "失敗"];
const frame = (t, p = new Uint8Array(0)) => { const o = new Uint8Array(3 + p.length); o[0] = t; o[1] = p.length & 255; o[2] = p.length >> 8; o.set(p, 3); return o; };
const le32 = (v) => new Uint8Array([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >>> 24) & 255]);
const hex = (v, n = 4) => "0x" + (v >>> 0).toString(16).toUpperCase().padStart(n, "0");

// ROM をパディング (本体 16 バイト境界、最小 0x100)
let rom = new Uint8Array(readFileSync(romPath));
const body = rom.length - 0xc0;
const padded = 0xc0 + Math.max(0x100, Math.ceil(body / 16) * 16);
if (padded !== rom.length) { const p = new Uint8Array(padded); p.set(rom); rom = p; }
if (rom.length > 0x40000) { console.error("ROM が 256 KiB を超えています"); process.exit(1); }

const port = new SerialPort({ path, baudRate: 115200, autoOpen: false });
await new Promise((res, rej) => port.open((e) => (e ? rej(e) : res())));
await new Promise((r) => port.set({ dtr: true, rts: true }, () => r()));
console.log(`port: ${path}`);

let buf = new Uint8Array(0);
let waiters = [];
let consumed = 0;
const listeners = [];
port.on("data", (d) => {
  const m = new Uint8Array(buf.length + d.length); m.set(buf); m.set(d, buf.length); buf = m;
  while (buf.length >= 3) {
    const len = buf[1] | (buf[2] << 8);
    if (buf.length < 3 + len) break;
    const f = { type: buf[0], payload: buf.slice(3, 3 + len) };
    buf = buf.slice(3 + len);
    for (const l of listeners) l(f);
    waiters = waiters.filter((w) => { if (w.pred(f)) { w.res(f); return false; } return true; });
  }
});
const waitFor = (pred, ms, what) => new Promise((res, rej) => {
  const t = setTimeout(() => rej(new Error(`${what} の応答がありません`)), ms);
  waiters.push({ pred, res: (f) => { clearTimeout(t); res(f); } });
});
const send = (t, p) => new Promise((res, rej) => port.write(frame(t, p), (e) => (e ? rej(e) : res())));
const view = (f) => new DataView(f.payload.buffer, f.payload.byteOffset, f.payload.byteLength);

await new Promise((r) => setTimeout(r, 200));
// RESET で同期を取り直す (ModemManager 等の干渉や、開いた直後の取りこぼしに備えて数回試す)
for (let attempt = 1; ; attempt++) {
  try {
    const p = waitFor((f) => f.type === EVT.status, 1000, "RESET");
    await send(CMD.reset);
    await p;
    break;
  } catch (e) {
    if (attempt >= 3) { console.error(`${e.message} (ファームウェアが応答しません。ブラウザ等でポートを開いていないか確認してください)`); port.close(() => process.exit(1)); await new Promise(() => {}); }
  }
}
const info = await (async () => { const p = waitFor((f) => f.type === EVT.info, 2000, "GET_INFO"); await send(CMD.getInfo); return view(await p); })();
console.log(`firmware v${info.getUint8(1)}.${info.getUint8(2)}.${info.getUint8(3)} proto ${info.getUint8(0)} ring ${info.getUint32(4, true)}`);
const ring = info.getUint32(4, true);
{
  const p = waitFor((f) => f.type === EVT.info, 2000, "SET_CONFIG");
  await send(CMD.setConfig, new Uint8Array([...le32(clockHz), gapUs & 255, gapUs >> 8, 0xd1, ...le32(timeoutMs)]));
  await p;
}
console.log(`rom: ${romPath} ${rom.length} bytes, ${clockHz / 1000} kHz, gap ${gapUs} µs, GBA 待ち ${timeoutMs / 1000} 秒`);
console.log("GBA をカートリッジなしで起動し、ロゴ画面で待たせてください…");

let lastPhase = -1;
const t0 = Date.now();
const result = new Promise((res, rej) => {
  listeners.push((f) => {
    const v = view(f);
    if (f.type === EVT.status) {
      const ph = v.getUint8(0);
      if (ph !== lastPhase) { lastPhase = ph; console.log(`[${((Date.now() - t0) / 1000).toFixed(1)}s] ${PHASE[ph] ?? ph}`); }
    } else if (f.type === EVT.progress) {
      consumed = v.getUint32(0, true);
      process.stdout.write(`\r  ${consumed}/${rom.length} bytes`);
    } else if (f.type === EVT.done) {
      process.stdout.write("\n");
      res({ crc: v.getUint16(0, true), ms: v.getUint32(2, true), cc: v.getUint8(6), hh: v.getUint8(7), rr: v.getUint8(8), pp: v.getUint8(9) });
    } else if (f.type === EVT.error) {
      process.stdout.write("\n");
      rej(new Error(`MB_ERROR code=${v.getUint8(0)} phase=${PHASE[v.getUint8(1)]} expected=${hex(v.getUint32(2, true))} got=${hex(v.getUint32(6, true))}`));
    } else if (f.type === EVT.nak) {
      rej(new Error(`NAK for command ${hex(v.getUint8(0), 2)}`));
    } else if (f.type === EVT.log) {
      console.log("[fw]", new TextDecoder().decode(f.payload));
    }
  });
});

await send(CMD.mbStart, le32(rom.length));
let sent = 0;
let finished = false;
result.then(() => (finished = true), () => (finished = true));
while (sent < rom.length && !finished) {
  if (sent - consumed + 1024 > Math.max(1024, ring)) { await new Promise((r) => setTimeout(r, 5)); continue; }
  const chunk = rom.subarray(sent, Math.min(rom.length, sent + 1024));
  await send(CMD.mbData, chunk);
  sent += chunk.length;
}
try {
  const r = await result;
  console.log(`done: CRC ${hex(r.crc)} in ${(r.ms / 1000).toFixed(1)}s (palette ${hex(r.pp, 2)} client ${hex(r.cc, 2)} handshake ${hex(r.hh, 2)} random ${hex(r.rr, 2)})`);
} catch (e) {
  console.error(String(e.message ?? e));
  process.exitCode = 1;
} finally {
  port.close(() => process.exit());
}
