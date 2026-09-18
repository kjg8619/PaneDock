import Foundation
import FocusProbeCore

/// 실제 macOS Dock 설정 제어.
///
/// **사용자가 동의한 Custom 모드에서만** 호출된다(자동 검사는 대체 구현을 쓴다).
/// 모든 변경은 적용 전에 원래 값·자료형·존재 여부를 기록하고, 실제로 바꾼 키만 되돌린다.
final class SystemDockControl: DockSystemControl {
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) {
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
            let double = number.doubleValue
            if double == double.rounded(), abs(double) < 9_007_199_254_740_992 {
                return .integer(Int(double))
            }
            return .double(double)
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
