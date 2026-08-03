// VeyraSDK — public iOS API of the combined Veyra SDK.
//
// Pure-Swift facade over the VeyraKMP umbrella framework. Mirrors Android's `VeyraSdk`
// facade: a combined SoftPOS+Wallet app configures BOTH SDKs through this entry point,
// which also owns the app's **exclusive mode** — the same shared state machine that
// Android's mode handling delegates to:
//
// - the process starts (and re-configures to) **inert `.none`** — never live at launch, even
// after being killed in Pay;
// - the mode is **SDK-managed**: claimed at the point of use (tap-session start,
// wallet payment execution), released at session end / payment completion, and dropped to
// `.none` when the app backgrounds — the host app never calls a mode API, it may only
// observe `currentMode`;
// - a payment genuinely mid-flight keeps its mode (switches/releases defer until it finishes);
// - iOS has no HCE (Apple platform lock); CoreNFC reader arming consults the same arbiter.
//
// Android ↔ iOS name mapping (excerpt; full table in the package README):
// VeyraSdk.initialize(activity, config); sdk.currentMode()
// ↔ VeyraSDK.configure(...); VeyraSDK.shared.currentMode
import Foundation
#if canImport(UIKit)
import UIKit
#endif
import VeyraKMP

/// The exclusive operating mode of a combined Veyra app (mirrors Android's `NfcMode`).
public enum VeyraMode: String, Sendable {
    /// No payment capability active. Safe idle default.
    case none = "NONE"
    /// Accepting payments (Get paid).
    case softpos = "SOFTPOS"
    /// Making payments (Pay).
    case wallet = "WALLET"
}

/// Errors thrown by the combined Veyra SDK.
public enum VeyraSDKError: Error, Sendable {
    /// `VeyraSDK.configure(_:)` has not been called.
    case notConfigured
}

/// Entry point of the combined Veyra SDK on iOS (SoftPOS + Wallet + exclusive mode).
///
/// The exclusive mode is SDK-managed — configure once at launch and use the two member SDKs;
/// the mode follows your payment activity by itself. `currentMode` is observe-only.
///
/// ```swift
/// VeyraSDK.configure(softpos: softposConfig, wallet: walletConfig)
/// ```
public final class VeyraSDK: @unchecked Sendable {

    public static let shared = VeyraSDK()

    private let lock = NSLock()
    private var configured = false

    private init() {}

    /// Configure the combined SDK: both member SDKs plus the exclusive-mode arbiter.
    /// The process starts **inert** (`.none`); safe to call again (reconfigures, stays inert).
    public static func configure(
        softpos: VeyraSoftPOSConfiguration,
        wallet: VeyraWalletConfiguration
    ) {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        VeyraSoftPOS.configure(softpos)
        VeyraWallet.configure(wallet)
        VeyraSdkKmp.shared.configure()
        shared.installBackgroundInertGuard()
        shared.configured = true
    }

    private var backgroundObserver: NSObjectProtocol?

    /// SDK-owned inertness on backgrounding (the iOS analogue of the Android inert backstop):
    /// whichever mode is held is released best-effort when the app leaves the foreground — a
    /// payment genuinely mid-flight keeps its mode until it finishes. Idempotent across
    /// reconfigures. Must be called with `lock` held.
    private func installBackgroundInertGuard() {
        #if canImport(UIKit)
        if let existing = backgroundObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            VeyraSdkKmp.shared.dropToInert()
        }
        #endif
    }

    private func requireConfigured() throws {
        lock.lock()
        defer { lock.unlock() }
        guard configured else { throw VeyraSDKError.notConfigured }
    }

    /// The app's current exclusive mode.
    public var currentMode: VeyraMode {
        lock.lock()
        defer { lock.unlock() }
        guard configured else { return .none }
        return VeyraMode(rawValue: VeyraSdkKmp.shared.currentMode()) ?? .none
    }

}
