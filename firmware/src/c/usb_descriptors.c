// USB ディスクリプタ: CDC-ACM (仮想シリアル) 1 ポートのみ。
//
// CDC-ACM は OS 標準のクラスドライバで動くため、専用ドライバや MS OS 2.0 ディスクリプタは不要。
// VID/PID は Raspberry Pi が RP2040 の CDC デバイス向けに公開している共通 ID
// (0x2E8A:0x000A "Raspberry Pi Pico SDK CDC UART (RP2040)") を既定にしている。
// デバイスの識別は iProduct / iSerial と、アプリ層の GET_INFO ハンドシェイクで行う。
#include "usb_descriptors.h"

#include <string.h>

#include "board_config.h"
#include "pico/unique_id.h"
#include "tusb.h"

// ---- Device -----------------------------------------------------------------------
static tusb_desc_device_t const desc_device = {
    .bLength = sizeof(tusb_desc_device_t),
    .bDescriptorType = TUSB_DESC_DEVICE,
    .bcdUSB = 0x0200,
    // CDC は IAD を使うので Miscellaneous / Common / IAD
    .bDeviceClass = TUSB_CLASS_MISC,
    .bDeviceSubClass = MISC_SUBCLASS_COMMON,
    .bDeviceProtocol = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0 = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor = USB_VID,
    .idProduct = USB_PID,
    .bcdDevice = (FW_VERSION_MAJOR << 8) | (FW_VERSION_MINOR << 4) | FW_VERSION_PATCH,
    .iManufacturer = 0x01,
    .iProduct = 0x02,
    .iSerialNumber = 0x03,
    .bNumConfigurations = 0x01,
};

uint8_t const *tud_descriptor_device_cb(void) { return (uint8_t const *)&desc_device; }

// ---- Configuration ----------------------------------------------------------------
#define CONFIG_TOTAL_LEN (TUD_CONFIG_DESC_LEN + TUD_CDC_DESC_LEN)

static uint8_t const desc_configuration[] = {
    // Config: 2 インターフェース (CDC 制御 + データ)、文字列 0、バスパワー 100mA
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, CONFIG_TOTAL_LEN, 0x00, 100),
    // CDC: 文字列 4、通知 EP 0x81 (8 バイト)、データ EP OUT 0x02 / IN 0x82 (64 バイト)
    TUD_CDC_DESCRIPTOR(ITF_NUM_CDC, 4, EPNUM_CDC_NOTIF, 8, EPNUM_CDC_OUT, EPNUM_CDC_IN, 64),
};

uint8_t const *tud_descriptor_configuration_cb(uint8_t index) {
  (void)index;
  return desc_configuration;
}

// ---- Strings ------------------------------------------------------------------------
static char serial_str[2 * PICO_UNIQUE_BOARD_ID_SIZE_BYTES + 1];

static char const *string_desc_arr[] = {
    (const char[]){0x09, 0x04},  // 0: 言語 = English (0x0409)
    "trickart",                  // 1: Manufacturer
    "GBA Multiboot Link",        // 2: Product
    serial_str,                  // 3: Serial (RP2040 固有 ID)
    "GBA Multiboot Link",        // 4: CDC インターフェース名
};

static uint16_t desc_str[32 + 1];

uint16_t const *tud_descriptor_string_cb(uint8_t index, uint16_t langid) {
  (void)langid;
  size_t chr_count;

  if (index == 0) {
    memcpy(&desc_str[1], string_desc_arr[0], 2);
    chr_count = 1;
  } else {
    if (index >= sizeof(string_desc_arr) / sizeof(string_desc_arr[0])) return NULL;
    if (index == 3 && serial_str[0] == 0) {
      pico_get_unique_board_id_string(serial_str, sizeof(serial_str));
    }
    const char *str = string_desc_arr[index];
    chr_count = strlen(str);
    size_t const max_count = sizeof(desc_str) / sizeof(desc_str[0]) - 1;
    if (chr_count > max_count) chr_count = max_count;
    for (size_t i = 0; i < chr_count; i++) desc_str[1 + i] = str[i];
  }

  desc_str[0] = (uint16_t)((TUSB_DESC_STRING << 8) | (2 * chr_count + 2));
  return desc_str;
}
