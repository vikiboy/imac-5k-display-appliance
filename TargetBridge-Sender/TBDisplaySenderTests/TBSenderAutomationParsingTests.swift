import CoreMedia
import XCTest
@testable import TargetBridge

/// Tests for the pure parsing helpers behind the `targetbridge://` URL scheme
/// and `--connect` launch arguments (docs/Automation.md). These decide which
/// transport/mode/preset/session a scripted connect uses, so regressions here
/// silently reroute automation traffic.
@MainActor
final class TBSenderAutomationParsingTests: XCTestCase {
    func testReceiverControlKeepsNativeCursorWithoutLargeCursor() {
        XCTAssertFalse(
            TBInputControlRole.receiverMaster.usesLowLatencyCursorOverlay(
                largeCursorEnabled: false
            )
        )
        XCTAssertFalse(
            TBInputControlRole.senderMaster.usesLowLatencyCursorOverlay(
                largeCursorEnabled: false
            )
        )
        XCTAssertFalse(
            TBInputControlRole.off.usesLowLatencyCursorOverlay(
                largeCursorEnabled: false
            )
        )
        XCTAssertTrue(
            TBInputControlRole.off.usesLowLatencyCursorOverlay(
                largeCursorEnabled: true
            )
        )

        XCTAssertFalse(
            TBInputControlRole.receiverMaster.changesCursorCaptureMode(
                from: .off,
                largeCursorEnabled: false
            )
        )
        XCTAssertFalse(
            TBInputControlRole.off.changesCursorCaptureMode(
                from: .receiverMaster,
                largeCursorEnabled: false
            )
        )
        XCTAssertFalse(
            TBInputControlRole.senderMaster.changesCursorCaptureMode(
                from: .off,
                largeCursorEnabled: false
            )
        )
        XCTAssertFalse(
            TBInputControlRole.receiverMaster.changesCursorCaptureMode(
                from: .off,
                largeCursorEnabled: true
            )
        )
    }

    func testHighFrameRatePresetsUseFiveCaptureSurfaces() {
        XCTAssertEqual(TBDisplayCapturePreset.standard1440p.queueDepth, 3)
        XCTAssertEqual(TBDisplayCapturePreset.smooth1440p60.queueDepth, 5)
        XCTAssertEqual(TBDisplayCapturePreset.retina4k60.queueDepth, 5)
        XCTAssertEqual(TBDisplayCapturePreset.native5k60Experimental.queueDepth, 5)
    }

    func testHighFrameRatePresetsRequestCaptureHeadroom() {
        XCTAssertEqual(TBDisplayCapturePreset.standard1440p.captureRequestFrameRate, 30)
        XCTAssertEqual(TBDisplayCapturePreset.smooth1440p60.captureRequestFrameRate, 120)
        XCTAssertEqual(TBDisplayCapturePreset.retina4k60.captureRequestFrameRate, 120)
        XCTAssertEqual(TBDisplayCapturePreset.native5k.captureRequestFrameRate, 96)
    }

    func testFrameRatePacerSamples75HzInputAt60Hz() {
        var pacer = TBFrameRatePacer(maximumFrameRate: 60)
        let emitted = (0..<750).filter { frame in
            pacer.shouldEmit(presentationTime: CMTime(seconds: Double(frame) / 75.0, preferredTimescale: 60_000))
        }
        XCTAssertEqual(emitted.count, 600)
    }

    func testFrameRatePacerPreservesInputsAtOrBelowCeiling() {
        for inputRate in [30, 60] {
            var pacer = TBFrameRatePacer(maximumFrameRate: 60)
            let emitted = (0..<(inputRate * 10)).filter { frame in
                pacer.shouldEmit(presentationTime: CMTime(seconds: Double(frame) / Double(inputRate), preferredTimescale: 60_000))
            }
            XCTAssertEqual(emitted.count, inputRate * 10)
        }
    }

    func testFrameRatePacerDoesNotAccumulateBurstCreditAfterIdleGap() {
        var pacer = TBFrameRatePacer(maximumFrameRate: 60)
        XCTAssertTrue(pacer.shouldEmit(presentationTime: CMTime(seconds: 0, preferredTimescale: 60_000)))
        XCTAssertTrue(pacer.shouldEmit(presentationTime: CMTime(seconds: 1, preferredTimescale: 60_000)))
        XCTAssertFalse(pacer.shouldEmit(presentationTime: CMTime(seconds: 1 + 1.0 / 75.0, preferredTimescale: 60_000)))
    }

    func testDPCMProcessPoisonPermanentlyRefusesNewEncoderCreation() {
        let state = TBDPCMEncoderProcessState()
        var creationAttempts = 0

        let first: Int? = state.createIfHealthy {
            creationAttempts += 1
            return 1
        }
        XCTAssertEqual(first, 1)
        XCTAssertEqual(state.recordDrain(isQuarantined: false), .drained)
        XCTAssertFalse(state.isPoisoned)

        XCTAssertEqual(state.recordDrain(isQuarantined: true), .quarantined)
        XCTAssertTrue(state.isPoisoned)
        let refused: Int? = state.createIfHealthy {
            creationAttempts += 1
            return 2
        }
        XCTAssertNil(refused)
        XCTAssertEqual(creationAttempts, 1)
        XCTAssertNil(TBDPCMAsyncEncode(processState: state))
    }

    func testDPCMQuarantinePropagatesToOneShotServiceTermination() {
        let state = TBDPCMEncoderProcessState()
        XCTAssertFalse(state.claimTerminationIfPoisoned())

        let drainStatus = state.recordDrain(isQuarantined: true)
        let stopOutcome = TBVideoPipelineStopOutcome.resolve(
            dpcmDrainStatus: drainStatus
        )

        XCTAssertEqual(drainStatus, .quarantined)
        XCTAssertEqual(stopOutcome, .dpcmEncoderQuarantined)
        XCTAssertTrue(stopOutcome.requiresProcessTermination)
        XCTAssertTrue(state.claimTerminationIfPoisoned())
        XCTAssertFalse(state.claimTerminationIfPoisoned())
    }

    func testCleanOrAbsentDPCMDrainDoesNotRequestProcessTermination() {
        XCTAssertEqual(
            TBVideoPipelineStopOutcome.resolve(dpcmDrainStatus: nil),
            .stopped
        )
        XCTAssertEqual(
            TBVideoPipelineStopOutcome.resolve(dpcmDrainStatus: .drained),
            .stopped
        )
        XCTAssertFalse(TBVideoPipelineStopOutcome.stopped.requiresProcessTermination)
    }

    func testDPCMProgressWatchdogRecoversAfterSentFrameThenSustainedFailures() {
        var watchdog = TBPostFirstFrameProgressWatchdog()
        watchdog.reset(capturedFrames: 0, sentFrames: 0)

        XCTAssertEqual(
            watchdog.observe(
                TBVideoPipelineProgressSnapshot(
                    capturedFrames: 1,
                    sentFrames: 1,
                    monitorsDPCMProgress: true,
                    terminalEncoderHealth: false
                ),
                hasDeliveredFirstFrame: true
            ),
            .none
        )
        XCTAssertEqual(
            watchdog.observe(
                TBVideoPipelineProgressSnapshot(
                    capturedFrames: 7,
                    sentFrames: 1,
                    monitorsDPCMProgress: true,
                    terminalEncoderHealth: false
                ),
                hasDeliveredFirstFrame: true
            ),
            .none
        )
        XCTAssertEqual(
            watchdog.observe(
                TBVideoPipelineProgressSnapshot(
                    capturedFrames: 14,
                    sentFrames: 1,
                    monitorsDPCMProgress: true,
                    terminalEncoderHealth: false
                ),
                hasDeliveredFirstFrame: true
            ),
            .tearDownPreservingCodec
        )
        XCTAssertEqual(
            watchdog.observe(
                TBVideoPipelineProgressSnapshot(
                    capturedFrames: 30,
                    sentFrames: 1,
                    monitorsDPCMProgress: true,
                    terminalEncoderHealth: false
                ),
                hasDeliveredFirstFrame: true
            ),
            .none,
            "recovery is one-shot until a new capture pipeline resets the watchdog"
        )
    }

    func testDPCMProgressWatchdogAcceptsHealthyStaticDesktop() {
        var watchdog = TBPostFirstFrameProgressWatchdog()
        watchdog.reset(capturedFrames: 20, sentFrames: 20)
        for _ in 0..<10 {
            XCTAssertEqual(
                watchdog.observe(
                    TBVideoPipelineProgressSnapshot(
                        capturedFrames: 20,
                        sentFrames: 20,
                        monitorsDPCMProgress: true,
                        terminalEncoderHealth: false
                    ),
                    hasDeliveredFirstFrame: true
                ),
                .none
            )
        }
    }

    func testDPCMProgressWatchdogAcceptsBackpressureAndFramePacingWithProgress() {
        var watchdog = TBPostFirstFrameProgressWatchdog()
        watchdog.reset(capturedFrames: 1, sentFrames: 1)

        // One active poll without a send is ordinary bounded backpressure.
        XCTAssertEqual(
            watchdog.observe(
                TBVideoPipelineProgressSnapshot(
                    capturedFrames: 8,
                    sentFrames: 1,
                    monitorsDPCMProgress: true,
                    terminalEncoderHealth: false
                ),
                hasDeliveredFirstFrame: true
            ),
            .none
        )
        // Any sent progress clears that evidence, even when pacing drops many
        // of the captured frames.
        XCTAssertEqual(
            watchdog.observe(
                TBVideoPipelineProgressSnapshot(
                    capturedFrames: 14,
                    sentFrames: 2,
                    monitorsDPCMProgress: true,
                    terminalEncoderHealth: false
                ),
                hasDeliveredFirstFrame: true
            ),
            .none
        )
        XCTAssertEqual(
            watchdog.observe(
                TBVideoPipelineProgressSnapshot(
                    capturedFrames: 90,
                    sentFrames: 62,
                    monitorsDPCMProgress: true,
                    terminalEncoderHealth: false
                ),
                hasDeliveredFirstFrame: true
            ),
            .none
        )
    }

    func testDPCMProgressWatchdogTerminalHealthIsImmediateAndOneShot() {
        var watchdog = TBPostFirstFrameProgressWatchdog()
        watchdog.reset(capturedFrames: 1, sentFrames: 1)
        let terminal = TBVideoPipelineProgressSnapshot(
            capturedFrames: 1,
            sentFrames: 1,
            monitorsDPCMProgress: true,
            terminalEncoderHealth: true
        )
        XCTAssertEqual(
            watchdog.observe(terminal, hasDeliveredFirstFrame: true),
            .terminatePoisonedProcess
        )
        XCTAssertEqual(
            watchdog.observe(terminal, hasDeliveredFirstFrame: true),
            .none
        )
    }

    func testSenderEnabledFlagUsesSelectedHomeDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("targetbridge-automation-path-test", isDirectory: true)
        XCTAssertEqual(
            TBSenderAutomation.senderEnabledFlagURL(homeDirectory: root).path,
            root.appendingPathComponent(
                "Library/Application Support/TargetBridge/Sender/enabled",
                isDirectory: false
            ).path
        )
    }

    func testUserStopRemovesAutomaticReconnectMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("targetbridge-user-stop-\(UUID().uuidString)", isDirectory: true)
        let marker = root.appendingPathComponent("enabled")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: Data()))

        TBSenderAutomation.suspendAutomaticReconnectAfterUserStop(enabledFlagURL: marker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try? FileManager.default.removeItem(at: root)
    }

    func testRequiredPermissionRemovesAutomaticReconnectMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("targetbridge-permission-stop-\(UUID().uuidString)", isDirectory: true)
        let marker = root.appendingPathComponent("enabled")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: Data()))

        TBSenderAutomation.suspendAutomaticReconnectForRequiredPermission(enabledFlagURL: marker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        try? FileManager.default.removeItem(at: root)
    }

    func testTransientCaptureFailurePreservesAutomaticReconnectMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("targetbridge-capture-stop-\(UUID().uuidString)", isDirectory: true)
        let marker = root.appendingPathComponent("enabled")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: marker.path, contents: Data()))

        TBSenderAutomation.preserveAutomaticReconnectAfterTransientCaptureFailure(
            enabledFlagURL: marker
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try? FileManager.default.removeItem(at: root)
    }

    func testAutomaticReconnectRetryBackoffIsBounded() {
        XCTAssertEqual(TBSenderAutomation.automaticReconnectRetryDelaySeconds(consecutiveFailures: -1), 2)
        XCTAssertEqual(TBSenderAutomation.automaticReconnectRetryDelaySeconds(consecutiveFailures: 0), 2)
        XCTAssertEqual(TBSenderAutomation.automaticReconnectRetryDelaySeconds(consecutiveFailures: 1), 2)
        XCTAssertEqual(TBSenderAutomation.automaticReconnectRetryDelaySeconds(consecutiveFailures: 2), 4)
        XCTAssertEqual(TBSenderAutomation.automaticReconnectRetryDelaySeconds(consecutiveFailures: 3), 8)
        XCTAssertEqual(TBSenderAutomation.automaticReconnectRetryDelaySeconds(consecutiveFailures: 4), 15)
        XCTAssertEqual(TBSenderAutomation.automaticReconnectRetryDelaySeconds(consecutiveFailures: Int.max), 15)
    }

    func testAutomationFlagsEnableOnPresenceOrTruthyValues() {
        for value in ["", "1", "true", "yes", "on", "unexpected"] {
            XCTAssertTrue(TBSenderAutomation.flagEnabled(value), "value \(value)")
        }
    }

    func testAutomationFlagsDisableOnMissingOrExplicitFalseValues() {
        XCTAssertFalse(TBSenderAutomation.flagEnabled(nil))
        for value in ["0", "false", "FALSE", "no", "off", " Off "] {
            XCTAssertFalse(TBSenderAutomation.flagEnabled(value), "value \(value)")
        }
    }

    func testContinuousConnectStartsRetryLoopOnlyWithScreenCapturePermission() {
        XCTAssertEqual(
            TBSenderAutomation.continuousConnectPermissionAction(screenCaptureGranted: true),
            .startRetryLoop
        )
        XCTAssertEqual(
            TBSenderAutomation.continuousConnectPermissionAction(screenCaptureGranted: false),
            .requestOnceAndSuspend
        )
    }

    func testMonitorModeLaunchRequiresPersistedEnabledMarker() {
        XCTAssertTrue(TBSenderAutomation.monitorModeLaunchAllowed(enabledMarkerExists: true))
        XCTAssertFalse(TBSenderAutomation.monitorModeLaunchAllowed(enabledMarkerExists: false))
    }

    func testPinnedConnectionPathsDoNotRunThroughputProbeOnEveryReconnect() {
        for preference in [
            TBConnectionPathPreference.thunderbolt,
            .usb,
            .ethernet,
            .wifi,
        ] {
            XCTAssertFalse(
                TBSenderAutomation.requiresComparativePathProbe(preference),
                "pinned \(preference.rawValue) path"
            )
        }
    }

    func testComparativeConnectionPathsStillMeasureCandidates() {
        XCTAssertTrue(
            TBSenderAutomation.requiresComparativePathProbe(.automatic)
        )
        XCTAssertTrue(
            TBSenderAutomation.requiresComparativePathProbe(.wired)
        )
    }

    func testAutomationAudioOmissionPreservesSessionSetting() {
        XCTAssertNil(TBSenderAutomation.parseAudioEnabled(nil))
    }

    func testAutomationAudioExplicitFalseDisablesAudio() {
        for value in ["0", "false", "FALSE", "no", "off", " Off "] {
            XCTAssertEqual(TBSenderAutomation.parseAudioEnabled(value), false, "value \(value)")
        }
    }

    func testAutomationAudioTruthyValuesEnableAudio() {
        for value in ["1", "true", "TRUE", "yes", "on", " On "] {
            XCTAssertEqual(TBSenderAutomation.parseAudioEnabled(value), true, "value \(value)")
        }
    }

    func testAutomationAudioInvalidValuesPreserveSessionSetting() {
        for value in ["", "unexpected", "2"] {
            XCTAssertNil(TBSenderAutomation.parseAudioEnabled(value), "value \(value)")
        }
    }

    // MARK: - parseTransport

    func testParseTransportNetworkAliases() {
        for alias in ["net", "network", "networklink", "link", "NET", "NetworkLink"] {
            XCTAssertEqual(TBSenderAutomation.parseTransport(alias), .networkLink, "alias \(alias)")
        }
    }

    /// Documents the current permissive behavior: anything that is not a
    /// network alias — including typos — selects Thunderbolt Bridge.
    func testParseTransportDefaultsToThunderbolt() {
        for value in ["tb", "thunderbolt", "", "bogus", "TB"] {
            XCTAssertEqual(TBSenderAutomation.parseTransport(value), .thunderboltBridge, "value \(value)")
        }
    }

    // MARK: - parseMode

    func testParseModeExtendedAliases() {
        for alias in ["extended", "extend", "extendeddesktop", "ext", "EXTENDED"] {
            XCTAssertEqual(TBSenderAutomation.parseMode(alias), .extendedDesktop, "alias \(alias)")
        }
    }

    func testParseModeMirrorAliases() {
        for alias in ["mirror", "mirrored", "desktopmirror", "Mirror"] {
            XCTAssertEqual(TBSenderAutomation.parseMode(alias), .desktopMirror, "alias \(alias)")
        }
    }

    func testParseModeAcceptsExactRawValues() {
        XCTAssertEqual(TBSenderAutomation.parseMode("extendedDesktop"), .extendedDesktop)
        XCTAssertEqual(TBSenderAutomation.parseMode("desktopMirror"), .desktopMirror)
    }

    func testParseModeRejectsUnknown() {
        XCTAssertNil(TBSenderAutomation.parseMode("bogus"))
        XCTAssertNil(TBSenderAutomation.parseMode(""))
    }

    // MARK: - parsePreset

    func testParsePresetAcceptsExactRawValues() {
        XCTAssertEqual(TBSenderAutomation.parsePreset("standard1440p"), .standard1440p)
        XCTAssertEqual(TBSenderAutomation.parsePreset("smooth1440p60"), .smooth1440p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("smooth1800p60"), .smooth1800p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("crisp2160p60"), .crisp2160p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("retina4k60"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("native5k"), .native5k)
        XCTAssertEqual(TBSenderAutomation.parsePreset("native5k60Experimental"), .native5k60Experimental)
    }

    func testParsePresetAliases() {
        XCTAssertEqual(TBSenderAutomation.parsePreset("1440p"), .standard1440p)
        XCTAssertEqual(TBSenderAutomation.parsePreset("standard"), .standard1440p)
        XCTAssertEqual(TBSenderAutomation.parsePreset("1440p60"), .smooth1440p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("smooth"), .smooth1440p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("1800p"), .smooth1800p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("4k"), .crisp2160p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("crisp"), .crisp2160p60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("retina4k"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("RETINA4K60"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("4096x2304"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("imac4k"), .retina4k60)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5k60"), .native5k60Experimental)
        XCTAssertEqual(TBSenderAutomation.parsePreset("native5k60"), .native5k60Experimental)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5kraw60"), .native5k60Experimental)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5k"), .native5k)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5K"), .native5k, "aliases are case-insensitive")
        XCTAssertEqual(TBSenderAutomation.parsePreset("native"), .native5k)
        XCTAssertEqual(TBSenderAutomation.parsePreset("5120x2880"), .native5k)
    }

    func testParsePresetRejectsUnknown() {
        XCTAssertNil(TBSenderAutomation.parsePreset("bogus"))
        XCTAssertNil(TBSenderAutomation.parsePreset(""))
        // Raw values are case-sensitive and "native5k" has no capitalized alias.
        XCTAssertNil(TBSenderAutomation.parsePreset("NATIVE5K"))
    }

    func testExperimental5K60UsesIndependent60FPSHEVCSettings() {
        let preset = TBDisplayCapturePreset.native5k60Experimental

        XCTAssertEqual(preset.width, 5120)
        XCTAssertEqual(preset.height, 2880)
        XCTAssertEqual(preset.expectedFrameRate, 60)
        XCTAssertEqual(preset.virtualDisplayRefreshRate, 60)
        XCTAssertEqual(preset.codecName, "HEVC")
        XCTAssertEqual(preset.averageBitRate, 150_000_000)
    }

    func testRetina4KPresetMatches215InchIMacPanel() {
        let preset = TBDisplayCapturePreset.retina4k60

        XCTAssertEqual(preset.width, 4096)
        XCTAssertEqual(preset.height, 2304)
        XCTAssertEqual(preset.expectedFrameRate, 60)
        XCTAssertEqual(preset.virtualDisplayRefreshRate, 60)
        XCTAssertEqual(preset.averageBitRate, 120_000_000)
        XCTAssertEqual(preset.codecName, "HEVC")
        XCTAssertEqual(preset.renderMatchedDesktopDescription, "2048 × 1152")
    }

    // MARK: - matches (receiver selection for --receiver <value>)

    private func makeReceiver() -> TBDiscoveredReceiver {
        TBDiscoveredReceiver(
            serviceName: "TargetBridge Jonathans-iMac",
            receiverName: "Jonathans-iMac",
            preferredIP: "192.168.1.64",
            thunderboltIP: "169.254.89.80",
            usbIP: "169.254.189.3",
            networkIP: "192.168.1.64",
            ethernetIP: "10.77.77.2",
            wifiIP: "192.168.1.64",
            resolvedIPv4Addresses: ["172.20.10.2"],
            panelSummary: "iMac 5K",
            version: "3.1.0",
            supportsHEVCDecode: true,
            hostName: "Jonathans-iMac.local."
        )
    }

    func testMatchesByName() {
        XCTAssertTrue(TBSenderAutomation.matches("Jonathans-iMac", makeReceiver()))
        XCTAssertTrue(TBSenderAutomation.matches("jonathans-imac", makeReceiver()), "name match is case-insensitive")
    }

    func testMatchesByShortHostName() {
        XCTAssertTrue(TBSenderAutomation.matches("jonathans-imac", makeReceiver()))
    }

    func testMatchesByAnyAdvertisedIP() {
        XCTAssertTrue(TBSenderAutomation.matches("192.168.1.64", makeReceiver()), "preferred/network IP")
        XCTAssertTrue(TBSenderAutomation.matches("169.254.89.80", makeReceiver()), "thunderbolt IP")
        XCTAssertTrue(TBSenderAutomation.matches("169.254.189.3", makeReceiver()), "direct USB IP")
        XCTAssertTrue(TBSenderAutomation.matches("10.77.77.2", makeReceiver()), "Ethernet IP")
        XCTAssertTrue(TBSenderAutomation.matches("172.20.10.2", makeReceiver()), "resolved Bonjour IP")
    }

    func testMatchesByID() {
        XCTAssertTrue(TBSenderAutomation.matches("targetbridge jonathans-imac|192.168.1.64", makeReceiver()))
    }

    func testDoesNotMatchUnrelatedValue() {
        XCTAssertFalse(TBSenderAutomation.matches("other-mac", makeReceiver()))
        XCTAssertFalse(TBSenderAutomation.matches("10.0.0.1", makeReceiver()))
    }

    // MARK: - resolveSessionIndex tri-state
    //
    // Returns `nil` = invalid input, `.some(nil)` = target all sessions,
    // `.some(index)` = zero-based session index.

    func testNoSessionParamTargetsAllSessionsWhenNotCreating() {
        let result: Int?? = TBSenderAutomation.resolveSessionIndex(nil, sessionCount: 3, createDefaultIfNeeded: false)
        XCTAssertEqual(result, Int??.some(.none), "absent session + no-create should mean 'all sessions'")
    }

    func testNoSessionParamDefaultsToFirstSessionWhenCreating() {
        XCTAssertEqual(
            TBSenderAutomation.resolveSessionIndex(nil, sessionCount: 0, createDefaultIfNeeded: true),
            Int??.some(0)
        )
        XCTAssertEqual(
            TBSenderAutomation.resolveSessionIndex(nil, sessionCount: 3, createDefaultIfNeeded: true),
            Int??.some(0)
        )
    }

    func testEmptySessionParamBehavesLikeAbsent() {
        XCTAssertEqual(
            TBSenderAutomation.resolveSessionIndex("", sessionCount: 2, createDefaultIfNeeded: false),
            Int??.some(.none)
        )
    }

    func testOneBasedIndexIsConvertedToZeroBased() {
        XCTAssertEqual(
            TBSenderAutomation.resolveSessionIndex("2", sessionCount: 3, createDefaultIfNeeded: false),
            Int??.some(1)
        )
    }

    func testOutOfRangeSessionIsInvalid() {
        XCTAssertNil(TBSenderAutomation.resolveSessionIndex("4", sessionCount: 3, createDefaultIfNeeded: false))
    }

    func testSessionOneOnEmptyListCreatesDefaultOnlyWhenAllowed() {
        XCTAssertEqual(
            TBSenderAutomation.resolveSessionIndex("1", sessionCount: 0, createDefaultIfNeeded: true),
            Int??.some(0)
        )
        XCTAssertNil(TBSenderAutomation.resolveSessionIndex("1", sessionCount: 0, createDefaultIfNeeded: false))
    }

    func testNonNumericAndNonPositiveSessionsAreInvalid() {
        XCTAssertNil(TBSenderAutomation.resolveSessionIndex("abc", sessionCount: 3, createDefaultIfNeeded: true))
        XCTAssertNil(TBSenderAutomation.resolveSessionIndex("0", sessionCount: 3, createDefaultIfNeeded: true))
        XCTAssertNil(TBSenderAutomation.resolveSessionIndex("-1", sessionCount: 3, createDefaultIfNeeded: true))
    }
}
