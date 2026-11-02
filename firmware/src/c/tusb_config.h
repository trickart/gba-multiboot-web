// TinyUSB 設定: Web Serial 用 CDC-ACM 1 ポートのみ
#ifndef TUSB_CONFIG_H_
#define TUSB_CONFIG_H_

#ifdef __cplusplus
extern "C" {
#endif

// CFG_TUSB_MCU / CFG_TUSB_OS は pico-sdk が定義する
#define CFG_TUSB_RHPORT0_MODE   (OPT_MODE_DEVICE | OPT_MODE_FULL_SPEED)

#ifndef CFG_TUSB_MEM_SECTION
#define CFG_TUSB_MEM_SECTION
#endif
#ifndef CFG_TUSB_MEM_ALIGN
#define CFG_TUSB_MEM_ALIGN      __attribute__((aligned(4)))
#endif

#define CFG_TUD_ENABLED         1
#define CFG_TUD_ENDPOINT0_SIZE  64

// クラス構成
#define CFG_TUD_CDC             1
#define CFG_TUD_MSC             0
#define CFG_TUD_HID             0
#define CFG_TUD_MIDI            0
#define CFG_TUD_VENDOR          0

// CDC の FIFO サイズ (ホストからの ROM ストリーム受信用)
#define CFG_TUD_CDC_EP_BUFSIZE  64
#define CFG_TUD_CDC_RX_BUFSIZE  2048
#define CFG_TUD_CDC_TX_BUFSIZE  1024

#ifdef __cplusplus
}
#endif

#endif
