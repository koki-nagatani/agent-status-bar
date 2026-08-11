import Foundation
import ASBDomain
import ASBApplication

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
}

/// `kill(pid, 0)` によるプロセス生存確認。
///
/// `ESRCH` はプロセス不在。`EPERM` は「存在するが権限がない」ため生存扱いにする。
public struct SignalProcessProbe: ProcessProbe {
    public init() {}

    public func isAlive(_ pid: ProcessID) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
