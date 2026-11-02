// TinyUSB コールバックと静的バッファ。
//   - DTR (SET_CONTROL_LINE_STATE) を「ホストが接続中」の印として使う
//   - 1200 bps が設定されたら UF2 ブートローダへ再起動する (pico-sdk / picotool の慣習と同じ)
#include <malloc.h>
#include <string.h>

#include "bsp/board_api.h"
#include "firmware_glue.h"
#include "pico/bootrom.h"
#include "tusb.h"
#include "usb_descriptors.h"

#ifndef BOARD_TUD_RHPORT
#define BOARD_TUD_RHPORT 0
#endif

// ---- 静的バッファ ---------------------------------------------------------------
static uint8_t rom_ring[ROM_RING_CAPACITY];
static uint8_t usb_scratch[2048];
static uint8_t cmd_buffer[64];
static uint8_t tx_buffer[256];

uint8_t *glue_rom_ring(void) { return rom_ring; }
uint8_t *glue_usb_scratch(void) { return usb_scratch; }
uint32_t glue_usb_scratch_size(void) { return sizeof(usb_scratch); }
uint8_t *glue_cmd_buffer(void) { return cmd_buffer; }
uint32_t glue_cmd_buffer_size(void) { return sizeof(cmd_buffer); }
uint8_t *glue_tx_buffer(void) { return tx_buffer; }
uint32_t glue_tx_buffer_size(void) { return sizeof(tx_buffer); }

// ---- 初期化 ---------------------------------------------------------------------
void glue_usb_init(void) {
  board_init();
  tusb_rhport_init_t dev_init = {.role = TUSB_ROLE_DEVICE, .speed = TUSB_SPEED_AUTO};
  tusb_init(BOARD_TUD_RHPORT, &dev_init);
  board_init_after_tusb();
}

bool glue_host_connected(void) { return tud_cdc_connected(); }

void glue_reset_to_bootsel(void) {
  reset_usb_boot(0, 0);
  while (1) {
  }
}

// ---- TinyUSB コールバック -------------------------------------------------------
void tud_mount_cb(void) {}
void tud_umount_cb(void) {}
void tud_suspend_cb(bool remote_wakeup_en) { (void)remote_wakeup_en; }
void tud_resume_cb(void) {}

// ホストが DTR を落としたら送信バッファの残りを捨てる
void tud_cdc_line_state_cb(uint8_t itf, bool dtr, bool rts) {
  (void)itf;
  (void)rts;
  if (!dtr) tud_cdc_write_clear();
}

// 1200 bps で開かれたら BOOTSEL へ (picotool と同じ慣習)
void tud_cdc_line_coding_cb(uint8_t itf, cdc_line_coding_t const *coding) {
  (void)itf;
  if (coding->bit_rate == 1200) glue_reset_to_bootsel();
}

// ---- Embedded Swift ランタイムが要求するアロケータ ---------------------------
// Swift の swift_slowAlloc は posix_memalign を呼ぶ。newlib にある場合はそちらが使われる。
int __attribute__((weak)) posix_memalign(void **memptr, size_t alignment, size_t size) {
  void *p = memalign(alignment, size);
  if (p == NULL) return 12;  // ENOMEM
  *memptr = p;
  return 0;
}
