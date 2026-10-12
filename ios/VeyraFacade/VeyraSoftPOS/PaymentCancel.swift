// Cancelling a SoftPOS payment by its merchant order ID.
//
// Kept in its own file, without `import VeyraKMP`: the shared core exports a type of the same name,
// and a file that imports both cannot name `CancelResult` unqualified.
import Foundation

extension VeyraSoftPOS.Payments {
    /// Cancel the payment you started with `merchantOrderID` — a card tap
    /// (``Tap/session(amountMinorUnits:currencyCode:merchantOrderID:onEvent:)``), a customer-QR
    /// charge (``chargeCustomerQr(_:merchantOrderID:)``) or a payment-QR create
    /// (``createContext(merchantID:amountMinorUnits:currency:onExpired:merchantOrderID:)``). You
    /// don't say which: the order ID names the payment.
    ///
    /// A payment can be cancelled only while its request is still on this device:
    /// - ``CancelResult/cancelled`` — nothing was sent. The payment itself ends `NOT_SENT` /
    ///   `CANCELLED` (a tap through its `.result` event, a charge or create as its returned
    ///   outcome). Go back to the previous screen; the same order ID can be used again.
    /// - ``CancelResult/tooLateToCancelRequestAlreadySent`` — the request has gone to the bank.
    ///   The payment carries on and delivers its normal result: show "This can no longer be
    ///   cancelled" and keep waiting for it.
    /// - ``CancelResult/noPaymentInProgressForOrderID`` — no payment with that order ID is armed
    ///   or running here (wrong ID, never started, or already finished). Nothing changes.
    ///
    /// A card tap can still be cancelled after the card has been read, up to the moment the
    /// request is sent; the card's data is then discarded and never sent later.
    ///
    /// Answers at once and never throws. Cancelling the Swift `Task` that awaits a charge or a
    /// create does the same, without an answer.
    @discardableResult
    public func cancelPayment(merchantOrderID: String) -> CancelResult {
        CancelRegistry.softposPayment(merchantOrderID: merchantOrderID)
    }
}
