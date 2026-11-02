// 外部から与えられたメモリ上で動く固定長リングバッファ (ヒープ非使用)。
// ファームウェアでは C 側の静的配列、wasm では静的なバッファを渡す。

public struct ByteRing: MultibootDataSource {
    private let storage: UnsafeMutablePointer<UInt8>
    public let capacity: Int
    private var head: Int = 0   // 次に読む位置
    private var count: Int = 0

    public init(storage: UnsafeMutablePointer<UInt8>, capacity: Int) {
        self.storage = storage
        self.capacity = capacity
    }

    public var available: Int { count }
    public var free: Int { capacity - count }
    public var isEmpty: Bool { count == 0 }

    public mutating func clear() {
        head = 0
        count = 0
    }

    @inline(__always)
    public mutating func readByte() -> UInt8 {
        let b = storage[head]
        head += 1
        if head == capacity { head = 0 }
        count -= 1
        return b
    }

    /// 書き込めるだけ書き込み、書き込んだバイト数を返す
    @discardableResult
    public mutating func write(_ src: UnsafePointer<UInt8>, count n: Int) -> Int {
        let toWrite = n < free ? n : free
        var tail = head + count
        if tail >= capacity { tail -= capacity }
        var i = 0
        while i < toWrite {
            storage[tail] = src[i]
            tail += 1
            if tail == capacity { tail = 0 }
            i += 1
        }
        count += toWrite
        return toWrite
    }
}

/// 連続メモリをそのまま読むデータソース (wasm のホスト駆動モードやテスト用)
public struct BufferSource: MultibootDataSource {
    private let base: UnsafePointer<UInt8>
    public let count: Int
    public private(set) var position: Int = 0

    public init(base: UnsafePointer<UInt8>, count: Int) {
        self.base = base
        self.count = count
    }

    public var available: Int { count - position }

    @inline(__always)
    public mutating func readByte() -> UInt8 {
        let b = base[position]
        position += 1
        return b
    }
}
