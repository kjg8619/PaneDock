// swift-tools-version:5.9
import PackageDescription

// 검증용 프로토타입이다. 제품 앱 타깃과 분리되어 있다.
// FocusProbeCore는 UI 의존이 없어 검증 후 앱의 Adapter 계층으로 옮길 수 있다.
let package = Package(
    name: "focus-probe",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "focus-probe", targets: ["FocusProbeCLI"]),
        // 제품 앱(app/PaneDock)이 같은 추적 로직을 재사용한다. 복제하지 않는다.
        .library(name: "FocusProbeCore", targets: ["FocusProbeCore"]),
    ],
    targets: [
        .target(name: "FocusProbeCore"),
        .executableTarget(name: "FocusProbeCLI", dependencies: ["FocusProbeCore"]),
    ]
)
