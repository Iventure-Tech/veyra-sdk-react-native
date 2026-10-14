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
// VeyraSdk.initialize(activity, customerId, config, provider); sdk.currentMode()
// ↔ VeyraSDK.configure(customerID:config:provider:); VeyraSDK.shared.currentMode()
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

/// The two member SDKs' settings for `VeyraSDK.configure(customerID:config:provider:)` — mirrors
/// Android's `VeyraSdkConfig(softpos, wallet)` and RN's `{ softpos, wallet }`.
public struct VeyraSDKConfiguration: Sendable {
    public let softpos: VeyraSoftPOSConfiguration
    public let wallet: VeyraWalletConfiguration

    public init(softpos: VeyraSoftPOSConfiguration, wallet: VeyraWalletConfiguration) {
        self.softpos = softpos
        self.wallet = wallet
    }
}

/// Entry point of the combined Veyra SDK on iOS (SoftPOS + Wallet + exclusive mode).
///
/// The exclusive mode is SDK-managed — configure once at launch and use the two member SDKs;
/// the mode follows your payment activity by itself. `currentMode()` is observe-only.
///
/// ```swift
/// let sdk = try VeyraSDK.configure(
///     customerID: signedInCustomer,
///     config: VeyraSDKConfiguration(softpos: softposConfig, wallet: walletConfig),
///     provider: provider
/// )
/// let wallet = try sdk.wallet
/// let softpos = try sdk.softpos
/// ```
public final class VeyraSDK: @unchecked Sendable {

    public static let shared = VeyraSDK()

    private let lock = NSLock()
    private var configured = false

    private init() {}

    /// Configure the combined SDK for the customer your app has signed in: both member SDKs
    /// plus the exclusive-mode arbiter. Call at every launch — the SDKs never remember who is
    /// signed in. The process starts **inert** (`.none`); safe to call again (reconfigures,
    /// stays inert). A different customer stops the previous customer's work in both SDKs.
    ///
    /// - Parameters:
    ///   - customerID: The customer your app has authenticated. The wallet sends it to Veyra on
    ///     its card requests (add card, eligibility, activation) so support can find them;
    ///     SoftPOS never sends it. Device logs only ever show it masked.
    ///   - config: Both member SDKs' settings.
    ///   - provider: How both SDKs reach Veyra — one provider shared by wallet and SoftPOS: your
    ///     `VeyraAssertionProvider` or `VeyraProxyProvider`.
    /// - Returns: `VeyraSDK.shared`.
    /// - Throws: the member SDK's `invalidConfiguration` when the provider cannot be used.
    @discardableResult
    public static func configure(
        customerID: String,
        config: VeyraSDKConfiguration,
        provider: any VeyraProvider
    ) throws -> VeyraSDK {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        try VeyraSoftPOS.configure(customerID: customerID, config: config.softpos, provider: provider)
        try VeyraWallet.configure(customerID: customerID, config: config.wallet, provider: provider)
        VeyraSdkKmp.shared.configure()
        shared.installBackgroundInertGuard()
        shared.configured = true
        return shared
    }

    /// The customer has logged out: both member SDKs stop everything they run for them and drop
    /// every observer registration. Their cards, merchant and history stay on the device for when
    /// they sign in again.
    public static func signOut() {
        CustomerSession.shared.signOut()
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
        guard configured else { throw VeyraError.notConfigured }
    }

    /// The wallet SDK this combined SDK configured — `VeyraWallet.shared`.
    /// - Throws: `VeyraError.notConfigured` before `configure(customerID:config:provider:)`.
    public var wallet: VeyraWallet {
        get throws {
            try requireConfigured()
            return VeyraWallet.shared
        }
    }

    /// The SoftPOS SDK this combined SDK configured — `VeyraSoftPOS.shared`.
    /// - Throws: `VeyraError.notConfigured` before `configure(customerID:config:provider:)`.
    public var softpos: VeyraSoftPOS {
        get throws {
            try requireConfigured()
            return VeyraSoftPOS.shared
        }
    }

    /// The app's current exclusive mode.
    /// - Throws: `VeyraError.notConfigured` before `configure(customerID:config:provider:)`.
    public func currentMode() throws -> VeyraMode {
        try requireConfigured()
        return VeyraMode(rawValue: VeyraSdkKmp.shared.currentMode()) ?? .none
    }

}
