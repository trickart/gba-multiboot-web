# GBA Multiboot Web

[GBA-PICO-LINK](https://bzl.booth.pm/items/8533267) (RP2040 製 GBA リンクケーブルアダプタ、
[Game-Boy-Zero-Link-Board](https://github.com/weimanc/game-boy-zero-link-board) とピン互換) を
**Web Serial** で制御し、ブラウザから GBA へ Multiboot ROM を転送する Web アプリとファームウェアです。

- **ファームウェア**: RP2040 / pico-sdk 2.3.1 + TinyUSB (CDC-ACM 仮想シリアル)、アプリ本体は **Embedded Swift**
- **Web**: GitHub Pages にホストする静的サイト (Vite + TypeScript)。ロジック層は **Embedded Swift → WebAssembly**
- **共有コア** (`Sources/LinkCore`): Multiboot プロトコルの状態機械・暗号化/CRC・USB フレーム定義を
  ファームウェア / wasm / ホストテストで共用

**動作確認済み** (2026-11-01、GBA-PICO-LINK + GBA 実機): ファームウェア経由で Multiboot 転送が完走し、
`tools/testrom` のチェック用 ROM が GBA 上で起動 (ブートモード値 2 = Normal mode、本体チェックサム一致、
キー入力反応) することを確認。GBA が返す乱数から再計算した CRC もファームの報告値と一致。

## ハードウェア

| GBA リンクポート | 基板の信号名 (RP2040 視点) | RP2040 GPIO | 役割 |
|---|---|---|---|
| SC  | SC | GPIO0 | クロック (RP2040 がマスタとして出力、アイドル High) |
| SO (GBA 出力) | SI | GPIO1 | RP2040 入力 |
| SI (GBA 入力) | SO | GPIO2 | RP2040 出力 |
| SD  | SD | GPIO3 | Normal mode では未使用 (プルアップ入力) |

基板のレベルシフタを介して GBA (3.3V) と接続します。GBA 側は**カートリッジを抜いた状態で電源を入れ**、
Nintendo ロゴ画面で待たせます (BIOS が Multiboot 要求を待ち受けます)。

## リポジトリ構成

```
Package.swift            共有コアのホストビルド / テスト / コード生成 (SwiftPM)
Sources/LinkCore/        共有ロジック (Foundation 非依存、ヒープ非使用)
  Protocol.swift           USB フレーム定義 (Command / Event / FrameParser)
  MultibootEngine.swift    GBA Multiboot マスタ側の状態機械 (sans-I/O)
  MultibootCipher.swift    GBATEK の暗号化 / CRC
  ROMImage.swift           ROM サイズ制約・ヘッダ検査
  ByteRing.swift           リングバッファ (外部メモリ上で動く)
Sources/LinkCoreWasm/    wasm 向け @_expose(wasm) エクスポート層
Sources/ProtocolGen/     web/src/protocol.generated.ts を生成するツール
Tests/LinkCoreTests/     疑似 GBA (FakeGBA) による結合テスト
firmware/                RP2040 ファームウェア (CMake + pico-sdk サブモジュール + Embedded Swift)
  src/*.swift              Firmware (コマンド処理) / LinkPort (PIO SPI) / UsbLink / Main
  src/c/                   TinyUSB ディスクリプタ (CDC-ACM)、DTR / 1200 bps リセット、静的バッファ
  src/linkport.pio         32bit SPI マスタ (CPOL=1, CPHA=1)
web/                     Vite + TypeScript。wasm (core.wasm) を public/ に配置して読み込む
scripts/build-wasm.sh    LinkCore を wasm にビルドして web/public/core.wasm へ
tools/testrom/           fasmarm 製の動作確認 ROM (カラーバー / ブートモード / チェックサム / キー入力表示) と build.py
tools/cli/upload.mjs     Node (serialport) から ROM を転送する開発用 CLI
docs/                    設計 (architecture.md) と USB プロトコル仕様 (protocol.md)
.github/workflows/       Pages デプロイ (pages.yml) / ファームウェアビルド (firmware.yml)
```

## 動作の流れ

1. Web が Web Serial でポートを開き (DTR がファームへの「接続中」の合図)、`GET_INFO` でプロトコル版を照合する。
2. ROM をドロップすると wasm (LinkCore) がサイズ・ヘッダチェックサム・ロゴ・Multiboot エントリを検査し、
   16 バイト境界へパディングする。
3. `MB_START` を送った後、ROM を 1 KiB ずつ `MB_DATA` でストリーミングする。ファームウェアは
   32 KiB のリングバッファに溜めつつ、`MultibootEngine` を回して GBA と会話する
   (接続待ち → ヘッダ → パレット/ハンドシェイク → 暗号化本体 → CRC)。
4. 進捗は `MB_PROGRESS` で返り、完了時に `MB_DONE` の CRC を wasm 側で再計算した値と照合する。

転送時間は SC クロックで決まります (256 kHz で 256 KiB ≒ 10 秒)。詳細は [docs/protocol.md](docs/protocol.md)。

## 開発環境 (macOS で確認)

| ツール | 用途 | 備考 |
|---|---|---|
| Swift 6.4.2 (swift.org toolchain) | 全部 | Xcode 同梱の swift ではなく `~/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain` を使う |
| Wasm SDK (`swift-6.4.2-RELEASE_wasm-embedded`) | wasm | 下記コマンドでインストール |
| CMake ≥ 3.29, Ninja | ファームウェア | `brew install cmake ninja` |
| Arm GNU Toolchain (arm-none-eabi-gcc, newlib 付き) | ファームウェア | pico-sdk の C 部分とリンク |
| Node.js 22+ | Web | `npm` |

```sh
# swift.org のツールチェーンを使う (以降のコマンド共通)
export PATH="$HOME/Library/Developer/Toolchains/swift-6.4.2-RELEASE.xctoolchain/usr/bin:$PATH"

# Wasm SDK (1 回だけ)
swift sdk install https://download.swift.org/swift-6.4.2-release/wasm-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz \
  --checksum 83baca83553f8c443cda7b84800912e6e709c3acd2e7ebf277794ca5836c0da5

# サブモジュール (pico-sdk と TinyUSB)
git submodule update --init firmware/lib/pico-sdk
git -C firmware/lib/pico-sdk submodule update --init lib/tinyusb
```

### 共有コアのテスト

```sh
swift test
```

### ファームウェア

```sh
cmake -S firmware -B firmware/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_Swift_COMPILER="$(which swiftc)"
cmake --build firmware/build
# → firmware/build/gba_link.uf2
```

書き込み: 基板のボタンを押しながら USB を挿すと `RPI-RP2` ドライブが現れるので `gba_link.uf2` をコピーします。
以降は Web の「BOOTSEL で再起動」ボタン、`node tools/cli/upload.mjs --bootsel`、
またはシリアルポートを 1200 bps で開く (picotool と同じ慣習) ことでも書き込みモードに入れます。

設定値 (`cmake -D...` で変更): `USB_VID` / `USB_PID`、`LINK_PIN_SC/SI/SO/SD`。

**VID/PID について**: デバイスは CDC-ACM 専用なので OS 標準のクラスドライバで動き、専用 PID は不要です。
Raspberry Pi が RP2040 の CDC デバイス向けに公開している共通 ID `0x2E8A:0x000A`
("Raspberry Pi Pico SDK CDC UART (RP2040)"、pico-sdk の stdio_usb と同じ) を使っています。
識別は iProduct / iSerial と `GET_INFO` ハンドシェイクで行います。
ベンダーインターフェースを追加して複合デバイスにする場合は、この ID は使えないので独自の PID が必要になります。

### 動作確認 ROM と CLI

```sh
# fasmarm が必要。ヘッダチェックサム付与と 16 バイト境界パディングまで行う
python3 tools/testrom/build.py            # → tools/testrom/mbcheck.gba (期待チェックサムのパターンも表示)

# ブラウザなしで転送 (Web と同じシリアルプロトコル)。ポートは VID/PID から自動検出
cd tools/cli && npm install
node upload.mjs ../testrom/mbcheck.gba --timeout 60 [--port /dev/cu.usbmodemXXXX] [--clock 256000] [--gap 40]
node upload.mjs --bootsel                 # UF2 ブートローダで再起動
```

### Web

```sh
cd web
npm install
npm run gen:protocol   # Sources/LinkCore → src/protocol.generated.ts
npm run build:wasm     # LinkCore → public/core.wasm (scripts/build-wasm.sh)
npm run dev            # http://localhost:5173/gba-multiboot-web/
npm run build          # 型チェック + dist/
```

Web Serial はデスクトップ版の Chrome / Edge で、`https://` または `localhost` でのみ使えます (Android は非対応)。
シリアルポートは排他なので、ターミナル等で開いたままだと接続できません。
Linux では ModemManager が CDC デバイスを一時的に掴むことがあります
(`ID_MM_DEVICE_IGNORE=1` の udev ルールで回避。ファーム側は `RESET` で同期を取り直せます)。

### GitHub Pages

`main` に push すると `.github/workflows/pages.yml` が Swift (swiftly) と Wasm SDK を入れ、
`swift test` → wasm ビルド → `vite build` → Pages デプロイを行います。
リポジトリ設定の Pages で「Source: GitHub Actions」を選んでください。
リポジトリ名が `gba-multiboot-web` でない場合もワークフローが `BASE_PATH` を自動設定します。

`firmware.yml` は push ごとに UF2 をアーティファクトとして保存し、`v*` タグで Release に添付します。

## 設計上のポイント

- **プロトコルはファームウェア側で回す**: 1 ワードごとに USB を往復させる方式 (loopj/gba-multiboot-pico) は
  256 KiB で数分かかるため、ホストは ROM を流すだけにして転送時間を SC クロックで決める。
- **PIO SPI**: 基板のピン配置は RP2040 のハード SPI と合わないため PIO で実装 (stacksmashing/gb-link-firmware と同じ考え方)。
- **共有コアは sans-I/O**: `MultibootEngine` は「次にやるべき動作」を返すだけなので、RP2040 / wasm / テストで同じコードが動く。
- **Web Serial (CDC-ACM)**: 標準クラスドライバで動くので専用ドライバも PID 申請も不要。WebUSB 案 (ベンダー IF + MS OS 2.0) から切り替えた。
- **Swift の守備範囲**: TinyUSB のディスクリプタ (マクロの塊) と静的バッファだけ C。それ以外は Swift。

詳しくは [docs/architecture.md](docs/architecture.md)。

## 今後の候補

- クロック上限の調査 (256 kHz で確認済み。GBATEK は 2 MHz を「不安定な場合あり」としている)
- ブラウザからのファームウェア書き込み (1200 bps で BOOTSEL に入れた後、WebUSB で PICOBOOT を叩く)
- UART ブリッジモード (転送後の GBA 側 printf 出力をブラウザに表示)
- GB-Link (Celio) 互換のオンライン通信機能との共存

## 参考

- [GBATEK – Multiboot Transfer Protocol](https://problemkaputt.de/gbatek.htm)
- [loopj/gba-multiboot-pico](https://github.com/loopj/gba-multiboot-pico) (MIT) – Multiboot 手順の実装参考
- [stacksmashing/gb-link-firmware](https://github.com/stacksmashing/gb-link-firmware) – ピン割り当て、PIO SPI
- [TinyUSB cdc_msc / webusb_serial examples](https://github.com/hathach/tinyusb/tree/master/examples/device) (MIT) – ディスクリプタの雛形
- [raspberrypi/usb-pid](https://github.com/raspberrypi/usb-pid) – RP2040 CDC 向け共通 VID/PID
- [swift-embedded-examples/rpi-pico-blink-sdk](https://github.com/apple/swift-embedded-examples) – Embedded Swift と pico-sdk の統合
- [pico-examples/pio/spi](https://github.com/raspberrypi/pico-examples) (BSD-3-Clause) – PIO SPI プログラム

## ライセンス

[MIT License](LICENSE) (Copyright (c) 2026 trickart)。

取り込んだ第三者コードの出典とライセンスは各ファイルの冒頭に記載しています:
TinyUSB のサンプル由来のディスクリプタ (MIT)、pico-examples の PIO SPI プログラム (BSD-3-Clause)、
Multiboot 手順の参考にした loopj/gba-multiboot-pico (MIT)。pico-sdk と TinyUSB はサブモジュールとして
それぞれのライセンス (BSD-3-Clause / MIT) に従います。
