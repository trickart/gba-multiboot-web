// このファイルは `swift run ProtocolGen` により Sources/LinkCore から生成されます。手で編集しないでください。
/* eslint-disable */

export const PROTOCOL_VERSION = 1;
export const FRAME_HEADER_SIZE = 3;
export const MAX_PAYLOAD = 2048;
export const DEFAULT_RING_CAPACITY = 32768;
export const ROM_HEADER_SIZE = 0xC0;
export const ROM_MIN_TOTAL_SIZE = 0x1C0;
export const ROM_MAX_TOTAL_SIZE = 0x40000;
export const ROM_BODY_ALIGNMENT = 0x10;

export const Command = {
  getInfo: 0x01,
  setConfig: 0x02,
  mbStart: 0x10,
  mbData: 0x11,
  mbAbort: 0x12,
  xfer32: 0x20,
  xfer16: 0x21,
  reset: 0x30,
  bootsel: 0x7F,
} as const;
export type Command = (typeof Command)[keyof typeof Command];
export const CommandName: Record<number, string> = {
  0x01: "getInfo",
  0x02: "setConfig",
  0x10: "mbStart",
  0x11: "mbData",
  0x12: "mbAbort",
  0x20: "xfer32",
  0x21: "xfer16",
  0x30: "reset",
  0x7F: "bootsel",
};

export const Event = {
  info: 0x80,
  log: 0x81,
  mbStatus: 0x90,
  mbProgress: 0x91,
  mbDone: 0x92,
  mbError: 0x93,
  xferResult: 0xA0,
  nak: 0xFE,
} as const;
export type Event = (typeof Event)[keyof typeof Event];
export const EventName: Record<number, string> = {
  0x80: "info",
  0x81: "log",
  0x90: "mbStatus",
  0x91: "mbProgress",
  0x92: "mbDone",
  0x93: "mbError",
  0xA0: "xferResult",
  0xFE: "nak",
};

export const MultibootPhase = {
  idle: 0x00,
  connecting: 0x01,
  header: 0x02,
  palette: 0x03,
  length: 0x04,
  payload: 0x05,
  crc: 0x06,
  done: 0x07,
  failed: 0x08,
} as const;
export type MultibootPhase = (typeof MultibootPhase)[keyof typeof MultibootPhase];
export const MultibootPhaseName: Record<number, string> = {
  0x00: "idle",
  0x01: "connecting",
  0x02: "header",
  0x03: "palette",
  0x04: "length",
  0x05: "payload",
  0x06: "crc",
  0x07: "done",
  0x08: "failed",
};

export const MultibootErrorCode = {
  none: 0x00,
  badSize: 0x01,
  connectTimeout: 0x02,
  badClientBit: 0x03,
  masterInfo: 0x04,
  headerAck: 0x05,
  headerDone: 0x06,
  paletteTimeout: 0x07,
  handshakeAck: 0x08,
  lengthAck: 0x09,
  payloadAck: 0x0A,
  transferDoneAck: 0x0B,
  crcReadyAck: 0x0C,
  crcAnnounceAck: 0x0D,
  crcMismatch: 0x0E,
  aborted: 0x0F,
} as const;
export type MultibootErrorCode = (typeof MultibootErrorCode)[keyof typeof MultibootErrorCode];
export const MultibootErrorCodeName: Record<number, string> = {
  0x00: "none",
  0x01: "badSize",
  0x02: "connectTimeout",
  0x03: "badClientBit",
  0x04: "masterInfo",
  0x05: "headerAck",
  0x06: "headerDone",
  0x07: "paletteTimeout",
  0x08: "handshakeAck",
  0x09: "lengthAck",
  0x0A: "payloadAck",
  0x0B: "transferDoneAck",
  0x0C: "crcReadyAck",
  0x0D: "crcAnnounceAck",
  0x0E: "crcMismatch",
  0x0F: "aborted",
};

export const RomCheck = {
  sizeOK: 0x1,
  headerChecksumOK: 0x2,
  logoOK: 0x4,
  multibootEntryOK: 0x8,
} as const;
