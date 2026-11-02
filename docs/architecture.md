# 構成と設計判断

```
┌─────────────────────────── ブラウザ (Chrome / Edge, GitHub Pages) ───────────────────────────┐
│  web/ (Vite + TypeScript)                                                                      │
│   ├ main.ts        UI (接続 / ROM 選択 / 設定 / 進捗 / ログ)                                   │
│   ├ multiboot.ts   転送オーケストレーション (フロー制御、イベント待ち)                          │
│   ├ serial/transport.ts  Web Serial: CDC ポートを open、ストリーム読み書き、フレーム分割       │
│   └ wasm/core.ts   core.wasm ローダ ─────────┐                                                 │
│                                              ▼                                                 │
│   core.wasm = Sources/LinkCore + Sources/LinkCoreWasm  (Embedded Swift → wasm32)               │
│      ROM 検査 / パディング / CRC 再計算 / Multiboot エンジン (ホスト駆動モード)                 │
└────────────────────────────────────────┬───────────────────────────────────────────────────────┘
                                         │ USB CDC-ACM (Web Serial, フレーム = type/len/payload)
┌────────────────────────────────────────▼───────────────────────────────────────────────────────┐
│  firmware/ (RP2040, pico-sdk 2.3.1 + TinyUSB, Embedded Swift)                                  │
│   ├ src/c/        TinyUSB ディスクリプタ (CDC-ACM), DTR / 1200 bps → BOOTSEL, 静的バッファ      │
│   ├ Firmware.swift  コマンド処理, リングバッファ, エンジン駆動, イベント送信                   │
│   ├ LinkPort.swift  PIO SPI マスタ (32bit, CPOL=1/CPHA=1, 256 kHz 既定)                        │
│   └ Sources/LinkCore (共有)  MultibootEngine / MultibootCipher / FrameParser / ByteRing        │
└────────────────────────────────────────┬───────────────────────────────────────────────────────┘
                                         │ GPIO0=SC, GPIO1=SI(入力), GPIO2=SO(出力), GPIO3=SD  (レベルシフタ経由)
                                   ┌─────▼─────┐
                                   │    GBA    │  カートリッジなしで起動 → BIOS が Multiboot を待つ
                                   └───────────┘
```

## 共有コア (`Sources/LinkCore`)

3 つの環境 (RP2040 / wasm / ホストテスト) で同じソースをコンパイルするため、次を守る。

- `import Foundation` しない。`String` の生成・連結、`print`、existential (`any P`) を避ける。
- ヒープを使わない。バッファは呼び出し側から `UnsafeMutablePointer` で渡す (`ByteRing`)。
- I/O をしない。`MultibootEngine` は「次にやること (`Action`)」を返し、ドライバが実行する。

`MultibootEngine` を sans-I/O にしたことで、`Tests/LinkCoreTests` の疑似 GBA (GBATEK の表から
独立に書いた復号・CRC 実装) に対して転送全体を結合テストできる。

## なぜファームウェア側でプロトコルを回すのか

Multiboot は 256 KiB で 65,000 回以上の 32bit 交換が必要で、1 交換ごとに USB 往復していると
数分かかる (loopj/gba-multiboot-pico の CLI 方式)。ファームが GBA との会話を担い、ホストは ROM を
ストリーミングするだけにすることで、転送時間は SC クロックで決まる (256 kHz で約 10 秒)。
ホスト駆動モードは共有コードの検証と障害切り分け用に残している。

## なぜ PIO SPI か

基板の配線 (GPIO0=SC, GPIO1=SI, GPIO2=SO) は RP2040 の SPI0 ピン機能 (GPIO2=SCK, GPIO3=TX, GPIO0=RX)
と一致しないため、ハード SPI は使えない。stacksmashing/gb-link-firmware と同様に PIO で SPI を
実装する (pico-examples の `spi_cpha1` を 32bit 幅で使用)。CPOL=1 は GPIO 出力反転で得る。

## 信号名の向き

基板の「SI/SO」は RP2040 視点。GPIO1 (SI) は RP2040 の入力 = GBA の SO、
GPIO2 (SO) は RP2040 の出力 = GBA の SI。gb-link-firmware の `PIN_SIN=1 (MISO)`, `PIN_SOUT=2 (MOSI)`
と同じ割り当て。`firmware/CMakeLists.txt` の `LINK_PIN_*` で変更できる。

## Embedded Swift と pico-sdk の接続

`firmware/CMakeLists.txt` は swift-embedded-examples の `rpi-pico-blink-sdk` の方式を踏襲する。

- `-target armv6m-none-none-eabi -enable-experimental-feature Embedded -parse-as-library`
- 依存ライブラリの `INTERFACE_COMPILE_DEFINITIONS` を再帰的に集めて `-Xcc -D` に変換
- `pico_standard_link` の C 専用フラグを C 限定にする
- ブリッジングヘッダで pico-sdk / TinyUSB / pioasm 生成ヘッダを import

C に残したもの: TinyUSB のディスクリプタ (マクロ定義が中心)、CDC のコールバック (DTR / 1200 bps リセット)、
静的バッファ、`tusb_init` (可変引数マクロ)、`reset_usb_boot`。

## なぜ WebUSB ではなく Web Serial か

当初は WebUSB (ベンダーインターフェース + MS OS 2.0 ディスクリプタで WinUSB を自動割り当て) で実装し実機でも動いたが、
Windows で専用ドライバを選ばせる以上、固有の VID/PID が必要になる。pid.codes は PCB データを含む
オープンソース公開が条件で、第三者製の基板 (GBA-PICO-LINK) では満たしにくい。
CDC-ACM なら OS 標準ドライバで動き、Raspberry Pi が RP2040 の CDC デバイス向けに公開する共通 ID
(0x2E8A:0x000A) を使えるため PID 申請が不要になる。失うのは Android 対応と WebUSB のランディングページ通知。
フレームプロトコルはバイトストリーム前提だったので、差し替えは USB クラスの設定と TS のトランスポート層のみで済んだ。Embedded Swift のランタイムが要求する `posix_memalign` は weak シムを置いている
(現状ヒープ割り当ては使っていない)。

## wasm 側

`swift build --swift-sdk swift-6.4.2-RELEASE_wasm-embedded` で `LinkCoreWasm` を実行可能プロダクトとして
ビルドし、`@_expose(wasm)` した関数だけをブラウザから呼ぶ (`web/src/wasm/core.ts`)。
Embedded SDK は wasip1 向けなので、7 つの WASI インポートを JS 側で空実装している。
wasm が読めない環境でも Web は動作し、ROM 検査と CRC 照合だけが無効になる。
