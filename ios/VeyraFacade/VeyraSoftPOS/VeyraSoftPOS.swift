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
// Android ↔ iOS name mapping (excerpt; full table in the package README):
// MerchantRegistrationClient(...).register(request) { … }
// ↔ try await VeyraSoftPOS.shared.merchant.register(registration)
import Foundation
import VeyraKMP

/// Configuration for the Veyra SoftPOS SDK.
///
/// **URLs are provided by the SDK, not the app developer** — selecting an `environment` is all
/// that is needed; endpoints resolve from the SDK's shared defaults (the same single source of
/// truth as Android). The only URL hooks are development overrides.
public struct VeyraSoftPOSConfiguration: Sendable {
    public enum Environment: String, Sendable {
        case local = "LOCAL"
        case test = "TEST"
        case live = "LIVE"
    }

    public let environment: Environment
    /// The payment app provider's globally unique identifier, as issued by the platform.
    /// Required — the gateway links every registered merchant to this provider and resolves the
    /// acquirer id and MCC from it; the app never supplies an acquirer id.
    public let paymentAppProviderID: String
    public let clientID: String?
    public let clientSecret: String?

    public init(
        environment: Environment,
        paymentAppProviderID: String,
        clientID: String? = nil,
        clientSecret: String? = nil
    ) {
        self.environment = environment
        self.paymentAppProviderID = paymentAppProviderID
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

/// A NUBAN-compatible settlement bank.
public struct SettlementBank: Sendable, Hashable, Identifiable {
    public let slug: String
    public let name: String
    public let institutionCode: String

    public var id: String { institutionCode }

    public init(slug: String, name: String, institutionCode: String) {
        self.slug = slug
        self.name = name
        self.institutionCode = institutionCode
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
    /// Required for `.personal` registrations.
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

/// Outcome of a merchant registration.
public struct MerchantRegistrationResult: Sendable, Hashable {
    public let success: Bool
    public let merchantID: String?
    public let terminalID: String?
    public let merchantStatus: String?
    public let message: String?

    public init(success: Bool, merchantID: String?, terminalID: String?, merchantStatus: String?, message: String?) {
        self.success = success
        self.merchantID = merchantID
        self.terminalID = terminalID
        self.merchantStatus = merchantStatus
        self.message = message
    }
}

/// A merchant's backend status (e.g. `"ACTIVE"`, `"DEACTIVATED"`).
public struct MerchantStatus: Sendable, Hashable {
    public let merchantID: String
    public let status: String?

    public init(merchantID: String, status: String?) {
        self.merchantID = merchantID
        self.status = status
    }
}

/// The merchant's backend status changed — delivered to `merchant.onMerchantStatusChanged`.
public struct MerchantStatusChange: Sendable, Hashable {
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

/// A gateway-signed merchant-presented (MPM) payment context.
/// Render `mpmPayload` as the QR verbatim; the customer's wallet verifies the gateway
/// signature before paying. Poll the outcome with `payments.contextStatus(txRef:)`.
/// A scanned, structurally-valid customer payment QR (consumer-presented): what the merchant
/// confirm screen shows. The amount/currency are read from the QR's cryptogram-covered data —
/// the merchant confirms, never re-keys.
public struct ScannedCustomerQr: Sendable {
    /// Last 4 digits of the paying card/token, for display.
    public let maskedCard: String
    /// Amount in minor units (e.g. kobo) — bound inside the QR's cryptogram.
    public let amountMinorUnits: Int64
    /// ISO 4217 numeric currency as carried in the QR (e.g. `"0566"`).
    public let currencyNumeric: String
    /// Cardholder Name (EMV `5F20`) when the QR carried one — the paying card's display name,
    /// e.g. "AFRIGO ****1234". Display only (it rides outside the cryptogram-covered data):
    /// show it on the confirm screen, never branch a payment decision on it.
    public let cardholderName: String?
    /// The KMP-scanned payload, kept for `chargeCustomerQr` (never public API).
    let raw: ScannedCpmQr
}

/// Outcome of charging a scanned customer QR.
public struct CustomerQrChargeOutcome: Sendable, Hashable {
    public let approved: Bool
    public let responseCode: String?
    public let transactionID: String?
    /// The merchant transaction reference this charge was submitted (and recorded) under —
    /// pass to `transactions.receipt(forReference:)` to build the receipt QR.
    public let reference: String
    /// The merchant-bank credit's identifier (NIP session id inter-bank, batch reference
    /// intra-bank) — the key for `transactions.creditConfirmation(...)`. Nil unless the charge
    /// was approved and the gateway sent one.
    public let creditTransactionID: String?
    /// Whether the merchant's (beneficiary) bank can confirm the credit at all — the backend's
    /// payment-time decision. When `true`, the SDK's app-scoped background sweep polls the
    /// confirmation rail and stamps the answer onto the sale's stored row
    /// (`creditConfirmationStatus`) — show a "confirming credit…" state and render the row.
    public let isCreditConfirmationSupported: Bool?
}

public struct PaymentContextQR: Sendable, Hashable {
    public let txRef: String
    /// ISO-8601 expiry (server clock) — offer a fresh QR once passed.
    public let expiry: String?
    /// Signing-key id the wallet uses to select its pinned verification key.
    public let kid: String?
    public let mpmPayload: String

    public init(txRef: String, expiry: String?, kid: String?, mpmPayload: String) {
        self.txRef = txRef
        self.expiry = expiry
        self.kid = kid
        self.mpmPayload = mpmPayload
    }
}

/// Lifecycle of a payment context: PENDING (QR live), IN_FLIGHT (push settling),
/// APPROVED / DECLINED (settled — `responseCode` carries the rail outcome), EXPIRED.
public struct PaymentContextState: Sendable, Hashable {
    public let txRef: String
    public let state: String
    public let responseCode: String?

    public var isSettled: Bool { state == "APPROVED" || state == "DECLINED" }
    public var isApproved: Bool { state == "APPROVED" }

    public init(txRef: String, state: String, responseCode: String?) {
        self.txRef = txRef
        self.state = state
        self.responseCode = responseCode
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
    /// Optional — how an already-registered BUSINESS merchant supplies its BVN.
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
    public let amount: Int64?
    public let responseCode: String
    public let merchantStatus: String?
    public let transactionID: String?
    /// The merchant-bank credit's identifier — sent when the transaction is approved, so an app
    /// that lost local state can still re-learn it from a status poll. See
    /// `transactions.creditConfirmation`.
    public let creditTransactionID: String?
    /// Whether the merchant's (beneficiary) bank can confirm the credit — the fetch gate.
    public let isCreditConfirmationSupported: Bool?

    public init(
        merchantTransactionReference: String,
        merchantID: String,
        amount: Int64?,
        responseCode: String,
        merchantStatus: String?,
        transactionID: String?,
        creditTransactionID: String? = nil,
        isCreditConfirmationSupported: Bool? = nil
    ) {
        self.merchantTransactionReference = merchantTransactionReference
        self.merchantID = merchantID
        self.amount = amount
        self.responseCode = responseCode
        self.merchantStatus = merchantStatus
        self.transactionID = transactionID
        self.creditTransactionID = creditTransactionID
        self.isCreditConfirmationSupported = isCreditConfirmationSupported
    }
}

/// One payment the merchant has taken, kept locally by the SDK. `amountMinorUnits` is
/// in **minor units**; `rail` is `"TAP"` / `"QR_MPM"` / `"QR_CPM"`; `status` is
/// `"APPROVED"` / `"DECLINED"` / `"PENDING"` / `"FAILED"`.
public struct MerchantTransaction: Sendable, Hashable {
    /// The sale's reference, **minted by the SDK** (`{terminalID}-YYYYMMDDHHmmssSSS`) and unique
    /// per merchant at the gateway — the key for receipts, status refreshes and credit confirmation.
    public let reference: String
    /// The **app's own** order / basket / invoice id for this sale, echoed back by the gateway, or
    /// nil when none was supplied. Never validated for uniqueness and never a lookup key, so the
    /// same value may sit on several attempts of one sale — which is what links a retry to its
    /// original order.
    public let merchantOrderID: String?
    public let rail: String
    public let amountMinorUnits: Int64
    public let currencyNumeric: String?
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
    /// intra-bank) — the key for `transactions.creditConfirmation(...)`. Nil on non-approved
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
        reference: String,
        // Defaulted so every existing call site keeps compiling unchanged (additive-only): the
        // stored property and `map` above were added without this parameter, which left the
        // explicit initializer unable to accept the field it is required to set.
        merchantOrderID: String? = nil,
        rail: String,
        amountMinorUnits: Int64,
        currencyNumeric: String?,
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
        self.reference = reference
        self.merchantOrderID = merchantOrderID
        self.rail = rail
        self.amountMinorUnits = amountMinorUnits
        self.currencyNumeric = currencyNumeric
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
/// `transactions.onTransactionResolved(_:)` when a stored row stops being pending.
///
/// The whole triple, because "it resolved" is not useful on its own: an app showing "processing"
/// needs to know whether to print a receipt (`status == "APPROVED"`), tell the cashier the card
/// was refused (`"DECLINED"`, with `reason` naming the cause) or offer a retry (`"FAILED"` —
/// nothing happened).
public struct TransactionResolution: Sendable, Hashable {
    /// The merchant transaction reference passed in when the payment was started. The SDK walks
    /// every pending row, so this can fire for a sale other than the one on screen — always match
    /// on it.
    public let reference: String
    /// The response code exactly as the backend sent it (`"00"`, `"51"`, `"96"`…). Receipts and
    /// disputes quote this literal, never a renamed enum. Nil on rows recorded before it existed.
    public let responseCode: String?
    /// `"APPROVED"` / `"DECLINED"` / `"FAILED"` — always one of the three finals, never `"PENDING"`.
    public let status: String
    /// Why it ended that way, e.g. `"INSUFFICIENT_FUNDS"`. Nil when the backend sent none.
    public let reason: String?

    public init(reference: String, responseCode: String?, status: String, reason: String?) {
        self.reference = reference
        self.responseCode = responseCode
        self.status = status
        self.reason = reason
    }
}

/// A sale's beneficiary credit confirmation, delivered to `transactions.onCreditConfirmation(_:)`
/// when the confirmation concludes.
///
/// Settlement confirmation only: it says whether the **merchant's bank received the funds**, and
/// never restates (or alters) the payment outcome the app already has.
///
/// Distinct from ``CreditConfirmation``, which is the reply to the on-demand
/// `transactions.creditConfirmation(merchantID:creditTransactionID:amountMinorUnits:)` fetch: that
/// one answers a question about a credit you named, so it has no sale reference to carry, while
/// this one arrives unprompted about whichever sale the SDK's sweep just settled.
public struct SaleCreditConfirmation: Sendable, Hashable {
    /// The merchant transaction reference passed in when the payment was started — match the
    /// confirmation to its sale with this.
    public let reference: String
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
        reference: String,
        creditTransactionID: String?,
        status: String,
        amountMinorUnits: Int64?,
        bankReference: String?,
        creditedAt: String?
    ) {
        self.reference = reference
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
    public let reference: String
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
        reference: String,
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
        self.reference = reference
        self.transactionHash = transactionHash
        self.qrPayload = qrPayload
        self.cardholderName = cardholderName
    }
}

/// Errors thrown by the Veyra SoftPOS SDK.
public enum VeyraSoftPOSError: Error, Sendable {
    /// `VeyraSoftPOS.configure(_:)` has not been called.
    case notConfigured
    /// A backend call failed; `message` carries the underlying description.
    case requestFailed(message: String)
    /// Arming the tap reader was refused — the wallet's payment is mid-flight, or the
    /// combined app bypassed `VeyraSDK` mode handling.
    case tapRefused(message: String)
    /// The device has **no working internet connection**, so the call never left it — ask the
    /// merchant to connect and try again. The Android SDK reports the same condition as
    /// `SdkErrorCode.NO_NETWORK_CONNECTION`.
    ///
    /// For a payment this is deliberately **not** an issuer decline or a `91`: nothing reached the
    /// gateway, so there is no response code, no transaction stored and nothing to reconcile. `91`
    /// (`ISSUER_SWITCH_NOT_AVAILABLE`) means the SDK *did* reach the network and was refused — a
    /// different situation with different advice, and the two must stay distinguishable.
    case noNetworkConnection(message: String)
}

// Without `LocalizedError`, `error.localizedDescription` renders the useless "The operation
// couldn't be completed. (VeyraSoftPOS.VeyraSoftPOSError error N.)" and the carried message — the
// only thing that says what actually went wrong — is invisible to the merchant and to anyone
// reading a support log. The wallet enum already had this; this one did not.
extension VeyraSoftPOSError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "VeyraSoftPOS is not configured — call VeyraSoftPOS.configure(_:) at launch."
        case .requestFailed(let message):
            return message
        case .tapRefused(let message):
            return message
        case .noNetworkConnection(let message):
            return message
        }
    }
}

/// Entry point of the Veyra SoftPOS SDK on iOS.
///
/// Configure once at launch, then use the service accessors:
/// ```swift
/// VeyraSoftPOS.configure(.init(environment: .test, apiBaseURL: url, …))
/// let status = try await VeyraSoftPOS.shared.merchant.status(merchantID: id)
/// ```
public final class VeyraSoftPOS: @unchecked Sendable {

    public static let shared = VeyraSoftPOS()

    private let lock = NSLock()
    private var kmp: SoftposKmp?
    private var merchantStorage: MerchantStorage = FileMerchantStorage()
    // The provider credential from the configuration — sent on merchant
    // register/update so the gateway can resolve the acquirer id and MCC.
    fileprivate var paymentAppProviderID: String = ""

    private init() {}

    /// Configure the SDK. Call once, before any service use (subsequent calls reconfigure).
    public static func configure(_ configuration: VeyraSoftPOSConfiguration) {
        // Scoped rather than `defer`-ed: the merchant-status watch below must be armed *outside*
        // the lock, because it reads stored-merchant state through `withMerchantStorage`, which
        // takes this same non-reentrant lock. A `defer` that unlocks at function exit would
        // deadlock the first configure on a device with a registered merchant.
        do {
            shared.lock.lock()
            defer { shared.lock.unlock() }
            shared.paymentAppProviderID = configuration.paymentAppProviderID
            shared.kmp = SoftposKmp(
                config: SoftposKmpConfig(
                    environmentName: configuration.environment.rawValue,
                    clientId: configuration.clientID,
                    clientSecret: configuration.clientSecret,
                    // Internal plumbing, not developer API: nil selects the SDK's
                    // environment-resolved defaults. ObjC-exported initializers carry no
                    // default arguments, so these parameters must be passed explicitly.
                    localBaseUrlOverride: nil,
                    remoteLogsUrlOverride: nil
                )
            )
        }
        // Arm the merchant-status watch at configure. Unconditional and app-scoped — there is no
        // event that "starts" interest in the merchant's status, only a merchant that already has
        // one, and the case that matters most is a merchant deactivated while the app was shut.
        shared.startMerchantStatusWatchIfRegistered()
    }

    /// Merchant lifecycle — registration, status, activate/deactivate, profile update, banks.
    public var merchant: Merchant { Merchant(owner: self) }

    /// Transaction queries — status polling by merchant transaction reference.
    public var transactions: Transactions { Transactions(owner: self) }

    /// Merchant-presented QR payments (MPM rail): create the signed context
    /// to render as the QR, and poll its lifecycle.
    public var payments: Payments { Payments(owner: self) }

    /// Contactless tap acceptance — the customer's Android Veyra wallet taps this iPhone.
    /// Reads Veyra's own application over CoreNFC; no Apple entitlement beyond
    /// standard NFC tag reading, no scheme-card reading.
    public var tap: Tap { Tap(owner: self) }

    fileprivate func requireKmp() throws -> SoftposKmp {
        lock.lock()
        defer { lock.unlock() }
        guard let kmp else { throw VeyraSoftPOSError.notConfigured }
        return kmp
    }

    fileprivate func call<T>(_ body: (SoftposKmp) async throws -> T) async throws -> T {
        let kmp = try requireKmp()
        do {
            return try await body(kmp)
        } catch let error as VeyraSoftPOSError {
            throw error
        } catch {
            let message = error.localizedDescription
            // the KMP transport codes an offline device into the message, exactly as the
            // wallet facade does for its own refusals. Typed here so a merchant app can say "check
            // your connection" instead of showing a generic request failure on every screen.
            if message.contains("NO_NETWORK_CONNECTION") {
                throw VeyraSoftPOSError.noNetworkConnection(
                    message: "No internet connection — connect to the internet and try again")
            }
            throw VeyraSoftPOSError.requestFailed(message: message)
        }
    }

    // Stored-merchant plumbing — SDK-owned Keychain persistence, the iOS twin of
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

    internal func clearStoredMerchant() {
        withMerchantStorage { $0.clear() }
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
        let previous: String? = withMerchantStorage { storage in
            guard let stored = storage.load(), stored.merchantID == merchantID else { return nil }
            let was = stored.merchantStatus
            storage.save(stored.updatingStatus(status))
            return was
        }
        // No stored merchant, or a response for a different one — nothing was written, so there is
        // nothing to announce. `status` nil means "not stated", which is not a change to report.
        guard let status, let kmp = try? requireKmp() else { return }
        kmp.notifyMerchantStatusChanged(merchantId: merchantID, previousStatus: previous, newStatus: status)
    }

    /// Start the SDK-owned merchant-status watch for the stored merchant, if there is one.
    ///
    /// §16: the SDK owns the waiting and the app process is its scope. Called at `configure` and
    /// after a successful registration — never by a screen, and never stopped by one. Before this,
    /// iOS had no merchant-status polling at all: a merchant deactivated mid-session stayed
    /// "active" on the device until a host happened to ask.
    internal func startMerchantStatusWatchIfRegistered() {
        guard let merchant = loadStoredMerchant(), let kmp = try? requireKmp() else { return }
        kmp.startMerchantStatusWatch(
            merchantId: merchant.merchantID,
            intervalSeconds: Int64(Self.merchantStatusWatchIntervalSeconds)
        ) { [weak self] status in
            // Land it in the Keychain, which is what fires the observer (above).
            self?.updateStoredMerchantStatus(merchantID: merchant.merchantID, status: status)
        }
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

    /// Test hook: swap the Keychain for an in-memory store.
    internal func replaceMerchantStorage(_ storage: MerchantStorage) {
        lock.lock()
        defer { lock.unlock() }
        merchantStorage = storage
    }

    /// Merchant operations (mirror Android's merchant clients).
    public struct Merchant: Sendable {
        fileprivate let owner: VeyraSoftPOS

        /// The merchant persisted on this device by the last successful `register(_:)`, if any.
        /// SDK-owned storage (Keychain) — survives app restarts. Mirrors Android's
        /// `merchantService.getStoredMerchantData()`.
        public var stored: StoredMerchant? { owner.loadStoredMerchant() }

        /// True when a merchant is registered on this device with every transaction-required
        /// field (merchant ID, terminal ID, name, acquirer ID, MCC, country code). Gate
        /// registration UI on this — mirrors Android's `merchantService.isRegistered()`.
        public var isRegistered: Bool { owner.loadStoredMerchant()?.isTransactionReady ?? false }

        /// Clear the stored merchant (e.g. logout or re-registration). Mirrors Android's
        /// `merchantService.clearStoredMerchant()`.
        public func clearStored() { owner.clearStoredMerchant() }

        /// Fetch the NUBAN settlement banks.
        public func banks() async throws -> [SettlementBank] {
            try await owner.call { kmp in
                try await kmp.banks().map {
                    SettlementBank(slug: $0.slug, name: $0.name, institutionCode: $0.institutionCode)
                }
            }
        }

        /// Register a merchant (personal or business).
        public func register(_ registration: MerchantRegistration) async throws -> MerchantRegistrationResult {
            try await owner.call { kmp in
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
                        paymentAppProviderId: owner.paymentAppProviderID,
                        walletAccountId: registration.walletAccountID
                    )
                )
                // Persist the registration — same fold as Android's MerchantService:
                // response-assigned fields win, terminal ID falls back to the merchant ID.
                if r.success, let merchantID = r.merchantId {
                    owner.saveStoredMerchant(
                        StoredMerchant(
                            registration: registration,
                            merchantID: merchantID,
                            terminalID: r.terminalId,
                            merchantStatus: r.merchantStatus,
                            merchantCategoryCode: r.merchantCategoryCode,
                            countryCode: r.countryCode,
                            // Gateway-resolved; there is no submitted value to fall
                            // back to any more.
                            acquirerID: r.acquirerId,
                            walletAccountID: r.walletAccountId ?? registration.walletAccountID
                        )
                    )
                    // There is now a merchant to watch. This is also the
                    // activation moment — a merchant registered as PENDING and activated minutes
                    // later is exactly the transition the app is waiting on, and before this the
                    // only way to see it was to keep asking.
                    owner.startMerchantStatusWatchIfRegistered()
                }
                return MerchantRegistrationResult(
                    success: r.success,
                    merchantID: r.merchantId,
                    terminalID: r.terminalId,
                    merchantStatus: r.merchantStatus,
                    message: r.message
                )
            }
        }

        /// Current backend status of a merchant. Refreshes the stored merchant's status when
        /// it is the stored one.
        public func status(merchantID: String) async throws -> MerchantStatus {
            try await owner.call { kmp in
                let r = try await kmp.merchantStatus(merchantId: merchantID)
                owner.updateStoredMerchantStatus(merchantID: r.merchantId, status: r.merchantStatus)
                return MerchantStatus(merchantID: r.merchantId, status: r.merchantStatus)
            }
        }

        /// Activate a merchant. Refreshes the stored merchant's status when it is the stored one.
        public func activate(merchantID: String) async throws -> MerchantStatus {
            try await owner.call { kmp in
                let r = try await kmp.activateMerchant(merchantId: merchantID)
                owner.updateStoredMerchantStatus(merchantID: r.merchantId, status: r.merchantStatus)
                return MerchantStatus(merchantID: r.merchantId, status: r.merchantStatus)
            }
        }

        /// Deactivate a merchant. Refreshes the stored merchant's status when it is the stored one.
        public func deactivate(merchantID: String) async throws -> MerchantStatus {
            try await owner.call { kmp in
                let r = try await kmp.deactivateMerchant(merchantId: merchantID)
                owner.updateStoredMerchantStatus(merchantID: r.merchantId, status: r.merchantStatus)
                return MerchantStatus(merchantID: r.merchantId, status: r.merchantStatus)
            }
        }

        /// Update a merchant's profile.
        public func update(merchantID: String, _ update: MerchantUpdate) async throws -> MerchantStatus {
            try await owner.call { kmp in
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
                        paymentAppProviderId: owner.paymentAppProviderID,
                        walletAccountId: update.walletAccountID,
                        bvn: update.bvn
                    )
                )
                // Fold the gateway-assigned identity from the update response into
                // the stored merchant (terminal id, provider-resolved acquirer id, wallet account).
                owner.applyStoredMerchantUpdate(update, merchantID: r.merchantId,
                                                terminalID: r.terminalId,
                                                acquirerID: r.acquirerId,
                                                walletAccountID: r.walletAccountId,
                                                status: r.merchantStatus)
                return MerchantStatus(merchantID: r.merchantId, status: r.merchantStatus)
            }
        }

        /// Observe the merchant's backend status changing — deactivated, suspended, or activated.
        ///
        /// **Why you want this.** A merchant deactivated or suspended mid-session should stop your
        /// app offering to take payments *at once*, not whenever a screen next happens to read
        /// `merchant.status`. It is also how you see the **activation** moment after registering,
        /// without polling for it yourself.
        ///
        /// The SDK owns the polling and it is **app-scoped**, not screen-scoped: it starts at
        /// `configure` (and after a successful `register`) and keeps running as the merchant
        /// navigates — no screen starts it and no screen may stop it.
        ///
        /// One platform boundary, stated rather than implied: iOS suspends timers when the OS
        /// suspends the app, so polling pauses while backgrounded and resumes on foreground. **No
        /// answer is lost** — the status lives in the SDK's store and the comparison is against
        /// what was persisted, so a change that happened while you were away is still reported on
        /// the first poll after you return.
        ///
        /// Act on `canAcceptPayments`, not on `status`: it is the SDK's own reading, so you can
        /// never be more permissive than the gate that would refuse the sale. Anything that is not
        /// `ACTIVE` — including a status added to the backend after this SDK shipped — is `false`.
        ///
        /// `previousStatus` is `nil` when this device had no status for the merchant yet.
        ///
        /// Callbacks arrive on the main thread. Observing again replaces the previous observer;
        /// `stopObservingMerchantStatus()` clears it. Register once, at start-up.
        public func onMerchantStatusChanged(
            _ observer: @escaping @Sendable (MerchantStatusChange) -> Void
        ) throws {
            let kmp = try owner.requireKmp()
            kmp.observeMerchantStatus { merchantID, status, canAcceptPayments, previousStatus in
                observer(
                    MerchantStatusChange(
                        merchantID: merchantID,
                        status: status,
                        canAcceptPayments: canAcceptPayments.boolValue,
                        previousStatus: previousStatus
                    )
                )
            }
        }

        /// Stop observing merchant status; no further callbacks fire.
        public func stopObservingMerchantStatus() throws {
            try owner.requireKmp().stopObservingMerchantStatus()
        }
    }

    /// Transaction queries (mirror Android's `TransactionStatusClient`).
    public struct Transactions: Sendable {
        fileprivate let owner: VeyraSoftPOS

        /// Status of a transaction by merchant transaction reference. `transactionDate` is `YYYY-MM-DD`.
        public func status(
            merchantID: String,
            merchantTransactionReference: String,
            transactionDate: String
        ) async throws -> [TransactionStatus] {
            try await owner.call { kmp in
                let items = try await kmp.transactionStatus(
                    merchantId: merchantID,
                    merchantTransactionReference: merchantTransactionReference,
                    transactionDate: transactionDate
                )
                return items.map {
                    TransactionStatus(
                        merchantTransactionReference: $0.merchantTransactionReference,
                        merchantID: $0.merchantId,
                        amount: $0.amount?.int64Value,
                        responseCode: $0.responseCode,
                        merchantStatus: $0.merchantStatus,
                        transactionID: $0.transactionId,
                        creditTransactionID: $0.creditTransactionId,
                        isCreditConfirmationSupported: $0.isCreditConfirmationSupported?.boolValue
                    )
                }
            }
        }

        /// The merchant's locally-kept transactions across every rail (tap, QR MPM, QR CPM), most
        /// recent first — the SDK records each payment taken, so this needs no backend round trip.
        /// Mirrors Android's `TransactionService.getLastTransactions`.
        public func history(limit: Int = 50) async throws -> [MerchantTransaction] {
            try await owner.call { kmp in
                try await kmp.merchantTransactions(limit: Int32(limit)).map(Self.map)
            }
        }

        /// Ask the gateway about **one** pending transaction now, and return the updated stored row.
        ///
        /// The on-demand counterpart to `history(limit:)`, which only reads what the device already
        /// knows. The SDK polls a pending transaction for you with exponential backoff and **stops
        /// after 30 days**; this is how a merchant staring at a row gets an answer sooner than the
        /// next rung, and the only route to one once that window has closed.
        ///
        /// It runs the SDK's own background sweep for this single row — same query, same reading of
        /// the answer, same write into the same local store — so an on-demand check and a background
        /// check cannot reach different conclusions. It is **not** a way to force an outcome: a
        /// payment that is still unsettled answers `PENDING` again, and the SDK invents nothing.
        ///
        /// Distinct from `status(merchantID:merchantTransactionReference:transactionDate:)`, which
        /// stays as the **raw** query: that one returns whatever the gateway said and writes nothing.
        ///
        /// - Returns: the transaction as it stands after the check, or `nil` if this device has no
        ///   such reference. A row that already has a final outcome is returned unchanged, without a
        ///   network call.
        /// - Throws: `VeyraSoftPOSError.noNetworkConnection` when the device is offline, and the
        ///   usual transport errors otherwise. A failed check never changes the stored row, so
        ///   showing the error and leaving the row as pending is the correct handling.
        public func refreshStatus(reference: String) async throws -> MerchantTransaction? {
            try await owner.call { kmp in
                try await kmp.refreshTransactionStatus(reference: reference).map(Self.map)
            }
        }

        /// Check the merchant credit **now** for one approved sale — "has my bank actually received
        /// the funds?" — and return the updated stored row.
        ///
        /// The SDK already asks this in the background, with exponential backoff, for **30 days**
        /// after the sale, and then records the row as `"UNABLE_TO_CONFIRM"` — which means *"we
        /// stopped asking"*, never *"the funds were not received"*. This is the escape hatch from
        /// that give-up and a convenience long before it: it still works once the window has closed,
        /// and a later `"RECEIVED"` replaces the give-up state.
        ///
        /// **Check `isCreditConfirmationSupported` on the transaction first.** Not every merchant's
        /// bank is on the confirmation rail. Offer this action only while
        /// ```swift
        /// txn.status == "APPROVED"
        ///     && txn.isCreditConfirmationSupported == true
        ///     && txn.creditConfirmationStatus != "RECEIVED"
        /// ```
        /// A call on a row that fails that predicate makes **no network request** and returns the row
        /// unchanged rather than throwing.
        ///
        /// Distinct from `creditConfirmation(merchantID:creditTransactionID:amountMinorUnits:)`,
        /// which stays as the **raw** fetch: that one returns whatever the gateway said and writes
        /// nothing, so a `"RECEIVED"` learned that way is gone on the next render. This one writes
        /// the stored row and fires the credit-confirmation observer, exactly as the background sweep
        /// does.
        ///
        /// Settlement only: nothing on this path can change the sale's `status`, `responseCode` or
        /// `responseStatusReason`.
        ///
        /// - Returns: the transaction as it stands after the check, or `nil` if this device has no
        ///   such reference.
        /// - Throws: `VeyraSoftPOSError.noNetworkConnection` when the device is offline, and the
        ///   usual transport errors otherwise. A failed check never changes the stored row, so
        ///   showing the error and leaving the credit line reading "not confirmed yet" is the correct
        ///   handling.
        public func refreshCreditConfirmation(reference: String) async throws -> MerchantTransaction? {
            try await owner.call { kmp in
                try await kmp.refreshCreditConfirmation(reference: reference).map(Self.map)
            }
        }

        private static func map(_ r: VeyraKMP.MerchantTransactionRecord) -> MerchantTransaction {
            MerchantTransaction(
                reference: r.reference,
                merchantOrderID: r.merchantOrderId,
                rail: r.rail,
                amountMinorUnits: r.amountMinorUnits,
                currencyNumeric: r.currencyNumeric,
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

        /// Beneficiary credit confirmation: has the merchant's bank actually received an approved
        /// sale's funds? Settlement confirmation only — it never restates the payment outcome.
        /// Pass the `creditTransactionID` from the transaction's history row (populated when the
        /// approval said `isCreditConfirmationSupported`) and the sale amount in **minor units**
        /// (cross-checked by the merchant's bank).
        ///
        /// The SDK polls this rail itself, app-scoped, on every platform: on iOS its background
        /// sweep runs for as long as the app is alive (no OS background execution — it suspends
        /// and resumes with the app) and persists each answer onto the transaction's stored row
        /// (`creditConfirmationStatus`) — render that row rather than polling here. This manual
        /// fetch remains for an on-demand check: "RECEIVED" is terminal — stop asking; anything
        /// else means ask again later. Mirrors `status(...)`'s shape.
        public func creditConfirmation(
            merchantID: String,
            creditTransactionID: String,
            amountMinorUnits: Int64
        ) async throws -> CreditConfirmation {
            try await owner.call { kmp in
                let r = try await kmp.creditConfirmation(
                    merchantId: merchantID,
                    creditTransactionId: creditTransactionID,
                    amountMinorUnits: amountMinorUnits
                )
                return CreditConfirmation(
                    creditTransactionID: r.creditTransactionId,
                    status: r.creditTransactionStatus,
                    amountMinorUnits: r.amount?.int64Value,
                    creditedAt: r.creditedAt,
                    bankReference: r.bankReference,
                    message: r.message
                )
            }
        }

        // ── Deferred answers: the SDK pushes, instead of the app polling ──────────────────

        /// Observe payments that stop being pending — the push half of `history(limit:)`.
        ///
        /// A tap or QR sale that gets no answer hands the app a `PENDING` result, and the SDK then
        /// polls it to a final status in the background. This fires the moment one settles, so a
        /// screen showing "processing" can finish without a timer of its own. It fires for **any**
        /// transaction that resolves — including one started in an earlier app launch and picked up
        /// by a later poll — so match `resolution.reference` to the sale you care about.
        ///
        /// **A notification, never the source of truth.** There is no replay on registration: an
        /// app that was not running when the row settled learns about it from `history(limit:)`.
        /// Keep reading the store when a screen appears and treat this as the live update while it
        /// is up.
        ///
        /// Callbacks arrive on the main thread. Observing again replaces the previous observer;
        /// `stopObservingTransactionResolved()` clears it. Register once, at start-up.
        ///
        /// ```swift
        /// try VeyraSoftPOS.shared.transactions.onTransactionResolved { resolution in
        ///     guard resolution.reference == self.pendingReference else { return }
        ///     self.show(status: resolution.status, code: resolution.responseCode)
        /// }
        /// ```
        public func onTransactionResolved(
            _ observer: @escaping @Sendable (TransactionResolution) -> Void
        ) throws {
            let kmp = try owner.requireKmp()
            kmp.observeTransactionResolved { reference, responseCode, status, reason in
                observer(
                    TransactionResolution(
                        reference: reference,
                        responseCode: responseCode,
                        status: status,
                        reason: reason
                    )
                )
            }
        }

        /// Stop observing resolved transactions; no further callbacks fire.
        public func stopObservingTransactionResolved() throws {
            try owner.requireKmp().stopObservingTransactionResolved()
        }


        /// Observe beneficiary credit confirmations — the answer the SDK's background sweep is
        /// waiting for after an approved sale whose response said `isCreditConfirmationSupported`.
        ///
        /// Fires once per sale, with `"RECEIVED"` (the funds are in the merchant's account) or
        /// `"UNABLE_TO_CONFIRM"` (the 30-day window closed unconfirmed — a give-up, not a
        /// reversal). Settlement confirmation only: it never changes the payment outcome.
        ///
        /// The polling is the SDK's and is **app-scoped**, not screen-scoped: it keeps running as
        /// the merchant navigates away from the result screen, and resumes when the app returns to
        /// the foreground (iOS suspends timers with the app — there is no OS background execution,
        /// so a suspended app loses time, never an answer). The confirmation is written to the
        /// transaction's stored row (`MerchantTransaction.creditConfirmationStatus`) as well as
        /// announced here, so a screen that appears later still shows it.
        ///
        /// Callbacks arrive on the main thread. Observing again replaces the previous observer;
        /// `stopObservingCreditConfirmation()` clears it. Register once, at start-up.
        public func onCreditConfirmation(
            _ observer: @escaping @Sendable (SaleCreditConfirmation) -> Void
        ) throws {
            let kmp = try owner.requireKmp()
            kmp.observeCreditConfirmation { reference, creditTransactionID, status, amountMinorUnits, bankReference, creditedAt in
                observer(
                    SaleCreditConfirmation(
                        reference: reference,
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
            try owner.requireKmp().stopObservingCreditConfirmation()
        }

        /// Build the receipt for one transaction: display fields plus a
        /// `qrPayload` JSON scannable by the wallet's receipt scanner. The registered merchant's
        /// name/address (Keychain-stored) are folded in. Nil when the reference is unknown.
        public func receipt(forReference reference: String) async throws -> MerchantReceipt? {
            let merchant = owner.loadStoredMerchant()
            let name = merchant?.merchantName ?? ""
            let address = [merchant?.addressLine1, merchant?.addressLine2, merchant?.city, merchant?.state, merchant?.countryCode]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            return try await owner.call { kmp in
                guard let r = try await kmp.merchantReceipt(reference: reference, merchantName: name, merchantAddress: address) else {
                    return nil
                }
                return MerchantReceipt(
                    merchantName: r.merchantName,
                    merchantAddress: r.merchantAddress,
                    transactionType: r.transactionType,
                    totalAmountMinorUnits: r.totalAmountMinorUnits,
                    totalAmountFormatted: r.totalAmountFormatted,
                    maskedToken: r.maskedToken,
                    reference: r.reference,
                    transactionHash: r.transactionHash,
                    qrPayload: r.qrPayload,
                    cardholderName: r.cardholderName
                )
            }
        }
    }

    /// Merchant-presented QR payments (MPM rail).
    public struct Payments: Sendable {
        fileprivate let owner: VeyraSoftPOS

        /// Create a gateway-signed payment context for the sale; render the returned
        /// `mpmPayload` as the QR verbatim. Same payment-gateway base URL as `/payment`.
        /// `currency` is ISO 4217 numeric (e.g. `"566"` for NGN; leading zeros accepted) —
        /// the gateway requires it, so the app must always supply it.
        /// - Parameter onExpired: the SDK calls this once, on the main thread, when the
        /// created QR reaches its `expiry`. Blank/replace the code on this so it can't be scanned
        /// once lapsed. The SDK owns the timer: a new `createContext` supersedes it, and
        /// `cancelQrExpiry()` stops it (call on teardown). Omit to keep the old behaviour.
        /// - Parameter merchantOrderID: your own order/basket/invoice id for the sale this QR
        ///   represents (optional). The gateway stores it on the context and copies it onto the
        ///   settled payment, reading it from its own stored context rather than from the payload
        ///   the paying wallet echoes back.
        public func createContext(
            merchantID: String,
            amountMinorUnits: Int64,
            currency: String,
            onExpired: (() -> Void)? = nil,
            merchantOrderID: String? = nil
        ) async throws -> PaymentContextQR {
            try await owner.call { kmp in
                let created = try await kmp.createContextPayment(
                    merchantId: merchantID,
                    amountMinorUnits: amountMinorUnits,
                    currency: currency,
                    onExpired: onExpired,
                    merchantOrderId: merchantOrderID
                )
                return PaymentContextQR(
                    txRef: created.txRef,
                    expiry: created.expiry,
                    kid: created.kid,
                    mpmPayload: created.mpmPayload
                )
            }
        }

        /// Stop the active MPM-QR expiry watch started by `createContext`. Call on
        /// teardown (the QR page is left) so the `onExpired` callback can't fire into dead UI.
        /// Idempotent; a new `createContext` also supersedes any prior watch.
        public func cancelQrExpiry() {
            (try? owner.requireKmp()).map { $0.cancelQrExpiry() }
        }

        /// Poll the context lifecycle (PENDING / IN_FLIGHT / APPROVED / DECLINED / EXPIRED).
        public func contextStatus(txRef: String) async throws -> PaymentContextState {
            try await owner.call { kmp in
                let status = try await kmp.contextStatus(txRef: txRef)
                return PaymentContextState(
                    txRef: status.txRef,
                    state: status.state,
                    responseCode: status.responseCode
                )
            }
        }

        /// Inspect a scanned **customer** QR (consumer-presented payment). Throws when the
        /// payload is not a valid Veyra payment QR — treat any throw as "not a payment QR":
        /// show a transient hint and stay armed for another scan. The returned amount/currency
        /// come from the QR's cryptogram — display them for the merchant to **confirm**; the
        /// amount is never keyed on the merchant side.
        public func inspectCustomerQr(_ payload: String) async throws -> ScannedCustomerQr {
            try await owner.call { kmp in
                let scanned = try kmp.inspectCpmQr(payload: payload)
                return ScannedCustomerQr(
                    maskedCard: String(scanned.dpan.suffix(4)),
                    amountMinorUnits: scanned.amountMinorUnits,
                    currencyNumeric: scanned.currencyNumeric4,
                    cardholderName: scanned.cardholderName,
                    raw: scanned
                )
            }
        }

        /// Charge a merchant-confirmed scanned customer QR over the standard payment rail,
        /// synchronously. The amount charged is the QR's own (cryptogram-bound) amount — a
        /// tampered payload or a different amount declines at the token provider.
        /// - Parameter merchantOrderID: your own order/basket/invoice id for this sale (optional).
        ///   The SDK mints the transaction reference itself; this is the field for *your*
        ///   identifier, and unlike the reference it is never used as a key, so you may reuse it
        ///   across the attempts of one sale.
        public func chargeCustomerQr(
            _ scanned: ScannedCustomerQr,
            merchantOrderID: String? = nil
        ) async throws -> CustomerQrChargeOutcome {
            return try await owner.call { kmp in
                // Apply the registered merchant so the /payment request carries
                // merchant_id/acquirer_id/mcc/name/location — the CPM twin of the tap's
                // merchant enrichment.
                let response = try await kmp.chargeCpmQr(
                    scanned: scanned.raw,
                    merchant: owner.storedTapMerchant(),
                    merchantTransactionReference: nil,
                    merchantOrderId: merchantOrderID
                )
                // the reference comes BACK from the gateway, it is not made here. This
                // used to mint its own ("\(millis)_\(random)") and hand that to the app as the
                // receipt key — which the SDK now ignores, so it would have been a value no
                // gateway had ever seen and every lookup built on it would have missed.
                return CustomerQrChargeOutcome(
                    approved: response.responseCode == "00",
                    responseCode: response.responseCode,
                    transactionID: response.transactionId,
                    reference: response.merchantTransactionReference ?? "",
                    creditTransactionID: response.creditTransactionId,
                    isCreditConfirmationSupported: response.isCreditConfirmationSupported?.boolValue
                )
            }
        }
    }

    /// Contactless tap acceptance (Android-wallet → iPhone rail).
    public struct Tap: Sendable {
        fileprivate let owner: VeyraSoftPOS

        /// Create a tap session for one sale (arm with `start()`, tear down with `cancel()`).
        /// Events are delivered on the main queue. `currencyCode` is ISO 4217 numeric
        /// (defaults to 566, NGN); `amountMinorUnits` is kobo for NGN.
        public func session(
            amountMinorUnits: Int64,
            currencyCode: Int32 = 566,
            onEvent: @escaping @Sendable (TapPaymentEvent) -> Void
        ) -> TapPaymentSession {
            // Enrich the tap with the registered merchant so 9F4E/9F15/DF0E/DF0F carry real
            // values (the Android reader sources these from MerchantDataStore).
            let merchant = owner.storedTapMerchant()
            return TapPaymentSession(
                amountMinorUnits: amountMinorUnits,
                currencyCode: currencyCode,
                merchant: merchant,
                kmp: try? owner.requireKmp(),
                onEvent: onEvent
            )
        }
    }
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

/// A tap-payment lifecycle event. Non-terminal events keep the reader armed —
/// mirror a physical terminal: show a transient hint, keep the waiting screen up.
public enum TapPaymentEvent: Sendable {
    /// Customer's phone connected and the Veyra application selected — dialogue running ("hold steady").
    case cardDetected
    /// Foreign/non-Veyra target — the reader stays armed; show "card not supported, try again".
    case unsupportedTarget
    /// The customer's phone left the field while the card dialogue was still running — show
    /// "hold steady", keep the waiting screen up. A transient hint, not an outcome: the dialogue
    /// still ends in `result`.
    case cardContactLost
    /// The card conversation is finished and the payment is going online — "you can take the
    /// phone away; contacting the bank". Nothing talks to the card after this point.
    case cardReadingComplete
    /// The settlement request is on its way to the gateway.
    case sendingRequestOnline
    /// The gateway's reply has arrived and is being read. The outcome still comes in `result`.
    case receivingOnlineResponse
    /// The reader session ended without a card.
    case ended(outcome: TapSessionOutcome)
    /// The kernel dialogue finished (any status — including the pending-settlement failure
    /// until the shared payment client lands).
    case result(TapPaymentResult)
}

/// Outcome of a tap's kernel dialogue.
public struct TapPaymentResult: Sendable {
    /// APPROVED / DECLINED / PENDING / FAILED (TransactionStatus names).
    public let status: String
    public let pan: String?
    /// DE55 EMV data (uppercase hex) when the card returned an ARQC — the online leg's input.
    public let iccDataHex: String?
    public let errorMessage: String?
    /// The SDK error code when the tap failed before or during dispatch — `"NO_NETWORK_CONNECTION"`
    /// when this device had no working internet connection, so nothing reached the gateway and
    /// there is nothing to reconcile: tell the merchant to connect and take the payment again.
    /// Nil for an ordinary outcome, including a decline.
    public let sdkErrorCode: String?
    /// The merchant transaction reference the settlement request carried — pass to
    /// `transactions.receipt(forReference:)` for the receipt QR.
    public let reference: String?
    /// The merchant-bank credit's identifier (NIP session id inter-bank, batch reference
    /// intra-bank). Nil unless the sale was approved and the gateway sent one.
    public let creditTransactionID: String?
    /// Whether the merchant's (beneficiary) bank can confirm the credit at all — the backend's
    /// payment-time decision. When `true`, the SDK polls the confirmation rail in the background
    /// and announces the answer through `transactions.onCreditConfirmation(_:)`: show a
    /// "confirming credit…" state on the result screen and flip it from that callback.
    /// `false`/`nil` means there is nothing to wait for.
    public let isCreditConfirmationSupported: Bool?
}

/// One armed tap acceptance. Create per waiting screen; always `cancel()` when the screen
/// leaves (arming is exclusive-mode-gated and must never outlive the Get-paid screen).
public final class TapPaymentSession: @unchecked Sendable {

    private let kotlin: IosTapAcceptance
    private let bridge: EventsBridge

    fileprivate init(
        amountMinorUnits: Int64,
        currencyCode: Int32,
        merchant: TapMerchant?,
        kmp: SoftposKmp?,
        onEvent: @escaping @Sendable (TapPaymentEvent) -> Void
    ) {
        let bridge = EventsBridge(onEvent: onEvent)
        self.bridge = bridge
        // Settlement capability: the shared payment client the kernel uses to run
        // TERMINAL_ACTION_ANALYSIS → ONLINE_PROCESSING → COMPLETION. nil if not configured —
        // the tap then runs the reader dialogue only.
        //
        // Built here rather than by the caller because the two online sub-phase hints come off
        // that client, so it needs the events bridge already in hand.
        let paymentProcessing = kmp?.makePaymentProcessing(
            onSendingRequestOnline: { bridge.onSendingRequestOnline() },
            onReceivingOnlineResponse: { bridge.onReceivingOnlineResponse() }
        )
        self.kotlin = IosTapAcceptance(
            amountMinorUnits: amountMinorUnits,
            currencyCode: currencyCode,
            events: bridge,
            aidHex: IosTapAcceptance.companion.VEYRA_AID_HEX,
            merchant: merchant,
            paymentProcessing: paymentProcessing
        )
    }

    /// Arm the reader (claims SOFTPOS at the point of use, like Android's `makeCardPayment`).
    /// - Throws: `VeyraSoftPOSError.tapRefused` when the exclusive-mode claim is refused.
    public func start() throws {
        do {
            try kotlin.start()
        } catch {
            throw VeyraSoftPOSError.tapRefused(message: error.localizedDescription)
        }
    }

    /// Tear down (merchant cancelled / screen left). No events fire after this.
    public func cancel() {
        kotlin.cancel()
    }

    private final class EventsBridge: NSObject, TapAcceptanceEvents {
        private let onEvent: @Sendable (TapPaymentEvent) -> Void
        init(onEvent: @escaping @Sendable (TapPaymentEvent) -> Void) { self.onEvent = onEvent }

        private func emit(_ event: TapPaymentEvent) {
            DispatchQueue.main.async { [onEvent] in onEvent(event) }
        }

        func onCardDetected() { emit(.cardDetected) }
        func onUnsupportedTarget() { emit(.unsupportedTarget) }
        func onCardContactLost() { emit(.cardContactLost) }
        func onCardReadingComplete() { emit(.cardReadingComplete) }
        func onSendingRequestOnline() { emit(.sendingRequestOnline) }
        func onReceivingOnlineResponse() { emit(.receivingOnlineResponse) }
        func onEnded(outcome: String) { emit(.ended(outcome: TapSessionOutcome(wire: outcome))) }
        func onResult(result: TapKernelResult) {
            emit(.result(TapPaymentResult(
                status: result.status,
                pan: result.pan,
                iccDataHex: result.iccDataHex(),
                errorMessage: result.errorMessage,
                sdkErrorCode: result.sdkErrorCode,
                reference: result.merchantTransactionReference,
                creditTransactionID: result.creditTransactionId,
                isCreditConfirmationSupported: result.isCreditConfirmationSupported?.boolValue
            )))
        }
    }
}
