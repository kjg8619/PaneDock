// swift-tools-version:5.9
import PackageDescription

// 0.1a: Ghostty 전용 최소 Dock UI.
//
// 추적 로직은 검증용 패키지의 FocusProbeCore를 그대로 가져다 쓴다. 복제하지 않는다.
let package = Package(
    name: "PaneDock",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PaneDock", targets: ["PaneDockApp"])
    ],
    dependencies: [
        .package(path: "../../prototypes/focus-probe")
    ],
    targets: [
        .executableTarget(
            name: "PaneDockApp",
            dependencies: [
                .product(name: "FocusProbeCore", package: "focus-probe")
            ]
        )
    ]
)
