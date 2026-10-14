import Foundation
import UIKit

/// The one switch the SDK flips to keep the screen awake: `UIApplication.isIdleTimerDisabled`. A seam
/// so tests can drive ``ScreenAwake`` without a host app.
@_spi(VeyraInternal)
public protocol IdleTimerSwitch: AnyObject {
    /// Nil when there is no application to ask: an app extension, or a test bundle with no host app.
    /// The SDK then leaves the screen alone rather than touching an application that is not there.
    var isIdleTimerDisabled: Bool? { get set }
}

/// Keeps the iPhone screen awake while a card can be tapped — the iOS twin of Android's
/// `FLAG_KEEP_SCREEN_ON` hold. A screen that turns off ends the CoreNFC reader session, so a merchant
/// waiting on a customer must not watch it dim mid-payment.
///
/// `isIdleTimerDisabled` is one app-wide flag, not a per-screen one, so this is written to share it
/// politely:
/// - **Counted.** Every hold is matched by one release; the screen may sleep again only when the last
///   hold goes, so two overlapping taps never release each other's.
/// - **Never the app's setting.** If the idle timer was already off when the first hold arrived (the
///   app keeps its own screen on), the SDK neither changes it nor turns it back on. It only restores
///   what it changed. An app that turns the idle timer off *during* a tap cannot be told apart from
///   the SDK's own setting, so an app that manages it should do so before starting a tap.
/// - **In order, on the main thread.** UIKit requires the main thread, and every hold and release is
///   queued onto it (`DispatchQueue.main.async`) from whatever thread made it — a tap starts on the
///   main thread and ends on a Kotlin one. Queuing even main-thread calls keeps them in the order they
///   were made: a release that ran immediately could otherwise overtake a hold still in the queue and
///   leave the screen held for good. Nothing ever waits on the main thread synchronously, so a caller
///   holding a lock cannot deadlock against it.
@_spi(VeyraInternal)
public final class ScreenAwake: @unchecked Sendable {

    public static let shared = ScreenAwake(idleTimer: ApplicationIdleTimer())

    private let idleTimer: IdleTimerSwitch
    private var holds = 0
    private var disabledBySdk = false

    public init(idleTimer: IdleTimerSwitch) {
        self.idleTimer = idleTimer
    }

    /// Whether the SDK currently holds the screen awake. Read on the main thread.
    public var isHolding: Bool { holds > 0 }

    public func hold() {
        onMain { [self] in
            holds += 1
            guard holds == 1, idleTimer.isIdleTimerDisabled == false else { return }
            idleTimer.isIdleTimerDisabled = true
            disabledBySdk = true
        }
    }

    public func release() {
        onMain { [self] in
            guard holds > 0 else { return }
            holds -= 1
            guard holds == 0, disabledBySdk else { return }
            disabledBySdk = false
            idleTimer.isIdleTimerDisabled = false
        }
    }

    private func onMain(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }
}

/// Production ``IdleTimerSwitch``: the running application's idle timer, when there is one.
final class ApplicationIdleTimer: IdleTimerSwitch {
    private var application: UIApplication? {
        // `UIApplication.shared` traps where no application exists (an extension, a hostless test
        // bundle). Only an app bundle has one.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UIApplication.shared
    }

    var isIdleTimerDisabled: Bool? {
        get { application?.isIdleTimerDisabled }
        set { if let newValue { application?.isIdleTimerDisabled = newValue } }
    }
}

/// One tap's share of ``ScreenAwake``: held once, released at most once — on the tap's end, or when
/// the session object goes away without ending.
@_spi(VeyraInternal)
public final class ScreenAwakeToken: @unchecked Sendable {
    private let screen: ScreenAwake
    private let lock = NSLock()
    private var held = false

    public init(_ screen: ScreenAwake = .shared) {
        self.screen = screen
    }

    public func hold() {
        lock.lock(); defer { lock.unlock() }
        guard !held else { return }
        held = true
        screen.hold()
    }

    public func release() {
        lock.lock(); defer { lock.unlock() }
        guard held else { return }
        held = false
        screen.release()
    }

    deinit { release() }
}
