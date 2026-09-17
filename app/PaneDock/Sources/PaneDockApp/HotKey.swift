import Carbon
import FocusProbeCore
import Foundation

/// 전역 단축키 하나를 등록한다.
///
/// **공식 API(Carbon `RegisterEventHotKey`)만 쓴다.** 접근성 권한이 필요 없고,
/// 키 입력을 감시하지 않는다. 시스템이 등록한 조합 하나만 알려준다.
///
/// 등록에 실패하면 이유를 돌려준다(다른 앱이 이미 쓰는 조합이면 `conflict`).
final class GlobalHotKey {
    enum Registration: Equatable {
        case registered
        case disabled
        /// 이미 다른 앱(또는 다른 인스턴스)이 같은 조합을 쓰고 있다.
        case conflict(code: Int32)
        case failed(code: Int32)

        var message: String {
            switch self {
            case .registered: return "등록됨"
            case .disabled: return "사용 안 함"
            case .conflict(let code): return "이미 다른 앱이 사용 중입니다 (오류 \(code))"
            case .failed(let code): return "등록 실패 (오류 \(code))"
            }
        }
    }

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        unregister()
    }

    @discardableResult
    func register(_ choice: HotKeyChoice) -> Registration {
        unregister()
        guard choice != .disabled else { return .disabled }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventCallback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else {
            return .failed(code: installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let modifiers = carbonModifiers(for: choice)
        let status = RegisterEventHotKey(
            Self.keyCodeD,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            unregister()
            if status == eventHotKeyExistsErr {
                return .conflict(code: status)
            }
            return .failed(code: status)
        }
        return .registered
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    fileprivate func fire() {
        action()
    }

    // MARK: - 조합 매핑

    /// 'D' 키. Carbon 가상 키코드.
    private static let keyCodeD: UInt32 = UInt32(kVK_ANSI_D)
    /// 'PDK1'
    private static let signature: OSType = 0x5044_4B31

    private func carbonModifiers(for choice: HotKeyChoice) -> UInt32 {
        switch choice {
        case .controlOptionCommandD:
            return UInt32(controlKey | optionKey | cmdKey)
        case .optionCommandD:
            return UInt32(optionKey | cmdKey)
        case .controlOptionD:
            return UInt32(controlKey | optionKey)
        case .disabled:
            return 0
        }
    }
}

/// Carbon 이벤트 콜백. C 함수 포인터여야 하므로 전역 함수로 둔다.
private func hotKeyEventCallback(
    _ callRef: EventHandlerCallRef?,
    _ eventRef: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        hotKey.fire()
    }
    return noErr
}
