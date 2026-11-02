// GBA リンクポート (Normal mode, 32bit) を PIO で駆動する SPI マスタ。
//
// 基板の配線 (GPIO0=SC, GPIO1=SI, GPIO2=SO) は RP2040 のハード SPI のピン機能に合わないため、
// pico-examples の spi_cpha1 プログラムを使った PIO SPI にしている。
// CPOL=1 (SC アイドル High) は GPIO 出力反転で実現する。

struct LinkPort {
    private let pio: PIO
    private let sm: UInt32
    private let offset: UInt32
    private let sck: UInt32
    private let mosi: UInt32
    private let miso: UInt32

    /// SC のクロック周波数 (Hz)
    private(set) var clockHz: UInt32
    /// 転送間に空ける時間 (µs)。GBATEK は 36µs 以上を要求する。
    var gapUs: UInt32

    static let minClockHz: UInt32 = 1_000
    static let maxClockHz: UInt32 = 2_000_000
    static let minGapUs: UInt32 = 36

    init(sck: UInt32, mosi: UInt32, miso: UInt32, sd: UInt32, clockHz: UInt32, gapUs: UInt32) {
        self.sck = sck
        self.mosi = mosi
        self.miso = miso
        self.clockHz = clockHz
        self.gapUs = gapUs

        let instance = pio_get_instance(0)!
        pio = instance
        sm = UInt32(pio_claim_unused_sm(instance, true))
        offset = UInt32(withUnsafePointer(to: linkport_spi_program) { pio_add_program(instance, $0) })

        // SD は Normal mode では使わない。プルアップ入力にしておく。
        gpio_init(sd)
        gpio_set_dir(sd, false)
        gpio_pull_up(sd)

        configure()
    }

    mutating func setClock(hz: UInt32) {
        var v = hz
        if v < Self.minClockHz { v = Self.minClockHz }
        if v > Self.maxClockHz { v = Self.maxClockHz }
        clockHz = v
        configure()
    }

    private func configure() {
        pio_sm_set_enabled(pio, sm, false)

        var c = linkport_spi_program_get_default_config(offset)
        sm_config_set_out_pins(&c, mosi, 1)
        sm_config_set_in_pins(&c, miso)
        sm_config_set_sideset_pins(&c, sck)
        // MSB first、autopull/autopush、32bit フレーム
        sm_config_set_out_shift(&c, false, true, 32)
        sm_config_set_in_shift(&c, false, true, 32)
        // 1bit = 4 PIO サイクル
        let div = Float(clock_get_hz(clk_sys)) / (4.0 * Float(clockHz))
        sm_config_set_clkdiv(&c, div)

        let outMask: UInt32 = (1 << sck) | (1 << mosi)
        pio_sm_set_pins_with_mask(pio, sm, 0, outMask)
        pio_sm_set_pindirs_with_mask(pio, sm, outMask, outMask | (1 << miso))
        pio_gpio_init(pio, mosi)
        pio_gpio_init(pio, miso)
        pio_gpio_init(pio, sck)
        // CPOL=1: side-set 0 (アイドル) を High にする
        gpio_set_outover(sck, UInt32(GPIO_OVERRIDE_INVERT.rawValue))

        pio_sm_init(pio, sm, offset, &c)
        pio_sm_clear_fifos(pio, sm)
        pio_sm_set_enabled(pio, sm, true)
    }

    /// 32bit ワードを 1 回交換する (ブロッキング)。終了後 gapUs だけ待つ。
    func exchange(_ word: UInt32) -> UInt32 {
        pio_sm_put_blocking(pio, sm, word)
        let received = pio_sm_get_blocking(pio, sm)
        busy_wait_us_32(gapUs)
        return received
    }
}
