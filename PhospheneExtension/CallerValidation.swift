// Validates the identity of processes connecting to the extension's XPC surface.
//
// The exported handler can change extension state, drive renderer/snapshot work,
// and reach library-mutation paths, so connections should only be served to the
// expected Apple wallpaper host. We derive the peer's code signature from its
// audit token (never trusting the PID alone, which is reusable) and require an
// Apple-signed platform binary.
//
// Posture: reject callers we can positively identify as non-Apple. Accept Apple
// platform binaries — logging when the signer isn't the expected WallpaperAgent
// rather than rejecting, since the settings surfaces are also Apple-hosted.
// Fail *open* only when peer identity genuinely can't be obtained, so an OS
// change to the audit-token SPI degrades to today's behavior instead of
// bricking the wallpaper.

import Foundation
import Security

enum CallerValidation {
    static func isAcceptable(_ connection: NSXPCConnection) -> Bool {
        guard connection.responds(to: NSSelectorFromString("auditToken")) else {
            extensionLog("  [Caller] auditToken SPI unavailable — accepting (fail-open)")
            return true
        }

        var token = connection.auditToken
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attrs = [kSecGuestAttributeAudit: tokenData] as CFDictionary

        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attrs, [], &code)
        guard status == errSecSuccess, let code else {
            extensionLog("  [Caller] Could not derive peer SecCode (status \(status)) — accepting (fail-open)")
            return true
        }

        guard let appleReq = requirement("anchor apple") else {
            extensionLog("  [Caller] Could not build anchor-apple requirement — accepting (fail-open)")
            return true
        }

        let appleStatus = SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), appleReq)
        guard appleStatus == errSecSuccess else {
            extensionLog("  [Caller] REJECTED non-Apple caller (status \(appleStatus))")
            return false
        }

        if let agentReq = requirement("identifier \"com.apple.wallpaper.agent\""),
           SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), agentReq) != errSecSuccess {
            extensionLog("  [Caller] Apple caller is not WallpaperAgent — accepting with note")
        }
        return true
    }

    private static func requirement(_ text: String) -> SecRequirement? {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(rawValue: 0), &req) == errSecSuccess else {
            return nil
        }
        return req
    }
}
