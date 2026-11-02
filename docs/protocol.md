# USB プロトコル (ホスト ⇄ ファームウェア)

USB CDC-ACM (仮想シリアル、Web Serial / 任意のシリアルライブラリ) のバイトストリームに、
次のフレームを連続して並べる。双方向で同じ形式。ボーレートは USB では意味を持たない (1200 bps だけは
BOOTSEL 再起動の合図として予約)。定義の正本は
[`Sources/LinkCore/Protocol.swift`](../Sources/LinkCore/Protocol.swift) で、
`swift run ProtocolGen` が `web/src/protocol.generated.ts` を生成する。

```
+--------+----------------+------------------------+
| type   | length (LE16)  | payload (length bytes) |
| 1 byte | 2 bytes        |                        |
+--------+----------------+------------------------+
```

数値はすべてリトルエンディアン。

## 接続手順

1. ポートを開き DTR を立てる (Web Serial の `open()` は自動で立てる)。ファームは DTR を「ホスト接続中」の印に使い、
   DTR が落ちると送信バッファを捨てる。
2. `RESET` (0x30) → `GET_INFO` (0x01) を送り、`INFO` の `protoVer` が一致することを確認する。
   `RESET` は前回の転送の残りデータや他プロセス (ModemManager 等) が送った文字列を捨てて同期を取り直す役割もある。

## コマンド (ホスト → デバイス)

| type | 名前        | payload                                                   | 応答 |
|-----:|-------------|-----------------------------------------------------------|------|
| 0x01 | GET_INFO    | なし                                                      | INFO |
| 0x02 | SET_CONFIG  | clockHz u32, gapUs u16, palette u8, connectTimeoutMs u32  | INFO |
| 0x10 | MB_START    | romSize u32 (ヘッダ 0xC0 を含む全長。本体は 16 バイト境界) | MB_STATUS … |
| 0x11 | MB_DATA     | ROM バイト列 (先頭から順に、分割自由)                      | (MB_PROGRESS) |
| 0x12 | MB_ABORT    | なし                                                      | MB_ERROR(aborted) |
| 0x20 | XFER32      | word u32                                                  | XFER_RESULT |
| 0x21 | XFER16      | word u16 (上位 16bit=0 で送り、応答の上位 16bit を返す)    | XFER_RESULT |
| 0x30 | RESET       | なし                                                      | MB_STATUS(idle) |
| 0x7F | BOOTSEL     | なし                                                      | (再起動) |

- `clockHz` は 1 kHz〜2 MHz にクランプ。`gapUs` は 36 µs 未満を 36 µs に丸める。
- `connectTimeoutMs` = 0 で GBA を無制限に待つ。
- `MB_START` 中に再度 `MB_START` を送ると `NAK`。

## イベント (デバイス → ホスト)

| type | 名前        | payload |
|-----:|-------------|---------|
| 0x80 | INFO        | protoVer u8, fwMajor u8, fwMinor u8, fwPatch u8, ringCapacity u32, clockHz u32, gapUs u16, palette u8, connectTimeoutMs u32 |
| 0x81 | LOG         | UTF-8 テキスト |
| 0x90 | MB_STATUS   | phase u8 (`MultibootPhase`), detail u32 |
| 0x91 | MB_PROGRESS | consumed u32 (GBA へ送り終えた ROM バイト数), total u32 |
| 0x92 | MB_DONE     | crc u16, elapsedMs u32, clientData u8, handshake u8, randomData u8, palette u8 |
| 0x93 | MB_ERROR    | code u8 (`MultibootErrorCode`), phase u8, expected u32, got u32 |
| 0xA0 | XFER_RESULT | word u32 |
| 0xFE | NAK         | type u8 (拒否したコマンド) |

## フロー制御

ファームは ROM をリングバッファ (既定 32 KiB、`INFO.ringCapacity`) に溜めながら GBA へ送る。
ホストは `sent - consumed + chunk <= ringCapacity` を満たす間だけ `MB_DATA` を送り、
`MB_PROGRESS` (1 KiB 消費ごと) で `consumed` を更新する。
リングが満杯のときファームは USB の受信を止める (エンドポイントが NAK を返す) ので、
ホストが多少先行しても壊れることはない。

## Multiboot 側の手順

GBA 側のプロトコルは GBATEK「Multiboot Transfer Protocol」に従い、
[`Sources/LinkCore/MultibootEngine.swift`](../Sources/LinkCore/MultibootEngine.swift) に
I/O 非依存の状態機械として実装している。同じコードを

- RP2040 ファームウェア (PIO SPI で 1 ワードずつ交換)
- ブラウザの wasm (`XFER32` コマンドで 1 ワードずつ交換する診断モード)
- ホストのテスト (`Tests/LinkCoreTests/FakeGBA.swift` が GBA BIOS 側を模す)

で使う。
