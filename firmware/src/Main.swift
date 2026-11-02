// エントリポイント。USB スタックを初期化し、TinyUSB のタスクとアプリの poll を回し続ける。

@main
struct Main {
    static func main() {
        glue_usb_init()
        var firmware = Firmware()
        while true {
            tud_task_ext(0, false)
            firmware.poll()
        }
    }
}
