// GBA ROM ヘッダの読み取り (表示用)。検査ロジック本体は LinkCore (wasm) 側。
import { RomCheck } from "./protocol.generated";

export interface ROMInfo {
  title: string;
  gameCode: string;
  makerCode: string;
  version: number;
  size: number;
}

function ascii(bytes: Uint8Array, start: number, length: number): string {
  let s = "";
  for (let i = start; i < start + length && i < bytes.length; i++) {
    const c = bytes[i]!;
    if (c === 0) break;
    s += c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : "?";
  }
  return s;
}

export function readROMInfo(rom: Uint8Array): ROMInfo {
  return {
    title: ascii(rom, 0xa0, 12),
    gameCode: ascii(rom, 0xac, 4),
    makerCode: ascii(rom, 0xb0, 2),
    version: rom[0xbc] ?? 0,
    size: rom.length,
  };
}

export interface CheckItem {
  label: string;
  ok: boolean;
  level: "ok" | "warn" | "err";
  note: string;
}

/** wasm の lc_rom_check が返すフラグを表示用に展開する */
export function describeChecks(flags: number): CheckItem[] {
  const has = (f: number) => (flags & f) !== 0;
  return [
    {
      label: "サイズ",
      ok: has(RomCheck.sizeOK),
      level: has(RomCheck.sizeOK) ? "ok" : "err",
      note: has(RomCheck.sizeOK) ? "256 KiB 以内" : "Multiboot で送れるサイズ (0xC0 超〜256 KiB) ではありません",
    },
    {
      label: "ヘッダ チェックサム",
      ok: has(RomCheck.headerChecksumOK),
      level: has(RomCheck.headerChecksumOK) ? "ok" : "err",
      note: has(RomCheck.headerChecksumOK) ? "一致" : "不一致。GBA BIOS に拒否されます",
    },
    {
      label: "Nintendo ロゴ",
      ok: has(RomCheck.logoOK),
      level: has(RomCheck.logoOK) ? "ok" : "err",
      note: has(RomCheck.logoOK) ? "あり" : "ロゴが見つかりません。GBA BIOS に拒否されます",
    },
    {
      label: "Multiboot エントリ",
      ok: has(RomCheck.multibootEntryOK),
      level: has(RomCheck.multibootEntryOK) ? "ok" : "warn",
      note: has(RomCheck.multibootEntryOK)
        ? "0xC0 に分岐命令あり"
        : "0xC0 に分岐命令がありません。Multiboot 対応 ROM か確認してください",
    },
  ];
}
