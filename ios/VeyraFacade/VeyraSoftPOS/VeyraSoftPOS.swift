// VeyraSoftPOS — public iOS API of the Veyra SoftPOS SDK.
//
// Pure-Swift facade over the VeyraKMP umbrella framework (Swift-idiomatic: async/await,
// typed errors). KMP/Obj-C types (VKMP*) must never appear in public signatures — every
// boundary maps to a Swift type here.
//
// The merchant surface: registration, activate/deactivate/status, update, bank list,
// transaction status — plus payment acceptance via the merchant-presented QR rail and
// contactless tap.
//
// Every operation hangs off `VeyraSoftPOS.shared`, under the same name as on Android and React
// Native, e.g. `try await VeyraSoftPOS.shared.register(registration)`.
import Foundation
import VeyraKMP

/// Configuration for the Veyra SoftPOS SDK.
///
/// **URLs are provided by the SDK, not the app developer** — selecting an `environment` is all
/// that is needed; endpoints resolve from the SDK's shared defaults (the same single source of
/// truth as Android). The only URL hooks are development overrides.
public struct VeyraSoftPOSConfiguration: Sendable {
    public let environment: VeyraEnvironment
    /// The payment app provider's globally unique identifier, as issued by the platform.
    /// Required — the gateway links every registered merchant to this provider and resolves the
    /// acquirer id and MCC from it; the app never supplies an acquirer id.
    public let paymentAppProviderID: String
    /// The longest the SDK waits for one backend call, start to finish, in seconds (5–60).
    /// `nil` (the default) keeps the SDK's own timeouts. A value outside 5–60 makes `configure`
    /// throw `invalidConfiguration`. A payment that runs out of time is **pending**, not failed:
    /// the request may have reached the server, so the SDK checks the result later. A shorter
    /// timeout answers sooner but leaves more payments pending.
    public let requestTimeoutSeconds: Int?

    public init(
        environment: VeyraEnvironment,
        paymentAppProviderID: String,
        requestTimeoutSeconds: Int? = nil
    ) {
        self.environment = environment
        self.paymentAppProviderID = paymentAppProviderID
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }
}

/// A merchant registration submission (mirrors Android `MerchantRegistrationRequest`).
public struct MerchantRegistration: Sendable {
    public enum MerchantType: String, Sendable {
        case personal = "PERSONAL"
        case business = "BUSINESS"
    }

    public let merchantType: MerchantType
    public let merchantName: String
    public let emailAddress: String
    public let phoneNumber: String
    public let addressLine1: String
    public let addressLine2: String
    public let city: String
    public let state: String
    public let countryCode: String
    /// Bank Verification Number, for either merchant type. Optional when your payment app provider
    /// is registered as the account issuer; otherwise the backend refuses with `BVN_REQUIRED`.
    /// Blank is sent as absent.
    public let bvn: String?
    /// Required for `.business` registrations.
    public let cacNumber: String?
    public let accountNumber: String
    public let institutionCode: String
    /// Optional — the merchant's wallet account id, stored verbatim by the gateway.
    public let walletAccountID: String?

    public init(
        merchantType: MerchantType,
        merchantName: String,
        emailAddress: String,
        phoneNumber: String,
        addressLine1: String,
        addressLine2: String = "",
        city: String,
        state: String,
        countryCode: String,
        bvn: String? = nil,
        cacNumber: String? = nil,
        accountNumber: String,
        institutionCode: String,
        walletAccountID: String? = nil
    ) {
        self.merchantType = merchantType
        self.merchantName = merchantName
        self.emailAddress = emailAddress
        self.phoneNumber = phoneNumber
        self.addressLine1 = addressLine1
        self.addressLine2 = addressLine2
        self.city = city
        self.state = state
        self.countryCode = countryCode
        self.bvn = bvn
        self.cacNumber = cacNumber
        self.accountNumber = accountNumber
        self.institutionCode = institutionCode
        self.walletAccountID = walletAccountID
    }
}

/// Outcome of a merchant registration. Branch on ``responseStatus``: `APPROVED` (registered;
/// ``merchantID`` is set), `FAILED` (refused — ``responseStatusReason`` names the field or rule, e.g.
/// `ACCOUNT_NUMBER_REQUIRED`), `PENDING` (sent, no usable answer — check `refreshStatus()` before
/// registering again). A registration that never reached Veyra is `FAILED` too, with its reason.
public struct MerchantRegistrationResult: Sendable, Hashable {
    /// `true` when registered — the same fact as `responseStatus == "APPROVED"`.
    public let success: Bool
    public let merchantID: String?
    public let terminalID: String?
    public let merchantStatus: String?
    public let message: String?
    public let responseStatus: String
    public let responseStatusReason: String?

    public init(success: Bool, merchantID: String?, terminalID: String?, merchantStatus: String?, message: String?,
                responseStatus: String, responseStatusReason: String? = nil) {
        self.success = success
        self.merchantID = merchantID
        self.terminalID = terminalID
        self.merchantStatus = merchantStatus
        self.message = message
        self.responseStatus = responseStatus
        self.responseStatusReason = responseStatusReason
    }
}

/// A merchant's backend status (e.g. `"ACTIVE"`, `"DEACTIVATED"`), as the outcome of a status read,
/// activate, deactivate or update. Branch on ``responseStatus``: `APPROVED` (answered; ``status`` is
/// set), `FAILED` (refused, e.g. `MERCHANT_NOT_FOUND`), `PENDING` (activate / deactivate / update sent
/// with no usable answer — read the status before trying again). Never reaching Veyra is `FAILED` too
/// (`MISSING_MANDATORY_CONFIG` when no merchant is registered). A status read is never `PENDING`.
public struct MerchantStatusResult: Sendable, Hashable {
    public let merchantID: String?
    public let merchantStatus: String?
    public let responseStatus: String
    public let responseStatusReason: String?
    public let message: String?

    public init(merchantID: String?, merchantStatus: String?, responseStatus: String = "APPROVED",
                responseStatusReason: String? = nil, message: String? = nil) {
        self.merchantID = merchantID
        self.merchantStatus = merchantStatus
        self.responseStatus = responseStatus
        self.responseStatusReason = responseStatusReason
        self.message = message
    }
}

/// The NUBAN settlement banks (a read). `APPROVED` with ``banks``, or the reason there are none
/// (`NO_NETWORK_CONNECTION`…). Never `PENDING`; retrying as is is always safe.
public struct SettlementBankList: Sendable, Hashable {
    public let banks: [Bank]
    public let responseStatus: String
    public let responseStatusReason: String?
    public let message: String?
}

/// The outcome of inspecting a scanned customer QR. `APPROVED` with ``qr`` — show its amount for the
/// merchant to confirm — or `FAILED` / `INVALID_REQUEST` when the payload is not a Veyra payment QR:
/// show a transient hint and stay armed. Nothing is sent either way.
public struct CustomerQrInspection: Sendable {
    public let qr: ScannedCustomerQr?
    public let responseStatus: String
    public let responseStatusReason: String?
    public let message: String?
}

/// The merchant's backend status changed — delivered to `observeMerchantStatusChanged(_:)`.
public struct MerchantStatusEvent: Sendable, Hashable {
    /// The merchant this is about.
    public let merchantID: String
    /// The new status as the backend stated it, e.g. `"ACTIVE"`, `"INACTIVE"`, `"SUSPENDED"`.
    public let status: String
    /// Whether the merchant may take payments now.
    ///
    /// Branch on this, not on `status`. It is the same reading the SDK's own payment gate uses, so
    /// acting on it can never leave you more permissive than the gate that will refuse the sale.
    /// Anything that is not `ACTIVE` is `false`, including a status added after this SDK shipped.
    public let canAcceptPayments: Bool
    /// What was stored before, or `nil` when this device had no status for the merchant yet.
    public let previousStatus: String?
}

/// A scanned, structurally-valid customer payment QR (consumer-presented): what the merchant
/// confirm screen shows. The amount/currency are read from the QR's cryptogram-covered data —
/// the merchant confirms, never re-keys.
public struct ScannedCustomerQr: Sendable {
    /// The paying card for display: `•••• ` and its last four digits. Never more of the number.
    public let maskedCard: String
    /// Amount in minor units (e.g. kobo) — bound inside the QR's cryptogram.
    public let amountMinorUnits: Int64
    /// The currency, ISO 4217 numeric, three digits (e.g. `"566"`), as on every other Veyra type.
    public let currencyCode: String
    /// Cardholder Name (EMV `5F20`) when the QR carried one — the paying card's display name,
    /// e.g. "AFRIGO ****1234". Display only (it rides outside the cryptogram-covered data):
    /// show it on the confirm screen, never branch a payment decision on it.
    public let cardholderName: String?
    /// The KMP-scanned payload, kept for `chargeCustomerQr` (never public API).
    let raw: VeyraKMP.ScannedCustomerQr
}

/// Outcome of charging a scanned customer QR. Every charge ends with one — branch on
/// ``responseStatus``:
///
/// | Status | Meaning | Order ID | What to do |
/// |---|---|---|---|
/// | `APPROVED` | done | used — paid | complete the sale |
/// | `DECLINED` | someone with authority refused; no money moved | free | show the reason; another card or method may be tried under the **same** order ID |
/// | `FAILED` | the gateway received it and did not perform it, and retrying with the same order ID won't help | free, except after `94` (the order is paid or possibly paid) | fix the reason |
/// | `PENDING` | may have been done; not known yet | used | **never retry**; the SDK resolves it in the background |
/// | `RETRY` | reached the gateway, but was never sent to the bank; nothing was done | **unused** | fix the reason; retry with the **same** order ID |
/// | `NOT_SENT` | never reached the gateway; nothing was done | **unused** | fix the reason; retry with the **same** order ID |
/// The payment that already holds a merchant order ID, carried on a `FAILED` /
/// `DUPLICATE_MERCHANT_ORDER_ID` refusal from a card tap, a customer-QR charge or a merchant QR.
///
/// The refusal only says "this order ID is used". ``responseStatus`` says what happened to the order:
/// `APPROVED` means it is already paid, `PENDING` that a payment is still being confirmed. **Do not take
/// another payment for the order** either way. Nil on the refusal when the gateway could not read the
/// original (two attempts raced for the same order ID).
public struct OriginalPayment: Sendable, Hashable {
    /// The original payment's wire code, e.g. `00`. For receipts and support only.
    public let responseCode: String?
    /// The original payment's status: `APPROVED`, `DECLINED`, `FAILED` or `PENDING`.
    public let responseStatus: String?
    /// Why the original payment ended as it did, e.g. `INSUFFICIENT_FUNDS`.
    public let responseStatusReason: String?
    /// The original payment's amount, in minor units.
    public let amountMinorUnits: Int64?
    /// The reference the original payment was recorded under.
    public let merchantTransactionReference: String?
    /// The gateway's transaction ID for the original payment.
    public let transactionID: String?

    public init(responseCode: String?, responseStatus: String?, responseStatusReason: String?,
                amountMinorUnits: Int64?, merchantTransactionReference: String?, transactionID: String?) {
        self.responseCode = responseCode
        self.responseStatus = responseStatus
        self.responseStatusReason = responseStatusReason
        self.amountMinorUnits = amountMinorUnits
        self.merchantTransactionReference = merchantTransactionReference
        self.transactionID = transactionID
    }

    init?(_ k: VeyraKMP.OriginalPayment?) {
        guard let k else { return nil }
        self.init(responseCode: k.responseCode, responseStatus: k.responseStatus,
                  responseStatusReason: k.responseStatusReason, amountMinorUnits: k.amountMinorUnits?.int64Value,
                  merchantTransactionReference: k.merchantTransactionReference, transactionID: k.transactionId)
    }
}

/// One payment attempt made under a merchant order ID. An order can have several: after `DECLINED`,
/// `FAILED` or `RETRY` the same order ID may be tried again.
public struct OrderPaymentAttempt: Sendable, Hashable {
    public let merchantTransactionReference: String?
    public let transactionID: String?
    public let amountMinorUnits: Int64?
    /// The wire code — receipts and support only.
    public let responseCode: String?
    /// `APPROVED`, `DECLINED`, `FAILED`, `PENDING` or `RETRY`.
    public let responseStatus: String?
    public let responseStatusReason: String?
}

/// What happened to a merchant order (`paymentStatus(merchantOrderID:)`). Branch on
/// ``responseStatus``: `APPROVED` — paid, never take another payment; `PENDING` — may have moved money,
/// never retry; `DECLINED` / `FAILED` / `RETRY` — no money moved, pay again with the **same** order ID.
/// The other top-level fields are the deciding attempt's; ``attempts`` lists them all, newest first.
public struct OrderPaymentStatus: Sendable, Hashable {
    public let merchantOrderID: String
    public let responseStatus: String
    public let responseStatusReason: String?
    public let responseCode: String?
    public let merchantTransactionReference: String?
    public let transactionID: String?
    public let amountMinorUnits: Int64?
    public let attempts: [OrderPaymentAttempt]
    /// `DEVICE` (this phone's own final record) or `GATEWAY`.
    public let answeredBy: String
}

public struct CustomerQrChargeOutcome: Sendable, Hashable {
    /// True only when ``responseStatus`` is `APPROVED` — never worked out from the code.
    public let approved: Bool
    /// `APPROVED` · `DECLINED` · `FAILED` · `PENDING` · `RETRY` · `NOT_SENT`. A plain string, so a status
    /// added after this SDK shipped still reaches you; treat one you don't know as unresolved.
    public let responseStatus: String
    /// Why it ended as it did (`INSUFFICIENT_FUNDS`, `NO_RESPONSE_RECEIVED`, `NO_NETWORK_CONNECTION`…).
    /// Show and log it; branch on ``responseStatus``.
    public let responseStatusReason: String?
    /// The wire code (`00`, `51`, `68`…) — for receipts and support, never to branch on. Nil on `NOT_SENT`.
    public let responseCode: String?
    /// A human-readable description, for logs.
    public let message: String?
    public let transactionID: String?
    /// The merchant transaction reference this charge was submitted (and recorded) under —
    /// pass to `receipt(merchantTransactionReference:)` to build the receipt QR. Nil when the
    /// charge never reached the gateway.
    public let merchantTransactionReference: String?
    /// Your own order ID, echoed back exactly as you passed it.
    public let merchantOrderID: String?
    /// The merchant-bank credit's identifier (NIP session id inter-bank, batch reference
    /// intra-bank) — the key for `creditConfirmation(...)`. Nil unless the charge
    /// was approved and the gateway sent one.
    public let creditTransactionID: String?
    /// Whether the merchant's (beneficiary) bank can confirm the credit at all — the backend's
    /// payment-time decision. When `true`, the SDK's app-scoped background sweep polls the
    /// confirmation rail and stamps the answer onto the sale's stored row
    /// (`creditConfirmationStatus`) — show a "confirming credit…" state and render the row.
    public let isCreditConfirmationSupported: Bool?
    /// On a `DUPLICATE_MERCHANT_ORDER_ID` refusal, the payment already holding the order ID. Nil otherwise.
    public let originalPayment: OriginalPayment?
}

/// The outcome of creating one: `APPROVED` (render ``mpmPayload``), `FAILED` (the gateway refused it —
/// ``responseStatusReason``, e.g. `DUPLICATE_MERCHANT_ORDER_ID`), `PENDING` (sent, no usable answer —
/// create a new QR) or `NOT_SENT` (never reached the gateway; fix the reason and retry with the same
/// order ID). ``txRef`` and ``mpmPayload`` are set only on `APPROVED`.
public struct PaymentContextQr: Sendable, Hashable {
    public let txRef: String?
    /// ISO-8601 expiry (server clock) — offer a fresh QR once passed.
    public let expiry: String?
    /// Signing-key id the wallet uses to select its pinned verification key.
    public let kid: String?
    public let mpmPayload: String?
    public let responseStatus: String
    public let responseStatusReason: String?
    public let message: String?
    /// On a `DUPLICATE_MERCHANT_ORDER_ID` refusal, the payment already holding the order ID. Nil otherwise.
    public let originalPayment: OriginalPayment?

    public init(txRef: String?, expiry: String?, kid: String?, mpmPayload: String?,
                responseStatus: String = "APPROVED", responseStatusReason: String? = nil, message: String? = nil,
                originalPayment: OriginalPayment? = nil) {
        self.txRef = txRef
        self.expiry = expiry
        self.kid = kid
        self.mpmPayload = mpmPayload
        self.responseStatus = responseStatus
        self.responseStatusReason = responseStatusReason
        self.message = message
        self.originalPayment = originalPayment
    }
}

/// Lifecycle of a payment context: PENDING (QR live), IN_FLIGHT (push settling),
/// APPROVED / DECLINED (settled — `responseCode` carries the rail outcome), EXPIRED.
public struct PaymentContextStatus: Sendable, Hashable {
    public let txRef: String
    public let state: String
    public let responseCode: String?
    /// The transaction hash the gateway computed once the push settled — what makes the sale's
    /// receipt scannable by the paying wallet. Nil while pending.
    public let transactionHash: String?

    public var isSettled: Bool { state == "APPROVED" || state == "DECLINED" }
    public var isApproved: Bool { state == "APPROVED" }

    public init(txRef: String, state: String, responseCode: String?, transactionHash: String? = nil) {
        self.txRef = txRef
        self.state = state
        self.responseCode = responseCode
        self.transactionHash = transactionHash
    }
}

/// A merchant profile update (mirrors Android `MerchantUpdateRequest`).
public struct MerchantUpdate: Sendable {
    public let merchantName: String
    public let emailAddress: String
    public let phoneNumber: String
    public let addressLine1: String
    public let addressLine2: String
    public let city: String
    public let state: String
    public let countryCode: String
    public let accountNumber: String
    public let institutionCode: String
    /// Optional — stored verbatim by the gateway when supplied.
    public let walletAccountID: String?
    /// Optional — how an already-registered merchant supplies its BVN; absent keeps the stored one.
    /// When your payment app provider is not registered as the account issuer, an update that
    /// leaves the merchant with no BVN is refused with `BVN_REQUIRED`.
    public let bvn: String?

    public init(
        merchantName: String,
        emailAddress: String,
        phoneNumber: String,
        addressLine1: String,
        addressLine2: String = "",
        city: String,
        state: String,
        countryCode: String,
        accountNumber: String,
        institutionCode: String,
        walletAccountID: String? = nil,
        bvn: String? = nil
    ) {
        self.merchantName = merchantName
        self.emailAddress = emailAddress
        self.phoneNumber = phoneNumber
        self.addressLine1 = addressLine1
        self.addressLine2 = addressLine2
        self.city = city
        self.state = state
        self.countryCode = countryCode
        self.accountNumber = accountNumber
        self.institutionCode = institutionCode
        self.walletAccountID = walletAccountID
        self.bvn = bvn
    }
}

/// One transaction's backend status. `amount` is in **minor units** — nil on a not-found
/// answer (`25`), where the gateway holds no transaction to take it from.
public struct TransactionStatus: Sendable, Hashable {
    public let merchantTransactionReference: String
    public let merchantID: String
    public let amountMinorUnits: Int64?
    /// The wire code — for receipts and support, never to branch on.
    public let responseCode: String
    /// The payment's outcome as the gateway stated it (`"APPROVED"`, `"PENDING"`, `"FAILED"`…) — what
    /// you branch on. `nil` from a gateway that does not state it.
    public let responseStatus: String?
    /// Why it ended as it did, e.g. `"UNABLE_TO_LOCATE_RECORD"`.
    public let responseStatusReason: String?
    public let merchantStatus: String?
    public let transactionID: String?
    /// The merchant-bank credit's identifier — sent when the transaction is approved, so an app
    /// that lost local state can still re-learn it from a status poll. See
    /// `creditConfirmation(creditTransactionID:amountMinorUnits:)`.
    public let creditTransactionID: String?
    /// Whether the merchant's (beneficiary) bank can confirm the credit — the fetch gate.
    public let isCreditConfirmationSupported: Bool?

    public init(
        merchantTransactionReference: String,
        merchantID: String,
        amountMinorUnits: Int64?,
        responseCode: String,
        merchantStatus: String?,
        transactionID: String?,
        creditTransactionID: String? = nil,
        isCreditConfirmationSupported: Bool? = nil,
        responseStatus: String? = nil,
        responseStatusReason: String? = nil
    ) {
        self.merchantTransactionReference = merchantTransactionReference
        self.merchantID = merchantID
        self.amountMinorUnits = amountMinorUnits
        self.responseCode = responseCode
        self.responseStatus = responseStatus
        self.responseStatusReason = responseStatusReason
        self.merchantStatus = merchantStatus
        self.transactionID = transactionID
        self.creditTransactionID = creditTransactionID
        self.isCreditConfirmationSupported = isCreditConfirmationSupported
    }
}

/// One payment the merchant has taken, kept locally by the SDK. `amountMinorUnits` is
/// in **minor units**; `rail` is `"TAP"` / `"QR_MPM"` / `"QR_CPM"`; `status` is
/// `"APPROVED"` / `"DECLINED"` / `"PENDING"` / `"FAILED"` / `"RETRY"` (see `ResponseStatus`); treat
/// one you don't know as unresolved.
public struct MerchantTransaction: Sendable, Hashable {
    /// The sale's reference, **minted by the SDK** (`{terminalID}-YYYYMMDDHHmmssSSS`) and unique
    /// per merchant at the gateway — the key for receipts, status refreshes and credit confirmation.
    public let merchantTransactionReference: String
    /// The **app's own** order / basket / invoice id for this sale, echoed back by the gateway, or
    /// nil when none was supplied. Several attempts may share it, until the order is `APPROVED` or
    /// `PENDING`. `merchantTransactionReference` stays the key.
    public let merchantOrderID: String?
    public let rail: String
    public let amountMinorUnits: Int64
    public let currencyCode: String?
    public let status: String
    public let responseCode: String?
    /// The outcome's stated cause (`"INSUFFICIENT_FUNDS"`, `"QR_EXPIRED"`…), carried verbatim
    /// as a plain string — display it, never parse it; nil on legacy/unresolved rows.
    public let responseStatusReason: String?
    public let transactionTime: String?
    public let transactionID: String?
    public let maskedTokenLast4: String
    public let transactionHash: String?
    /// Human label for `rail` — "Tap" / "QR" / "Scan". Derived by the SDK so both platforms
    /// word it identically; an unrecognised rail code is passed through unchanged.
    public let railLabel: String
    /// Cardholder Name (EMV tag `5F20`) as the card presented it — on a Veyra token the card's
    /// display name (e.g. "AFRIGO ****1234"), not a person's name. Nil on QR-MPM payments and
    /// on rows recorded before the SDK captured it.
    public let cardholderName: String?
    /// The beneficiary credit's identifier (NIP session id inter-bank, batch reference
    /// intra-bank) — the key for `creditConfirmation(...)`. Nil on non-approved
    /// rows and from gateways predating the credit-confirmation rail.
    public let creditTransactionID: String?
    /// Whether the merchant's (beneficiary) bank can confirm the credit at all — the backend's
    /// payment-time decision, and the whole gate for fetching a confirmation.
    public let isCreditConfirmationSupported: Bool?
    /// Terminal credit-confirmation state: "RECEIVED" when the merchant's bank confirmed the
    /// funds, "UNABLE_TO_CONFIRM" only as the final give-up after the 30-day window. **Nil while
    /// unconfirmed** — render it as "not confirmed yet" (or nothing), never as "not received".
    /// Settlement fact only; `status` remains the payment outcome.
    public let creditConfirmationStatus: String?

    public init(
        merchantTransactionReference: String,
        // Defaulted so every existing call site keeps compiling unchanged (additive-only): the
        // stored property and `map` above were added without this parameter, which left the
        // explicit initializer unable to accept the field it is required to set.
        merchantOrderID: String? = nil,
        rail: String,
        amountMinorUnits: Int64,
        currencyCode: String?,
        status: String,
        responseCode: String?,
        responseStatusReason: String? = nil,
        transactionTime: String?,
        transactionID: String?,
        maskedTokenLast4: String,
        transactionHash: String?,
        railLabel: String = "",
        cardholderName: String? = nil,
        creditTransactionID: String? = nil,
        isCreditConfirmationSupported: Bool? = nil,
        creditConfirmationStatus: String? = nil
    ) {
        self.merchantTransactionReference = merchantTransactionReference
        self.merchantOrderID = merchantOrderID
        self.rail = rail
        self.amountMinorUnits = amountMinorUnits
        self.currencyCode = currencyCode
        self.status = status
        self.responseCode = responseCode
        self.responseStatusReason = responseStatusReason
        self.transactionTime = transactionTime
        self.transactionID = transactionID
        self.maskedTokenLast4 = maskedTokenLast4
        self.transactionHash = transactionHash
        self.railLabel = railLabel
        self.cardholderName = cardholderName
        self.creditTransactionID = creditTransactionID
        self.isCreditConfirmationSupported = isCreditConfirmationSupported
        self.creditConfirmationStatus = creditConfirmationStatus
    }
}

/// The beneficiary side's answer to "has the merchant's bank actually received the funds?" —
/// settlement confirmation for an approved sale, never a change to its payment outcome.
/// `status` is a plain string: "RECEIVED" (terminal — the credit is in the merchant's account,
/// id resolved and amount matched) or "UNABLE_TO_CONFIRM" (not confirmed yet — ask again later);
/// unknown values are carried through verbatim. `amountMinorUnits`, `creditedAt` and
/// `bankReference` are populated on "RECEIVED" only.
public struct CreditConfirmation: Sendable, Hashable {
    public let creditTransactionID: String
    public let status: String
    public let amountMinorUnits: Int64?
    public let creditedAt: String?
    public let bankReference: String?
    public let message: String?

    public init(
        creditTransactionID: String,
        status: String,
        amountMinorUnits: Int64? = nil,
        creditedAt: String? = nil,
        bankReference: String? = nil,
        message: String? = nil
    ) {
        self.creditTransactionID = creditTransactionID
        self.status = status
        self.amountMinorUnits = amountMinorUnits
        self.creditedAt = creditedAt
        self.bankReference = bankReference
        self.message = message
    }
}

/// How a payment the app was left waiting on finally ended — delivered to
/// `observeTransactionResolved(_:)` when a stored row stops being pending.
///
/// The whole triple, because "it resolved" is not useful on its own: an app showing "processing"
/// needs to know whether to print a receipt (`status == "APPROVED"`), tell the cashier the card
/// was refused (`"DECLINED"`, with `reason` naming the cause) or offer a retry (`"FAILED"` —
/// nothing happened).
public struct TransactionResolvedEvent: Sendable, Hashable {
    /// The merchant transaction reference passed in when the payment was started. The SDK walks
    /// every pending row, so this can fire for a sale other than the one on screen — always match
    /// on it.
    public let merchantTransactionReference: String
    /// The response code exactly as the backend sent it (`"00"`, `"51"`, `"96"`…). Receipts and
    /// disputes quote this literal, never a renamed enum. Nil on rows recorded before it existed.
    public let responseCode: String?
    /// `"APPROVED"` / `"DECLINED"` / `"FAILED"` — always one of the three finals, never `"PENDING"`.
    public let status: String
    /// Why it ended that way, e.g. `"INSUFFICIENT_FUNDS"`. Nil when the backend sent none.
    public let reason: String?

    public init(merchantTransactionReference: String, responseCode: String?, status: String, reason: String?) {
        self.merchantTransactionReference = merchantTransactionReference
        self.responseCode = responseCode
        self.status = status
        self.reason = reason
    }
}

/// A sale's beneficiary credit confirmation, delivered to `observeCreditConfirmation(_:)`
/// when the confirmation concludes.
///
/// Settlement confirmation only: it says whether the **merchant's bank received the funds**, and
/// never restates (or alters) the payment outcome the app already has.
///
/// Distinct from ``CreditConfirmation``, which is the reply to the on-demand
/// `creditConfirmation(creditTransactionID:amountMinorUnits:)` fetch: that
/// one answers a question about a credit you named, so it has no sale reference to carry, while
/// this one arrives unprompted about whichever sale the SDK's sweep just settled.
public struct CreditConfirmationEvent: Sendable, Hashable {
    /// The merchant transaction reference passed in when the payment was started — match the
    /// confirmation to its sale with this.
    public let merchantTransactionReference: String
    /// The credit's identifier (NIP session id inter-bank, batch reference intra-bank).
    public let creditTransactionID: String?
    /// `"RECEIVED"` (terminal — the funds landed) or `"UNABLE_TO_CONFIRM"` (the 30-day window
    /// closed without a confirmation: a give-up, **not** a reversal).
    public let status: String
    /// Credited amount in **minor units**, as the merchant's bank reported it. `RECEIVED` only.
    public let amountMinorUnits: Int64?
    /// The merchant bank's own reference for the credit. `RECEIVED` only.
    public let bankReference: String?
    /// When the merchant's bank posted the credit (ISO date-time). `RECEIVED` only.
    public let creditedAt: String?

    public init(
        merchantTransactionReference: String,
        creditTransactionID: String?,
        status: String,
        amountMinorUnits: Int64?,
        bankReference: String?,
        creditedAt: String?
    ) {
        self.merchantTransactionReference = merchantTransactionReference
        self.creditTransactionID = creditTransactionID
        self.status = status
        self.amountMinorUnits = amountMinorUnits
        self.bankReference = bankReference
        self.creditedAt = creditedAt
    }
}

/// A merchant receipt for one transaction. `qrPayload` is the receipt JSON to
/// render as a QR — scannable by the customer wallet's receipt scanner.
public struct MerchantReceipt: Sendable, Hashable {
    public let merchantName: String
    public let merchantAddress: String
    public let transactionType: String
    public let totalAmountMinorUnits: Int64
    public let totalAmountFormatted: String
    public let maskedToken: String
    public let merchantTransactionReference: String
    public let transactionHash: String?
    public let qrPayload: String
    /// Cardholder Name (EMV tag `5F20`) as the card presented it — the card's display name
    /// (e.g. "AFRIGO ****1234"), not a person's name. Nil on QR-MPM and on older rows.
    /// Merchant-side display only: it is not part of `qrPayload`, the format the customer
    /// wallet scans.
    public let cardholderName: String?

    public init(
        merchantName: String,
        merchantAddress: String,
        transactionType: String,
        totalAmountMinorUnits: Int64,
        totalAmountFormatted: String,
        maskedToken: String,
        merchantTransactionReference: String,
        transactionHash: String?,
        qrPayload: String,
        cardholderName: String? = nil
    ) {
        self.merchantName = merchantName
        self.merchantAddress = merchantAddress
        self.transactionType = transactionType
        self.totalAmountMinorUnits = totalAmountMinorUnits
        self.totalAmountFormatted = totalAmountFormatted
        self.maskedToken = maskedToken
        self.merchantTransactionReference = merchantTransactionReference
        self.transactionHash = transactionHash
        self.qrPayload = qrPayload
        self.cardholderName = cardholderName
    }
}

// Without `LocalizedError`, `error.localizedDescription` renders the useless "The operation
// couldn't be completed. (VeyraSoftPOS.VeyraError error N.)" and the carried message is
// invisible to anyone reading a support log.
/// The SoftPOS SDK's per-customer work, stopped and started by the shared customer session when
/// a customer signs out or another signs in.
private final class SoftposCustomerWork: NSObject, CustomerSessionParticipant {
    private unowned let owner: VeyraSoftPOS
    init(owner: VeyraSoftPOS) { self.owner = owner }
    func startCustomerWork() { owner.startCustomerWork() }
    func stopCustomerWork() { owner.stopCustomerWork() }
}

/// Entry point of the Veyra SoftPOS SDK on iOS.
///
/// Configure once at launch, then call operations on the shared instance:
/// ```swift
/// let softpos = try VeyraSoftPOS.configure(customerID: signedInCustomer,
///                                          config: .init(environment: .test, paymentAppProviderID: id),
///                                          provider: provider)
/// let status = try await softpos.refreshStatus()
/// ```
public final class VeyraSoftPOS: @unchecked Sendable {

    public static let shared = VeyraSoftPOS()

    private let lock = NSLock()
    private var kmp: SoftposKmp?
    // The current customer's merchant store, rebuilt at every configure (one store per
    // customer); none until a customer is signed in.
    private var merchantStorage: MerchantStorage = NoCustomerMerchantStorage()
    // The provider credential from the configuration — sent on merchant
    // register/update so the gateway can resolve the acquirer id and MCC.
    fileprivate var paymentAppProviderID: String = ""
    // Kept so a sign-in can build the instance for whoever is signed in.
    private var configuration: VeyraSoftPOSConfiguration?
    private lazy var customerWork = SoftposCustomerWork(owner: self)
    // The tap now running, held until it ends: keeps its reader alive and answers the tap state.
    private var currentTap: TapPaymentSession?

    private init() {}

    /// Configure the SDK for the customer your app has signed in. Call at every launch, before
    /// any service use (subsequent calls reconfigure).
    ///
    /// The merchant and its transactions are kept **per customer**, and the SDK never remembers
    /// who is signed in, so `customerID` is required every time. The same customer again changes
    /// nothing; a different customer stops the previous customer's watches and opens the new
    /// customer's merchant. Observer registrations are dropped on a switch — register them again
    /// after this call. Call `signOut()` when a customer logs out.
    ///
    /// - Parameters:
    ///   - customerID: The customer your app has authenticated. Never leaves the device.
    ///   - provider: How the SDK reaches Veyra — required, no default: your `VeyraAssertionProvider` or
    ///     `VeyraProxyProvider`. A combined app passes the same one to both SDKs.
    ///
    /// - Throws: `VeyraError.invalidConfiguration` when the provider cannot be used (the
    ///   message names the problem) or is of a different kind from an earlier `configure`, or when
    ///   `requestTimeoutSeconds` is outside 5–60. Every
    ///   `configure` re-binds the provider, which background work uses too.
    @discardableResult
    public static func configure(customerID: String, config configuration: VeyraSoftPOSConfiguration, provider: any VeyraProvider) throws -> VeyraSoftPOS {
        guard !customerID.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw VeyraError.invalidConfiguration(message: "customerID must not be blank")
        }
        let requestTimeout: KotlinInt?
        switch KmpConnectionBridge.kmpRequestTimeout(configuration.requestTimeoutSeconds) {
        case .failure(let problem): throw VeyraError.invalidConfiguration(message: problem.message)
        case .success(let value): requestTimeout = value
        }
        switch KmpConnectionBridge.kmpProvider(provider) {
        case .failure(let problem):
            throw VeyraError.invalidConfiguration(message: problem.message)
        case .success(let kmpProvider):
            do {
                try IosConnections.shared.bindSoftpos(environmentName: configuration.environment.rawValue, provider: kmpProvider, requestTimeoutSeconds: requestTimeout)
            } catch {
                throw VeyraError.invalidConfiguration(message: error.localizedDescription)
            }
        }
        // Stores from before customers were partitioned belong to nobody: erased, never inherited.
        FileMerchantStorage.eraseUnpartitionedStores()
        // Stop and drop the current instance (a reconfigure, or another customer), keep the
        // configuration, then sign in: the session's start builds the instance and the merchant
        // store for whoever is signed in, and arms the merchant's watches ([startCustomerWork]).
        shared.lock.lock()
        let previous = shared.kmp
        shared.kmp = nil
        shared.merchantStorage = NoCustomerMerchantStorage()
        shared.configuration = configuration
        shared.paymentAppProviderID = configuration.paymentAppProviderID
        shared.lock.unlock()
        previous?.stopCustomerWork()
        CustomerSession.shared.register(participant: shared.customerWork)
        CustomerSession.shared.signIn(customerId: customerID)
        return shared
    }

    /// The customer has logged out: stop every merchant watch and drop every observer
    /// registration. Their merchant and transactions stay on the device for when they sign in
    /// again. Until the next `configure` every call throws `VeyraError.notSignedIn`.
    public static func signOut() {
        CustomerSession.shared.signOut()
    }

    /// Build the instance and merchant store for the customer now signed in, if there are none,
    /// and arm the merchant's watches (app-scoped, §16: the case that matters most is a merchant
    /// deactivated while the app was shut). Outside the lock: the watches read the stored
    /// merchant through `withMerchantStorage`, which takes this same non-reentrant lock.
    fileprivate func startCustomerWork() {
        lock.lock()
        guard kmp == nil, let configuration, let partition = CustomerScope.shared.currentPartition else {
            lock.unlock()
            return
        }
        merchantStorage = FileMerchantStorage(partition: partition)
        kmp = VeyraSoftPOS.makeKmp(configuration)
        lock.unlock()
        startMerchantWatchesIfRegistered()
    }

    /// Stop the instance's work and drop it with the merchant store: both are bound to the
    /// customer they were built for.
    fileprivate func stopCustomerWork() {
        lock.lock()
        let current = kmp
        kmp = nil
        merchantStorage = NoCustomerMerchantStorage()
        lock.unlock()
        current?.stopCustomerWork()
    }

    private static func makeKmp(_ configuration: VeyraSoftPOSConfiguration) -> SoftposKmp {
        SoftposKmp(
            config: SoftposKmpConfig(
                environmentName: configuration.environment.rawValue,
                // Internal plumbing, not developer API: nil selects the SDK's
                // environment-resolved defaults. ObjC-exported initializers carry no
                // default arguments, so these parameters must be passed explicitly.
                localBaseUrlOverride: nil,
                remoteLogsUrlOverride: nil,
                // The App ID prefix App Attest binds the device proof to, read from the app's
                // own Keychain access group — a platform fact, detected rather than configured.
                appleTeamId: KeychainMerchantKeyStore().appIDPrefix()
            )
        )
    }

    /// Contactless tap acceptance — the customer's Android Veyra wallet taps this iPhone.
    /// Reads Veyra's own application over CoreNFC; no Apple entitlement beyond
    /// standard NFC tag reading, no scheme-card reading. Start a tap with `tap.start`.
    public var tap: Tap { Tap(owner: self) }

    fileprivate func requireKmp() throws -> SoftposKmp {
        lock.lock()
        defer { lock.unlock() }
        guard let kmp else {
            throw configuration == nil ? VeyraError.notConfigured : VeyraError.notSignedIn
        }
        return kmp
    }

    fileprivate func call<T>(_ body: (SoftposKmp) async throws -> T) async throws -> T {
        let kmp = try requireKmp()
        do {
            return try await body(kmp)
        } catch let error as VeyraError {
            throw error
        } catch {
            throw Self.setupError(error)
        }
    }

    /// Every operation returns its outcome; what the shared core still throws is a setup error,
    /// whose message starts with its code (`INVALID_CONFIGURATION: …`). Anything else would be an
    /// SDK defect and is passed on unchanged rather than dressed up as an outcome.
    static func setupError(_ error: Error) -> Error {
        let message = error.localizedDescription
        if message.hasPrefix("NOT_SIGNED_IN") { return VeyraError.notSignedIn }
        if message.hasPrefix("NOT_CONFIGURED") { return VeyraError.notConfigured }
        if message.hasPrefix("SESSION_REQUIRED") { return VeyraError.sessionRequired }
        if message.hasPrefix("UNSUPPORTED_ON_PLATFORM") { return VeyraError.unsupportedOnPlatform }
        if message.hasPrefix("INVALID_CONFIGURATION") { return VeyraError.invalidConfiguration(message: message) }
        return error
    }

    /// A status / activate / deactivate answer as the public outcome, folding an answered status
    /// into the stored merchant.
    fileprivate func merchantStatusOutcome(_ r: VeyraKMP.MerchantStatusResult) -> MerchantStatusResult {
        if let id = r.merchantId, let status = r.merchantStatus {
            updateStoredMerchantStatus(merchantID: id, status: status)
        }
        return MerchantStatusResult(merchantID: r.merchantId, merchantStatus: r.merchantStatus,
                              responseStatus: r.responseStatus.isEmpty ? ResponseStatus.failed : r.responseStatus,
                              responseStatusReason: r.responseStatusReason, message: r.message)
    }

    // Stored-merchant plumbing — SDK-owned file persistence (`FileMerchantStorage`), the iOS twin of
    // Android's MerchantDataStore. Internal (not fileprivate) so tests can drive it directly.

    private func withMerchantStorage<T>(_ body: (MerchantStorage) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(merchantStorage)
    }

    internal func loadStoredMerchant() -> StoredMerchant? {
        withMerchantStorage { $0.load() }
    }

    /// The registered merchant as the KMP tap/CPM enrichment (9F4E/9F15/DF0E/DF0F + the
    /// `/payment` merchant ids). `nil` when unregistered — both rails then go out with empty
    /// merchant fields, exactly as an unregistered tap does. Shared by the tap and CPM flows so
    /// both source the same values (the Android reader sources them from `MerchantDataStore`).
    internal func storedTapMerchant() -> TapMerchant? {
        loadStoredMerchant().map { m in
            TapMerchant(
                merchantName: m.merchantName,
                addressLine1: m.addressLine1,
                addressLine2: m.addressLine2,
                city: m.city,
                state: m.state,
                categoryCode: m.merchantCategoryCode,
                accountNumber: m.accountNumber,
                institutionCode: m.institutionCode,
                merchantId: m.merchantID,
                acquirerId: m.acquirerID
            )
        }
    }

    internal func saveStoredMerchant(_ merchant: StoredMerchant) {
        withMerchantStorage { $0.save(merchant) }
    }

    /// Refresh the stored status; a response for a different merchant leaves storage untouched.
    ///
    /// This is iOS's **single fire site** for the merchant-status observer — the twin of Android's
    /// `MerchantDataStore.updateMerchantStatus`. Every route that changes the stored status arrives
    /// here (the SDK-owned watch, and the host calling `status`/`activate`/`deactivate`), so one
    /// hook covers them all. The store is written first and the observer told after; the shared
    /// Kotlin rule decides whether anything actually changed, so the two platforms cannot disagree
    /// about what counts as a change.
    internal func updateStoredMerchantStatus(merchantID: String, status: String?) {
        // Outer nil: nothing was written. Inner: the status the stored merchant had before.
        let written: String?? = withMerchantStorage { storage in
            guard let stored = storage.load(), stored.merchantID == merchantID else { return nil }
            let was = stored.merchantStatus
            storage.save(stored.updatingStatus(status))
            return .some(was)
        }
        // No stored merchant, or a response for a different one — nothing was written, so there is
        // nothing to announce. This guard once tested only `status`, so an answer for a
        // logged-out merchant reached the observer as `nil → ACTIVE` — a "change" — on every poll.
        // `status` nil means "not stated", which is not a change to report either.
        guard case .some(let previous) = written, let status, let kmp = try? requireKmp() else { return }
        kmp.notifyMerchantStatusChanged(merchantId: merchantID, previousStatus: previous, newStatus: status)
    }

    /// Start the SDK-owned merchant watches for the stored merchant, if there is one: the status
    /// poll, the pending-outcome and credit sweeps, and the MPM settle watches.
    ///
    /// §16: the SDK owns the waiting and the app process is its scope. Called at `configure` and
    /// after a successful registration — never by a screen, and never stopped by one; `signOut`
    /// (or another customer signing in) stops them. They never run while no merchant is stored.
    internal func startMerchantWatchesIfRegistered() {
        guard let merchant = loadStoredMerchant(), let kmp = try? requireKmp() else { return }
        kmp.startMerchantWatches(
            merchantId: merchant.merchantID,
            intervalSeconds: Int64(Self.merchantStatusWatchIntervalSeconds)
        ) { [weak self] status in
            // Land it in the stored merchant, which is what fires the observer (above).
            self?.updateStoredMerchantStatus(merchantID: merchant.merchantID, status: status)
        }
    }

    /// Names of the merchant watches running — test support.
    internal func activeMerchantWatches() -> [String] {
        (try? requireKmp())?.activeMerchantWatches() ?? []
    }

    /// Test hook: the current instance, so a test can check the instance that *was* running
    /// after a sign-out drops it.
    internal var currentKmpForTesting: SoftposKmp? {
        lock.lock()
        defer { lock.unlock() }
        return kmp
    }

    /// How often the merchant-status watch asks, in seconds. Matches the Android scheduler's
    /// 5-minute default; the Kotlin side floors it so a bad value cannot become a request storm.
    private static let merchantStatusWatchIntervalSeconds = 300

    /// Fold a successful profile update into storage (same different-merchant guard as above).
    /// the response's gateway-assigned identity (terminal id, provider-resolved
    /// acquirer id, wallet account id) is folded in with it.
    internal func applyStoredMerchantUpdate(
        _ update: MerchantUpdate,
        merchantID: String,
        terminalID: String?,
        acquirerID: String?,
        walletAccountID: String?,
        status: String?
    ) {
        withMerchantStorage { storage in
            guard let stored = storage.load(), stored.merchantID == merchantID else { return }
            storage.save(stored.applying(update, status: status, terminalID: terminalID,
                                         acquirerID: acquirerID, walletAccountID: walletAccountID))
        }
    }

    /// Test hook: swap the file store for an in-memory store.
    internal func replaceMerchantStorage(_ storage: MerchantStorage) {
        lock.lock()
        defer { lock.unlock() }
        merchantStorage = storage
    }

    // ── The stored merchant ─────────────────────────────────────────────────────────────────

    /// What an operation that needs the stored merchant answers when there is none: refused on
    /// the phone, nothing sent — `FAILED` / `MISSING_MANDATORY_CONFIG`, the same refusal Android
    /// and React Native give. Never thrown: it is an outcome, not a setup mistake.
    static let noMerchantReason = "MISSING_MANDATORY_CONFIG"
    static let noMerchantMessage = "No merchant is registered on this device"

    /// The stored merchant's ID, or the failure line for an operation that needed one and found
    /// none. Setup errors come first (`notConfigured` / `notSignedIn`), as on Android.
    /// - Parameter status: the refusal's status — `NOT_SENT` for a payment call (nothing was sent),
    ///   `FAILED` for every other call (`devices` outcome rule: `NOT_SENT` is for payments only).
    private func requireStoredMerchantID(operation: String, action: String?,
                                         status: String = ResponseStatus.failed) throws -> String? {
        let kmp = try requireKmp()
        if let id = loadStoredMerchant()?.merchantID, !id.trimmingCharacters(in: .whitespaces).isEmpty {
            return id
        }
        // One failure line for the refusal (`devices/CLAUDE.md` §25), like every other outcome.
        kmp.logRefusal(operation: operation, action: action, status: status,
                       reason: Self.noMerchantReason)
        return nil
    }

    private static func noMerchantStatus() -> MerchantStatusResult {
        MerchantStatusResult(merchantID: nil, merchantStatus: nil, responseStatus: ResponseStatus.failed,
                       responseStatusReason: noMerchantReason, message: noMerchantMessage)
    }

    /// The merchant registered on this device for `customerID`, read **without configuring the
    /// SDK** — nothing is signed in, started or claimed. For the Home screen: decide whether to
    /// offer "Get paid" before the payment screen configures the SDK.
    ///
    /// Reads that customer's own merchant, whoever else is signed in. `nil` when they have none
    /// on this device, or when `customerID` is blank.
    public static func storedMerchantData(customerID: String) -> StoredMerchant? {
        storedMerchantData(customerID: customerID, keyStore: KeychainMerchantKeyStore(),
                       directoryName: FileMerchantStorage.defaultDirectoryName)
    }

    /// Whether `customerID` has a merchant registered on this device with every field a payment
    /// needs — ``isRegistered()`` for a customer, read **without configuring the SDK**.
    public static func isMerchantRegistered(customerID: String) -> Bool {
        isMerchantRegistered(customerID: customerID, keyStore: KeychainMerchantKeyStore(),
                             directoryName: FileMerchantStorage.defaultDirectoryName)
    }

    internal static func isMerchantRegistered(customerID: String, keyStore: MerchantKeyStore,
                                              directoryName: String) -> Bool {
        storedMerchantData(customerID: customerID, keyStore: keyStore, directoryName: directoryName)?
            .isTransactionReady ?? false
    }

    /// The init-free read over an injectable key store and directory (tests).
    internal static func storedMerchantData(customerID: String, keyStore: MerchantKeyStore,
                                        directoryName: String) -> StoredMerchant? {
        guard !customerID.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let partition = CustomerScope.shared.partitionKeyFor(customerId: customerID)
        return FileMerchantStorage(partition: partition, keyStore: keyStore, directoryName: directoryName).load()
    }

    /// The merchant persisted on this device by the last successful ``register(_:)``, if any.
    /// SDK-owned storage (protected sandbox file) — survives app restarts, cleared on uninstall.
    /// `nil` while no customer is signed in.
    public func storedMerchantData() -> StoredMerchant? { loadStoredMerchant() }

    /// The stored merchant's ID, or `nil` when no merchant is registered on this device.
    public func storedMerchantID() -> String? {
        loadStoredMerchant()?.merchantID.nilIfBlank
    }

    /// Whether a merchant is stored on this device (it may still lack a field a payment needs —
    /// gate payments on ``isRegistered()``).
    public func hasStoredMerchant() -> Bool { storedMerchantID() != nil }

    /// True when a merchant is registered on this device with every transaction-required field
    /// (merchant ID, terminal ID, name, acquirer ID, MCC, country code). Gate registration UI on this.
    public func isRegistered() -> Bool { loadStoredMerchant()?.isTransactionReady ?? false }

    /// Whether the stored merchant may take payments, by its last known status — the same reading
    /// the SDK's payment gate makes. `false` when no merchant is stored. A merchant stored before
    /// statuses were kept (no status) still reads as active.
    public func isMerchantActive() -> Bool {
        guard let merchant = loadStoredMerchant() else { return false }
        return SoftposMerchantStatusRule.shared.allowsPayments(status: merchant.merchantStatus)
    }

    // ── Merchant lifecycle ──────────────────────────────────────────────────────────────────

    /// Fetch the NUBAN settlement banks — an outcome, never a thrown failure.
    public func banks() async throws -> SettlementBankList {
        try await call { kmp in
            let r = try await kmp.banks()
            return SettlementBankList(
                banks: r.banks.map { Bank(slug: $0.slug, name: $0.name, institutionCode: $0.institutionCode) },
                responseStatus: r.responseStatus.isEmpty ? ResponseStatus.failed : r.responseStatus,
                responseStatusReason: r.responseStatusReason,
                message: r.message
            )
        }
    }

    /// Register a merchant (personal or business). A registered merchant is stored on this device
    /// and becomes the merchant every other call uses.
    public func register(_ registration: MerchantRegistration) async throws -> MerchantRegistrationResult {
        try await call { kmp in
            let r = try await kmp.register(
                request: MerchantRegistrationRequest(
                    merchantType: registration.merchantType.rawValue,
                    merchantName: registration.merchantName,
                    emailAddress: registration.emailAddress,
                    phoneNumber: registration.phoneNumber,
                    addressLine1: registration.addressLine1,
                    addressLine2: registration.addressLine2,
                    city: registration.city,
                    state: registration.state,
                    countryCode: registration.countryCode,
                    bvn: registration.bvn,
                    cacNumber: registration.cacNumber,
                    accountNumber: registration.accountNumber,
                    institutionCode: registration.institutionCode,
                    // The provider credential from the configuration; the gateway
                    // resolves the acquirer id and MCC from it. No acquirer id is sent.
                    paymentAppProviderId: paymentAppProviderID,
                    walletAccountId: registration.walletAccountID
                )
            )
            // Persist the registration — same fold as Android's MerchantService:
            // response-assigned fields win, terminal ID falls back to the merchant ID.
            if r.success, let merchantID = r.merchantId {
                saveStoredMerchant(
                    StoredMerchant(
                        registration: registration,
                        merchantID: merchantID,
                        terminalID: r.terminalId,
                        merchantStatus: r.merchantStatus,
                        merchantCategoryCode: r.merchantCategoryCode,
                        countryCode: r.countryCode,
                        // Gateway-resolved; there is no submitted value to fall back to.
                        acquirerID: r.acquirerId,
                        walletAccountID: r.walletAccountId ?? registration.walletAccountID
                    )
                )
                // There is now a merchant to watch. This is also the activation moment — a
                // merchant registered as PENDING and activated minutes later is exactly the
                // transition the app is waiting on.
                startMerchantWatchesIfRegistered()
            }
            return MerchantRegistrationResult(
                success: r.success,
                merchantID: r.merchantId,
                terminalID: r.terminalId,
                merchantStatus: r.merchantStatus,
                message: r.message,
                responseStatus: r.responseStatus.isEmpty ? ResponseStatus.failed : r.responseStatus,
                responseStatusReason: r.responseStatusReason
            )
        }
    }

    /// Read the stored merchant's backend status now, and fold it into the stored merchant (which
    /// also fires ``observeMerchantStatusChanged(_:)`` when it changed). No stored merchant is
    /// `FAILED` / `MISSING_MANDATORY_CONFIG`.
    public func refreshStatus() async throws -> MerchantStatusResult {
        guard let merchantID = try requireStoredMerchantID(
            operation: SdkOperation.shared.MERCHANT_STATUS, action: SdkAction.shared.REFRESH
        ) else { return Self.noMerchantStatus() }
        return try await call { kmp in
            merchantStatusOutcome(try await kmp.merchantStatus(merchantId: merchantID))
        }
    }

    /// Activate the stored merchant. No stored merchant is `FAILED` / `MISSING_MANDATORY_CONFIG`.
    public func activate() async throws -> MerchantStatusResult {
        guard let merchantID = try requireStoredMerchantID(
            operation: SdkOperation.shared.MERCHANT_STATUS, action: SdkAction.shared.ACTIVATE_MERCHANT
        ) else { return Self.noMerchantStatus() }
        return try await call { kmp in
            merchantStatusOutcome(try await kmp.activateMerchant(merchantId: merchantID))
        }
    }

    /// Deactivate the stored merchant. No stored merchant is `FAILED` / `MISSING_MANDATORY_CONFIG`.
    public func deactivate() async throws -> MerchantStatusResult {
        guard let merchantID = try requireStoredMerchantID(
            operation: SdkOperation.shared.MERCHANT_STATUS, action: SdkAction.shared.DEACTIVATE_MERCHANT
        ) else { return Self.noMerchantStatus() }
        return try await call { kmp in
            merchantStatusOutcome(try await kmp.deactivateMerchant(merchantId: merchantID))
        }
    }

    /// Update the stored merchant's profile. No stored merchant is `FAILED` /
    /// `MISSING_MANDATORY_CONFIG`.
    public func updateMerchant(_ update: MerchantUpdate) async throws -> MerchantStatusResult {
        guard let merchantID = try requireStoredMerchantID(
            operation: SdkOperation.shared.MERCHANT_UPDATE, action: nil
        ) else { return Self.noMerchantStatus() }
        return try await call { kmp in
            let r = try await kmp.updateMerchant(
                merchantId: merchantID,
                request: MerchantUpdateRequest(
                    merchantName: update.merchantName,
                    emailAddress: update.emailAddress,
                    phoneNumber: update.phoneNumber,
                    addressLine1: update.addressLine1,
                    addressLine2: update.addressLine2,
                    city: update.city,
                    state: update.state,
                    countryCode: update.countryCode,
                    accountNumber: update.accountNumber,
                    institutionCode: update.institutionCode,
                    paymentAppProviderId: paymentAppProviderID,
                    walletAccountId: update.walletAccountID,
                    bvn: update.bvn
                )
            )
            // Fold the gateway-assigned identity from the update response into the stored
            // merchant (terminal id, provider-resolved acquirer id, wallet account) — only when
            // the gateway answered.
            if let answeredID = r.merchantId {
                applyStoredMerchantUpdate(update, merchantID: answeredID,
                                          terminalID: r.terminalId,
                                          acquirerID: r.acquirerId,
                                          walletAccountID: r.walletAccountId,
                                          status: r.merchantStatus)
            }
            return MerchantStatusResult(merchantID: r.merchantId, merchantStatus: r.merchantStatus,
                                  responseStatus: r.responseStatus.isEmpty ? ResponseStatus.failed : r.responseStatus,
                                  responseStatusReason: r.responseStatusReason, message: r.message)
        }
    }

    // ── Observers ───────────────────────────────────────────────────────────────────────────

    /// Observe the merchant's backend status changing — deactivated, suspended, or activated.
    ///
    /// **Why you want this.** A merchant deactivated or suspended mid-session should stop your
    /// app offering to take payments *at once*, not whenever a screen next calls
    /// ``refreshStatus()``. It is also how you see the **activation** moment after registering,
    /// without polling for it yourself.
    ///
    /// The SDK owns the polling and it is **app-scoped**, not screen-scoped: it starts at
    /// `configure` (and after a successful `register`) and keeps running as the merchant
    /// navigates — no screen starts it and no screen may stop it.
    ///
    /// iOS suspends timers when the OS suspends the app, so polling pauses while backgrounded and
    /// resumes on foreground. **No answer is lost** — the status lives in the SDK's store and the
    /// comparison is against what was persisted, so a change that happened while you were away is
    /// still reported on the first poll after you return.
    ///
    /// Act on `canAcceptPayments`, not on `status`: it is the SDK's own reading, so you can never
    /// be more permissive than the gate that would refuse the sale. `previousStatus` is `nil` when
    /// this device had no status for the merchant yet.
    ///
    /// Callbacks arrive on the main thread. Observing again replaces the previous observer;
    /// ``stopObservingMerchantStatusChanged()`` clears it. Register once, at start-up.
    public func observeMerchantStatusChanged(
        _ observer: @escaping @Sendable (MerchantStatusEvent) -> Void
    ) throws {
        let kmp = try requireKmp()
        kmp.observeMerchantStatus { merchantID, status, canAcceptPayments, previousStatus in
            observer(
                MerchantStatusEvent(
                    merchantID: merchantID,
                    status: status,
                    canAcceptPayments: canAcceptPayments.boolValue,
                    previousStatus: previousStatus
                )
            )
        }
    }

    /// Stop observing merchant status; no further callbacks fire.
    public func stopObservingMerchantStatusChanged() throws {
        try requireKmp().stopObservingMerchantStatusChanged()
    }

    /// Observe payments that stop being pending — the push half of ``transactions(limit:)``.
    ///
    /// A tap or QR sale that gets no answer hands the app a `PENDING` result, and the SDK then
    /// polls it to a final status in the background. This fires the moment one settles, so a
    /// screen showing "processing" can finish without a timer of its own. It fires for **any**
    /// transaction that resolves — including one started in an earlier app launch — so match
    /// `resolution.reference` to the sale you care about.
    ///
    /// **A notification, never the source of truth.** There is no replay on registration: an app
    /// that was not running when the row settled learns about it from ``transactions(limit:)``.
    ///
    /// Callbacks arrive on the main thread. Observing again replaces the previous observer;
    /// ``stopObservingTransactionResolved()`` clears it. Register once, at start-up.
    ///
    /// ```swift
    /// try softpos.observeTransactionResolved { resolution in
    ///     guard resolution.reference == self.pendingReference else { return }
    ///     self.show(status: resolution.status, code: resolution.responseCode)
    /// }
    /// ```
    public func observeTransactionResolved(
        _ observer: @escaping @Sendable (TransactionResolvedEvent) -> Void
    ) throws {
        let kmp = try requireKmp()
        kmp.observeTransactionResolved { reference, responseCode, status, reason in
            observer(TransactionResolvedEvent(merchantTransactionReference: reference, responseCode: responseCode,
                                           status: status, reason: reason))
        }
    }

    /// Stop observing resolved transactions; no further callbacks fire.
    public func stopObservingTransactionResolved() throws {
        try requireKmp().stopObservingTransactionResolved()
    }

    /// Observe beneficiary credit confirmations — the answer the SDK's background sweep is waiting
    /// for after an approved sale whose response said `isCreditConfirmationSupported`.
    ///
    /// Fires once per sale, with `"RECEIVED"` (the funds are in the merchant's account) or
    /// `"UNABLE_TO_CONFIRM"` (the 30-day window closed unconfirmed — a give-up, not a reversal).
    /// Settlement confirmation only: it never changes the payment outcome.
    ///
    /// The polling is the SDK's and is **app-scoped**: it keeps running as the merchant navigates
    /// away from the result screen, and resumes when the app returns to the foreground. The
    /// confirmation is written to the transaction's stored row
    /// (`MerchantTransaction.creditConfirmationStatus`) as well as announced here, so a screen that
    /// appears later still shows it.
    ///
    /// Callbacks arrive on the main thread. Observing again replaces the previous observer;
    /// ``stopObservingCreditConfirmation()`` clears it. Register once, at start-up.
    public func observeCreditConfirmation(
        _ observer: @escaping @Sendable (CreditConfirmationEvent) -> Void
    ) throws {
        let kmp = try requireKmp()
        kmp.observeCreditConfirmation { reference, creditTransactionID, status, amountMinorUnits, bankReference, creditedAt in
            observer(
                CreditConfirmationEvent(
                    merchantTransactionReference: reference,
                    creditTransactionID: creditTransactionID,
                    status: status,
                    amountMinorUnits: amountMinorUnits?.int64Value,
                    bankReference: bankReference,
                    creditedAt: creditedAt
                )
            )
        }
    }

    /// Stop observing credit confirmations; no further callbacks fire.
    public func stopObservingCreditConfirmation() throws {
        try requireKmp().stopObservingCreditConfirmation()
    }

    // ── Tap state ───────────────────────────────────────────────────────────────────────────

    /// True while a tap payment is mid-flight: a card has been detected and its dialogue, or the
    /// online leg after it, is running. A tap that is armed and waiting for a card is not in
    /// progress (see ``isAwaitingCardTap()``).
    public func isTransactionInProgress() -> Bool { currentTapPhase() == .inProgress }

    /// True while a tap payment is armed and waiting for a card — started with `tap.start`, no
    /// card seen yet.
    public func isAwaitingCardTap() -> Bool { currentTapPhase() == .awaitingCard }

    private func currentTapPhase() -> TapPaymentSession.Phase {
        lock.lock()
        let session = currentTap
        lock.unlock()
        return session?.phase ?? .ended
    }

    /// Hold the tap now running, so its reader outlives the call that started it and the tap
    /// state can be read.
    func tapStarted(_ session: TapPaymentSession) {
        lock.lock()
        currentTap = session
        lock.unlock()
    }

    /// Drop a finished tap, unless a newer one has replaced it.
    func tapEnded(_ session: TapPaymentSession) {
        lock.lock()
        if currentTap === session { currentTap = nil }
        lock.unlock()
    }

    // ── Cancel ──────────────────────────────────────────────────────────────────────────────

    /// Run a SoftPOS payment so that cancelling the awaiting Swift `Task` cancels it by its order
    /// ID (before it is sent; after, the normal result is returned).
    private func cancellable<T>(_ merchantOrderID: String, _ body: () async throws -> T) async throws -> T {
        try await TaskCancelBridge.run(
            cancel: { [self] in cancelPayment(merchantOrderID: merchantOrderID) },
            notFound: .noPaymentInProgressForOrderID,
            body
        )
    }

    // ── Customer QR (CPM) ───────────────────────────────────────────────────────────────────

    /// Inspect a scanned **customer** QR (consumer-presented payment). `FAILED` /
    /// `INVALID_REQUEST` when the payload is not a valid Veyra payment QR: show a transient hint
    /// and stay armed for another scan. On `APPROVED` the QR's amount/currency come from its
    /// cryptogram — display them for the merchant to **confirm**; the amount is never keyed.
    public func inspectCustomerQr(_ payload: String) async throws -> CustomerQrInspection {
        try await call { kmp in
            let inspection = try kmp.inspectCpmQr(payload: payload)
            let qr = inspection.qr.map { scanned in
                ScannedCustomerQr(
                    maskedCard: scanned.maskedCard,
                    amountMinorUnits: scanned.amountMinorUnits,
                    currencyCode: scanned.currencyCode,
                    cardholderName: scanned.cardholderName,
                    raw: scanned
                )
            }
            return CustomerQrInspection(
                qr: qr,
                responseStatus: inspection.responseStatus,
                responseStatusReason: inspection.responseStatusReason,
                message: inspection.message
            )
        }
    }

    /// Charge a merchant-confirmed scanned customer QR over the standard payment rail. The amount
    /// charged is the QR's own (cryptogram-bound) amount — a tampered payload or a different
    /// amount declines at the token provider.
    /// - Parameter merchantOrderID: your own order/basket/invoice id for this sale.
    ///   **Required** and non-blank — a blank one is a `NOT_SENT` / `INVALID_REQUEST` outcome.
    ///   The SDK mints the transaction reference itself; this is the field for *your*
    ///   identifier. Reusable until the order is `APPROVED` or `PENDING`; after that a reused one
    ///   is refused `94` / `FAILED` / `DUPLICATE_MERCHANT_ORDER_ID` — do not take another payment
    ///   for the order.
    public func chargeCustomerQr(
        _ scanned: ScannedCustomerQr,
        merchantOrderID: String
    ) async throws -> CustomerQrChargeOutcome {
        try await cancellable(merchantOrderID) { try await call { kmp in
            // Apply the registered merchant so the /payment request carries
            // merchant_id/acquirer_id/mcc/name/location — the CPM twin of the tap's enrichment.
            let response = try await kmp.chargeCpmQr(
                scanned: scanned.raw,
                merchant: storedTapMerchant(),
                merchantTransactionReference: nil,
                merchantOrderId: merchantOrderID
            )
            // The reference comes back from the gateway, it is not made here. The shared outcome
            // already carries the status as the gateway stated it (absent or unrecognised →
            // PENDING, never a refusal), the same mapping Android uses.
            return CustomerQrChargeOutcome(
                approved: response.approved,
                responseStatus: response.responseStatus,
                responseStatusReason: response.responseStatusReason,
                responseCode: response.responseCode,
                message: response.message,
                transactionID: response.transactionId,
                merchantTransactionReference: response.merchantTransactionReference,
                merchantOrderID: response.merchantOrderId ?? merchantOrderID,
                creditTransactionID: response.creditTransactionId,
                isCreditConfirmationSupported: response.isCreditConfirmationSupported?.boolValue,
                originalPayment: OriginalPayment(response.originalPayment)
            )
        } }
    }

    // ── Merchant QR (MPM) ───────────────────────────────────────────────────────────────────

    /// Create a gateway-signed payment QR for a sale by the stored merchant; render the returned
    /// `mpmPayload` as the QR verbatim. No stored merchant is `NOT_SENT` / `MISSING_MANDATORY_CONFIG`
    /// — a payment that was never sent.
    /// - Parameters:
    ///   - amountMinorUnits: the amount in minor units (kobo for NGN).
    ///   - currency: ISO 4217 numeric, default `"566"` (NGN); leading zeros accepted.
    ///   - merchantOrderID: your own order/basket/invoice id for the sale this QR represents.
    ///     **Required** and non-blank — a blank one is a `NOT_SENT` / `INVALID_REQUEST` outcome.
    ///     One already used by another of the merchant's payments is `FAILED` /
    ///     `DUPLICATE_MERCHANT_ORDER_ID` — create the QR with a different one.
    ///   - onExpired: called once, on the main thread, when the created QR reaches its `expiry`.
    ///     Blank or replace the code so it can't be scanned once lapsed. The SDK owns the timer: a
    ///     new `createPaymentContext` supersedes it, and ``cancelQrExpiry()`` stops it.
    public func createPaymentContext(
        amountMinorUnits: Int64,
        currency: String = "566",
        merchantOrderID: String,
        onExpired: (() -> Void)? = nil
    ) async throws -> PaymentContextQr {
        guard let merchantID = try requireStoredMerchantID(
            operation: SdkOperation.shared.MPM_CONTEXT, action: SdkAction.shared.CREATE,
            status: ResponseStatus.notSent
        ) else {
            return PaymentContextQr(txRef: nil, expiry: nil, kid: nil, mpmPayload: nil,
                                    responseStatus: ResponseStatus.notSent,
                                    responseStatusReason: Self.noMerchantReason,
                                    message: Self.noMerchantMessage)
        }
        return try await cancellable(merchantOrderID) { try await call { kmp in
            let created = try await kmp.createContextPayment(
                merchantId: merchantID,
                amountMinorUnits: amountMinorUnits,
                currency: currency,
                onExpired: onExpired,
                merchantOrderId: merchantOrderID
            )
            return PaymentContextQr(
                txRef: created.txRef,
                expiry: created.expiry,
                kid: created.kid,
                mpmPayload: created.mpmPayload,
                responseStatus: created.responseStatus,
                responseStatusReason: created.responseStatusReason,
                message: created.message,
                originalPayment: OriginalPayment(created.originalPayment)
            )
        } }
    }

    /// Poll a payment QR's lifecycle (PENDING / IN_FLIGHT / APPROVED / DECLINED / EXPIRED). A poll
    /// that could not be made carries ``VeyraLookup/failureReason`` and no state.
    public func contextStatus(txRef: String) async throws -> VeyraLookup<PaymentContextStatus> {
        try await call { kmp in
            let lookup = try await kmp.contextStatus(txRef: txRef)
            guard let status = lookup.value else {
                return VeyraLookup(value: nil, failureReason: lookup.failureReason, message: lookup.message)
            }
            return VeyraLookup(value: PaymentContextStatus(
                txRef: status.txRef,
                state: status.state,
                responseCode: status.responseCode,
                transactionHash: status.transactionHash
            ))
        }
    }

    /// Stop the payment-QR expiry watch started by ``createPaymentContext(amountMinorUnits:currency:merchantOrderID:onExpired:)``.
    /// Call on teardown (the QR page is left) so `onExpired` can't fire into dead UI. Idempotent.
    public func cancelQrExpiry() {
        (try? requireKmp()).map { $0.cancelQrExpiry() }
    }

    // ── Transactions ────────────────────────────────────────────────────────────────────────

    /// The merchant's locally kept transactions across every rail (tap, merchant QR, customer QR),
    /// most recent first — the SDK records each payment taken, so this needs no backend round trip.
    public func transactions(limit: Int = 50) async throws -> [MerchantTransaction] {
        try await call { kmp in
            try await kmp.merchantTransactions(limit: Int32(clamping: limit)).map(Self.map)
        }
    }

    /// One locally kept transaction by its merchant transaction reference, or `nil` when this
    /// device has no such reference. A local read: nothing is sent.
    public func transaction(merchantTransactionReference: String) async throws -> MerchantTransaction? {
        try await call { kmp in
            try await kmp.merchantTransaction(reference: merchantTransactionReference).map(Self.map)
        }
    }

    /// Build the receipt for one transaction: display fields plus a `qrPayload` JSON scannable by
    /// the wallet's receipt scanner. The registered merchant's name/address are folded in. `nil`
    /// when the reference is unknown.
    public func receipt(merchantTransactionReference: String) async throws -> MerchantReceipt? {
        let merchant = loadStoredMerchant()
        let name = merchant?.merchantName ?? ""
        let address = [merchant?.addressLine1, merchant?.addressLine2, merchant?.city, merchant?.state, merchant?.countryCode]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return try await call { kmp in
            guard let r = try await kmp.merchantReceipt(reference: merchantTransactionReference,
                                                        merchantName: name, merchantAddress: address) else {
                return nil
            }
            return MerchantReceipt(
                merchantName: r.merchantName,
                merchantAddress: r.merchantAddress,
                transactionType: r.transactionType,
                totalAmountMinorUnits: r.totalAmountMinorUnits,
                totalAmountFormatted: r.totalAmountFormatted,
                maskedToken: r.maskedToken,
                merchantTransactionReference: r.reference,
                transactionHash: r.transactionHash,
                qrPayload: r.qrPayload,
                cardholderName: r.cardholderName
            )
        }
    }

    /// What happened to a merchant order, by **your own order ID** — the one you passed to the
    /// tap, ``createPaymentContext(amountMinorUnits:currency:merchantOrderID:onExpired:)`` or
    /// ``chargeCustomerQr(_:merchantOrderID:)``. Works for all three rails; you don't say which.
    ///
    /// The order's status is decided by precedence over all its attempts: any `APPROVED`, else any
    /// `PENDING`, else the latest attempt (`DECLINED`, `FAILED` or `RETRY`); an order with no
    /// attempts is `RETRY` / `25` / `UNABLE_TO_LOCATE_RECORD`. ``OrderPaymentStatus/attempts`` lists
    /// every attempt. Answered from this phone's own record when it is final, otherwise from the
    /// gateway — combined with this phone's own attempts.
    ///
    /// A read: when the gateway could not be asked, `failureReason` says why and `value` is what
    /// this phone holds for the order, if anything. Only a setup mistake throws.
    public func paymentStatus(merchantOrderID: String) async throws -> VeyraLookup<OrderPaymentStatus> {
        let merchantID = loadStoredMerchant()?.merchantID
        return try await call { kmp in
            let r = try await kmp.paymentStatus(merchantId: merchantID, merchantOrderId: merchantOrderID)
            return VeyraLookup(value: r.value.map(Self.mapOrder), failureReason: r.failureReason, message: r.message)
        }
    }

    /// Ask the gateway about **one** pending transaction now, and return the updated stored row.
    ///
    /// The on-demand counterpart to ``transactions(limit:)``, which only reads what the device
    /// already knows. The SDK polls a pending transaction for you with exponential backoff and
    /// **stops after 30 days**; this is how a merchant staring at a row gets an answer sooner, and
    /// the only route to one once that window has closed. It runs the SDK's own background check
    /// for this single row, so an on-demand check and a background one cannot disagree. A payment
    /// still unsettled answers `PENDING` again; the SDK invents nothing.
    ///
    /// Distinct from ``transactionStatus(merchantTransactionReference:transactionDate:)``, the
    /// **raw** query that returns whatever the gateway said and writes nothing.
    ///
    /// - Returns: the transaction as it stands after the check, or a `nil` value if this device has
    ///   no such reference. A check that could not be made is not thrown:
    ///   ``VeyraLookup/failureReason`` says why (`NO_NETWORK_CONNECTION` when offline) and the
    ///   stored row is unchanged.
    public func refreshTransactionStatus(merchantTransactionReference: String) async throws -> VeyraLookup<MerchantTransaction> {
        try await call { kmp in
            let lookup = try await kmp.refreshTransactionStatus(reference: merchantTransactionReference)
            return VeyraLookup(value: lookup.value.map(Self.map),
                               failureReason: lookup.failureReason, message: lookup.message)
        }
    }

    /// Check the merchant credit **now** for one approved sale — "has my bank actually received
    /// the funds?" — and return the updated stored row.
    ///
    /// The SDK already asks this in the background for **30 days** after the sale, then records
    /// `"UNABLE_TO_CONFIRM"` — *"we stopped asking"*, never *"the funds were not received"*. This
    /// still works once that window has closed, and a later `"RECEIVED"` replaces the give-up.
    ///
    /// Offer it only while
    /// ```swift
    /// txn.status == "APPROVED"
    ///     && txn.isCreditConfirmationSupported == true
    ///     && txn.creditConfirmationStatus != "RECEIVED"
    /// ```
    /// A call on a row that fails that predicate makes **no network request** and returns the row
    /// unchanged. It writes the stored row and fires ``observeCreditConfirmation(_:)``, exactly as the
    /// background check does. Settlement only: nothing here changes the sale's outcome.
    ///
    /// A check that could not be made is not thrown: ``VeyraLookup/failureReason`` says why.
    public func refreshCreditConfirmation(merchantTransactionReference: String) async throws -> VeyraLookup<MerchantTransaction> {
        try await call { kmp in
            let lookup = try await kmp.refreshCreditConfirmation(reference: merchantTransactionReference)
            return VeyraLookup(value: lookup.value.map(Self.map),
                               failureReason: lookup.failureReason, message: lookup.message)
        }
    }

    /// The gateway's raw status for one of the stored merchant's transactions. `transactionDate`
    /// is `YYYY-MM-DD`. Writes nothing — ``refreshTransactionStatus(merchantTransactionReference:)``
    /// is the check that updates the stored row. No stored merchant is a `failureReason` of
    /// `MISSING_MANDATORY_CONFIG`.
    public func transactionStatus(
        merchantTransactionReference: String,
        transactionDate: String
    ) async throws -> VeyraLookup<[TransactionStatus]> {
        guard let merchantID = try requireStoredMerchantID(
            operation: SdkOperation.shared.TRANSACTION_STATUS, action: nil
        ) else {
            return VeyraLookup(value: nil, failureReason: Self.noMerchantReason, message: Self.noMerchantMessage)
        }
        return try await call { kmp in
            let lookup = try await kmp.transactionStatus(
                merchantId: merchantID,
                merchantTransactionReference: merchantTransactionReference,
                transactionDate: transactionDate
            )
            guard lookup.failureReason == nil else {
                return VeyraLookup(value: nil, failureReason: lookup.failureReason, message: lookup.message)
            }
            let items = (lookup.value as? [VeyraKMP.TransactionStatus]) ?? []
            return VeyraLookup(value: items.map {
                TransactionStatus(
                    merchantTransactionReference: $0.merchantTransactionReference,
                    merchantID: $0.merchantId,
                    amountMinorUnits: $0.amountMinorUnits?.int64Value,
                    responseCode: $0.responseCode,
                    merchantStatus: $0.merchantStatus,
                    transactionID: $0.transactionId,
                    creditTransactionID: $0.creditTransactionId,
                    isCreditConfirmationSupported: $0.isCreditConfirmationSupported?.boolValue,
                    responseStatus: $0.responseStatus,
                    responseStatusReason: $0.responseStatusReason
                )
            })
        }
    }

    /// The raw beneficiary credit confirmation for one of the stored merchant's approved sales:
    /// has the merchant's bank received the funds? Pass the sale's `creditTransactionID` and its
    /// amount in **minor units** (cross-checked by the merchant's bank). Writes nothing — the SDK
    /// polls this itself and stamps the stored row; render that, or use
    /// ``refreshCreditConfirmation(merchantTransactionReference:)`` to check now. `"RECEIVED"` is
    /// terminal; anything else means ask again later. No stored merchant is a `failureReason` of
    /// `MISSING_MANDATORY_CONFIG`.
    public func creditConfirmation(
        creditTransactionID: String,
        amountMinorUnits: Int64
    ) async throws -> VeyraLookup<CreditConfirmation> {
        guard let merchantID = try requireStoredMerchantID(
            operation: SdkOperation.shared.CREDIT_CONFIRMATION, action: nil
        ) else {
            return VeyraLookup(value: nil, failureReason: Self.noMerchantReason, message: Self.noMerchantMessage)
        }
        return try await call { kmp in
            let lookup = try await kmp.creditConfirmation(
                merchantId: merchantID,
                creditTransactionId: creditTransactionID,
                amountMinorUnits: amountMinorUnits
            )
            guard let r = lookup.value else {
                return VeyraLookup(value: nil, failureReason: lookup.failureReason, message: lookup.message)
            }
            return VeyraLookup(value: CreditConfirmation(
                creditTransactionID: r.creditTransactionId,
                status: r.status,
                amountMinorUnits: r.amountMinorUnits?.int64Value,
                creditedAt: r.creditedAt,
                bankReference: r.bankReference,
                message: r.message
            ))
        }
    }

    private static func mapOrder(_ o: VeyraKMP.OrderPaymentStatus) -> OrderPaymentStatus {
        OrderPaymentStatus(
            merchantOrderID: o.merchantOrderId,
            responseStatus: o.responseStatus,
            responseStatusReason: o.responseStatusReason,
            responseCode: o.responseCode,
            merchantTransactionReference: o.merchantTransactionReference,
            transactionID: o.transactionId,
            amountMinorUnits: o.amountMinorUnits?.int64Value,
            attempts: o.attempts.map {
                OrderPaymentAttempt(merchantTransactionReference: $0.merchantTransactionReference, transactionID: $0.transactionId,
                                    amountMinorUnits: $0.amountMinorUnits?.int64Value, responseCode: $0.responseCode,
                                    responseStatus: $0.responseStatus, responseStatusReason: $0.responseStatusReason)
            },
            answeredBy: o.answeredBy
        )
    }

    /// ISO 4217 numeric, three digits (`"0566"` → `"566"`), as every Veyra type carries it.
    private static func threeDigitCurrency(_ code: String) -> String {
        let trimmed = String(code.drop(while: { $0 == "0" }))
        return String(repeating: "0", count: max(0, 3 - trimmed.count)) + trimmed
    }

    private static func map(_ r: VeyraKMP.MerchantTransactionRecord) -> MerchantTransaction {
        MerchantTransaction(
            merchantTransactionReference: r.reference,
            merchantOrderID: r.merchantOrderId,
            rail: r.rail,
            amountMinorUnits: r.amountMinorUnits,
            currencyCode: r.currencyNumeric.map(Self.threeDigitCurrency),
            status: r.status,
            responseCode: r.responseCode,
            responseStatusReason: r.responseStatusReason,
            transactionTime: r.transactionTime,
            transactionID: r.transactionId,
            maskedTokenLast4: r.maskedTokenLast4,
            transactionHash: r.transactionHash,
            railLabel: r.railLabel,
            cardholderName: r.cardholderName,
            creditTransactionID: r.creditTransactionId,
            isCreditConfirmationSupported: r.isCreditConfirmationSupported?.boolValue,
            creditConfirmationStatus: r.creditConfirmationStatus
        )
    }

    // ── Tap ─────────────────────────────────────────────────────────────────────────────────

    /// Contactless tap acceptance (Android-wallet → iPhone rail).
    public struct Tap: Sendable {
        fileprivate let owner: VeyraSoftPOS

        /// Arm the reader for one sale. The tap's progress and its final ``TapResult`` arrive
        /// through `onEvent`, on the main queue:
        ///
        /// ```swift
        /// try softpos.tap.start(TapRequest(amountMinorUnits: 5000, merchantOrderID: "ORD-1")) { event in
        ///     switch event {
        ///     case .cardDetected: …
        ///     case .result(let result): show(result)
        ///     …
        ///     }
        /// }
        /// ```
        ///
        /// Cancel it with ``VeyraSoftPOS/cancelPayment(merchantOrderID:)`` under the request's
        /// order ID. A refusal before the reader arms — a blank order ID or a currency that is not
        /// ISO 4217 numeric (`INVALID_REQUEST`), the wallet's payment in flight (`MODE_REFUSED`) —
        /// ends the tap with a `NOT_SENT` ``TapEvent/result(_:)``; nothing is armed or sent. The
        /// registered merchant is applied to the tap.
        ///
        /// - Throws: ``VeyraError/notConfigured`` / ``VeyraError/notSignedIn``, or
        ///   ``VeyraError/invalidConfiguration(message:)`` when both SDKs are in the app
        ///   without `VeyraSDK` — setup mistakes.
        public func start(_ request: TapRequest, onEvent: @escaping @Sendable (TapEvent) -> Void) throws {
            let kmp = try owner.requireKmp()
            guard let currencyCode = request.currencyCode else {
                kmp.logRefusal(operation: SdkOperation.shared.MERCHANT_TAP, action: nil,
                               status: ResponseStatus.notSent, reason: "INVALID_REQUEST")
                TapPaymentSession.EventsBridge(onEvent: onEvent).emit(.result(TapResult.refused(
                    reason: "INVALID_REQUEST",
                    message: "currency must be an ISO 4217 numeric code, e.g. \"566\"")))
                return
            }
            let session = TapPaymentSession(
                amountMinorUnits: request.amountMinorUnits,
                currencyCode: currencyCode,
                // Enrich the tap with the registered merchant so 9F4E/9F15/DF0E/DF0F carry real
                // values (the Android reader sources these from its merchant store).
                merchant: owner.storedTapMerchant(),
                merchantOrderID: request.merchantOrderID,
                kmp: kmp,
                onEnded: { [weak owner] session in owner?.tapEnded(session) },
                onEvent: onEvent
            )
            owner.tapStarted(session)
            do {
                try session.start()
            } catch {
                owner.tapEnded(session)
                throw error
            }
        }
    }
}

/// One tap payment — a purchase — for `VeyraSoftPOS.shared.tap.start(_:onEvent:)`.
public struct TapRequest: Sendable, Hashable {
    /// The amount in **minor units** (kobo for NGN).
    public let amountMinorUnits: Int64
    /// ISO 4217 numeric currency, default `"566"` (NGN); leading zeros accepted (`"0566"`).
    public let currency: String
    /// Your own order/basket/invoice id for this sale. **Required** and non-blank — a blank one
    /// ends the tap with a `NOT_SENT` / `INVALID_REQUEST` result before the reader arms. Sent with
    /// the payment, stored on the transaction, and shown on both sides' history. Reusable after
    /// `DECLINED`, `FAILED`, `RETRY` or `NOT_SENT`; while a payment for the order is approved or
    /// still being confirmed, a reused one ends the payment `94` / `FAILED` /
    /// `DUPLICATE_MERCHANT_ORDER_ID`, with ``TapResult/originalPayment`` saying which — do not take
    /// another payment for the order.
    public let merchantOrderID: String

    public init(amountMinorUnits: Int64, currency: String = "566", merchantOrderID: String) {
        self.amountMinorUnits = amountMinorUnits
        self.currency = currency
        self.merchantOrderID = merchantOrderID
    }

    /// The currency as the reader's numeric code, or `nil` when it is not ISO 4217 numeric.
    var currencyCode: Int32? {
        let digits = currency.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let code = Int32(digits), code > 0 else { return nil }
        return code
    }
}

/// A tap payment's progress, delivered to `tap.start`'s `onEvent` on the main queue. Every event
/// but ``result(_:)`` and ``ended(outcome:)`` keeps the reader armed — like a physical terminal:
/// show a transient hint and keep the waiting screen up.
public enum TapEvent: Sendable {
    /// The customer's phone connected and the Veyra application was selected — the card dialogue
    /// is running ("hold steady").
    case cardDetected
    /// The customer's phone left the field while the card dialogue was still running — show
    /// "hold steady", keep the waiting screen up. A hint, not an outcome: the tap still ends in
    /// ``result(_:)``.
    case cardContactLost
    /// Something other than a Veyra wallet was tapped — the reader stays armed; show "card not
    /// supported, try again".
    case unsupportedCard
    /// The card conversation is finished and the payment is going online — "you can take the
    /// phone away; contacting the bank". Nothing talks to the card after this point.
    case cardReadingComplete
    /// The payment request is on its way to the gateway.
    case sendingRequestOnline
    /// The gateway's reply has arrived and is being read. The outcome still comes in ``result(_:)``.
    case receivingOnlineResponse
    /// The tap's outcome (any status) — final. A tap cancelled with `cancelPayment(merchantOrderID:)`
    /// before its request was sent ends here as `NOT_SENT` / `CANCELLED` — also when the card had
    /// already been read; one cancelled too late ends with its normal result.
    case result(TapResult)
    /// iOS only: the system NFC sheet closed without a card dialogue (dismissed, timed out, or NFC
    /// unavailable). When a card was already detected the tap still ends in ``result(_:)``.
    case ended(outcome: TapSessionOutcome)
}

/// How a tap reader session ended **without a card dialogue** — the typed form of what used to
/// be a raw string, so a host `switch` is exhaustive and the compiler flags a missed case.
public enum TapSessionOutcome: String, Sendable {
    /// The merchant dismissed the system NFC sheet — dismiss quietly; not an error.
    case cancelled = "CANCELLED"
    /// No card was presented before the reader's re-arm budget ran out — "try again".
    case timeout = "TIMEOUT"
    /// Any other session invalidation — "something went wrong".
    case error = "ERROR"
    /// This device cannot accept taps (no NFC reading) — terminal for the feature.
    case unavailable = "UNAVAILABLE"

    /// An outcome name this build does not know still ends the session, so it reads as
    /// `.error` — the "something went wrong" advice is right for it by construction.
    init(wire: String) {
        self = TapSessionOutcome(rawValue: wire) ?? .error
    }
}

/// The outcome of a tap payment, carried by ``TapEvent/result(_:)``.
public struct TapResult: Sendable {
    /// The outcome — what you branch on: `"APPROVED"`, `"DECLINED"`, `"FAILED"`, `"PENDING"`,
    /// `"RETRY"`, or `"NOT_SENT"` when the payment never reached the gateway (``responseStatusReason``
    /// says why — `NO_NETWORK_CONNECTION`, `CARD_READ_FAILED`, `MODE_REFUSED`, `INVALID_REQUEST`,
    /// `CANCELLED`…; retry with the same order ID). `"PENDING"` always means "the SDK is still
    /// resolving it — never charge again". A status you don't know is unresolved, never a decline.
    public let responseStatus: String
    /// Why the payment ended as it did, e.g. `"INSUFFICIENT_FUNDS"`. Display and log; a plain
    /// string by design, so a cause added later can never fail to parse.
    public let responseStatusReason: String?
    /// The wire literal the payment server stated (`"00"`, `"51"`, `"96"`…). Display it on
    /// receipts and quote it in support; **never branch on it** — branch on ``responseStatus``.
    /// Nil on `NOT_SENT`, which never reached the wire.
    public let responseCode: String?
    /// A human-readable description of the outcome, for logs and the result screen.
    public let message: String?
    /// The amount tapped, in minor units.
    public let amountMinorUnits: Int64?
    /// Card scheme, e.g. `"VISA"`, `"MASTERCARD"`, `"AFRIGO"`.
    public let cardScheme: String?
    /// The last four digits of the card or token, for the receipt.
    public let maskedTokenLast4: String?
    /// Cardholder Name (EMV tag `5F20`) as the tapped card presented it — on a Veyra token the
    /// card's display label (`AFRIGO ****1234`), not a person's name. Nil when the card carried
    /// none.
    public let cardholderName: String?
    /// The merchant transaction reference the SDK minted for this payment — pass to
    /// `receipt(merchantTransactionReference:)` for the receipt QR.
    public let merchantTransactionReference: String?
    /// The gateway's transaction ID, for the receipt and transaction detail.
    public let transactionID: String?
    /// The merchant's status as the gateway reported it with this payment.
    public let merchantStatus: String?
    /// The merchant-bank credit's identifier (NIP session id inter-bank, batch reference
    /// intra-bank). Nil unless the sale was approved and the gateway sent one.
    public let creditTransactionID: String?
    /// Whether the merchant's (beneficiary) bank can confirm the credit at all — the backend's
    /// payment-time decision. When `true`, the SDK polls the confirmation rail in the background
    /// and announces the answer through `observeCreditConfirmation(_:)`: show a "confirming credit…"
    /// state on the result screen and flip it from that callback. `false`/`nil` means there is
    /// nothing to wait for.
    public let isCreditConfirmationSupported: Bool?
    /// On a `DUPLICATE_MERCHANT_ORDER_ID` refusal, the payment already holding the order ID: its
    /// `responseStatus` says whether the order is already paid or still being confirmed. Nil otherwise.
    public let originalPayment: OriginalPayment?

    /// A tap refused on the phone before the reader armed: `NOT_SENT`, nothing sent.
    static func refused(reason: String, message: String) -> TapResult {
        TapResult(responseStatus: ResponseStatus.notSent, responseStatusReason: reason, responseCode: nil,
                  message: message, amountMinorUnits: nil, cardScheme: nil, maskedTokenLast4: nil,
                  cardholderName: nil, merchantTransactionReference: nil, transactionID: nil,
                  merchantStatus: nil, creditTransactionID: nil, isCreditConfirmationSupported: nil,
                  originalPayment: nil)
    }
}

/// One armed tap acceptance — the engine behind `tap.start`, internal: apps never create it.
/// CoreNFC opens and closes a sheet around each tap, so each tap gets its own session; the
/// SDK holds the running one until it ends (`VeyraSoftPOS.currentTap`).
///
/// Cancelled through `VeyraSoftPOS.shared.cancelPayment(merchantOrderID:)` with the sale's order
/// ID: before the payment is sent that stops the reader and the tap's `.result` event carries
/// `NOT_SENT` / `CANCELLED`; once it has been sent the cancel answers
/// ``CancelResult/tooLateToCancelRequestAlreadySent`` and the tap delivers its normal result.
final class TapPaymentSession: @unchecked Sendable {

    /// Where the tap is: armed and waiting for a card, a card's payment running, or over.
    enum Phase: Equatable {
        case awaitingCard
        case inProgress
        case ended
    }

    private let kotlin: IosTapAcceptance
    private let bridge: EventsBridge
    private let lock = NSLock()
    private var _phase: Phase = .awaitingCard
    private let onEnded: (TapPaymentSession) -> Void
    /// Keeps the screen awake from `start()` until the tap's `.result` or `.ended` — the iOS twin of
    /// Android holding the get-paid screen on while a card payment is live. Released on deinit too.
    private let keepAwake: ScreenAwakeToken

    var phase: Phase {
        lock.lock()
        defer { lock.unlock() }
        return _phase
    }

    init(
        amountMinorUnits: Int64,
        currencyCode: Int32,
        merchant: TapMerchant?,
        merchantOrderID: String,
        kmp: SoftposKmp,
        onEnded: @escaping (TapPaymentSession) -> Void,
        onEvent: @escaping @Sendable (TapEvent) -> Void
    ) {
        self.onEnded = onEnded
        let keepAwake = ScreenAwakeToken()
        self.keepAwake = keepAwake
        let bridge = EventsBridge(onEvent: onEvent, onFinished: { keepAwake.release() })
        self.bridge = bridge
        // Settlement capability: the shared payment client the kernel uses to run
        // TERMINAL_ACTION_ANALYSIS → ONLINE_PROCESSING → COMPLETION. Built here rather than by the
        // caller because the two online sub-phase hints come off that client, so it needs the
        // events bridge already in hand.
        let paymentProcessing = kmp.makePaymentProcessing(
            onSendingRequestOnline: { bridge.onSendingRequestOnline() },
            onReceivingOnlineResponse: { bridge.onReceivingOnlineResponse() }
        )
        self.kotlin = IosTapAcceptance(
            amountMinorUnits: amountMinorUnits,
            currencyCode: currencyCode,
            events: bridge,
            aidHex: IosTapAcceptance.companion.VEYRA_AID_HEX,
            merchant: merchant,
            paymentProcessing: paymentProcessing,
            merchantOrderId: merchantOrderID
        )
        bridge.onPhaseEvent = { [weak self] event in self?.advance(on: event) }
    }

    /// Arm the reader (claims SOFTPOS at the point of use). A refusal arrives as a `NOT_SENT`
    /// `.result`; only a setup mistake throws. Holds the screen awake until the tap ends.
    func start() throws {
        keepAwake.hold()
        do {
            try kotlin.start()
        } catch {
            keepAwake.release()
            advance(to: .ended)
            throw VeyraSoftPOS.setupError(error)
        }
    }

    /// Move the phase on an event, on the thread that raised it (before the event reaches the app,
    /// so the tap state an `onEvent` handler reads is already current).
    func advance(on event: TapEvent) {
        switch event {
        case .cardDetected:
            advance(to: .inProgress)
        case .result:
            advance(to: .ended)
        case .ended:
            // The sheet closing while a card's payment runs does not end the payment: its result
            // still comes. Closing while waiting for a card does.
            if phase == .awaitingCard { advance(to: .ended) }
        case .cardContactLost, .unsupportedCard, .cardReadingComplete, .sendingRequestOnline,
             .receivingOnlineResponse:
            break
        }
    }

    private func advance(to next: Phase) {
        lock.lock()
        let was = _phase
        if was != .ended { _phase = next }
        lock.unlock()
        if was != .ended && next == .ended { onEnded(self) }
    }

    /// The Kotlin reader's events as ``TapEvent``s, delivered on the main queue.
    final class EventsBridge: NSObject, TapAcceptanceEvents {
        private let onEvent: @Sendable (TapEvent) -> Void
        /// The tap is over (its result, or the reader ended without a card): let the screen sleep.
        private let onFinished: @Sendable () -> Void
        /// The owning session's phase hook, run synchronously before the event is dispatched.
        var onPhaseEvent: ((TapEvent) -> Void)?

        init(onEvent: @escaping @Sendable (TapEvent) -> Void, onFinished: @escaping @Sendable () -> Void = {}) {
            self.onEvent = onEvent
            self.onFinished = onFinished
        }

        func emit(_ event: TapEvent) {
            onPhaseEvent?(event)
            DispatchQueue.main.async { [onEvent] in onEvent(event) }
        }

        func onCardDetected() { emit(.cardDetected) }
        func onUnsupportedTarget() { emit(.unsupportedCard) }
        func onCardContactLost() { emit(.cardContactLost) }
        func onCardReadingComplete() { emit(.cardReadingComplete) }
        func onSendingRequestOnline() { emit(.sendingRequestOnline) }
        func onReceivingOnlineResponse() { emit(.receivingOnlineResponse) }
        func onEnded(outcome: String) {
            onFinished()
            emit(.ended(outcome: TapSessionOutcome(wire: outcome)))
        }
        func onResult(result: TapKernelResult) {
            onFinished()
            emit(.result(TapResult(
                responseStatus: result.responseStatus ?? ResponseStatus.pending,
                responseStatusReason: result.responseStatusReason,
                responseCode: result.responseCode,
                message: result.message,
                amountMinorUnits: result.amountMinorUnits?.int64Value,
                cardScheme: result.cardScheme,
                maskedTokenLast4: result.maskedTokenLast4,
                cardholderName: result.cardholderName,
                merchantTransactionReference: result.merchantTransactionReference,
                transactionID: result.transactionId,
                merchantStatus: result.merchantStatus,
                creditTransactionID: result.creditTransactionId,
                isCreditConfirmationSupported: result.isCreditConfirmationSupported?.boolValue,
                originalPayment: OriginalPayment(result.originalPayment)
            )))
        }
    }
}

private extension String {
    /// `nil` for a blank string.
    var nilIfBlank: String? { trimmingCharacters(in: .whitespaces).isEmpty ? nil : self }
}
