// VeyraCommon — the outcome shape every Veyra SDK operation shares on iOS.
//

import Foundation

/// The statuses every Veyra SDK operation ends with. Plain strings, so a status added after this SDK
/// shipped still reaches you — treat one you don't know as unresolved.
///
/// | Status | Meaning | Your reference (order ID) | What to do |
/// |---|---|---|---|
/// | `APPROVED` | done | used — paid | complete |
/// | `DECLINED` | done; someone with authority refused; no money moved | free | show the reason; another card or method may be tried under the **same** reference |
/// | `FAILED` | received, but not performed, and retrying with the same reference won't help | free, except after `94` (the order is paid or possibly paid) | fix the reason |
/// | `PENDING` | may have been done; not known yet | used | **never retry**; the SDK resolves it in the background |
/// | `RETRY` | Veyra received it and did not send it to the bank; nothing was done | **unused** | fix the reason; retry with the **same** reference |
/// | `NOT_SENT` | never reached Veyra; nothing was done | **unused** | fix the reason; retry with the **same** reference |
///
/// `NOT_SENT` is the SDK's own status: no service ever states it, and it never carries a response code.
/// `RETRY` is stated by Veyra, carries its response code, and is recorded in history. `RETRY` and
/// `NOT_SENT` are handled the same way: nothing was debited; retry with the same order ID.
/// An order ID can be used again until the order is `APPROVED` or `PENDING`; after that a new attempt
/// is refused `94` / `FAILED` / `DUPLICATE_MERCHANT_ORDER_ID`.
public enum ResponseStatus {
    public static let approved = "APPROVED"
    public static let declined = "DECLINED"
    public static let failed = "FAILED"
    public static let pending = "PENDING"
    public static let notSent = "NOT_SENT"
    public static let retry = "RETRY"
}

/// The answer to a read — a status check, a credit check, a context poll.
///
/// A read does not carry a status of its own: when it is about a payment, the payment's status is
/// inside `value`, and a check that could not be made never changes it. When the check could not be
/// made, `failureReason` says why (`NO_NETWORK_CONNECTION`, `SDK_UNABLE_TO_CONNECT`,
/// `NOT_AUTHENTICATED`, `UPSTREAM_ERROR`…) and `value` is what the device already holds, if anything.
/// A read changes nothing, so retrying it as is is always safe.
public struct VeyraLookup<Value: Sendable>: Sendable {
    /// The answer; for a refresh, the stored row as it now stands. `nil` when there is none.
    public let value: Value?
    /// Why the check could not be made; `nil` when it was made.
    public let failureReason: String?
    /// A human-readable description of the failure, for logs and error text.
    public let message: String?

    /// `true` when the check was made and answered.
    public var checked: Bool { failureReason == nil }

    public init(value: Value?, failureReason: String? = nil, message: String? = nil) {
        self.value = value
        self.failureReason = failureReason
        self.message = message
    }
}

extension VeyraLookup: Equatable where Value: Equatable {}
extension VeyraLookup: Hashable where Value: Hashable {}
