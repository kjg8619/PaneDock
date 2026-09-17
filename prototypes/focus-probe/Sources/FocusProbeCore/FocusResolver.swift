import Foundation

/// 포커스 판정. 기획서 §7 "순서 역전과 오작동 방지"를 담당한다.
///
/// 규칙: 포커스 대상이 바뀌거나 연결이 끊겼다가 복구되면 **세대를 올린다**.
/// 조회 응답에는 요청 당시의 세대와 대상 ID를 붙이고, 도착 시 현재 값과 다르면 버린다.
/// 시각 비교로 순서를 판단하지 않는다.
public final class FocusResolver {
    public private(set) var generation: UInt64 = 0
    public private(set) var targetPaneID: String?

    public init() {}

    /// 포커스 대상 pane을 설정한다. 같은 대상이면 세대를 유지한다.
    @discardableResult
    public func setTarget(_ paneID: String) -> UInt64 {
        if targetPaneID != paneID {
            targetPaneID = paneID
            generation += 1
        }
        return generation
    }

    /// 연결 재수립 시 호출한다. 이전 연결에서 나간 요청의 응답을 무효화한다.
    @discardableResult
    public func invalidateForReconnect() -> UInt64 {
        generation += 1
        return generation
    }

    /// 대상이 사라졌을 때 호출한다(예: cmux에서 터미널이 아닌 패널로 포커스가 옮겨간 경우).
    ///
    /// 세대를 올려 **이전 대상에 대한 늦은 응답이 현재 대상으로 되살아나지 않게** 한다.
    /// 대상이 없던 상태에서 다시 호출해도 세대는 그대로다.
    @discardableResult
    public func clearTarget() -> UInt64 {
        guard targetPaneID != nil else { return generation }
        targetPaneID = nil
        generation += 1
        return generation
    }

    /// 응답이 현재 포커스에 대한 것인지 판정한다.
    public func accepts(generation observationGeneration: UInt64, paneID: String) -> Bool {
        observationGeneration == generation && paneID == targetPaneID
    }
}
