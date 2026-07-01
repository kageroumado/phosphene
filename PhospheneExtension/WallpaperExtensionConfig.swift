// XPC connection configuration for the wallpaper extension.
//
// Accepts incoming connections from WallpaperAgent, sets up class whitelists
// for all XPC type parameters, and wires up the handler.

import ExtensionFoundation
import Foundation

struct WallpaperExtensionConfig: AppExtensionConfiguration {
    /// How long to keep the still-frame bridge up after a mid-render connection
    /// drop before forcing recovery. Covers the observed re-acquire latency
    /// (~1-2 s) with margin while keeping post-churn / post-hibernation recovery
    /// quick.
    nonisolated static let recoveryGrace: Double = 3

    func accept(connection: NSXPCConnection) -> Bool {
        extensionLog("XPC from PID=\(connection.processIdentifier)")

        // Validate the caller before building interfaces, exporting the handler,
        // or resuming — an unexpected (non-Apple) process never reaches our
        // exported methods.
        guard CallerValidation.isAcceptable(connection) else {
            extensionLog("XPC rejected: untrusted caller")
            return false
        }

        let exported = NSXPCInterface(with: (any WallpaperExtensionXPCProtocol).self)

        // Build class whitelist from runtime-loaded WallpaperExtensionKit classes
        let typeNames = [
            "WallpaperIDXPC",
            "WallpaperCreationRequestXPC",
            "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC",
            "WallpaperSnapshotXPC",
            "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC",
            "WallpaperChoiceIDsXPC",
            "WallpaperExtensionChoiceRequestXPC",
            "WallpaperChoiceRequestAdditionResultXPC",
            "WallpaperDebugRequestXPC",
            "WallpaperDebugResponseXPC",
            "WallpaperMigrationVersionXPC",
            "WallpaperSettingsViewModelsXPC",
            "AuditTokenXPC",
        ]

        let allTypes = NSMutableSet()
        var missing: [String] = []
        for name in typeNames {
            if let cls = objc_getClass(name) {
                allTypes.add(cls)
            } else {
                missing.append(name)
            }
        }
        if !missing.isEmpty {
            extensionLog("  MISSING types: \(missing.joined(separator: ", "))")
        }
        allTypes.add(NSString.self)
        allTypes.add(NSNumber.self)
        allTypes.add(NSData.self)
        allTypes.add(NSArray.self)
        allTypes.add(NSDictionary.self)
        allTypes.add(NSURL.self)
        allTypes.add(NSError.self)

        let classes = allTypes as! Set<AnyHashable>

        let selectors: [(Selector, Int, Bool)] = [
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.acquire(withId:request:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.update(withId:request:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.invalidate(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.snapshot(withId:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.selectedChoicesDidChange(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.isChoiceDownloaded(with:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.download(withChoiceID:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.pauseDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.cancelDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.resumeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.removeDownload(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrateSelectedChoice(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.migrate(from:to:reply:)), 1, false),
            (#selector(WallpaperXPCHandler.skipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.canSkipShuffledContent(withId:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, false),
            (#selector(WallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, true),
            (#selector(WallpaperXPCHandler.handleNotification(withNamed:reply:)), 0, false),
        ]

        for (sel, idx, isReply) in selectors {
            exported.setClasses(classes, for: sel, argumentIndex: idx, ofReply: isReply)
        }

        connection.exportedInterface = exported
        connection.remoteObjectInterface = NSXPCInterface(with: (any WallpaperExtensionProxyXPCProtocol).self)

        let handler = WallpaperXPCHandler()
        handler.connectionPID = connection.processIdentifier
        connection.exportedObject = handler

        connection.interruptionHandler = { extensionLog("XPC interrupted") }
        connection.invalidationHandler = { [weak handler] in
            guard let handler else { extensionLog("XPC invalidated (handler gone)"); return }
            // Flag first, before tearing down contexts: an acquire Task still in
            // flight on this connection checks this under the state lock and skips
            // its store, so it can't orphan a live context after we've cleaned up.
            handler.invalidation.markInvalidated()
            handler.agentProxy = nil
            let pid = handler.connectionPID

            // Remove and stop ONLY this connection's contexts. One extension process
            // serves several connections — the live desktop render (WallpaperAgent),
            // the Settings preview (isPreview), the snapshot/thumbnail service — each
            // with its own contexts. Apple keys teardown per-WallpaperID and never
            // touches another connection's render; a process-global wipe here is what
            // let a routine preview/thumbnail disconnect kill the live wallpaper and
            // force a recovery exit on every pick (issue #13). Tearing down promptly
            // also lets WallpaperAgent fall back to its own cached BMP snapshot — its
            // normal bridge — instead of a stale surface (keeping a dropped CAContext
            // alive confuses the Agent's compositor: mis-sized/mis-placed surface).
            let removed = WallpaperState.shared.removeContexts(ownedBy: handler.ownerToken)
            guard !removed.isEmpty else {
                extensionLog("XPC invalidated (pid: \(pid)) — no owned contexts")
                return
            }

            let removedLive = removed.contains { !$0.isPreview }
            let remainingLive = WallpaperState.shared.liveContextCount
            WallpaperPrefs.shared.setActive(remainingLive > 0)

            guard removedLive, remainingLive == 0 else {
                extensionLog("XPC invalidated (pid: \(pid)) — released \(removed.count) context(s); live render intact (remaining live: \(remainingLive))")
                return
            }

            // We lost the live desktop render. On every wallpaper pick (and idle
            // transitions) WallpaperAgent drops the connection holding the current
            // render and re-acquires ~1s later, bridging with its cached BMP — so
            // DON'T exit yet. Arm a delayed recovery instead.
            let genAtArm = WallpaperState.shared.acquireGeneration
            extensionLog("XPC invalidated mid-render (pid: \(pid)) — lost live render (freed \(removed.count) ctx); arming \(Int(Self.recoveryGrace)) s recovery")
            RecoveryCoordinator.shared.arm(grace: .seconds(Self.recoveryGrace)) {
                // Grace elapsed with no replacement. If the agent is still actively
                // acquiring (generation changed), this is just a transient gap from
                // rapid switching — don't exit. Only a genuinely quiescent desktop
                // (deep standby/hibernation), where WallpaperAgent won't re-acquire
                // on its own (verified by disassembling it), warrants exiting so
                // RunningBoard relaunches us into a fresh acquire (issue #2). The
                // exit is debounced cross-process — RunningBoard's relaunch backoff
                // can't be tuned and repeated exits would brick the wallpaper (#13).
                if WallpaperState.shared.acquireGeneration != genAtArm {
                    extensionLog("[Recovery] Agent still acquiring — no exit (waiting to settle)")
                    return
                }
                guard RecoveryGate.shouldExitForRecovery() else {
                    extensionLog("[Recovery] Live render still gone but recovery debounced — staying alive")
                    return
                }
                extensionLog("[Recovery] Live render not restored within grace — exiting to force re-acquire")
                _exit(0)
            }
        }

        // Publish the proxy before resuming so an early incoming callback can't
        // observe a nil agentProxy (and skip its invalidateSnapshots).
        handler.agentProxy = connection.remoteObjectProxy as? (any WallpaperExtensionProxyXPCProtocol)

        connection.resume()

        extensionLog("XPC accepted with full protocol")
        return true
    }
}
