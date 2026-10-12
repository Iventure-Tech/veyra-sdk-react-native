// VeyraCommon — the answer to a cancel request, shared by both SDKs on iOS.
//

import Foundation
import VeyraKMP

/// The answer to a cancel request. It is the reply to the **cancel**, never the cancelled call's
/// status: the call itself still ends with its own outcome.
///
/// Every cancel names the call by a reference your app already holds: a payment by its merchant
/// order ID, an add-card (digitisation) by its client request ID. A call can be cancelled only
/// while its request is still on the device; once it has been sent, the payment or card may be
/// processed whatever the phone does next, so the cancel is refused and the call delivers its
/// normal result.
///
/// | Answer | What happened | What to show |
/// |---|---|---|
/// | `CANCELLED` | Nothing was sent. The call ends `NOT_SENT` / `CANCELLED`. | Go back to the previous screen; the same reference can be used again. |
/// | `TOO_LATE_TO_CANCEL_REQUEST_ALREADY_SENT` | The request has left the device. | "This can no longer be cancelled" — keep waiting for the call's result. |
/// | `TOO_LATE_TO_CANCEL_TASK_ALREADY_PROCESSED` | The call had already finished. | The result already delivered. |
/// | `NO_PAYMENT_IN_PROGRESS_FOR_ORDER_ID` | No payment with that order ID is running. | Nothing was in progress. |
/// | `NO_DIGITISATION_IN_PROGRESS_FOR_CLIENT_REQUEST_ID` | No add-card with that client request ID is running. | Nothing was in progress. |
public enum CancelResult: String, Sendable, CaseIterable {
    /// Cancelled before anything was sent. The call ends `NOT_SENT` / `CANCELLED`; nothing was
    /// done, and the same reference can be used again.
    case cancelled = "CANCELLED"
    /// Too late: the request has already left the device. The call carries on and delivers its
    /// normal result. Tell the user it can no longer be cancelled and keep waiting.
    case tooLateToCancelRequestAlreadySent = "TOO_LATE_TO_CANCEL_REQUEST_ALREADY_SENT"
    /// Too late: the call had already finished and delivered its result. Nothing changes.
    case tooLateToCancelTaskAlreadyProcessed = "TOO_LATE_TO_CANCEL_TASK_ALREADY_PROCESSED"
    /// No payment with that merchant order ID is armed or running on this device — the ID is
    /// wrong, the payment was never started, or it ended before the cancel arrived. Nothing changes.
    case noPaymentInProgressForOrderID = "NO_PAYMENT_IN_PROGRESS_FOR_ORDER_ID"
    /// No add-card with that client request ID is running on this device — the ID is wrong, the
    /// add-card was started without one, or it ended before the cancel arrived. Nothing changes.
    case noDigitisationInProgressForClientRequestID = "NO_DIGITISATION_IN_PROGRESS_FOR_CLIENT_REQUEST_ID"

    /// Maps the shared core's answer by its wire name. A name this build does not know reads as
    /// `tooLateToCancelRequestAlreadySent` — "keep waiting for the result" is the one answer that
    /// can never make an app abandon a call that might still complete.
    @_spi(VeyraInternal)
    public init(kmp: VeyraKMP.CancelResult) {
        self.init(wire: kmp.name)
    }

    @_spi(VeyraInternal)
    public init(wire: String) {
        self = CancelResult(rawValue: wire) ?? .tooLateToCancelRequestAlreadySent
    }
}

/// Cancels by reference in the shared core's registries. SDK plumbing, not developer API: the
/// facades' public cancels call these. The registries, not a configured instance, so a call that is
/// running stays cancellable even while the SDK is reconfigured or the customer switched.
@_spi(VeyraInternal)
public enum CancelRegistry {
    /// SoftPOS: card tap, customer-QR charge, payment-QR create — by merchant order ID.
    public static func softposPayment(merchantOrderID: String) -> CancelResult {
        CancelResult(kmp: CancellableCalls.companion.softposPayments.cancel(reference: merchantOrderID))
    }

    /// Wallet: scan-to-pay — by the merchant order ID in the scanned QR.
    public static func walletPayment(merchantOrderID: String) -> CancelResult {
        CancelResult(kmp: CancellableCalls.companion.walletPayments.cancel(reference: merchantOrderID))
    }

    /// Wallet: add-card — by client request ID.
    public static func digitisation(clientRequestID: String) -> CancelResult {
        CancelResult(kmp: CancellableCalls.companion.digitisations.cancel(reference: clientRequestID))
    }
}

/// Honours Swift `Task` cancellation for a call the shared core can cancel by reference.
/// SDK plumbing, not developer API.
///
/// A Kotlin suspend call does not see the Swift `Task` it was awaited from, so a `Task` cancel
/// is forwarded as a cancel by the call's reference. The core registers the reference when the
/// call starts; a `Task` cancelled in the instant before that would find nothing, so the cancel
/// is repeated briefly until the call is found or has returned. Before the request is sent the
/// call then ends `NOT_SENT` / `CANCELLED`; after it, the cancel is refused and the call returns
/// its normal result.
@_spi(VeyraInternal)
public enum TaskCancelBridge {

    /// How long a `Task` cancel keeps looking for a call that has not registered yet.
    static let registrationWait: TimeInterval = 2.0
    static let retryInterval: TimeInterval = 0.01

    /// Run `body`; if the surrounding `Task` is cancelled while it runs, call `cancel` (which
    /// cancels the call by its reference). `notFound` is `cancel`'s answer for a reference with
    /// no call registered.
    public static func run<T>(
        cancel: @escaping @Sendable () -> CancelResult,
        notFound: CancelResult,
        _ body: () async throws -> T
    ) async throws -> T {
        let state = CallState()
        return try await withTaskCancellationHandler {
            defer { state.finish() }
            return try await body()
        } onCancel: {
            forward(cancel: cancel, notFound: notFound, state: state)
        }
    }

    /// Cancel until the call answers something other than "not found", or it has returned.
    static func forward(cancel: @escaping @Sendable () -> CancelResult, notFound: CancelResult, state: CallState) {
        if state.isFinished || cancel() != notFound { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(registrationWait)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: retryInterval)
                if state.isFinished || cancel() != notFound { return }
            }
        }
    }

    /// Whether the call has returned.
    final class CallState: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false

        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return finished
        }

        func finish() {
            lock.lock(); finished = true; lock.unlock()
        }
    }
}
