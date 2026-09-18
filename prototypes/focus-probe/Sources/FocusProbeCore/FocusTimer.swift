import Foundation

/// 집중 타이머의 **실행 상태**(카드 하나에 하나).
///
/// 지키는 것:
/// - **남은 시간은 시각으로 계산한다.** 갱신 횟수를 세지 않으므로 갱신이 밀리거나 건너뛰어도 값이 맞는다.
/// - 이 값은 **파일에 저장하지 않는다**. 프로젝트 전환·접기·배치 변경으로 초기화하지 않고,
///   앱을 완전히 종료하면 사라진다(복원은 이번 범위가 아니다).
public struct FocusTimerState: Equatable, Sendable {
    /// 기본 집중 시간(25분). 통계·프로젝트별 기록은 두지 않는다.
    public static let defaultDuration: TimeInterval = 25 * 60

    public var duration: TimeInterval
    /// 흐르기 시작한 시각. 멈춰 있으면 nil.
    public var runningSince: Date?
    /// 이미 흐른 시간(멈춘 구간의 합).
    public var accumulated: TimeInterval

    public init(duration: TimeInterval = FocusTimerState.defaultDuration) {
        self.duration = duration
        self.runningSince = nil
        self.accumulated = 0
    }

    public var isRunning: Bool { runningSince != nil }

    /// 지금 시각 기준으로 흐르고 있는가. **끝난 타이머는 흐르지 않는 것으로 본다**(00:00에서 멈춘다).
    public func isRunning(at now: Date) -> Bool {
        runningSince != nil && remaining(at: now) > 0
    }

    /// 지금까지 흐른 시간.
    public func elapsed(at now: Date) -> TimeInterval {
        guard let runningSince else { return accumulated }
        // 시각이 뒤로 가도(수동 조정·시계 보정) 음수를 만들지 않는다.
        return accumulated + max(0, now.timeIntervalSince(runningSince))
    }

    /// 남은 시간. 0 아래로 내려가지 않는다.
    public func remaining(at now: Date) -> TimeInterval {
        max(0, duration - elapsed(at: now))
    }

    /// 남은 비율(진행 링). 1이면 가득 찬 상태.
    public func remainingFraction(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return remaining(at: now) / duration
    }

    public func isFinished(at now: Date) -> Bool { remaining(at: now) <= 0 }

    /// 카드에 보여줄 상태 문구. **`00:00`에서는 "끝남"이고 버튼도 그 상태에 맞는다.**
    public func statusText(at now: Date) -> String {
        if isFinished(at: now) { return "끝남" }
        if isRunning(at: now) { return "집중 중" }
        if elapsed(at: now) > 0 { return "일시정지" }
        return "집중 타이머"
    }

    /// `mm:ss`. 남은 시간을 **올림**해 보여준다(시작 직후 25:00, 끝에서 00:00).
    public func text(at now: Date) -> String {
        let total = Int(remaining(at: now).rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 시작. 끝난(00:00) 상태에서 누르면 **처음부터 다시 시작**한다.
    /// 이미 흐르고 있으면 아무것도 하지 않는다(두 번 눌러도 시간이 늘지 않는다).
    public mutating func start(at now: Date) {
        guard runningSince == nil else { return }
        if isFinished(at: now) { accumulated = 0 }
        runningSince = now
    }

    /// 일시정지. 흐른 시간을 확정하고 멈춘다.
    public mutating func pause(at now: Date) {
        guard runningSince != nil else { return }
        accumulated = elapsed(at: now)
        runningSince = nil
    }

    /// 00:00에 도달한 것을 확정한다. 흐르는 표시를 지우고 남은 시간을 0으로 고정한다.
    /// (`pause`와 달리 남은 시간을 되살리지 않는다 — 끝난 타이머는 끝난 상태로 남는다.)
    public mutating func complete(at now: Date) {
        guard isFinished(at: now) else { return }
        accumulated = duration
        runningSince = nil
    }

    /// 재설정. 처음 상태(가득 찬 시간, 멈춤)로 되돌린다.
    public mutating func reset() {
        accumulated = 0
        runningSince = nil
    }
}
