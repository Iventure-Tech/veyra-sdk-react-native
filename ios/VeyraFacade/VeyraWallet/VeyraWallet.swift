// VeyraWallet — public iOS API of the Veyra wallet SDK.
//
// Pure-Swift facade over the VeyraKMP umbrella framework (Swift-idiomatic: async/await,
// typed errors). KMP/Obj-C types (VKMP*) must never appear in public signatures — every
// boundary maps to a Swift type here.
//
// Android ↔ iOS name mapping (excerpt; full table in the package README):
// VeyraWalletSdk.getInstance()?.tokenisationService.getBanks { … }
// ↔ try await VeyraWallet.shared.tokenisation.banks()
import Foundation
import VeyraKMP

/// Configuration for the Veyra wallet SDK.
///
/// **URLs are provided by the SDK, not the app developer** — selecting an `environment` is all
/// that is needed; endpoints resolve from the SDK's shared defaults (the same single source of
/// truth as Android). The only URL hooks are development overrides.
public struct VeyraWalletConfiguration: Sendable {
    public enum Environment: String, Sendable {
        case local = "LOCAL"
        case test = "TEST"
        case live = "LIVE"
    }

    public let environment: Environment
    public let clientID: String?
    public let clientSecret: String?
    /// Wallet identity (mirrors Android's `VeyraWalletSdkConfig`; required for eligibility/digitise).
    /// The `paymentApplicationInstanceID` is NOT configured — the SDK generates and persists an
    /// install-scoped one and sends it on every eligibility/digitise request (read it via
    /// `VeyraWallet.shared.paymentApplicationInstanceID()`).
    public let paymentAppProviderID: String?
    public let tokenRequestorID: String?
    /// App version reported to the backend during digitise.
    public let appVersion: String
    /// Optional override for the app's bundle id (the attestation `package_name` / App Attest
    /// app-id suffix). Normally leave `nil` — the SDK auto-detects it from `Bundle.main`, like
    /// Android reads `context.packageName`. Only the Team ID must be supplied.
    public let bundleID: String?
    /// **Your app's** Apple Developer Team ID (e.g. `"TV4JRK677Z"`). With `bundleID` this is the
    /// App Attest app id (`teamID.bundleID`) the attestation binds to and the backend verifies.
    /// App Attest attests the *app*, so this is your team — not the SDK vendor's. **Mandatory:**
    /// `digitise` fails fast if it is missing.
    public let appleTeamID: String
    /// Digitise `provision_context` allow-lists (mirror Android's `VeyraWalletSdkConfig`).
    /// The token product can restrict provisioning to these — a restricted dimension that the
    /// request omits is declined (e.g. `country_code … do not match any of allowed`).
    /// Country codes are ISO 3166-1 *numeric*, 3–4 digits (`"0566"` Nigeria, `"0826"` UK).
    public let allowedAcquirerIDs: [String]
    public let allowedMerchantIDs: [String]
    public let allowedCountryCodes: [String]
    public let allowedMCCs: [String]

    public init(
        environment: Environment,
        clientID: String? = nil,
        clientSecret: String? = nil,
        paymentAppProviderID: String? = nil,
        tokenRequestorID: String? = nil,
        appVersion: String = "1.0.0",
        bundleID: String? = nil,
        appleTeamID: String,
        allowedAcquirerIDs: [String] = [],
        allowedMerchantIDs: [String] = [],
        allowedCountryCodes: [String] = [],
        allowedMCCs: [String] = []
    ) {
        self.environment = environment
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.paymentAppProviderID = paymentAppProviderID
        self.tokenRequestorID = tokenRequestorID
        self.appVersion = appVersion
        self.bundleID = bundleID
        self.appleTeamID = appleTeamID
        self.allowedAcquirerIDs = allowedAcquirerIDs
        self.allowedMerchantIDs = allowedMerchantIDs
        self.allowedCountryCodes = allowedCountryCodes
        self.allowedMCCs = allowedMCCs
    }
}

/// The wallet provider's tokenisation recommendation — a business decision **your app** makes
/// per digitise call (the SDK never assumes one). Mirrors Android's `TokenizationRecommendation`.
public enum TokenizationRecommendation: String, Sendable {
    case approve = "APPROVE"
    case decline = "DECLINE"
    case requireAdditionalAuthentication = "REQUIRE_ADDITIONAL_AUTHENTICATION"
}

/// Trust score for the device/account in a digitise request (mirrors Android's `TrustScore`).
public enum TrustScore: String, Sendable {
    case untrusted = "UNTRUSTED"
    case lowTrust = "LOW_TRUST"
    case moderateTrust = "MODERATE_TRUST"
    case trusted = "TRUSTED"
    case highlyTrusted = "HIGHLY_TRUSTED"
}

/// Reason codes backing the tokenisation recommendation (mirrors Android's
/// `TokenizationRecommendationReason`).
public enum TokenizationRecommendationReason: String, Sendable {
    case longAccountTenure = "LONG_ACCOUNT_TENURE"
    case goodActivityHistory = "GOOD_ACTIVITY_HISTORY"
    case cardholderUnavailable = "CARDHOLDER_UNAVAILABLE"
    case authenticationNotSupported = "AUTHENTICATION_NOT_SUPPORTED"
    case recentCardholderAuthentication = "RECENT_CARDHOLDER_AUTHENTICATION"
    case recentApprovedToken = "RECENT_APPROVED_TOKEN"
    case deviceAuthenticationVerified = "DEVICE_AUTHENTICATION_VERIFIED"
    case additionalDevice = "ADDITIONAL_DEVICE"
    case softwareUpdate = "SOFTWARE_UPDATE"
    case accountTooNewSinceLaunch = "ACCOUNT_TOO_NEW_SINCE_LAUNCH"
    case accountTooNew = "ACCOUNT_TOO_NEW"
    case accountCardTooNew = "ACCOUNT_CARD_TOO_NEW"
    case accountRecentlyChanged = "ACCOUNT_RECENTLY_CHANGED"
    case suspiciousActivity = "SUSPICIOUS_ACTIVITY"
    case inactiveAccount = "INACTIVE_ACCOUNT"
    case hasSuspendedTokens = "HAS_SUSPENDED_TOKENS"
    case deviceRecentlyLost = "DEVICE_RECENTLY_LOST"
    case tooManyRecentAttempts = "TOO_MANY_RECENT_ATTEMPTS"
    case tooManyRecentTokens = "TOO_MANY_RECENT_TOKENS"
    case tooManyDifferentCardholders = "TOO_MANY_DIFFERENT_CARDHOLDERS"
    case lowDeviceScore = "LOW_DEVICE_SCORE"
    case lowAccountScore = "LOW_ACCOUNT_SCORE"
    case outsideHomeTerritory = "OUTSIDE_HOME_TERRITORY"
    case unableToAssess = "UNABLE_TO_ASSESS"
    case highRiskDigitization = "HIGH_RISK_DIGITIZATION"
    case other = "OTHER"
}

/// A tokenised card stored in this wallet — display metadata for the wallet screen (the token
/// material itself stays in secure storage and is never exposed).
public struct StoredCard: Sendable, Hashable, Identifiable {
    /// Token unique reference — the card's identity for activation/removal/status calls.
    public let tokenUniqueReference: String
    /// Last four digits of the device PAN (empty when unavailable).
    public let panLastFour: String
    /// Masked device PAN for display, e.g. "•••• •••• •••• 1112" (empty when unavailable).
    public let maskedPAN: String
    /// Card expiry for display, "MM/YY" (empty when the response carried none).
    public let expiry: String
    /// The card's display name — the scheme's application label and the masked last four of the
    /// device PAN, e.g. `AFRIGO ****1234`. It is **not** a person's name: a token is not a named
    /// credential, so this carries no personal data. It is also what the card presents to a
    /// terminal in EMV tag `5F20`, so a receipt and this field read the same.
    ///
    /// Empty on cards digitised before it existed — re-digitise to populate it.
    public let cardHolderName: String
    /// Account holder name as digitised.
    public let accountHolderName: String
    /// Bank display name supplied at digitise time.
    public let bankName: String?
    /// Raw digitise response code (e.g. "APPROVED", "APPROVE_REQUIRE_AUTH").
    public let status: String
    /// True when the token still needs user activation before it can pay.
    public let requiresActivation: Bool
    /// True on the wallet's **active** token — the one payments use by default. At most one
    /// stored card is active; change the selection with `setActiveToken(_:)`.
    public let isActive: Bool
    /// True when this card cannot pay until the wallet app has been **online** to refresh it —
    /// render the card greyed out / not tappable and prompt the user to connect.
    /// Derived fresh on every read; it clears on its own once a refresh succeeds.
    public let requiresOnline: Bool

    public var id: String { tokenUniqueReference }
}

/// Outcome of a digitise attempt. On success the token material has already been decrypted and
/// stored securely on-device; `responseCode` is the backend verdict.
public struct DigitiseResult: Sendable, Hashable {
    public let tokenUniqueReference: String?
    public let responseCode: String?
    public let message: String?
    public let activationMethods: [DigitiseActivationMethod]
    /// True when provisioning data was decrypted + stored (the wallet now holds the token material).
    public let tokenStored: Bool

    /// `responseCode == "APPROVED"` — token active and ready.
    public var isApproved: Bool { responseCode == "APPROVED" }
    /// `responseCode == "APPROVE_REQUIRE_AUTH"` — provisioned, activation required.
    public var requiresActivation: Bool { responseCode == "APPROVE_REQUIRE_AUTH" }
}

/// An activation channel offered by the backend (masked email/phone, etc.).
public struct DigitiseActivationMethod: Sendable, Hashable {
    public let medium: String
    public let contact: String?
}

/// A NUBAN-compatible bank that can be linked to an account number.
public struct Bank: Sendable, Hashable, Identifiable {
    /// Bank slug identifier (e.g. `"9_payment_service_bank"`).
    public let slug: String
    /// Display name (e.g. `"9 payment service Bank"`).
    public let name: String
    /// Institution code (e.g. `"120001"`) — used for verify/digitise.
    public let institutionCode: String

    public var id: String { institutionCode }

    public init(slug: String, name: String, institutionCode: String) {
        self.slug = slug
        self.name = name
        self.institutionCode = institutionCode
    }
}

/// Result of an account eligibility check. Eligible when `responseCode == "APPROVED"`.
public struct VerifyAccountResponse: Sendable, Hashable {
    public let responseCode: String?
    public let message: String?

    /// Convenience: the account is within the allowed range and digitise may proceed.
    public var isApproved: Bool { responseCode == "APPROVED" }

    public init(responseCode: String?, message: String?) {
        self.responseCode = responseCode
        self.message = message
    }
}

/// How an activation code is delivered to the customer (mirrors Android `ActivationMethods`).
public enum ActivationMethod: String, Sendable {
    case maskedEmail = "MASKED_EMAIL"
    case maskedMobilePhone = "MASKED_MOBILE_PHONE"
}

/// Why an activation code is being requested (mirrors Android `ActivationCodeReason`).
public enum ActivationReason: String, Sendable {
    case addCard = "ADD_CARD"
    case checkAccountEligibility = "VERIFY_ACCOUNT"
    case other = "OTHER"
}

/// Machine-readable activation failure kinds (`failure_code`) — branch on this, never on
/// `message`. The pair that motivated it: `.codeRequestRateLimited` (disable "resend", keep the
/// flow open) versus `.activationLocked` (terminal — end the flow, contact the issuer), which
/// used to arrive as identical `status=FAILURE` + English prose.
public enum ActivationFailureCode: Sendable, Hashable {
    /// No inactive token exists for the reference — end the flow, re-digitise.
    case tokenNotFound
    /// Provisioning status forbids activation — end the flow, contact the issuer.
    case tokenNotActivatable
    /// Locked after repeated exhausted cycles — terminal: hide both retry and resend.
    case activationLocked
    /// No pending activation — go back to "request a code".
    case noPendingActivation
    /// The pending code lapsed — keep the flow open, enable resend.
    case codeExpired
    /// Wrong code, attempts remain — stay on entry; `attemptsRemaining` says how many.
    case codeInvalid
    /// Attempt cap hit; the cycle is closed — carries the delete recommendation.
    case maxAttemptsExceeded
    /// Too many code (re)sends — disable resend until later; do NOT end the flow.
    case codeRequestRateLimited
    /// The request itself was malformed or unsupported on this endpoint.
    case invalidRequest
    /// The activation failed server-side after a valid code — safe to retry later.
    case activationFailed
    /// A code this build does not know — `raw` carries the wire value; never coerced.
    case unknown(raw: String)

    init?(kmp: VeyraKMP.ActivationFailureCode?, raw: String?) {
        guard let kmp else { return nil }
        switch kmp.name {
        case "TOKEN_NOT_FOUND": self = .tokenNotFound
        case "TOKEN_NOT_ACTIVATABLE": self = .tokenNotActivatable
        case "ACTIVATION_LOCKED": self = .activationLocked
        case "NO_PENDING_ACTIVATION": self = .noPendingActivation
        case "CODE_EXPIRED": self = .codeExpired
        case "CODE_INVALID": self = .codeInvalid
        case "MAX_ATTEMPTS_EXCEEDED": self = .maxAttemptsExceeded
        case "CODE_REQUEST_RATE_LIMITED": self = .codeRequestRateLimited
        case "INVALID_REQUEST": self = .invalidRequest
        case "ACTIVATION_FAILED": self = .activationFailed
        default: self = .unknown(raw: raw ?? kmp.name)
        }
    }
}

/// The server's token-delete recommendation after an exhausted activation cycle: `.must` after
/// an exhausted add-card cycle (the token was never legitimately owned — delete it and start
/// over), `.may` after account verification (deletion is advisory), absent otherwise.
public enum RecommendDelete: Sendable, Hashable {
    case must
    case may
    /// A value this build does not know — `raw` carries the wire value.
    case unknown(raw: String)

    init?(kmp: VeyraKMP.RecommendDelete?, raw: String?) {
        guard let kmp else { return nil }
        switch kmp.name {
        case "MUST": self = .must
        case "MAY": self = .may
        default: self = .unknown(raw: raw ?? kmp.name)
        }
    }
}

/// Response to an activation-code request.
public struct ActivationCodeResponse: Sendable, Hashable {
    public let tokenUniqueReference: String?
    public let expirationDateTime: String?
    public let status: String?
    public let message: String?
    /// Why the request failed, typed — branch on this, never on `message`.
    public let failureCode: ActivationFailureCode?
    /// The raw `failure_code` wire value, for logs and forward compatibility.
    public let failureCodeRaw: String?

    public init(
        tokenUniqueReference: String?, expirationDateTime: String?, status: String?, message: String?,
        failureCode: ActivationFailureCode? = nil, failureCodeRaw: String? = nil
    ) {
        self.tokenUniqueReference = tokenUniqueReference
        self.expirationDateTime = expirationDateTime
        self.status = status
        self.message = message
        self.failureCode = failureCode
        self.failureCodeRaw = failureCodeRaw
    }
}

/// Response to a token activation.
public struct ActivateResponse: Sendable, Hashable {
    public let tokenUniqueReference: String?
    public let status: String?
    public let message: String?
    /// Why activation failed, typed — branch on this, never on `message`.
    public let failureCode: ActivationFailureCode?
    /// The raw `failure_code` wire value, for logs and forward compatibility.
    public let failureCodeRaw: String?
    /// Code attempts left in this cycle, where an attempt cap applies (0 when exhausted/locked).
    public let attemptsRemaining: Int?
    /// The server's delete recommendation after an exhausted cycle.
    public let recommendDelete: RecommendDelete?
    /// The raw `recommend_delete` wire value.
    public let recommendDeleteRaw: String?

    public init(
        tokenUniqueReference: String?, status: String?, message: String?,
        failureCode: ActivationFailureCode? = nil, failureCodeRaw: String? = nil,
        attemptsRemaining: Int? = nil,
        recommendDelete: RecommendDelete? = nil, recommendDeleteRaw: String? = nil
    ) {
        self.tokenUniqueReference = tokenUniqueReference
        self.status = status
        self.message = message
        self.failureCode = failureCode
        self.failureCodeRaw = failureCodeRaw
        self.attemptsRemaining = attemptsRemaining
        self.recommendDelete = recommendDelete
        self.recommendDeleteRaw = recommendDeleteRaw
    }
}

/// Response to a token status update (deactivate).
public struct TokenStatusUpdateResponse: Sendable, Hashable {
    public let tokenUniqueReference: String?
    public let status: String?
    public let message: String?

    public init(tokenUniqueReference: String?, status: String?, message: String?) {
        self.tokenUniqueReference = tokenUniqueReference
        self.status = status
        self.message = message
    }
}

/// A scanned merchant payment that passed **on-device** verification (gateway signature against
/// the SDK's pinned key + expiry) — safe to show on a confirm screen.
public struct VerifiedPayment: Sendable {
    /// The gateway transaction reference the payment settles under.
    public let txRef: String
    public let merchantID: String
    public let merchantName: String
    public let merchantCity: String?
    /// Display amount, major units with 2 decimals (e.g. `"5000.00"`).
    public let amount: String
    /// Amount in minor units (e.g. kobo).
    public let amountMinorUnits: Int64
    /// ISO 4217 numeric currency (e.g. `"566"`).
    public let currencyNumeric: String
    /// When the scanned context expires (epoch seconds) — pay before this.
    public let expiryEpochSeconds: Int64

    /// The verified KMP context, kept for `payScannedContext` (never public API).
    let raw: VerifiedPaymentContext
}

/// Why a scanned QR was rejected. A rejected payload must never reach a confirm screen.
public enum ScanRejectionReason: String, Sendable {
    /// Not a decodable Veyra MPM payload (framing/CRC/missing fields).
    case malformed = "MALFORMED"
    /// No gateway signature on the context.
    case missingSignature = "MISSING_SIGNATURE"
    /// Signing key not in this SDK's pinned set.
    case unknownKey = "UNKNOWN_KEY"
    /// Signature does not verify — tampered or wrong key.
    case badSignature = "BAD_SIGNATURE"
    /// Signature fine but the context is past its expiry.
    case expired = "EXPIRED"
}

/// Outcome of inspecting a scanned QR payload.
public enum ScanInspection: Sendable {
    /// Verified on-device — show the merchant + amount on your confirm screen.
    case verified(VerifiedPayment)
    /// Rejected — end the flow; never show a confirm screen for this payload.
    case rejected(ScanRejectionReason, detail: String?)
}

/// Outcome of a scan-to-pay push, as the gateway stated it.
public struct PaymentOutcome: Sendable, Hashable {
    /// Convenience for the happy path only: `responseStatus == "APPROVED"`. It is `false` for a
    /// declined, failed *and* pending payment alike, so anything that must tell a refusal from an
    /// unresolved payment reads `responseStatus`.
    public let approved: Bool
    public let responseCode: String?
    /// What the gateway said the payment **is**: `"APPROVED"`, `"DECLINED"`, `"FAILED"` or
    /// `"PENDING"`. The push is a synchronous call, but it can still answer `PENDING` — a hop
    /// below the gateway timed out, errored, or is still settling — and that means *not yet
    /// known*, never refused. The SDK stores such a payment open and keeps asking until the
    /// gateway states a final outcome, which then appears on the row in `recentActivity`.
    ///
    /// A plain string, not an enum, so a value added after this version shipped still reaches you.
    public let responseStatus: String?
    /// The stated cause (`"INSUFFICIENT_FUNDS"`, `"NO_RESPONSE_RECEIVED"`, …) — display and log.
    public let responseStatusReason: String?
    public let message: String?
    /// Registered merchant name returned by the gateway — authoritative over the name printed in
    /// the scanned QR. Nil when the gateway did not supply one (show the scanned name instead).
    public let merchantName: String?
    /// Registered merchant location (`"city, state"`) returned by the gateway. Nil when the
    /// gateway did not supply one (fall back to the scanned QR's `merchantCity`).
    public let merchantLocation: String?
}

/// One rendered "show QR to pay" code (dynamic CPM): the payload to display plus its display
/// metadata. The amount is inside the QR's cryptogram; after `expiresAtEpochMillis` render a
/// fresh one (new authentication).
public struct PaymentQr: Sendable, Hashable {
    public let tokenUniqueReference: String
    /// The QR content to render (base64 EMVCo CPM BER-TLV).
    public let payload: String
    /// Amount in minor units (e.g. kobo) — bound into the cryptogram.
    public let amountMinorUnits: Int64
    /// ISO 4217 numeric currency, e.g. `"566"`.
    public let currencyNumeric: String
    /// When the wallet should stop displaying this QR and offer regenerate.
    public let expiresAtEpochMillis: Int64
    /// SHA-256(cryptogram‖ATC‖UN) hex — this render's unique transaction hash. Match it against a
    /// `TransactionSummary.transactionHash` to reconcile the outcome of *exactly this* QR,
    /// instead of guessing by record time.
    public let transactionHash: String
}

/// A token's Limited-Use Key state — for a "keys remaining" indicator and refresh prompts.
public struct LukState: Sendable, Hashable {
    /// How many provisioned keys can still pay (not expired, under their thresholds).
    public let usableKeyCount: Int
    /// True when the SDK considers a key refresh due (low on usable keys, or a key nears expiry).
    public let refreshDue: Bool
}

/// One payment in a token's recent activity — a terminal scan-to-pay outcome.
public struct TokenActivity: Sendable, Hashable {
    public let merchantName: String
    /// Amount in minor units (e.g. kobo).
    public let amountMinorUnits: Int64
    /// ISO 4217 numeric currency in the stored 4-digit shape (e.g. `"0566"`).
    public let currencyNumeric: String
    /// `"APPROVED"` or `"DECLINED"`.
    public let status: String
    /// When the payment was made (epoch milliseconds).
    public let atEpochMillis: Int64
}

/// One row of the customer's transaction history — a payment on any rail (MPM or CPM QR).
public struct TransactionSummary: Sendable, Hashable {
    public let merchantName: String
    /// Amount in minor units (e.g. kobo). 64-bit, matching `MerchantTransaction.amount` and every
    /// gateway field either side of it — a 32-bit amount could not carry a payment above
    /// ₦21,474,836.47.
    public let amountInMinorUnit: Int64
    /// ISO 4217 numeric currency in the stored 4-digit shape (e.g. `"0566"`), or nil.
    public let transactionCurrencyCode: String?
    /// SHA-256(cryptogram‖ATC‖UN) hex — the join key to a `TransactionReceipt`, or nil.
    public let transactionHash: String?
    /// `"PENDING"`, `"APPROVED"`, `"DECLINED"`, `"FAILED"`, or nil for unknown.
    public let authorizationStatus: String?
    /// The outcome's response code (`"00"`, `"51"`, `"91"`…), carried verbatim from the rail
    /// that resolved this row; nil on legacy rows and rows still awaiting their reconcile.
    /// Receipts and support conversations quote this literal.
    public let responseCode: String?
    /// The outcome's stated cause (`"INSUFFICIENT_FUNDS"`, `"QR_EXPIRED"`…), carried verbatim
    /// as a plain string — display it, never parse it; nil on legacy/unresolved rows.
    public let responseStatusReason: String?
    /// When the payment was recorded (epoch milliseconds), for the QR rails; nil for tap rows.
    public let atEpochMillis: Int64?
    /// How this wallet paid: `"TAP"`, `"QR_GENERATED"` (showed a CPM QR), `"QR_SCANNED"`
    /// (scanned a merchant MPM QR); nil on legacy rows — show nothing rather than guess.
    public let entryMethod: String?
    /// Registered merchant location (`"city, state"`) when known; backfilled on CPM rows by
    /// `reconcilePendingTransactions()` from the gateway.
    public let merchantLocation: String?
    /// The merchant's transaction reference (MPM: the scanned QR's txRef, captured before the
    /// push) — with `merchantId` + the transaction date, the join key for MPM merchant receipts,
    /// which carry no cryptogram hash. Nil for tap/legacy rows.
    public let merchantTransactionReference: String?
    /// The merchant id from the verified QR context; nil for tap/legacy rows.
    public let merchantId: String?
    /// The beneficiary credit's identifier (NIP session id inter-bank, batch reference intra-bank)
    /// — display and support only. The SDK polls the confirmation itself; never pass this back.
    /// Nil on rows that were not approved, and from gateways predating the credit rail.
    public let creditTransactionID: String?
    /// Whether the merchant's (beneficiary) bank can confirm the credit at all — **the gate for
    /// everything on this rail**. `true` means the SDK is polling in the background and the app
    /// should render the credit line; `false`/nil means there is nothing to ask, so show no credit
    /// UI for this transaction. Nil is "unknown", never "not credited".
    public let isCreditConfirmationSupported: Bool?
    /// The terminal credit-confirmation state: `"RECEIVED"` (the merchant's bank confirmed the
    /// funds) or `"UNABLE_TO_CONFIRM"` (the 30-day window closed without a confirmation — the
    /// give-up state, *not* a statement that the money never arrived).
    ///
    /// **Nil while in flight**: an unconfirmed attempt is never stored, so nil means "no answer
    /// yet". With `isCreditConfirmationSupported == true` that is the "confirming…" state.
    public let creditConfirmationStatus: String?
    /// When the beneficiary bank posted the credit (ISO date-time). Present on `"RECEIVED"` only.
    public let creditedAt: String?
    /// The beneficiary bank's own reference for the credit — what a customer quotes if a merchant
    /// says the money never arrived. Present on `"RECEIVED"` only.
    public let bankReference: String?
}

/// A scanned merchant receipt, linked to a transaction by `transactionHash`.
public struct TransactionReceipt: Sendable, Hashable {
    public let merchantName: String
    public let merchantId: String?
    public let merchantAddress: String?
    public let transactionType: String
    public let transactionStatus: String
    public let transactionTime: String
    /// Amount in minor units, as a string (e.g. `"10000"`).
    public let totalAmount: String
    /// Display string (e.g. `"100.00"`).
    public let totalAmountFormatted: String
    public let currency: String?
    public let maskedToken: String?
    public let merchantTransactionReference: String?
    public let cdcvmApprovedByWallet: Bool?
    public let cdcvmOutcome: String?
    public let transactionId: String?
    /// SHA-256(cryptogram‖ATC‖UN) hex — links this receipt to a `TransactionSummary`.
    public let transactionHash: String?
}

/// Errors thrown by the Veyra wallet SDK.
public enum VeyraWalletError: Error, Sendable {
    /// `VeyraWallet.configure(_:)` has not been called.
    case notConfigured
    /// A backend call failed; `message` carries the underlying description.
    case requestFailed(message: String)
    /// The device has **no working internet connection**, so the call never left it — ask the user
    /// to connect and try again. Nothing was sent, so nothing needs undoing or reconciling.
    ///
    /// Distinct from `onlineRequired`, which is easy to confuse because both end with "get online":
    /// `onlineRequired` means the *card* has run out of payment keys and the wallet must refresh it,
    /// which is a card state, not a network state. This case means the phone itself has no
    /// connection. A card that needs refreshing on a device that is online reports `onlineRequired`;
    /// any call at all on a device in aeroplane mode reports `noNetworkConnection`.
    case noNetworkConnection(message: String)
    /// The system authentication (Face ID / Touch ID / passcode) failed or was cancelled —
    /// stay on the confirm screen; no payment was attempted.
    case authenticationFailed(message: String)
    /// The card cannot pay until the wallet has been **online** to refresh it —
    /// prompt the user to connect to the internet; no payment was attempted.
    case onlineRequired(message: String)
    /// The card's server-side status is not ACTIVE (e.g. suspended by the issuer) — payments
    /// are refused until a later status sync sees it active again; no payment was attempted.
    case tokenNotActive(message: String)
    /// The amount is larger than this card can carry in one payment. Unlike `onlineRequired`
    /// this does **not** resolve by going online — offer a smaller amount or another card;
    /// no payment was attempted.
    case amountExceedsCardLimit(message: String)
    /// Digitisation answered with a response code this SDK version does not recognise, so the
    /// token was **discarded**: nothing was provisioned and no card was added — even if the
    /// response carried complete token data. A token whose terms the SDK cannot interpret is
    /// never installed on a guess. Show the message, offer a retry, and update the Veyra SDK if
    /// it persists; `message` quotes the raw code for support.
    case unrecognisedResponseCode(message: String)
}

// Without LocalizedError, `error.localizedDescription` renders the useless
// "The operation couldn't be completed. (VeyraWallet.VeyraWalletError error N.)" and the
// underlying reason (e.g. a receipt rejection's precise cause) is invisible to the user AND
// to anyone debugging. Every case now surfaces its carried message.
extension VeyraWalletError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "VeyraWallet is not configured — call VeyraWallet.configure(_:) at launch."
        case .requestFailed(let message):
            return message
        case .noNetworkConnection(let message):
            return message
        case .authenticationFailed(let message):
            return message
        case .onlineRequired(let message):
            return message
        case .tokenNotActive(let message):
            return message
        case .amountExceedsCardLimit(let message):
            return message
        case .unrecognisedResponseCode(let message):
            return message
        }
    }
}

/// Entry point of the Veyra wallet SDK on iOS.
///
/// Configure once at launch, then use the service accessors:
/// ```swift
/// VeyraWallet.configure(.init(environment: .test, apiBaseURL: url, …))
/// let banks = try await VeyraWallet.shared.tokenisation.banks()
/// ```
public final class VeyraWallet: @unchecked Sendable {

    public static let shared = VeyraWallet()

    private let lock = NSLock()
    private var kmp: WalletKmp?

    private init() {}

    /// Configure the SDK. Call once, before any service use (subsequent calls reconfigure).
    public static func configure(_ configuration: VeyraWalletConfiguration) {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        shared.kmp = WalletKmp(
            config: WalletKmpConfig(
                environmentName: configuration.environment.rawValue,
                clientId: configuration.clientID,
                clientSecret: configuration.clientSecret,
                paymentAppProviderId: configuration.paymentAppProviderID,
                tokenRequestorId: configuration.tokenRequestorID,
                // Internal plumbing, not developer API: nil selects the SDK's
                // environment-resolved defaults. ObjC-exported initializers carry no
                // default arguments, so these parameters must be passed explicitly.
                localBaseUrlOverride: nil,
                localGatewayUrlOverride: nil,
                remoteLogsUrlOverride: nil,
                appVersion: configuration.appVersion,
                bundleId: configuration.bundleID,
                appleTeamId: configuration.appleTeamID,
                tokenType: "HCE",
                recommendationStandardVersion: "1.0",
                allowedAcquirerIds: configuration.allowedAcquirerIDs,
                allowedMerchantIds: configuration.allowedMerchantIDs,
                allowedCountryCodes: configuration.allowedCountryCodes,
                allowedMccs: configuration.allowedMCCs
            )
        )
    }

    /// Tokenisation service — bank lookup, eligibility, digitise, activation.
    public var tokenisation: Tokenisation { Tokenisation(owner: self) }

    /// This install's SDK-generated `payment_application_instance_id` (`VYRA` + 32 hex chars):
    /// minted on first use, persisted install-scoped (never backed up), new on reinstall.
    /// Read-only — the app cannot set or regenerate it. Mirrors Android's
    /// `getPaymentApplicationInstanceId()`.
    public func paymentApplicationInstanceID() throws -> String {
        try requireKmp().paymentApplicationInstanceId()
    }

    fileprivate func requireKmp() throws -> WalletKmp {
        lock.lock()
        defer { lock.unlock() }
        guard let kmp else { throw VeyraWalletError.notConfigured }
        return kmp
    }

    /// Tokenisation operations (mirrors Android's `TokenisationService`).
    public struct Tokenisation: Sendable {
        fileprivate let owner: VeyraWallet

        /// Fetch the NUBAN banks that can be linked (optionally filtered by account number).
        /// Mirrors Android `getBanks` incl. de-duplication by institution code.
        public func banks(accountNumber: String? = nil) async throws -> [Bank] {
            try await call { kmp in
                let result = try await kmp.banks(accountNumber: accountNumber)
                return result.map { Bank(slug: $0.slug, name: $0.name, institutionCode: $0.institutionCode) }
            }
        }

        /// Check account eligibility before digitising (mirrors Android `checkAccountEligibility`).
        /// Requires `paymentAppProviderID`/`tokenRequestorID` in the configuration.
        public func verifyAccount(
            accountNumber: String,
            institutionCode: String,
            walletAccountID: String,
            accountHolderName: String,
            accountNumberSource: String? = nil
        ) async throws -> VerifyAccountResponse {
            try await call { kmp in
                let r = try await kmp.verifyAccount(
                    accountNumber: accountNumber,
                    institutionCode: institutionCode,
                    walletAccountId: walletAccountID,
                    accountHolderName: accountHolderName,
                    accountNumberSource: accountNumberSource
                )
                return VerifyAccountResponse(responseCode: r.responseCode, message: r.message)
            }
        }

        /// Digitise (tokenise) an account: attests, sends the device key, and on success decrypts
        /// and stores the token material on-device. Requires `paymentAppProviderID`/`tokenRequestorID` in the
        /// configuration.
        public func digitise(
            accountNumber: String,
            institutionCode: String,
            walletAccountID: String,
            accountHolderName: String,
            emailAddress: String,
            recommendation: TokenizationRecommendation,
            mobileNumber: String? = nil,
            bvn: String? = nil,
            accountHolderAddress: String? = nil,
            accountNumberSource: String? = nil,
            consumerIdentifier: String? = nil,
            deviceScore: TrustScore? = nil,
            accountScore: TrustScore? = nil,
            recommendationReasons: [TokenizationRecommendationReason]? = nil,
            bankName: String? = nil
        ) async throws -> DigitiseResult {
            // number_of_active_tokens is SDK-computed from its token registry — no caller input.
            try await call { kmp in
                let r = try await kmp.digitise(
                    accountNumber: accountNumber,
                    institutionCode: institutionCode,
                    walletAccountId: walletAccountID,
                    accountHolderName: accountHolderName,
                    emailAddress: emailAddress,
                    recommendation: recommendation.rawValue,
                    mobileNumber: mobileNumber,
                    bvn: bvn,
                    accountHolderAddress: accountHolderAddress,
                    accountNumberSource: accountNumberSource,
                    consumerIdentifier: consumerIdentifier,
                    deviceScore: deviceScore?.rawValue,
                    accountScore: accountScore?.rawValue,
                    recommendationReasons: recommendationReasons.map { $0.map(\.rawValue) },
                    bankName: bankName
                )
                return DigitiseResult(
                    tokenUniqueReference: r.tokenUniqueReference,
                    responseCode: r.responseCode,
                    message: r.message,
                    activationMethods: r.activationMethods.map { DigitiseActivationMethod(medium: $0.medium, contact: $0.contact) },
                    tokenStored: r.tokenStored
                )
            }
        }

        /// The tokens this wallet holds — the SDK's own registry, written by
        /// `digitise` on a successful provision; includes which token is active. Local read,
        /// no network.
        public func tokens() async throws -> [StoredCard] {
            try await call { kmp in
                try await kmp.tokens().map {
                    StoredCard(
                        tokenUniqueReference: $0.tokenUniqueReference,
                        panLastFour: $0.panLastFour,
                        maskedPAN: $0.maskedPan,
                        expiry: $0.expiry,
                        cardHolderName: $0.cardHolderName,
                        accountHolderName: $0.accountHolderName,
                        bankName: $0.bankName,
                        status: $0.status,
                        requiresActivation: $0.requiresActivation,
                        isActive: $0.isActive,
                        requiresOnline: $0.requiresOnline
                    )
                }
            }
        }

        /// The wallet's active token — the one payments use — or `nil` when the wallet is empty.
        public var activeToken: StoredCard? {
            get async throws {
                try await tokens().first(where: \.isActive)
            }
        }

        /// Select the token payments use. Throws when the token is not in this wallet.
        public func setActiveToken(_ tokenUniqueReference: String) async throws {
            try await call { kmp in
                try await kmp.setActiveToken(tokenUniqueReference: tokenUniqueReference)
            }
        }

        /// Delete a token from the wallet: best-effort server deactivate, then — always — a full
        /// local wipe of the token and all its payment material, promoting the next token when
        /// the deleted one was active. Use for the user's "remove card" action.
        public func delete(_ tokenUniqueReference: String) async throws {
            try await call { kmp in
                try await kmp.deleteToken(tokenUniqueReference: tokenUniqueReference)
            }
        }

        /// Wipe every token and all SDK-held data from this device (local only).
        public func wipeAll() async throws {
            try await call { kmp in
                try await kmp.wipeAll()
            }
        }

        /// Request an activation code delivered via the chosen method (mirrors Android).
        public func requestActivationCode(
            tokenUniqueReference: String,
            method: ActivationMethod,
            reason: ActivationReason = .addCard
        ) async throws -> ActivationCodeResponse {
            try await call { kmp in
                let r = try await kmp.requestActivationCode(
                    tokenUniqueReference: tokenUniqueReference,
                    selectedActivationMethod: method.rawValue,
                    preferredActivationChannel: method.rawValue,
                    reasonCode: reason.rawValue
                )
                return ActivationCodeResponse(
                    tokenUniqueReference: r.tokenUniqueReference,
                    expirationDateTime: r.expirationDateTime,
                    status: r.status,
                    message: r.message,
                    failureCode: ActivationFailureCode(kmp: r.failureCode, raw: r.failureCodeRaw),
                    failureCodeRaw: r.failureCodeRaw
                )
            }
        }

        /// Activate a token with the code the customer received.
        public func activate(tokenUniqueReference: String, activationCode: String) async throws -> ActivateResponse {
            try await call { kmp in
                let r = try await kmp.activate(tokenUniqueReference: tokenUniqueReference, activationCode: activationCode)
                return ActivateResponse(
                    tokenUniqueReference: r.tokenUniqueReference,
                    status: r.status,
                    message: r.message,
                    failureCode: ActivationFailureCode(kmp: r.failureCode, raw: r.failureCodeRaw),
                    failureCodeRaw: r.failureCodeRaw,
                    attemptsRemaining: r.attemptsRemaining?.intValue,
                    recommendDelete: RecommendDelete(kmp: r.recommendDelete, raw: r.recommendDeleteRaw),
                    recommendDeleteRaw: r.recommendDeleteRaw
                )
            }
        }

        /// Deactivate a token on the backend. On success the SDK also wipes every on-device
        /// artefact for the token and promotes the next token when the active one was removed;
        /// on failure nothing local changes.
        public func deactivate(_ tokenUniqueReference: String) async throws -> TokenStatusUpdateResponse {
            try await call { kmp in
                let r = try await kmp.deactivateToken(tokenUniqueReference: tokenUniqueReference)
                return TokenStatusUpdateResponse(tokenUniqueReference: r.tokenUniqueReference, status: r.status, message: r.message)
            }
        }

        /// Current backend status of a token (e.g. `"ACTIVE"`), or nil when the server omits it.
        public func tokenStatus(tokenUniqueReference: String) async throws -> String? {
            try await call { kmp in
                try await kmp.tokenStatus(tokenUniqueReference: tokenUniqueReference)
            }
        }

        /// Observe a token until it activates:
        /// the SDK polls the token's status every 10 seconds for up to 5 minutes. `onActivated`
        /// fires exactly once when the token becomes ACTIVE (navigate to the wallet);
        /// `onTimeout` after 5 minutes without activation; `onError` reports each failed check
        /// and polling continues. Callbacks arrive on the main thread. Observing the same token
        /// again replaces the previous observer. Pair with `pauseActivationObserver` /
        /// `resumeActivationObserver` (scene background/foreground — the timeout clock keeps
        /// running while paused) and `stopActivationObserver` (screen dismissed).
        public func observeActivation(
            tokenUniqueReference: String,
            onActivated: @escaping () -> Void,
            onTimeout: @escaping () -> Void,
            onError: ((String) -> Void)? = nil
        ) throws {
            let kmp = try owner.requireKmp()
            kmp.observeActivation(
                tokenUniqueReference: tokenUniqueReference,
                onActivated: onActivated,
                onTimeout: onTimeout,
                onError: onError
            )
        }

        /// Pause an activation observer's polling (call when the app backgrounds); the
        /// 5-minute timeout clock keeps running while paused.
        public func pauseActivationObserver(tokenUniqueReference: String) throws {
            try owner.requireKmp().pauseActivationObserver(tokenUniqueReference: tokenUniqueReference)
        }

        /// Resume a paused activation observer; if the timeout window elapsed while paused,
        /// `onTimeout` fires immediately.
        public func resumeActivationObserver(tokenUniqueReference: String) throws {
            try owner.requireKmp().resumeActivationObserver(tokenUniqueReference: tokenUniqueReference)
        }

        /// Stop observing a token's activation (call when the screen is dismissed); no further
        /// callbacks fire.
        public func stopActivationObserver(tokenUniqueReference: String) throws {
            try owner.requireKmp().stopActivationObserver(tokenUniqueReference: tokenUniqueReference)
        }

        // ── Payment refusals ───────────────────────────────────────────────────────────────

        /// Observe payments refused before any proof was built.
        ///
        /// Two callbacks, because the advice differs and giving the payer the wrong one wastes
        /// their time:
        /// - `onRequireOnline` — the card's payment keys need refreshing and the wallet could not
        ///   reach the server. Tell the payer to connect and try again.
        /// - `onAmountExceedsCardLimit` — the amount is larger than this card can carry in one
        ///   payment. **Never tell them to go online here**: a refreshed key carries the same cap,
        ///   so they would connect, retry and fail identically with no way to learn what was
        ///   wrong. Tell them to pay less or use another card. `cardLimitMinorUnits` is that cap
        ///   when it is known, and `nil` when it could not be read — omit the figure rather than
        ///   show a guess.
        ///
        /// Both report **this payment**, not the card's state: `requiresOnline` on a card answers
        /// the different question "can this card pay *anything* offline?" and stays `false` for a
        /// card that can still make smaller payments. Show a message about the payment that just
        /// failed; don't grey the card out on the strength of one refused amount.
        ///
        /// On iOS these fire from the QR rails (`rail` is `"CPM_QR"` or `"MPM_QR"`); there is no
        /// tap-to-pay on iOS, so no `"TAP"` refusal can occur. The pay calls also keep throwing
        /// `VeyraWalletError.onlineRequired` / `.amountExceedsCardLimit` — this observer is
        /// additional, for hosts that would rather handle refusals in one place than at every call
        /// site.
        ///
        /// Callbacks arrive on the main thread. Observing again replaces the previous observer.
        public func observePaymentRefusals(
            onRequireOnline: @escaping (_ tokenUniqueReference: String?, _ amountMinorUnits: Int64, _ rail: String) -> Void,
            onAmountExceedsCardLimit: @escaping (_ tokenUniqueReference: String?, _ amountMinorUnits: Int64, _ cardLimitMinorUnits: Int64?, _ rail: String) -> Void
        ) throws {
            let kmp = try owner.requireKmp()
            kmp.observePaymentRefusals(
                onRequireOnline: { tokenUniqueReference, amountMinorUnits, rail in
                    onRequireOnline(tokenUniqueReference, amountMinorUnits.int64Value, rail)
                },
                onAmountExceedsCardLimit: { tokenUniqueReference, amountMinorUnits, cardLimitMinorUnits, rail in
                    onAmountExceedsCardLimit(
                        tokenUniqueReference,
                        amountMinorUnits.int64Value,
                        cardLimitMinorUnits?.int64Value,
                        rail
                    )
                }
            )
        }

        /// Stop observing payment refusals; no further callbacks fire.
        public func stopObservingPaymentRefusals() throws {
            try owner.requireKmp().stopObservingPaymentRefusals()
        }

        // ── Scan-to-pay: inspect → authenticate (Face ID / Touch ID) → pay ─────────────────

        /// Inspect a scanned merchant QR payload. Verification happens **on-device** (gateway
        /// signature against the SDK's pinned key + expiry). Only `.verified` may be shown on a
        /// confirm screen; every `.rejected` must end the flow.
        public func inspectScannedQr(_ payload: String) throws -> ScanInspection {
            let kmp = try owner.requireKmp()
            let result = kmp.inspectScannedQr(payload: payload)
            if let verified = result as? MpmScanResultVerified {
                let ctx = verified.context
                return .verified(VerifiedPayment(
                    txRef: ctx.txRef,
                    merchantID: ctx.merchantId,
                    merchantName: ctx.merchantName,
                    merchantCity: ctx.merchantCity,
                    amount: ctx.amount,
                    amountMinorUnits: ctx.amountMinorUnits,
                    currencyNumeric: ctx.currencyNumeric,
                    expiryEpochSeconds: ctx.expiryEpochSeconds,
                    raw: ctx
                ))
            }
            if let rejected = result as? MpmScanResultRejected {
                let reason = ScanRejectionReason(rawValue: rejected.reason.name) ?? .malformed
                return .rejected(reason, detail: rejected.detail)
            }
            return .rejected(.malformed, detail: "unrecognised inspection result")
        }

        /// CDCVM for scan-to-pay: shows the **system** authentication sheet (Face ID / Touch ID,
        /// falling back to the device passcode when `allowDeviceCredential`) over your confirm
        /// screen. On success the SDK records a fresh, **single-use** authentication —
        /// `payScannedContext` requires one and fails without it (SDK-enforced). Put the
        /// merchant and amount in `reason` so the gesture is visibly bound to what it authorizes
        /// (e.g. `"Pay ₦5,000.00 to Ada's Store"`). Throws `.authenticationFailed` on
        /// cancel/failure — stay on the confirm screen; nothing was recorded.
        public func authenticateForScannedPayment(
            reason: String,
            allowDeviceCredential: Bool = true
        ) async throws {
            let kmp = try owner.requireKmp()
            do {
                try await kmp.authenticateForScannedPayment(
                    reason: reason,
                    allowDeviceCredential: allowDeviceCredential
                )
            } catch {
                throw VeyraWalletError.authenticationFailed(message: error.localizedDescription)
            }
        }

        /// Pay a verified scanned payment with the wallet's **active token**. Requires a fresh
        /// `authenticateForScannedPayment` (one authentication per payment — the SDK enforces
        /// it). Whatever the gateway states — approved, declined, failed or still pending — also
        /// lands in the paying token's `recentActivity`; a pending row keeps being polled by the
        /// SDK until the gateway states a final outcome.
        public func payScannedContext(_ payment: VerifiedPayment) async throws -> PaymentOutcome {
            try await call { kmp in
                let outcome = try await kmp.payScannedContext(verified: payment.raw)
                return PaymentOutcome(
                    approved: outcome.approved,
                    responseCode: outcome.responseCode,
                    responseStatus: outcome.responseStatus,
                    responseStatusReason: outcome.responseStatusReason,
                    message: outcome.message,
                    merchantName: outcome.merchantName,
                    merchantLocation: outcome.merchantLocation
                )
            }
        }

        /// Render a **show QR to pay** code (dynamic CPM): key the merchant-stated amount first —
        /// it rides inside the QR's cryptogram, so the merchant's scan charges exactly that
        /// amount or fails verification. Requires a fresh `authenticateForScannedPayment`
        /// (one authentication per QR — a regenerate after `expiresAtEpochMillis` needs a new
        /// one; the SDK enforces it). Fully offline: nothing is sent; the merchant's SoftPOS
        /// submits the payment and the outcome appears via the wallet's history polling.
        /// - Parameter onExpired: the SDK calls this once, on the main thread, when the
        /// returned QR reaches its `expiresAtEpochMillis`. Blank/replace the code on this so it
        /// can't be scanned once lapsed (a dimmed QR is still machine-readable). The SDK owns the
        /// timer: a new `showQrToPay` supersedes it, and `cancelQrExpiry()` stops it (call on
        /// teardown). Omit to keep the old behaviour.
        public func showQrToPay(amountMinorUnits: Int64, onExpired: (() -> Void)? = nil) async throws -> PaymentQr {
            try await call { kmp in
                let qr = try await kmp.showQrToPay(amountMinorUnits: amountMinorUnits, onExpired: onExpired)
                return PaymentQr(
                    tokenUniqueReference: qr.tokenUniqueReference,
                    payload: qr.payload,
                    amountMinorUnits: qr.amountMinorUnits,
                    currencyNumeric: qr.currencyNumeric,
                    expiresAtEpochMillis: qr.expiresAtEpochMillis,
                    transactionHash: qr.transactionHash
                )
            }
        }

        /// Stop the active show-to-pay QR expiry watch started by `showQrToPay`. Call on
        /// teardown (the QR screen is dismissed) so the `onExpired` callback can't fire into dead
        /// UI. Idempotent; a new `showQrToPay` also supersedes any prior watch.
        public func cancelQrExpiry() {
            (try? owner.requireKmp())?.cancelQrExpiry()
        }

        /// The token's recent activity: terminal scan-to-pay outcomes, most recent first.
        /// Local read, no network.
        public func recentActivity(tokenUniqueReference: String) async throws -> [TokenActivity] {
            try await call { kmp in
                try await kmp.recentActivity(tokenUniqueReference: tokenUniqueReference).map {
                    TokenActivity(
                        merchantName: $0.merchantName,
                        amountMinorUnits: $0.amountMinorUnits,
                        currencyNumeric: $0.currencyNumeric,
                        status: $0.status,
                        atEpochMillis: $0.atEpochMillis
                    )
                }
            }
        }

        // ── Receipts & transaction history ─────────────────────────────────────

        /// Process a scanned merchant-receipt QR: decode/validate, verify it matches a transaction
        /// this wallet made, dedupe, and store. Returns the stored receipt. Raw JSON or base64.
        @discardableResult
        /// - Parameter expectedTransactionHash: set when the scan was launched FROM a specific
        /// transaction's screen — a receipt belonging to a different transaction is
        /// rejected (and not stored) instead of silently linking elsewhere. Nil = unscoped.
        public func processReceipt(_ qrPayload: String, expectedTransactionHash: String? = nil) async throws -> TransactionReceipt {
            try await call { kmp in
                map(try await kmp.processReceipt(qrPayload: qrPayload, expectedTransactionHash: expectedTransactionHash))
            }
        }

        /// The last `limit` stored receipts, most recent first. Local read, no network.
        public func receipts(limit: Int = 100) async throws -> [TransactionReceipt] {
            try await call { kmp in try await kmp.receipts(limit: Int32(limit)).map(map) }
        }

        /// The receipt linked to a transaction by its hash, or nil. Local read.
        public func receipt(forTransactionHash transactionHash: String) async throws -> TransactionReceipt? {
            try await call { kmp in
                try await kmp.receiptForTransaction(transactionHash: transactionHash).map(map)
            }
        }

        /// The token's full transaction history (all rails), most recent first. Local read.
        public func transactionHistory(tokenUniqueReference: String, limit: Int = 100) async throws -> [TransactionSummary] {
            try await call { kmp in
                try await kmp.transactionHistory(tokenUniqueReference: tokenUniqueReference, limit: Int32(limit))
                    .map(Self.map)
            }
        }

        /// Ask the backend about **one** pending transaction now, keyed by its transaction hash, and
        /// return the updated stored row.
        ///
        /// The per-transaction counterpart to `reconcilePendingTransactions()`, which asks about
        /// every open row and returns nothing — this one answers about the row the customer is
        /// actually looking at. The SDK polls a pending transaction for you with exponential backoff
        /// and **stops after 30 days**; this is how a customer gets an answer sooner than the next
        /// rung, and the only route to one once that window has closed.
        ///
        /// It runs the SDK's own background sweep for this single row — same query, same reading of
        /// the answer, same write into the same local history — so an on-demand check and a
        /// background check cannot disagree. It is **not** a way to force an outcome: a payment that
        /// is still unsettled answers `PENDING` again.
        ///
        /// - Returns: the transaction as it stands after the check, or `nil` if no row on this device
        ///   carries that hash. A row that already has a final outcome is returned unchanged, without
        ///   a network call.
        /// - Throws: `VeyraWalletError.noNetworkConnection` when the device is offline, and the usual
        ///   transport errors otherwise. A failed check never changes the stored row.
        public func refreshTransactionStatus(transactionHash: String) async throws -> TransactionSummary? {
            try await call { kmp in
                try await kmp.refreshTransactionStatus(transactionHash: transactionHash).map(Self.map)
            }
        }

        /// Check the merchant credit **now** for one approved payment — "has the merchant's bank
        /// actually received the funds I paid?" — and return the updated stored row.
        ///
        /// The SDK already asks this in the background, with exponential backoff, for **30 days**
        /// after the payment, and then records the row as `"UNABLE_TO_CONFIRM"` — which means *"we
        /// stopped asking"*, never *"the merchant was not paid"*. This is how a customer gets an
        /// answer sooner than the next rung, and the only route to one once that window has closed:
        /// it still works on a row already marked `"UNABLE_TO_CONFIRM"`, and a later `"RECEIVED"`
        /// replaces that give-up.
        ///
        /// **Check `isCreditConfirmationSupported` on the transaction first.** Not every merchant's
        /// bank is on the confirmation rail. Offer this action only while
        /// ```swift
        /// txn.authorizationStatus == "APPROVED"
        ///     && txn.isCreditConfirmationSupported == true
        ///     && txn.creditConfirmationStatus != "RECEIVED"
        /// ```
        /// A call on a row that fails that predicate makes **no network request** and returns the row
        /// unchanged rather than throwing.
        ///
        /// Settlement only: nothing on this path can change the payment's `authorizationStatus`,
        /// `responseCode` or `responseStatusReason`. There is deliberately no callback — the returned
        /// row and the SDK's stored history are the whole surface.
        ///
        /// - Returns: the transaction as it stands after the check, or `nil` if no row on this device
        ///   carries that hash.
        /// - Throws: `VeyraWalletError.noNetworkConnection` when the device is offline, and the usual
        ///   transport errors otherwise. A failed check never changes the stored row.
        public func refreshCreditConfirmation(transactionHash: String) async throws -> TransactionSummary? {
            try await call { kmp in
                try await kmp.refreshCreditConfirmation(transactionHash: transactionHash).map(Self.map)
            }
        }

        private static func map(_ r: VeyraKMP.TransactionSummary) -> TransactionSummary {
            TransactionSummary(
                merchantName: r.merchantName,
                amountInMinorUnit: r.amountInMinorUnit,
                transactionCurrencyCode: r.transactionCurrencyCode,
                transactionHash: r.transactionHash,
                authorizationStatus: r.authorizationStatus,
                responseCode: r.responseCode,
                responseStatusReason: r.responseStatusReason,
                atEpochMillis: r.atEpochMillis?.int64Value,
                entryMethod: r.entryMethod,
                merchantLocation: r.merchantLocation,
                merchantTransactionReference: r.merchantTransactionReference,
                merchantId: r.merchantId,
                creditTransactionID: r.creditTransactionId,
                isCreditConfirmationSupported: r.isCreditConfirmationSupported?.boolValue,
                creditConfirmationStatus: r.creditConfirmationStatus,
                creditedAt: r.creditedAt,
                bankReference: r.bankReference
            )
        }

        /// Reconcile still-PENDING transactions against the backend. Call on scene-active
        /// (a `scenePhase` observer) and after showing a CPM QR; the CPM rail is offline, so this is
        /// how a shown-QR payment's outcome (approved/declined) lands in the history. Best-effort.
        public func reconcilePendingTransactions() async throws {
            try await call { kmp in try await kmp.reconcilePendingTransactions() }
        }

        private func map(_ r: VeyraKMP.TransactionReceipt) -> TransactionReceipt {
            TransactionReceipt(
                merchantName: r.merchantName,
                merchantId: r.merchantId,
                merchantAddress: r.merchantAddress,
                transactionType: r.transactionType,
                transactionStatus: r.transactionStatus,
                transactionTime: r.transactionTime,
                totalAmount: r.totalAmount,
                totalAmountFormatted: r.totalAmountFormatted,
                currency: r.currency,
                maskedToken: r.maskedToken,
                merchantTransactionReference: r.merchantTransactionReference,
                cdcvmApprovedByWallet: r.cdcvmApprovedByWallet?.boolValue,
                cdcvmOutcome: r.cdcvmOutcome,
                transactionId: r.transactionId,
                transactionHash: r.transactionHash
            )
        }

        // ── LUK refresh: keep the token paying past its initial key allotment ──────────────

        /// The token's Limited-Use Key state — how many keys can still pay and whether a refresh
        /// is due. For a "keys remaining" indicator. Local read, no network.
        public func lukState(tokenUniqueReference: String) async throws -> LukState {
            try await call { kmp in
                let s = try await kmp.lukState(tokenUniqueReference: tokenUniqueReference)
                return LukState(usableKeyCount: Int(s.usableKeyCount), refreshDue: s.refreshDue)
            }
        }

        /// Scene-active wallet maintenance. Call when the app becomes active (e.g. from a
        /// `scenePhase` observer): the SDK syncs each stored card's server status (a suspended
        /// card becomes non-payable until polled active again; a deactivated one is removed),
        /// self-heals cards the server marks as needing refresh, and tops up the active card's
        /// payment keys if they're running low — the key check also runs automatically before
        /// every payment. Best-effort: a no-op without cards; failures never throw.
        public func topUpKeysIfNeeded() async throws {
            try await call { kmp in
                try await kmp.topUpKeysIfNeeded()
            }
        }

        /// Shared guard + error mapping: KMP/transport failures surface as `VeyraWalletError`.
        private func call<T>(_ body: (WalletKmp) async throws -> T) async throws -> T {
            let kmp = try owner.requireKmp()
            do {
                return try await body(kmp)
            } catch let error as VeyraWalletError {
                throw error
            } catch {
                let message = error.localizedDescription
                // the device has no working connection and the call never left it.
                // Checked before the card-state refusals below because it is a fact about the phone
                // rather than about a card, and because on an offline device it is the *only* honest
                // answer any of these calls can give.
                if message.contains("NO_NETWORK_CONNECTION") {
                    throw VeyraWalletError.noNetworkConnection(
                        message: "No internet connection — connect to the internet and try again")
                }
                // the KMP layer codes the generic go-online refusal into the message;
                // surface it as the typed case so hosts can branch without string matching.
                // an amount over the card's per-payment limit: going online cannot fix it,
                // so it is a distinct case from onlineRequired.
                if message.contains("AMOUNT_EXCEEDS_CARD_LIMIT") {
                    throw VeyraWalletError.amountExceedsCardLimit(
                        message: "This amount is too large for this card — try a smaller amount, or another card")
                }
                if message.contains("ONLINE_REQUIRED") {
                    throw VeyraWalletError.onlineRequired(
                        message: "Connect to the internet — the wallet needs to refresh this card before it can pay")
                }
                // a non-ACTIVE polled status (e.g. issuer-side suspension) refuses
                // before any proof is built; typed so hosts can branch without string matching.
                if message.contains("TOKEN_NOT_ACTIVE") {
                    throw VeyraWalletError.tokenNotActive(message: message)
                }
                // digitisation answered with a code this build cannot classify: the token was
                // discarded and nothing was stored. Typed so an add-card screen can offer a
                // retry instead of showing a generic request failure.
                if message.contains("UNRECOGNISED_RESPONSE_CODE") {
                    throw VeyraWalletError.unrecognisedResponseCode(message: message)
                }
                throw VeyraWalletError.requestFailed(message: message)
            }
        }
    }
}
