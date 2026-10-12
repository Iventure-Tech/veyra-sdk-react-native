// Cancelling an add-card by its client request ID, and a scan-to-pay by its merchant order ID.
//
// Kept in its own file, without `import VeyraKMP`: the shared core exports a type of the same name,
// and a file that imports both cannot name `CancelResult` unqualified.
import Foundation

extension VeyraWallet.Tokenisation {
    /// Cancel the add-card you started with `clientRequestID`
    /// (``digitise(accountNumber:institutionCode:walletAccountID:accountHolderName:emailAddress:recommendation:mobileNumber:bvn:accountHolderAddress:accountNumberSource:consumerIdentifier:deviceScore:accountScore:recommendationReasons:bankName:clientRequestID:)``).
    ///
    /// - ``CancelResult/cancelled`` — nothing was sent; `digitise` returns `NOT_SENT` /
    ///   `CANCELLED`. Go back to the previous screen; the card can be added again.
    /// - ``CancelResult/tooLateToCancelRequestAlreadySent`` — the request has been sent. The
    ///   add-card carries on and returns its normal result: show "This can no longer be
    ///   cancelled" and keep waiting for it.
    /// - ``CancelResult/noDigitisationInProgressForClientRequestID`` — no add-card with that ID
    ///   is running (wrong ID, started without one, or already finished). Nothing changes.
    ///
    /// Answers at once and never throws.
    @discardableResult
    public func cancelDigitise(clientRequestID: String) -> CancelResult {
        CancelRegistry.digitisation(clientRequestID: clientRequestID)
    }

    /// Cancel the scan-to-pay of the QR whose order ID is `merchantOrderID`
    /// (``VerifiedPayment/merchantOrderID``, passed to ``payScannedContext(_:)``).
    ///
    /// - ``CancelResult/cancelled`` — nothing was sent; `payScannedContext` returns `NOT_SENT` /
    ///   `CANCELLED`. Go back to the previous screen; the same QR can be paid again.
    /// - ``CancelResult/tooLateToCancelRequestAlreadySent`` — the payment has been sent. It
    ///   carries on and returns its normal result: show "This can no longer be cancelled" and
    ///   keep waiting for it.
    /// - ``CancelResult/noPaymentInProgressForOrderID`` — no scan-to-pay with that order ID is
    ///   running (wrong ID, never started, already finished, or a QR that carries no order ID).
    ///   Nothing changes.
    ///
    /// Answers at once and never throws. This cancels only this wallet's own payment, never a
    /// merchant payment with the same order ID in the same app. Show-QR-to-pay has nothing to
    /// cancel here: the wallet sends nothing; the merchant's charge is the payment.
    @discardableResult
    public func cancelPayment(merchantOrderID: String) -> CancelResult {
        CancelRegistry.walletPayment(merchantOrderID: merchantOrderID)
    }
}
