// TinyUSB の CDC-ACM (仮想シリアル) 経由でホストへイベントフレームを送る。

struct UsbLink {
    private let tx: UnsafeMutablePointer<UInt8>
    private let txCapacity: Int

    init() {
        tx = glue_tx_buffer()
        txCapacity = Int(glue_tx_buffer_size())
    }

    /// ホストがポートを開いている (DTR) か
    var isConnected: Bool { glue_host_connected() }

    /// ペイロードを組み立ててフレームを送る。
    /// - Parameters:
    ///   - important: true なら送信バッファが空くまで (上限付きで) 待つ。false なら空きがなければ捨てる。
    ///   - fill: ペイロード領域にデータを書き、バイト数を返す
    /// - Returns: 送信できたか
    @discardableResult
    func send(_ type: EventType, important: Bool = false, _ fill: (UnsafeMutablePointer<UInt8>) -> Int) -> Bool {
        guard tud_mounted() else { return false }
        let payload = tx + LinkProtocol.frameHeaderSize
        var n = fill(payload)
        if n > txCapacity - LinkProtocol.frameHeaderSize { n = txCapacity - LinkProtocol.frameHeaderSize }
        FrameHeader(type: type.rawValue, length: UInt16(n)).write(to: tx)
        let total = UInt32(n + LinkProtocol.frameHeaderSize)

        var tries = 0
        while tud_cdc_write_available() < total {
            if !important || tries >= 5_000 { return false }
            tud_task_ext(0, false)
            busy_wait_us_32(100)
            tries += 1
        }
        _ = tud_cdc_write(UnsafeRawPointer(tx), total)
        _ = tud_cdc_write_flush()
        return true
    }
}
