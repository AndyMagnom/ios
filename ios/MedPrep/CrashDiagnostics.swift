import Foundation
import MetricKit

// Use the OS diagnostic channel instead of unsafe crash/signal handlers.
// Delivery can be delayed; this is a previous-crash notice, not a crash catcher.
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnostics()
    func start() { MXMetricManager.shared.add(self) }
    func didReceive(_ payloads: [MXMetricPayload]) { }
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where !(payload.crashDiagnostics?.isEmpty ?? true) {
            UserDefaults.standard.set(payload.timeStampEnd, forKey: "previousCrashReportedAt")
        }
    }
    func takeNotice() -> String? {
        guard let date = UserDefaults.standard.object(forKey: "previousCrashReportedAt") as? Date else { return nil }
        UserDefaults.standard.removeObject(forKey: "previousCrashReportedAt")
        guard Date().timeIntervalSince(date) < 7 * 24 * 3600 else { return nil }
        return "iOS reported a previous MedPrep crash. If it happens again, contact support."
    }
}
