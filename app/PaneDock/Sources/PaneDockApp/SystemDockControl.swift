import Foundation
import FocusProbeCore

/// 실제 macOS Dock 설정 제어.
///
/// **사용자가 동의한 Custom 모드에서만** 호출된다(자동 검사는 대체 구현을 쓴다).
/// 모든 변경은 적용 전에 원래 값·자료형·존재 여부를 기록하고, 실제로 바꾼 키만 되돌린다.
final class SystemDockControl: DockSystemControl {
    private let log: (String) -> Void
    /// Dock 재시작 허용 여부. **검증용 플래그로만 끈다**(운영에서는 항상 재시작한다).
    private let allowRestart: Bool

    init(allowRestart: Bool = true, log: @escaping (String) -> Void = { _ in }) {
        self.allowRestart = allowRestart
        self.log = log
    }

    func snapshot(_ keys: [DockPreferenceKey]) -> DockPreferenceSnapshot {
        DockPreferenceSnapshot(
            entries: keys.map { DockPreferenceSnapshot.Entry(key: $0, value: currentValue(for: $0)) }
        )
    }

    func currentValue(for key: DockPreferenceKey) -> DockPreferenceValue? {
        guard let raw = CFPreferencesCopyValue(
            key.name as CFString,
            key.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) else { return nil }
        return Self.value(from: raw)
    }

    func set(_ value: DockPreferenceValue, for key: DockPreferenceKey) throws {
        CFPreferencesSetValue(
            key.name as CFString,
            Self.cfValue(from: value),
            key.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard CFPreferencesAppSynchronize(key.domain as CFString) else {
            throw DockModeError.applyFailed(step: "설정 쓰기", reason: "\(key.name)을(를) 저장하지 못했습니다")
        }
        log("dockctl set \(key.label)=\(value.text) (\(value.typeName))")
    }

    func remove(_ key: DockPreferenceKey) throws {
        // 없던 키는 **지워서** 원래 상태(키 없음)로 되돌린다.
        CFPreferencesSetValue(
            key.name as CFString,
            nil,
            key.domain as CFString,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        guard CFPreferencesAppSynchronize(key.domain as CFString) else {
            throw DockModeError.applyFailed(step: "설정 삭제", reason: "\(key.name)을(를) 지우지 못했습니다")
        }
        log("dockctl remove \(key.label)")
    }

    /// 설정 반영을 위해 Dock을 **한 번** 다시 시작한다(반복 강제 종료 금지).
    func restartDock() throws {
        guard allowRestart else {
            log("dockctl restart=skipped (검증용 플래그)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DockModeError.applyFailed(step: "Dock 재시작", reason: (error as NSError).localizedDescription)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DockModeError.applyFailed(step: "Dock 재시작", reason: "killall Dock 종료 코드 \(process.terminationStatus)")
        }
        log("dockctl restart=ok")
    }

    // MARK: - 값 변환

    private static func value(from raw: CFTypeRef) -> DockPreferenceValue? {
        if CFGetTypeID(raw) == CFBooleanGetTypeID(), let number = raw as? NSNumber {
            return .bool(number.boolValue)
        }
        if let number = raw as? NSNumber {
            // **부동소수 여부를 그대로 살린다.** 값을 보고 정수로 바꾸면
            // `autohide-delay = 1000.0`이 `.integer(1000)`으로 읽혀 원래 자료형을 잃는다.
            return DockPreferenceValue.fromNumber(
                number.doubleValue,
                isFloat: CFNumberIsFloatType(number as CFNumber)
            )
        }
        if let text = raw as? String { return .string(text) }
        return nil
    }

    private static func cfValue(from value: DockPreferenceValue) -> CFTypeRef {
        switch value {
        case .bool(let inner): return (inner ? kCFBooleanTrue : kCFBooleanFalse)
        case .integer(let inner): return NSNumber(value: inner)
        case .double(let inner): return NSNumber(value: inner)
        case .string(let inner): return inner as CFString
        }
    }
}
