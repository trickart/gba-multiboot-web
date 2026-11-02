#!/usr/bin/env python3
"""mbcheck.asm を fasmarm で組み立て、GBA ヘッダのチェックサムを付与し、Multiboot 用に 16 バイト境界へ揃える。
使い方: python3 build.py [出力パス]   (既定: mbcheck.gba)
"""
import os
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "mbcheck.asm")
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "mbcheck.gba")
raw = os.path.join(here, "mbcheck.raw")

subprocess.run(["fasmarm", src, raw], check=True)
rom = bytearray(open(raw, "rb").read())
os.remove(raw)

# ヘッダチェックサム: 0xA0..0xBC の和の補数 - 0x19
chk = 0
for i in range(0xA0, 0xBD):
    chk = (chk - rom[i]) & 0xFF
rom[0xBD] = (chk - 0x19) & 0xFF

# 本体 (0xC0 以降) を最小 0x100、16 バイト境界に
body = len(rom) - 0xC0
pad = max(0x100, (body + 15) // 16 * 16) - body
rom += b"\0" * pad

# ROM が表示するチェックサム (0xE0 .. rom_end の 32bit 和) の期待値
end = len(rom) - pad  # rom_end
total = 0
for off in range(0xE0, end, 4):
    total = (total + int.from_bytes(rom[off:off + 4], "little")) & 0xFFFFFFFF
bits = "".join("■" if (total >> i) & 1 else "□" for i in range(16))

open(out, "wb").write(rom)
print(f"wrote {out}: {len(rom)} bytes (body {body} + pad {pad}), header checksum 0x{rom[0xBD]:02X}")
print(f"body sum = 0x{total:08X}  →  y=44 の 16 個の四角 (左が bit0): {bits}")
