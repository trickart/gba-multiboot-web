// Swift 側から使う C シムの宣言。
// TinyUSB の初期化・ディスクリプタ、静的バッファ、ブート ROM 呼び出しなど
// マクロやテーブル定義が中心で Swift に向かない部分だけを C に置く。
#pragma once

#include <stdbool.h>
#include <stdint.h>

#include "board_config.h"

#ifdef __cplusplus
extern "C" {
#endif

/// ホストから流れてくる ROM データを溜めるリングバッファ (バイト)
#define ROM_RING_CAPACITY 32768
uint8_t *glue_rom_ring(void);

/// USB 受信の一時バッファ
uint8_t *glue_usb_scratch(void);
uint32_t glue_usb_scratch_size(void);

/// 小さなコマンドのペイロード組み立て用
uint8_t *glue_cmd_buffer(void);
uint32_t glue_cmd_buffer_size(void);

/// イベント送信用
uint8_t *glue_tx_buffer(void);
uint32_t glue_tx_buffer_size(void);

/// TinyUSB デバイススタックを初期化する
void glue_usb_init(void);

/// ホストがシリアルポートを開いている (DTR が立っている) か
bool glue_host_connected(void);

/// UF2 ブートローダ (BOOTSEL) で再起動する
void glue_reset_to_bootsel(void) __attribute__((noreturn));

#ifdef __cplusplus
}
#endif
