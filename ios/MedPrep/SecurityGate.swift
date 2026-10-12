import Foundation
import UIKit
import Security
import CryptoKit
import MachO
import Darwin

// Public Darwin process state detects an attached debugger, not whether iOS
// Developer Mode is enabled. App Attest supplies the server integrity proof.
enum SecurityGate {
    private static var lastIntegrityCheck = -Double.infinity
    private static var cachedIntegrityIssue: String?
    @MainActor private static var integrityIssue: String? {
        guard CACurrentMediaTime() - lastIntegrityCheck >= 2 else { return cachedIntegrityIssue }
        lastIntegrityCheck = CACurrentMediaTime()
        let paths = ["/Applications/Cydia.app", "/Applications/Sileo.app", "/var/jb",
                     "/Library/MobileSubstrate/MobileSubstrate.dylib", "/usr/sbin/sshd"]
        var suspicious = paths.contains { FileManager.default.fileExists(atPath: $0) }
        suspicious = suspicious || ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] != nil
        for index in 0..<_dyld_image_count() {
            if let raw = _dyld_get_image_name(index) {
                let name = String(cString: raw).lowercased()
                if ["frida", "substrate", "substitute", "libhooker", "ellekit"].contains(where: name.contains) { suspicious = true }
            }
        }
        if !suspicious {
            let probe = "/private/medprep-" + UUID().uuidString
            do {
                try Data([0]).write(to: URL(fileURLWithPath: probe), options: .withoutOverwriting)
                try? FileManager.default.removeItem(atPath: probe)
                suspicious = true
            } catch { /* A normal app cannot write outside its sandbox. */ }
        }
        if !suspicious {
            suspicious = ["cydia://", "sileo://"].contains {
                URL(string: $0).map { UIApplication.shared.canOpenURL($0) } ?? false
            }
        }
        cachedIntegrityIssue = suspicious ? "Device integrity checks failed. Protected content is unavailable." : nil
        return cachedIntegrityIssue
    }
    @MainActor static var issue: String? {
        #if targetEnvironment(simulator)
        return "MedPrep requires a physical Apple device."
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac { return "Protected content is unavailable on Mac." }
        if #available(iOS 17.0, *), UIDevice.current.userInterfaceIdiom == .vision {
            return "Protected content is unavailable on Apple Vision Pro."
        }
        if !PinnedTrust.configured(host: AppConfig.site.host ?? "") {
            return "Current and backup server public-key pins must be configured before content is available."
        }
        if let issue = integrityIssue { return issue }
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var names: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let status = names.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), &process, &size, nil, 0)
        }
        guard status == 0 else { return "Device process integrity could not be checked. Retry after restarting MedPrep." }
        return (process.kp_proc.p_flag & P_TRACED) != 0 ? "Disconnect the debugger to continue." : nil
        #endif
    }
}


