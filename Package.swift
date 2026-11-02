// swift-tools-version: 6.0
// 共有コア (LinkCore) のホストビルド・テスト・コード生成用パッケージ。
//
//  - LinkCore      : ファームウェア (RP2040 / Embedded Swift)、Web (Embedded Swift → wasm)、
//                    ホストテストの 3 環境で共通利用するロジック。Foundation 非依存。
//  - LinkCoreWasm  : wasm 向けの @_expose(wasm) エクスポート層 (scripts/build-wasm.sh からビルド)
//  - ProtocolGen   : LinkCore の定義から web/src/protocol.generated.ts を生成する
//  - LinkCoreTests : 疑似 GBA (BIOS 側プロトコル) を使った Multiboot エンジンの結合テスト
import PackageDescription

let package = Package(
    name: "gba-multiboot-link",
    products: [
        .library(name: "LinkCore", targets: ["LinkCore"]),
        .executable(name: "LinkCoreWasm", targets: ["LinkCoreWasm"]),
        .executable(name: "ProtocolGen", targets: ["ProtocolGen"]),
    ],
    targets: [
        .target(
            name: "LinkCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LinkCoreWasm",
            dependencies: ["LinkCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ProtocolGen",
            dependencies: ["LinkCore"]
        ),
        .testTarget(
            name: "LinkCoreTests",
            dependencies: ["LinkCore"]
        ),
    ]
)
