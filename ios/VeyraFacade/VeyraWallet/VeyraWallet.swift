// VeyraWallet — public iOS API of the Veyra wallet SDK.
//
// Pure-Swift facade over the VeyraKMP umbrella framework (Swift-idiomatic: async/await,
// typed errors). KMP/Obj-C types (VKMP*) must never appear in public signatures — every
// boundary maps to a Swift type here.
//
// Android ↔ iOS name mapping (excerpt): the same operations on the same owner, with Swift naming
// (no `get` prefix) — VeyraWalletSdk.getInstance()?.getBanks { … }
// ↔ try await VeyraWallet.shared.banks()
import Foundation
import VeyraKMP

/// Configuration for the Veyra wallet SDK.
///
/// **URLs are provided by the SDK, not the app developer** — selecting an `environment` is all
/// that is needed; endpoints resolve from the SDK's shared defaults (the same single source of
/// truth as Android). The only URL hooks are development overrides.
public struct VeyraWalletConfiguration: Sendable {
    public let environment: VeyraEnvironment
    /// Wallet identity (mirrors Android's `VeyraWalletSdkConfig`; required for eligibility/digitise).
    /// The `paymentApplicationInstanceID` is NOT configured — the SDK generates and persists an
    /// install-scoped one and sends it on every eligibility/digitise request (read it via
    /// `VeyraWallet.shared.paymentApplicationInstanceID()`).
    public let paymentAppProviderID: String?
    public let tokenRequestorID: String?
    /// App version reported to the backend during digitise.
    public let appVersion: String
    /// The app's bundle id override for attestation — always `nil` for apps: the SDK detects it
    /// from `Bundle.main`, as Android reads `context.packageName`.
    let bundleID: String? = nil
    /// **Your app's** Apple Developer Team ID (e.g. `"TV4JRK677Z"`). With the app's bundle id this is the
    /// App Attest app id (`teamID.bundleID`) the attestation binds to and the backend verifies.
    /// App Attest attests the *app*, so this is your team — not the SDK vendor's. **Mandatory:**
    /// `digitise` fails fast if it is missing.
    public let appleTeamID: String
    /// Digitise `provision_context` allow-lists the integrating app decides (mirror Android's
    /// `VeyraWalletSdkConfig`). The token product can restrict provisioning to these — a
    /// restricted dimension that the request omits is declined.
    ///
    /// Country, currency and MCC are **not** here: the SDK declares those itself, identically on
    /// every platform, so they can neither be supplied nor overridden by the app.
    public let allowedAcquirerIDs: [String]
    public let allowedMerchantIDs: [String]
    /// Whether the device passcode may satisfy the payment authentication the SDK raises, inside
    /// the same system sheet, for customers with no enrolled biometry. Default `true` — Apple Pay
    /// treats the device passcode as CDCVM, and biometry-only needs a bespoke "unavailable on this
    /// device" flow. Set `false` for a biometry-only posture.
    public let cdcvmAllowDeviceCredential: Bool
    /// Optional overrides for the copy in the payment authentication sheet. The SDK composes
    /// English defaults from the payment itself, so set these only for different wording or
    /// another locale. `{amount}` is substituted in all of them, `{merchant}` in the pay ones.
    ///
    /// iOS shows a **single** string, so the *subtitle* is what the customer reads — it carries
    /// the merchant and amount. Overriding only a title has no visible effect on this platform.
    public let cdcvmPayTitle: String?
    public let cdcvmPaySubtitle: String?
    public let cdcvmShowQrTitle: String?
    public let cdcvmShowQrSubtitle: String?
    /// The longest the SDK waits for one backend call, start to finish, in seconds (5–60).
    /// `nil` (the default) keeps the SDK's own timeouts. A value outside 5–60 makes `configure`
    /// throw `invalidConfiguration`. A payment that runs out of time is **pending**, not failed:
    /// the request may have reached the server, so the SDK checks the result later. A shorter
    /// timeout answers sooner but leaves more payments pending.
    public let requestTimeoutSeconds: Int?

    public init(
        environment: VeyraEnvironment,
        paymentAppProviderID: String? = nil,
        tokenRequestorID: String? = nil,
        appVersion: String = "1.0.0",
        appleTeamID: String,
        allowedAcquirerIDs: [String] = [],
        allowedMerchantIDs: [String] = [],
        cdcvmAllowDeviceCredential: Bool = true,
        cdcvmPayTitle: String? = nil,
        cdcvmPaySubtitle: String? = nil,
        cdcvmShowQrTitle: String? = nil,
        cdcvmShowQrSubtitle: String? = nil,
        requestTimeoutSeconds: Int? = nil
    ) {
        self.environment = environment
        self.paymentAppProviderID = paymentAppProviderID
        self.tokenRequestorID = tokenRequestorID
        self.appVersion = appVersion
        self.appleTeamID = appleTeamID
        self.allowedAcquirerIDs = allowedAcquirerIDs
        self.allowedMerchantIDs = allowedMerchantIDs
        self.cdcvmAllowDeviceCredential = cdcvmAllowDeviceCredential
        self.cdcvmPayTitle = cdcvmPayTitle
        self.cdcvmPaySubtitle = cdcvmPaySubtitle
        self.cdcvmShowQrTitle = cdcvmShowQrTitle
        self.cdcvmShowQrSubtitle = cdcvmShowQrSubtitle
        self.requestTimeoutSeconds = requestTimeoutSeconds
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

/// What `VeyraWallet.verifyAccount(_:)` checks — the same fields as Android's and React Native's
/// `VerifyAccountParams`.
/// Where the account number in a verify / digitise request came from. The same values as Android and
/// React Native `AccountNumberSource`.
public enum AccountNumberSource: String, Sendable {
    case cardOnFile = "CARD_ON_FILE"
    case manual = "MANUAL"
    case recent = "RECENT"
    case scan = "SCAN"
    case application = "APPLICATION"
    case existingToken = "EXISTING_TOKEN"
    case other = "OTHER"
}

public struct VerifyAccountParams: Sendable, Hashable {
    public var accountNumber: String
    public var institutionCode: String
    /// The account's registered email address or phone number — see
    /// ``DigitiseParams/walletAccountID``.
    public var walletAccountID: String
    public var accountHolderName: String?
    public var accountNumberSource: AccountNumberSource?

    public init(
        accountNumber: String,
        institutionCode: String,
        walletAccountID: String,
        accountHolderName: String? = nil,
        accountNumberSource: AccountNumberSource? = nil
    ) {
        self.accountNumber = accountNumber
        self.institutionCode = institutionCode
        self.walletAccountID = walletAccountID
        self.accountHolderName = accountHolderName
        self.accountNumberSource = accountNumberSource
    }
}

/// The card to add with `VeyraWallet.digitise(_:)` — the same fields, and the same required
/// ones, as Android's and React Native's `DigitiseParams`.
public struct DigitiseParams: Sendable, Hashable {
    public var accountNumber: String
    public var institutionCode: String
    public var accountHolderName: String
    /// The wallet's own identifier for this user — **use the account's registered email address
    /// or phone number**. The SDK hashes it and the issuer recomputes that hash from the
    /// email/phone on its own record and compares. A value the bank does not hold (a GUID, an
    /// internal user id, a placeholder) hashes fine and matches nothing, costing the
    /// digitisation its identity-match signal and raising its risk score.
    public var walletAccountID: String
    public var emailAddress: String
    /// The wallet provider's own judgement — never defaulted by the SDK.
    public var recommendation: TokenizationRecommendation
    public var consumerIdentifier: String?
    /// The account holder's BVN. Optional when your payment app provider is registered as the
    /// account issuer; otherwise the backend refuses with `BVN_REQUIRED`
    /// (`DigitiseResult.responseStatusReason`). Blank is sent as absent.
    public var bvn: String?
    public var accountHolderAddress: String?
    public var mobileNumber: String?
    /// Your own unique ID for this add-card. Set one to be able to cancel it with
    /// `VeyraWallet.cancelDigitise(clientRequestID:)`; leave it `nil` and the SDK generates one.
    public var clientRequestID: String?
    public var accountNumberSource: AccountNumberSource?
    public var deviceScore: TrustScore?
    public var accountScore: TrustScore?
    public var recommendationReasons: [TokenizationRecommendationReason]?
    /// Shown on the stored card.
    public var bankName: String?

    public init(
        accountNumber: String,
        institutionCode: String,
        accountHolderName: String,
        walletAccountID: String,
        emailAddress: String,
        recommendation: TokenizationRecommendation,
        consumerIdentifier: String? = nil,
        bvn: String? = nil,
        accountHolderAddress: String? = nil,
        mobileNumber: String? = nil,
        clientRequestID: String? = nil,
        accountNumberSource: AccountNumberSource? = nil,
        deviceScore: TrustScore? = nil,
        accountScore: TrustScore? = nil,
        recommendationReasons: [TokenizationRecommendationReason]? = nil,
        bankName: String? = nil
    ) {
        self.accountNumber = accountNumber
        self.institutionCode = institutionCode
        self.accountHolderName = accountHolderName
        self.walletAccountID = walletAccountID
        self.emailAddress = emailAddress
        self.recommendation = recommendation
        self.consumerIdentifier = consumerIdentifier
        self.bvn = bvn
        self.accountHolderAddress = accountHolderAddress
        self.mobileNumber = mobileNumber
        self.clientRequestID = clientRequestID
        self.accountNumberSource = accountNumberSource
        self.deviceScore = deviceScore
        self.accountScore = accountScore
        self.recommendationReasons = recommendationReasons
        self.bankName = bankName
    }
}

/// A token (tokenised card) in this wallet, from `tokens()`, `token(_:)` and `activeToken()`. The
/// same type, with the same fields, as Android and React Native `Token`. It carries no card data:
/// the token material itself stays in secure storage and is never exposed.
public struct Token: Sendable, Hashable, Identifiable {
    /// Token unique reference — the identifier every wallet call takes.
    public let tokenUniqueReference: String
    /// The token's number masked to its last four digits for display, e.g. "**** **** **** 1112"
    /// (empty when unavailable).
    public let maskedPAN: String
    /// Last four digits of the token's number (empty when unavailable).
    public let panLastFour: String
    /// The card's display name — the scheme's application label and the masked last four, e.g.
    /// `AFRIGO ****1234`. It is **not** a person's name, and it is what the card presents to a
    /// terminal in EMV tag `5F20`, so a receipt and this field read the same. Empty on cards added
    /// before it existed.
    public let cardHolderName: String
    /// Expiry for display, "MM/YY" (empty when the token carries none).
    public let expiry: String
    /// Bank display name supplied at digitise time.
    public let bankName: String?
    /// The card scheme, when known.
    public let cardScheme: CardScheme?
    /// The token's lifecycle status as the SDK last saw it — lets a card list say *why* a card is
    /// not payable (suspended, pending activation, expired) without a network call per card.
    /// `nil` when the token has never been status-synced.
    public let status: TokenStatus?
    /// True when the token is activated and can pay.
    public let isActive: Bool
    /// True on the token payments use (`setActiveToken(_:)`). At most one token is selected.
    public let isSelected: Bool
    /// True when the token still needs user activation before it can pay.
    public let requiresActivation: Bool
    /// When ``requiresActivation``, how the user can activate; `nil` when none were offered.
    public let activationMethods: [ActivationMethodInfo]?
    /// True when this token cannot pay until the wallet app has been **online** to refresh it —
    /// render it greyed out / not tappable and prompt the user to connect. Derived fresh on every
    /// read; it clears on its own once a refresh succeeds.
    public let requiresOnline: Bool
    /// True when this token was added on **another device** (or before this app was reinstalled)
    /// and the Veyra backend will not issue it new payment keys here. It cannot pay on this phone
    /// again: prompt the user to remove it and add it again. A token in this state always reads
    /// `requiresOnline == false`.
    public let deviceNotBound: Bool

    public var id: String { tokenUniqueReference }
}

/// The payment network a token belongs to. The same values as Android and React Native `CardScheme`.
public enum CardScheme: String, Sendable {
    case iventurePay = "IVENTUREPAY"
    case visa = "VISA"
    case mastercard = "MASTERCARD"
    case amex = "AMEX"
    case discover = "DISCOVER"
    case unknown = "UNKNOWN"
}

/// A token's lifecycle status. The same values as Android and React Native `TokenStatus`.
public enum TokenStatus: Sendable, Hashable {
    case active
    case pendingActivation
    case suspended
    case deactivated
    case expired
    /// A value this build does not know — `raw` carries the stored value. Not payable.
    case unknown(raw: String)

    /// The status for a stored or wire value.
    public init(raw: String) {
        switch raw.uppercased() {
        case "ACTIVE": self = .active
        case "PENDING_ACTIVATION": self = .pendingActivation
        case "SUSPENDED": self = .suspended
        case "DEACTIVATED": self = .deactivated
        case "EXPIRED": self = .expired
        default: self = .unknown(raw: raw)
        }
    }

    /// The wire value (`"ACTIVE"`, `"PENDING_ACTIVATION"`…), or the raw value for an unknown status.
    public var rawValue: String {
        switch self {
        case .active: return "ACTIVE"
        case .pendingActivation: return "PENDING_ACTIVATION"
        case .suspended: return "SUSPENDED"
        case .deactivated: return "DEACTIVATED"
        case .expired: return "EXPIRED"
        case .unknown(let raw): return raw
        }
    }
}

/// Outcome of a digitise attempt. On success the token material has already been decrypted and
/// stored securely on-device; `responseCode` is the backend verdict.
public struct DigitiseResult: Sendable, Hashable {
    public let tokenUniqueReference: String?
    public let responseCode: String?
    public let message: String?
    /// What the **call** did, as distinct from what the issuer decided: `"APPROVED"`,
    /// `"DECLINED"`, `"FAILED"` or `"NOT_SENT"` (never reached Veyra — retry with the same request).
    /// Digitise is never `"PENDING"`. Carried verbatim — a value this SDK has never heard of
    /// still reaches you.
    public let responseStatus: String
    /// **Why** — the symbolic cause, and the field to branch on.
    ///
    /// Carries the issuer's own cause verbatim (`ACCOUNT_NAME_MISMATCH`, `BVN_MISMATCH`,
    /// `ACCOUNT_NOT_LINKED_TO_BVN`, `ACCOUNT_ADDRESS_MISMATCH`, `ACCOUNT_BLOCKED`,
    /// `MAX_ACTIVE_TOKENS_EXCEEDED`, `RISK_SCORE_BELOW_THRESHOLD`, …), the token provider's when
    /// it decided this itself (`INVALID_ACCOUNT_NUMBER`, `UNKNOWN_ISSUER`, `BVN_REQUIRED` — no
    /// `bvn` and your payment app provider is not registered as the account issuer, …), or an API
    /// failure on a `FAILED` call.
    ///
    /// **Present on `APPROVE_REQUIRE_AUTH` too**, which is the case worth handling: it says why
    /// step-up is required — usually an identity mismatch — so the activation prompt can say
    /// something truthful instead of a generic "verification needed".
    ///
    /// Before this existed the cause reached apps only inside `message`, prose the backend is free
    /// to reword. Keep a default branch: the vocabulary grows without an SDK release.
    public let responseStatusReason: String?
    public let activationMethods: [ActivationMethodInfo]
    /// True when provisioning data was decrypted + stored (the wallet now holds the token material).
    public let tokenStored: Bool
    /// The `client_request_id` this digitise was sent with — yours, or the one the SDK generated.
    /// Keep it when the result is `"FAILED"` with `NO_RESPONSE_RECEIVED` or `UPSTREAM_ERROR`: the
    /// token provider may have created a token whose details never reached the phone, and
    /// ``VeyraWallet/deactivateDigitise(clientRequestID:)`` switches it off. Then digitise again
    /// with a new ID.
    public let clientRequestID: String?

    /// True when the token was added — ``responseStatus`` is `APPROVED`. Read from the status,
    /// never the code.
    public var isApproved: Bool { responseStatus == ResponseStatus.approved }
    /// True when the token was added but must be activated before it can pay (decision
    /// `APPROVE_REQUIRE_AUTH`).
    public var requiresActivation: Bool { responseCode == "APPROVE_REQUIRE_AUTH" }
}

/// One way a token can be activated, as the backend offered it — on a ``DigitiseResult`` and on a
/// ``Token``. `medium` is an ``ActivationMedium`` value; `contact` the masked address or number to
/// show, when there is one. The same type as Android and React Native `ActivationMethodInfo`.
public struct ActivationMethodInfo: Sendable, Hashable {
    public let medium: String
    public let contact: String?
}

/// Result of an account eligibility check. Eligible when `responseCode == "APPROVED"`.
public struct VerifyAccountResponse: Sendable, Hashable {
    public let responseCode: String?
    public let message: String?
    /// What the **call** did: `"APPROVED"`, `"DECLINED"` (the check ran, the answer is no),
    /// or `"FAILED"` (it could not be run, so nothing was decided about the account — also when it never
    /// reached Veyra; retry as is). A check changes nothing, so it is never `"PENDING"`.
    public let responseStatus: String
    /// **Why** — the symbolic cause, and the field to branch on. Same vocabulary as
    /// `DigitiseResult.responseStatusReason`; see it for the values and the warning about
    /// defaulting.
    public let responseStatusReason: String?

    /// Convenience: the account is within the allowed range and digitise may proceed.
    public var isApproved: Bool { responseStatus == ResponseStatus.approved }

    public init(responseCode: String?, message: String?,
                responseStatus: String, responseStatusReason: String? = nil) {
        self.responseCode = responseCode
        self.message = message
        self.responseStatus = responseStatus
        self.responseStatusReason = responseStatusReason
    }
}

/// How a token can be activated — the same six values as Android and React Native's
/// `ActivationMedium`. `requestActivationCode` sends a code by ``maskedEmail`` or
/// ``maskedMobilePhone``; the others are instructions to show the customer (call the bank, visit
/// its website, open its app).
public enum ActivationMedium: String, Sendable {
    case maskedEmail = "MASKED_EMAIL"
    case maskedMobilePhone = "MASKED_MOBILE_PHONE"
    case automatedCallCenterPhone = "AUTOMATED_CALL_CENTER_PHONE"
    case callCenterPhone = "CALL_CENTER_PHONE"
    case website = "WEBSITE"
    case mobileApplication = "MOBILE_APPLICATION"
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

    /// The outcome — `APPROVED` (code sent), `FAILED` (refused: ``responseStatusReason`` is the
    /// failure code, e.g. `CODE_REQUEST_RATE_LIMITED`), `PENDING` (sent, no usable answer — wait before
    /// asking again). Never reaching Veyra is `FAILED` too, with its reason — fix it and ask again.
    public let responseStatus: String
    public let responseStatusReason: String?

    public init(
        tokenUniqueReference: String?, expirationDateTime: String?, status: String?, message: String?,
        failureCode: ActivationFailureCode? = nil, failureCodeRaw: String? = nil,
        responseStatus: String = "APPROVED", responseStatusReason: String? = nil
    ) {
        self.tokenUniqueReference = tokenUniqueReference
        self.expirationDateTime = expirationDateTime
        self.status = status
        self.message = message
        self.failureCode = failureCode
        self.failureCodeRaw = failureCodeRaw
        self.responseStatus = responseStatus
        self.responseStatusReason = responseStatusReason
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

    /// The outcome — `APPROVED` (activated), `FAILED` (refused: ``responseStatusReason`` is the failure
    /// code, e.g. `CODE_INVALID`), `PENDING` (sent, no usable answer — read the token status before
    /// trying again). Never reaching Veyra is `FAILED` too, with its reason — submit the same code again.
    public let responseStatus: String
    public let responseStatusReason: String?

    public init(
        tokenUniqueReference: String?, status: String?, message: String?,
        failureCode: ActivationFailureCode? = nil, failureCodeRaw: String? = nil,
        attemptsRemaining: Int? = nil,
        recommendDelete: RecommendDelete? = nil, recommendDeleteRaw: String? = nil,
        responseStatus: String = "APPROVED", responseStatusReason: String? = nil
    ) {
        self.responseStatus = responseStatus
        self.responseStatusReason = responseStatusReason
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
    /// The token's state after the call (e.g. `"DEACTIVATED"`), when the server answered.
    public let status: String?
    public let message: String?
    /// The outcome of the call — `APPROVED` (done; the card was removed from this device), `FAILED`,
    /// (also when it never reached Veyra) or `PENDING` (sent, no usable answer). Only `APPROVED`
    /// removes the card locally.
    public let responseStatus: String
    public let responseStatusReason: String?

    public init(tokenUniqueReference: String?, status: String?, message: String?,
                responseStatus: String = "APPROVED", responseStatusReason: String? = nil) {
        self.tokenUniqueReference = tokenUniqueReference
        self.status = status
        self.message = message
        self.responseStatus = responseStatus
        self.responseStatusReason = responseStatusReason
    }
}

/// The NUBAN bank list (a read). `APPROVED` with ``banks``, or the reason there are none
/// (`NO_NETWORK_CONNECTION`…). Never `PENDING`; retrying as is is always safe.
public struct BankList: Sendable, Hashable {
    public let banks: [Bank]
    public let responseStatus: String
    public let responseStatusReason: String?
    public let message: String?
}

/// A card's status on the server (a read). `APPROVED` with ``tokenStatus`` (`"ACTIVE"`,
/// `"SUSPENDED"`…), or the reason the check could not be made. Never `PENDING`.
public struct TokenStatusResult: Sendable, Hashable {
    public let tokenStatus: String?
    public let responseStatus: String
    public let responseStatusReason: String?
    public let message: String?
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
    public let amountDisplay: String
    /// Amount in minor units (e.g. kobo).
    public let amountMinorUnits: Int64
    /// ISO 4217 numeric currency (e.g. `"566"`).
    public let currencyCode: String
    /// When the scanned context expires (epoch seconds) — pay before this.
    public let expiresAtEpochSeconds: Int64
    /// The merchant's order ID for this sale, signed into the QR — pass it to
    /// `cancelPayment(merchantOrderID:)` to cancel the payment. Nil for a QR that carries none;
    /// such a payment cannot be cancelled.
    public let merchantOrderID: String?

    /// The verified KMP context, kept for `payScannedContext` (never public API).
    let raw: VeyraKMP.VerifiedPayment
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
    /// gateway states a final outcome, which then appears on the row in `transactions(tokenUniqueReference:limit:)`.
    ///
    /// A plain string, not an enum, so a value added after this version shipped still reaches you.
    public let responseStatus: String
    /// The stated cause (`"INSUFFICIENT_FUNDS"`, `"NO_RESPONSE_RECEIVED"`, …) — display and log.
    public let responseStatusReason: String?
    public let message: String?
    /// Registered merchant name returned by the gateway — authoritative over the name printed in
    /// the scanned QR. Nil when the gateway did not supply one (show the scanned name instead).
    public let merchantName: String?
    /// Registered merchant location (`"city, state"`) returned by the gateway. Nil when the
    /// gateway did not supply one (fall back to the scanned QR's `merchantCity`).
    public let merchantLocation: String?
    /// The merchant-bank credit's identifier; nil unless the payment was approved and the gateway
    /// sent one.
    public let creditTransactionID: String?
    /// Whether the merchant's bank can confirm the credit at all — the backend's payment-time
    /// decision. Settlement news only: it never changes the outcome above.
    public let isCreditConfirmationSupported: Bool?
}

/// One rendered "show QR to pay" code (dynamic CPM): the payload to display plus its display
/// metadata. The amount is inside the QR's cryptogram; after `expiresAtEpochMillis` render a
/// fresh one (new authentication).
///
/// Branch on ``responseStatus``: `APPROVED` — show ``payload``; the payment's own outcome arrives
/// through history. `NOT_SENT` — no QR was made (``responseStatusReason``: `AUTH_CANCELLED`,
/// `AUTH_FAILED`, `AUTH_UNAVAILABLE`, `ONLINE_REQUIRED`, `AMOUNT_EXCEEDS_CARD_LIMIT`,
/// `TOKEN_NOT_ACTIVE`, `DEVICE_NOT_BOUND`, `NO_ACTIVE_CARD`, `CARD_CANNOT_SHOW_QR`, `INVALID_REQUEST`);
/// fix it and try again. Showing a QR sends nothing, so there is no other status.
public struct PaymentQr: Sendable, Hashable {
    public let tokenUniqueReference: String?
    /// The QR content to render (base64 EMVCo CPM BER-TLV). `nil` unless `APPROVED`.
    public let payload: String?
    /// Amount in minor units (e.g. kobo) — bound into the cryptogram.
    public let amountMinorUnits: Int64
    /// ISO 4217 numeric currency, e.g. `"566"`.
    public let currencyCode: String?
    /// When the wallet should stop displaying this QR and offer regenerate.
    public let expiresAtEpochMillis: Int64
    /// SHA-256(cryptogram‖ATC‖UN) hex — this render's unique transaction hash. Match it against a
    /// `TransactionSummary.transactionHash` to reconcile the outcome of *exactly this* QR,
    /// instead of guessing by record time.
    public let transactionHash: String?
    public let responseStatus: String
    public let responseStatusReason: String?
    public let message: String?
}

/// A payment was refused on the phone before anything was built or sent — delivered to the handlers
/// passed to `observePaymentRefusals`. The same payload as Android and React Native
/// `WalletPaymentRefusal`. ``type`` says which refusal, and the advice differs: `requireOnline`
/// (connect and try again), `amountExceedCardLimit` (pay less or use another card — going online
/// does not help), `deviceNotBound` (remove the card and add it again on this phone).
public struct WalletPaymentRefusal: Sendable, Hashable {
    /// `"requireOnline"`, `"amountExceedCardLimit"` or `"deviceNotBound"`.
    public let type: String
    /// The token the payment was attempted with; nil when the SDK could not attribute it.
    public let tokenUniqueReference: String?
    /// The amount that was refused, in minor units.
    public let amountMinorUnits: Int64
    /// The card's per-payment cap in minor units — on `amountExceedCardLimit` only, when known.
    public let cardLimitMinorUnits: Int64?
    /// The rail the payment was attempted on: `CPM_QR` or `MPM_QR` (iOS has no tap-to-pay).
    public let rail: String
    /// A human-readable description, for logs.
    public let message: String

    init(_ k: KmpWalletPaymentRefusal) {
        type = k.type
        tokenUniqueReference = k.tokenUniqueReference
        amountMinorUnits = k.amountMinorUnits
        cardLimitMinorUnits = k.cardLimitMinorUnits?.int64Value
        rail = k.rail
        message = k.message
    }
}

/// A card's lifecycle status changed — the issuer suspended, reactivated, expired or deactivated
/// it. Delivered to `VeyraWallet.shared.observeTokenStatusChanged`.
public struct TokenStatusChangedEvent: Sendable, Hashable {
    /// Which card. Fires per card, so an app holding several must check it.
    public let tokenUniqueReference: String
    /// `ACTIVE`, `PENDING_ACTIVATION`, `SUSPENDED`, `DEACTIVATED`, `EXPIRED`, or `UNKNOWN` for a
    /// value this SDK build does not recognise.
    public let status: TokenStatus
    /// The status exactly as stored, recognised or not. For `UNKNOWN` this is the only thing that
    /// identifies it — quote it in logs and support calls.
    public let rawStatus: String
    /// Whether the card can pay **right now**, as the SDK's own payment gates read it. `false` for
    /// suspended, pending-activation, expired, deactivated and unrecognised statuses alike.
    ///
    /// This answers "is the card alive", not "can it pay this amount": a card whose payment keys
    /// are exhausted reports `canPay == true` here and refuses the payment through
    /// `requiresOnline`. Two different questions, deliberately.
    public let canPay: Bool
    /// What the card held before, or `nil` when this is the first status it has ever had.
    public let previousStatus: String?
}

/// A wallet payment that was left `PENDING` has reached its final outcome. Delivered to
/// `VeyraWallet.shared.observeTransactionResolved`.
public struct WalletTransactionResolvedEvent: Sendable, Hashable {
    /// The hash identifying this payment on every rail — the same value a receipt links on, and
    /// what you pass to look the row up again.
    public let transactionHash: String
    /// The card that paid.
    public let tokenUniqueReference: String?
    /// `APPROVED`, `DECLINED` or `FAILED` — never `PENDING`.
    public let status: String
    /// The wire literal (`"00"`, `"51"`, …), for receipts and support. `nil` if the answer had none.
    public let responseCode: String?
    /// Why it ended that way, e.g. `INSUFFICIENT_FUNDS`. Display and log it; never parse it.
    public let reason: String?
    /// What was paid, in minor units — so you can render the notification without a store read.
    public let amountMinorUnits: Int64
    /// The merchant, as the stored row records it.
    public let merchantName: String
}

/// A card's payment-key state changed — delivered by `observeTokenKeyStateChanged(onTokenKeyStateChanged:)`.
///
/// The same event Android and React Native deliver as `TokenKeyStateEvent`.
public struct TokenKeyStateEvent: Sendable, Hashable {
    /// Which card. Fires per card, so an app holding several must check it.
    public let tokenUniqueReference: String
    /// `true` when the card cannot pay until the SDK refreshes its keys — the same value
    /// `Token.requiresOnline` carries.
    public let requiresOnline: Bool
    /// `true` when the backend has refused this device payment keys for the card (it was added on
    /// another device, or before this app was reinstalled). Going online cannot fix it, so
    /// `requiresOnline` is `false` alongside it: prompt the user to add the card again. The same
    /// value `Token.deviceNotBound` carries.
    public let deviceNotBound: Bool

    public init(tokenUniqueReference: String, requiresOnline: Bool, deviceNotBound: Bool) {
        self.tokenUniqueReference = tokenUniqueReference
        self.requiresOnline = requiresOnline
        self.deviceNotBound = deviceNotBound
    }
}

/// One row of the customer's transaction history — a payment on any rail (MPM or CPM QR).
public struct TransactionSummary: Sendable, Hashable {
    public let merchantName: String
    /// Amount in minor units (e.g. kobo). 64-bit, matching `MerchantTransaction.amount` and every
    /// gateway field either side of it — a 32-bit amount could not carry a payment above
    /// ₦21,474,836.47.
    public let amountMinorUnits: Int64
    /// ISO 4217 numeric currency, three digits (e.g. `"566"`), or nil.
    public let currencyCode: String?
    /// SHA-256(cryptogram‖ATC‖UN) hex — the join key to a `TransactionReceipt`, or nil.
    public let transactionHash: String?
    /// The token that paid.
    public let tokenUniqueReference: String?
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
    /// ISO 8601 local date-time with timezone, from the terminal's EMV date and time — tap rows
    /// only; QR rows carry ``atEpochMillis`` instead. Nil on legacy rows.
    public let localTransactionDateTime: String?
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
    public let merchantID: String?
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
    /// The merchant's own order/basket id for this sale, as the merchant's app supplied it at
    /// charge time — the id the merchant's systems know the sale by. A scanned-QR (MPM) row
    /// carries it from payment time; tap/CPM rows learn it from the status poll, so nil on a
    /// still-open row means "not learned yet", not "no order id". Display only — never a lookup
    /// key; receipts and refreshes still key off `transactionHash`/`merchantTransactionReference`.
    public let merchantOrderID: String?
}

/// A scanned merchant receipt, linked to a transaction by `transactionHash`.
/// The outcome of choosing the card payments use (`setActiveToken`). On the phone; nothing is sent.
/// `APPROVED`: selected. `FAILED`: not selected, `responseStatusReason` says why — `CARD_NOT_FOUND`
/// (no such card in this wallet).
public struct TokenSelection: Sendable, Hashable {
    public let responseStatus: String
    public let responseStatusReason: String?
    public let message: String?
    /// True when the card is now the one payments use.
    public var selected: Bool { responseStatus == ResponseStatus.approved }
}

/// The answer to ``VeyraWallet/openPaySession()`` — the same type and reasons as Android's
/// `PaySessionResult`. iPhone cannot pay by tap (Apple keeps card emulation to itself), so on iOS it is
/// always `FAILED` / `NFC_UNAVAILABLE` — the answer an Android phone without NFC gives, which a
/// cross-platform app already handles by offering a QR rail.
public struct PaySessionResult: Sendable, Hashable {
    public static let modeRefused = "MODE_REFUSED"
    public static let nfcUnavailable = "NFC_UNAVAILABLE"
    public static let nfcDisabled = "NFC_DISABLED"
    public static let tapRoutingRefused = "TAP_ROUTING_REFUSED"
    public static let screenNotActive = "SCREEN_NOT_ACTIVE"

    public let responseStatus: String
    public let responseStatusReason: String?
    public let message: String?
    /// True when tap-to-pay is armed on the pay screen. Never on iOS.
    public var opened: Bool { responseStatus == ResponseStatus.approved }
}

/// The answer to `reconcilePendingTransactions` — a read across every open transaction, so it states no
/// status of its own. `failureReason` is set only when the reconcile itself could not run; read the
/// updated rows from the history either way.
public struct ReconcileResult: Sendable, Hashable {
    public let failureReason: String?
    public let message: String?
    /// True when the reconcile ran.
    public var checked: Bool { failureReason == nil }
}

/// The outcome of scanning a merchant receipt QR (`processReceipt`). On the phone; nothing is sent.
/// `APPROVED` with ``receipt``, or `FAILED` with the reason: `INVALID_RECEIPT` (not a readable Veyra
/// receipt), `RECEIPT_NOT_FROM_THIS_WALLET`, `RECEIPT_MISMATCH` (amount / currency / date / merchant /
/// reference disagree with this wallet's record), `PAYMENT_NOT_CONFIRMED` (scan again shortly) or
/// `RECEIPT_FOR_ANOTHER_TRANSACTION`.
public struct ReceiptScan: Sendable, Hashable {
    /// The stored receipt; nil unless `responseStatus` is `APPROVED`.
    public let receipt: TransactionReceipt?
    public let responseStatus: String
    public let responseStatusReason: String?
    public let message: String?
    /// True when the receipt was accepted and stored.
    public var stored: Bool { responseStatus == ResponseStatus.approved && receipt != nil }
}

public struct TransactionReceipt: Sendable, Hashable {
    public let merchantName: String
    public let merchantID: String?
    public let merchantAddress: String?
    public let transactionType: String
    public let transactionStatus: String
    public let transactionTime: String
    /// Amount in minor units, as a string (e.g. `"10000"`).
    public let totalAmountMinorUnits: Int64
    /// Display string (e.g. `"100.00"`).
    public let totalAmountFormatted: String
    public let currencyCode: String?
    public let maskedToken: String?
    public let merchantTransactionReference: String?
    public let cdcvmApprovedByWallet: Bool?
    public let cdcvmOutcome: String?
    public let transactionID: String?
    /// SHA-256(cryptogram‖ATC‖UN) hex — links this receipt to a `TransactionSummary`.
    public let transactionHash: String?
}

// Without LocalizedError, `error.localizedDescription` renders the useless
// "The operation couldn't be completed. (VeyraWallet.VeyraError error N.)".
/// The wallet's per-customer work, stopped and started by the shared customer session when a
/// customer signs out or another signs in.
private final class WalletCustomerWork: NSObject, CustomerSessionParticipant {
    private unowned let owner: VeyraWallet
    init(owner: VeyraWallet) { self.owner = owner }
    func startCustomerWork() { owner.startCustomerWork() }
    func stopCustomerWork() { owner.stopCustomerWork() }
}

/// Entry point of the Veyra wallet SDK on iOS.
///
/// Configure once at launch, then call the wallet's operations on `VeyraWallet.shared`:
/// ```swift
/// try VeyraWallet.configure(customerID: signedInCustomer, config: .init(environment: .test, …), provider: provider)
/// let wallet = VeyraWallet.shared
/// let banks = try await wallet.banks()
/// ```
public final class VeyraWallet: @unchecked Sendable {

    public static let shared = VeyraWallet()

    private let lock = NSLock()
    private var kmp: WalletKmp?
    // Kept so a sign-in can build the instance for whoever is signed in.
    private var configuration: VeyraWalletConfiguration?
    private lazy var customerWork = WalletCustomerWork(owner: self)
    // Tokens with a live activation observer, for `hasActivationObserver`, each with the
    // registration it belongs to so a replaced observer's late callback cannot clear its
    // successor. Guarded by `lock`.
    private var observedActivations: [String: UUID] = [:]

    private init() {}

    /// Configure the SDK for the customer your app has signed in. Call at every launch, before
    /// any service use (subsequent calls reconfigure).
    ///
    /// Cards, keys, history and receipts are kept **per customer**, and the SDK never remembers
    /// who is signed in, so `customerID` is required every time. The same customer again changes
    /// nothing and downloads nothing; a different customer stops the previous customer's work and
    /// opens the new customer's cards. Observer registrations are dropped on a switch — register
    /// them again after this call. Call `signOut()` when a customer logs out.
    ///
    /// - Parameters:
    ///   - customerID: The customer your app has authenticated. Sent to Veyra on the wallet's
    ///     card requests (add card, eligibility, activation) so support can find them; device
    ///     logs only ever show it masked.
    ///   - provider: How the SDK reaches Veyra — required, no default: your `VeyraAssertionProvider` or
    ///     `VeyraProxyProvider`. A combined app passes the same one to both SDKs.
    ///
    /// - Throws: `VeyraError.invalidConfiguration` when the provider cannot be used (the
    ///   message names the problem) or is of a different kind from an earlier `configure`, or when
    ///   `requestTimeoutSeconds` is outside 5–60. Every
    ///   `configure` re-binds the provider, which background work uses too.
    @discardableResult
    public static func configure(customerID: String, config configuration: VeyraWalletConfiguration, provider: any VeyraProvider) throws -> VeyraWallet {
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
                try IosConnections.shared.bindWallet(environmentName: configuration.environment.rawValue, provider: kmpProvider, requestTimeoutSeconds: requestTimeout)
            } catch {
                throw VeyraError.invalidConfiguration(message: error.localizedDescription)
            }
        }
        // Stop and drop the current instance (a reconfigure, or another customer), keep the
        // configuration so a sign-in can build for whoever is signed in, then sign in: the
        // session starts the work — this facade's [startCustomerWork] builds the instance.
        shared.lock.lock()
        let previous = shared.kmp
        shared.kmp = nil
        // Stopping the instance stops its activation pollers too.
        shared.observedActivations.removeAll()
        shared.configuration = configuration
        shared.lock.unlock()
        previous?.stopCustomerWork()
        CustomerSession.shared.register(participant: shared.customerWork)
        CustomerSession.shared.signIn(customerId: customerID)
        return shared
    }

    /// The customer has logged out: stop everything the wallet runs for them and drop every
    /// observer registration. Their cards, keys, history and receipts stay on the device for when
    /// they sign in again (nothing is downloaded then). Until the next `configure` every call
    /// throws `VeyraError.notSignedIn`.
    public static func signOut() {
        CustomerSession.shared.signOut()
    }

    /// Build the instance for the customer now signed in, if there is none.
    fileprivate func startCustomerWork() {
        lock.lock()
        defer { lock.unlock() }
        guard kmp == nil, let configuration, CustomerScope.shared.isSignedIn else { return }
        kmp = VeyraWallet.makeKmp(configuration)
    }

    /// Stop the instance's work and drop it: it is bound to the customer it was built for.
    fileprivate func stopCustomerWork() {
        lock.lock()
        let current = kmp
        kmp = nil
        // The instance stops every activation poller with its work.
        observedActivations.removeAll()
        lock.unlock()
        current?.stopCustomerWork()
    }

    private static func makeKmp(_ configuration: VeyraWalletConfiguration) -> WalletKmp {
        WalletKmp(
            config: WalletKmpConfig(
                environmentName: configuration.environment.rawValue,
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
                // Same ObjC-export rule as the overrides above: these carry Kotlin defaults that
                // do not survive the export, so they are passed explicitly.
                cdcvmAllowDeviceCredential: configuration.cdcvmAllowDeviceCredential,
                cdcvmPayTitle: configuration.cdcvmPayTitle,
                cdcvmPaySubtitle: configuration.cdcvmPaySubtitle,
                cdcvmShowQrTitle: configuration.cdcvmShowQrTitle,
                cdcvmShowQrSubtitle: configuration.cdcvmShowQrSubtitle
            )
        )
    }

    /// This install's SDK-generated `payment_application_instance_id` (`VYRA` + 32 hex chars):
    /// minted on first use, persisted install-scoped (never backed up), new on reinstall.
    /// Read-only — the app cannot set or regenerate it. Mirrors Android's
    /// `getPaymentApplicationInstanceId()`.
    public func paymentApplicationInstanceID() throws -> String {
        try requireKmp().paymentApplicationInstanceId()
    }

    // MARK: Pay session — the same three calls as Android and React Native

    /// Arms tap-to-pay on the pay screen. iPhone cannot pay by tap, so this always answers
    /// `FAILED` / `NFC_UNAVAILABLE` and changes nothing. It exists so the same integration runs on
    /// every platform: on Android the same call arms the screen.
    public func openPaySession() -> PaySessionResult {
        PaySessionResult(
            responseStatus: ResponseStatus.failed,
            responseStatusReason: PaySessionResult.nfcUnavailable,
            message: "iPhone cannot pay by tap; pay with a QR code"
        )
    }

    /// Disarms tap-to-pay. Nothing is ever armed on iOS, so this does nothing.
    public func closePaySession() {}

    /// Whether tap-to-pay is armed on the pay screen. Always `false` on iOS.
    public func isPaySessionOpen() -> Bool { false }

    fileprivate func requireKmp() throws -> WalletKmp {
        lock.lock()
        defer { lock.unlock() }
        guard let kmp else {
            throw configuration == nil ? VeyraError.notConfigured : VeyraError.notSignedIn
        }
        return kmp
    }
}

// MARK: - Wallet operations
//
// Every wallet operation hangs off `VeyraWallet.shared` — the same owner as Android's
// `VeyraWalletSdk` and React Native's `wallet`.
extension VeyraWallet {

    /// Fetch the NUBAN banks that can be linked (optionally filtered by account number).
    /// Mirrors Android `getBanks` incl. de-duplication by institution code.
    public func banks(accountNumber: String? = nil) async throws -> BankList {
        try await call { kmp in
            let r = try await kmp.banks(accountNumber: accountNumber)
            return BankList(
                banks: r.banks.map { Bank(slug: $0.slug, name: $0.name, institutionCode: $0.institutionCode) },
                responseStatus: r.responseStatus, responseStatusReason: r.responseStatusReason, message: r.message
            )
        }
    }

    /// Check account eligibility before digitising — the same call as Android's and React Native's
    /// `verifyAccount(params)`. Requires `paymentAppProviderID`/`tokenRequestorID` in the
    /// configuration.
    public func verifyAccount(_ params: VerifyAccountParams) async throws -> VerifyAccountResponse {
        try await call { kmp in
            let r = try await kmp.verifyAccount(
                accountNumber: params.accountNumber,
                institutionCode: params.institutionCode,
                walletAccountId: params.walletAccountID,
                accountHolderName: params.accountHolderName ?? "",
                accountNumberSource: params.accountNumberSource?.rawValue
            )
            return VerifyAccountResponse(
                responseCode: r.responseCode,
                message: r.message,
                responseStatus: r.responseStatus,
                responseStatusReason: r.responseStatusReason
            )
        }
    }

    /// Digitise (tokenise) an account — the same call as Android's and React Native's
    /// `digitise(params)`: attests, sends the device key, and on success decrypts and stores the
    /// token material on-device. Requires `paymentAppProviderID`/`tokenRequestorID` in the
    /// configuration.
    ///
    /// Set ``DigitiseParams/clientRequestID`` to be able to cancel it with
    /// ``cancelDigitise(clientRequestID:)``; leave it `nil` and the SDK generates one. Either way,
    /// cancelling the Swift `Task` that awaits this call cancels it while it is still on the
    /// device: it then returns `NOT_SENT` / `CANCELLED`. Once the request has been sent a cancel
    /// is refused and the card is added (or refused) as normal.
    public func digitise(_ params: DigitiseParams) async throws -> DigitiseResult {
        // With no ID from the app, one is made here rather than by the core, so cancelling the
        // Task can still name this digitisation.
        let requestID = params.clientRequestID?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? UUID().uuidString
        // number_of_active_tokens is SDK-computed from its token registry — no caller input.
        return try await TaskCancelBridge.run(
            cancel: { [self] in cancelDigitise(clientRequestID: requestID) },
            notFound: .noDigitisationInProgressForClientRequestID
        ) { try await call { kmp in
            let r = try await kmp.digitise(
                accountNumber: params.accountNumber,
                institutionCode: params.institutionCode,
                walletAccountId: params.walletAccountID,
                accountHolderName: params.accountHolderName,
                emailAddress: params.emailAddress,
                recommendation: params.recommendation.rawValue,
                mobileNumber: params.mobileNumber,
                bvn: params.bvn,
                accountHolderAddress: params.accountHolderAddress,
                accountNumberSource: params.accountNumberSource?.rawValue,
                consumerIdentifier: params.consumerIdentifier,
                deviceScore: params.deviceScore?.rawValue,
                accountScore: params.accountScore?.rawValue,
                recommendationReasons: params.recommendationReasons.map { $0.map(\.rawValue) },
                bankName: params.bankName,
                clientRequestId: requestID
            )
            return DigitiseResult(
                tokenUniqueReference: r.tokenUniqueReference,
                responseCode: r.responseCode,
                message: r.message,
                responseStatus: r.responseStatus,
                responseStatusReason: r.responseStatusReason,
                activationMethods: r.activationMethods.map { ActivationMethodInfo(medium: $0.medium, contact: $0.contact) },
                tokenStored: r.tokenStored,
                clientRequestID: requestID
            )
        } }
    }

    /// The tokens this wallet holds — the SDK's own registry, written by
    /// `digitise` on a successful provision; includes which token is active. Local read,
    /// no network.
    public func tokens() async throws -> [Token] {
        try await call { kmp in
            try await kmp.tokens().map {
                Token(
                    tokenUniqueReference: $0.tokenUniqueReference,
                    maskedPAN: $0.maskedPan,
                    panLastFour: $0.panLastFour,
                    cardHolderName: $0.cardHolderName,
                    expiry: $0.expiry,
                    bankName: $0.bankName,
                    cardScheme: nil,
                    status: $0.status.isEmpty ? nil : TokenStatus(raw: $0.status),
                    isActive: $0.isActive,
                    isSelected: $0.isSelected,
                    requiresActivation: $0.requiresActivation,
                    activationMethods: nil,
                    requiresOnline: $0.requiresOnline,
                    deviceNotBound: $0.deviceNotBound
                )
            }
        }
    }

    /// The wallet's active token — the one payments use — or `nil` when the wallet is empty.
    public func activeToken() async throws -> Token? {
        try await tokens().first(where: \.isSelected)
    }

    /// One token by its unique reference, or `nil` when it is not in this wallet. Local read.
    public func token(_ tokenUniqueReference: String) async throws -> Token? {
        try await tokens().first { $0.tokenUniqueReference == tokenUniqueReference }
    }

    /// Select the token payments use. Answers a ``TokenSelection``: `APPROVED`, or `FAILED` /
    /// `CARD_NOT_FOUND` when the token is not in this wallet. On the phone; only a setup mistake
    /// throws.
    @discardableResult
    public func setActiveToken(_ tokenUniqueReference: String) async throws -> TokenSelection {
        try await call { kmp in
            let r = try await kmp.setActiveToken(tokenUniqueReference: tokenUniqueReference)
            return TokenSelection(responseStatus: r.responseStatus, responseStatusReason: r.responseStatusReason,
                                 message: r.message)
        }
    }

    /// Request an activation code delivered via the chosen medium — one of the token's
    /// `activationMethods` from `digitise`. The same call as Android and React Native.
    public func requestActivationCode(
        tokenUniqueReference: String,
        medium: ActivationMedium,
        reason: ActivationReason = .addCard
    ) async throws -> ActivationCodeResponse {
        try await call { kmp in
            let r = try await kmp.requestActivationCode(
                tokenUniqueReference: tokenUniqueReference,
                selectedActivationMethod: medium.rawValue,
                preferredActivationChannel: medium.rawValue,
                reasonCode: reason.rawValue
            )
            return ActivationCodeResponse(
                tokenUniqueReference: r.tokenUniqueReference,
                expirationDateTime: r.expirationDateTime,
                status: r.status,
                message: r.message,
                failureCode: ActivationFailureCode(kmp: r.failureCode, raw: r.failureCodeRaw),
                failureCodeRaw: r.failureCodeRaw,
                responseStatus: r.responseStatus ?? ResponseStatus.failed,
                responseStatusReason: r.responseStatusReason
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
                recommendDeleteRaw: r.recommendDeleteRaw,
                responseStatus: r.responseStatus ?? ResponseStatus.failed,
                responseStatusReason: r.responseStatusReason
            )
        }
    }

    /// Deactivate a token on the backend. On success the SDK also wipes every on-device
    /// artefact for the token and promotes the next token when the active one was removed;
    /// on failure nothing local changes.
    public func deactivateToken(_ tokenUniqueReference: String) async throws -> TokenStatusUpdateResponse {
        try await call { kmp in
            let r = try await kmp.deactivateToken(tokenUniqueReference: tokenUniqueReference)
            return TokenStatusUpdateResponse(tokenUniqueReference: r.tokenUniqueReference, status: r.status, message: r.message,
                                             responseStatus: r.responseStatus ?? ResponseStatus.failed,
                                             responseStatusReason: r.responseStatusReason)
        }
    }

    /// Deactivate, on the server, the token that the ``digitise(_:)`` sent with `clientRequestID`
    /// created — for a digitise that ended `"FAILED"` with `NO_RESPONSE_RECEIVED` or `UPSTREAM_ERROR`
    /// after it was sent, whose token details never reached this device. Only this device can do it.
    ///
    /// - `"APPROVED"` — deactivated (or already was); `tokenUniqueReference` names it. If that card
    ///   is on this device, it is removed with its data.
    /// - `"FAILED"` / `NO_TOKEN_CREATED` — the digitise ended before a token was created.
    /// - `"FAILED"` / `DIGITISATION_NOT_FOUND` — no finished digitise with that ID from this device.
    ///   One still running is not found until it ends: call again after it would have timed out.
    /// - `"PENDING"` — sent, no usable answer; call again (a repeat is harmless).
    ///
    /// ``DigitiseResult/clientRequestID`` holds the ID, including one the SDK generated.
    public func deactivateDigitise(clientRequestID: String) async throws -> TokenStatusUpdateResponse {
        try await call { kmp in
            let r = try await kmp.deactivateDigitise(clientRequestId: clientRequestID)
            return TokenStatusUpdateResponse(tokenUniqueReference: r.tokenUniqueReference, status: r.status, message: r.message,
                                             responseStatus: r.responseStatus ?? ResponseStatus.failed,
                                             responseStatusReason: r.responseStatusReason)
        }
    }

    /// Current backend status of a token (e.g. `"ACTIVE"`), as an outcome — a read, never `PENDING`.
    public func tokenStatus(tokenUniqueReference: String) async throws -> TokenStatusResult {
        try await call { kmp in
            let r = try await kmp.tokenStatus(tokenUniqueReference: tokenUniqueReference)
            return TokenStatusResult(tokenStatus: r.tokenStatus, responseStatus: r.responseStatus,
                                     responseStatusReason: r.responseStatusReason, message: r.message)
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
        let kmp = try requireKmp()
        let registration = UUID()
        setActivationObserver(tokenUniqueReference, registration)
        kmp.observeActivation(
            tokenUniqueReference: tokenUniqueReference,
            onActivated: { [self] in
                endActivationObserver(tokenUniqueReference, ifRegistration: registration)
                onActivated()
            },
            onTimeout: { [self] in
                endActivationObserver(tokenUniqueReference, ifRegistration: registration)
                onTimeout()
            },
            onError: onError
        )
    }

    /// Whether an activation observer is running for the token — started by
    /// ``observeActivation(tokenUniqueReference:onActivated:onTimeout:onError:)`` and not yet
    /// activated, timed out or stopped. A paused observer is still running.
    public func hasActivationObserver(tokenUniqueReference: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedActivations[tokenUniqueReference] != nil
    }

    private func setActivationObserver(_ tokenUniqueReference: String, _ registration: UUID?) {
        lock.lock()
        observedActivations[tokenUniqueReference] = registration
        lock.unlock()
    }

    private func endActivationObserver(_ tokenUniqueReference: String, ifRegistration registration: UUID) {
        lock.lock()
        if observedActivations[tokenUniqueReference] == registration {
            observedActivations[tokenUniqueReference] = nil
        }
        lock.unlock()
    }

    /// Pause an activation observer's polling (call when the app backgrounds); the
    /// 5-minute timeout clock keeps running while paused.
    public func pauseActivationObserver(tokenUniqueReference: String) throws {
        try requireKmp().pauseActivationObserver(tokenUniqueReference: tokenUniqueReference)
    }

    /// Resume a paused activation observer; if the timeout window elapsed while paused,
    /// `onTimeout` fires immediately.
    public func resumeActivationObserver(tokenUniqueReference: String) throws {
        try requireKmp().resumeActivationObserver(tokenUniqueReference: tokenUniqueReference)
    }

    /// Stop observing a token's activation (call when the screen is dismissed); no further
    /// callbacks fire.
    public func stopActivationObserver(tokenUniqueReference: String) throws {
        try requireKmp().stopActivationObserver(tokenUniqueReference: tokenUniqueReference)
        setActivationObserver(tokenUniqueReference, nil)
    }

    // ── Payment refusals ───────────────────────────────────────────────────────────────

    /// Observe payments refused before any proof was built, **for one card**.
    ///
    /// Handlers are registered against a token's unique reference and only ever hear about
    /// that card. Registering the same card again replaces its handlers; other cards are
    /// untouched. Call ``stopObservingPaymentRefusals(forTokenUniqueReference:)`` to clear one.
    ///
    /// Two callbacks, because the advice differs and giving the payer the wrong one wastes
    /// their time:
    /// - `onRequireOnline` — the card's payment keys need refreshing and the wallet could not
    ///   reach the server. Tell the payer to connect and try again.
    /// - `onAmountExceedCardLimit` — the amount is larger than this card can carry in one
    ///   payment. **Never tell them to go online here**: a refreshed key carries the same cap,
    ///   so they would connect, retry and fail identically with no way to learn what was
    ///   wrong. Tell them to pay less or use another card. `cardLimitMinorUnits` is that cap
    ///   when it is known, and `nil` when it could not be read — omit the figure rather than
    ///   show a guess.
    ///
    /// - `onDeviceNotBound` (optional) — the card was added on another device (or before this
    ///   app was reinstalled) and cannot be issued payment keys here. Neither going online nor
    ///   a smaller amount helps: tell the payer to add the card again on this phone. Unlike the
    ///   other two this *is* a card state — `Token.deviceNotBound` reads `true` too.
    ///
    /// The first two report **this payment**, not the card's state: `requiresOnline` on a card answers
    /// the different question "can this card pay *anything* offline?" and stays `false` for a
    /// card that can still make smaller payments. Show a message about the payment that just
    /// failed; don't grey the card out on the strength of one refused amount.
    ///
    /// These fire from the QR rails (`rail` is `"CPM_QR"` or `"MPM_QR"`); there is no
    /// tap-to-pay on iOS, so no `"TAP"` refusal can occur. The pay calls also answer the same
    /// refusal as their own outcome — `NOT_SENT` with reason `ONLINE_REQUIRED` /
    /// `AMOUNT_EXCEEDS_CARD_LIMIT` — this observer is additional, for hosts that would rather
    /// handle refusals in one place than at every call site.
    ///
    /// A refusal the SDK could not attribute to a card reaches **every** registered handler
    /// rather than none: the payer was refused either way. The callback's own
    /// `tokenUniqueReference` is `nil` in that case, so a host can tell the two apart.
    ///
    /// Callbacks arrive on the main thread.
    public func observePaymentRefusals(
        forTokenUniqueReference tokenUniqueReference: String,
        onRequireOnline: @escaping (_ refusal: WalletPaymentRefusal) -> Void,
        onAmountExceedCardLimit: @escaping (_ refusal: WalletPaymentRefusal) -> Void,
        onDeviceNotBound: ((_ refusal: WalletPaymentRefusal) -> Void)? = nil
    ) throws {
        let kmp = try requireKmp()
        kmp.observePaymentRefusals(
            tokenUniqueReference: tokenUniqueReference,
            onRequireOnline: { onRequireOnline(WalletPaymentRefusal($0)) },
            onAmountExceedsCardLimit: { onAmountExceedCardLimit(WalletPaymentRefusal($0)) },
            onDeviceNotBound: { onDeviceNotBound?(WalletPaymentRefusal($0)) }
        )
    }

    /// Stop observing payment refusals for one card; its handlers fire no more. Other cards'
    /// registrations are unaffected.
    public func stopObservingPaymentRefusals(forTokenUniqueReference tokenUniqueReference: String) throws {
        try requireKmp().stopObservingPaymentRefusals(tokenUniqueReference: tokenUniqueReference)
    }

    // ── The SDK tells you when stored truth changes ────────────────────────────────────

    /// Observe the issuer changing a card's status — suspended, reactivated, expired,
    /// deactivated.
    ///
    /// **Why you want this.** The SDK polls token status in the background and writes the
    /// answer to its store. Without this observer your app finds out only the next time it
    /// reads `tokens()` — which, if the customer is already sitting on a card screen, means it
    /// never finds out at all. They tap a card your UI still shows as usable, and it fails at
    /// the terminal.
    ///
    /// `canPay` is the SDK's own answer, not something to re-derive from `status`: it is
    /// exactly the predicate the payment gates use, so a status added to the backend after
    /// this SDK shipped is correctly reported as not payable rather than guessed at.
    ///
    /// - `status` is the parsed vocabulary value — `ACTIVE`, `PENDING_ACTIVATION`,
    ///   `SUSPENDED`, `DEACTIVATED`, `EXPIRED`, or `UNKNOWN` for a value this build does not
    ///   know. `rawStatus` is the literal as stored; quote it in logs and support calls,
    ///   because for `UNKNOWN` it is the only thing that identifies the status.
    /// - `previousStatus` is what the card held before, or `nil` if this is its first status —
    ///   useful because the *transition* is often what you act on (`ACTIVE` → `SUSPENDED`
    ///   deserves an interruption; `PENDING_ACTIVATION` → `ACTIVE` is good news).
    ///
    /// Register once, at start-up — not per card screen. It fires for **any** stored card,
    /// including ones no screen is showing, which is the case that matters.
    ///
    /// It does **not** replay: an app that was not running when the status changed is served
    /// by reading `tokens()` at start-up, so keep that read. The observer is a convenience over
    /// the store, not a delivery guarantee.
    ///
    /// Callbacks arrive on the main thread. Observing again replaces the previous observer
    /// (last registration wins); `stopObservingTokenStatusChanged()` clears it.
    public func observeTokenStatusChanged(
        onTokenStatusChanged: @escaping (_ change: TokenStatusChangedEvent) -> Void
    ) throws {
        let kmp = try requireKmp()
        kmp.observeTokenLifecycle { tokenUniqueReference, status, rawStatus, canPay, previousRawStatus in
            onTokenStatusChanged(TokenStatusChangedEvent(
                tokenUniqueReference: tokenUniqueReference,
                status: TokenStatus(raw: status),
                rawStatus: rawStatus,
                canPay: canPay.boolValue,
                previousStatus: previousRawStatus
            ))
        }
    }

    /// Stop observing token status changes; no further callbacks fire.
    public func stopObservingTokenStatusChanged() throws {
        try requireKmp().stopObservingTokenLifecycle()
    }

    /// Observe a payment that was left `PENDING` reaching its final outcome.
    ///
    /// A wallet payment that gets no immediate answer is stored and polled by the SDK until
    /// the backend settles it — which can be seconds or days. This is how your app hears the
    /// answer without polling the store itself. It fires from every route that resolves a row:
    /// the background sweep, an on-demand status check, and the scan-to-pay push.
    ///
    /// `status` is `APPROVED`, `DECLINED` or `FAILED` — never `PENDING`, because a row that is
    /// still open has not resolved. `reason` is a plain string to display and log, never to
    /// parse; `responseCode` is the wire literal for receipts and support.
    ///
    /// Register once, at start-up — not per payment: the payment most likely to need this is
    /// one that settles after the screen (or the process) that made it is gone. It does
    /// **not** replay, so keep reading history at start-up.
    ///
    /// Callbacks arrive on the main thread. Observing again replaces the previous observer
    /// (last registration wins); `stopObservingTransactionResolved()` clears it.
    public func observeTransactionResolved(
        onTransactionResolved: @escaping (_ resolution: WalletTransactionResolvedEvent) -> Void
    ) throws {
        let kmp = try requireKmp()
        kmp.observeTransactionResolved { transactionHash, tokenUniqueReference, status, responseCode, reason, amountMinorUnits, merchantName in
            onTransactionResolved(WalletTransactionResolvedEvent(
                transactionHash: transactionHash,
                tokenUniqueReference: tokenUniqueReference,
                status: status,
                responseCode: responseCode,
                reason: reason,
                amountMinorUnits: amountMinorUnits.int64Value,
                merchantName: merchantName
            ))
        }
    }

    /// Stop observing transaction resolutions; no further callbacks fire.
    public func stopObservingTransactionResolved() throws {
        try requireKmp().stopObservingTransactionResolved()
    }

    /// Observe a card running out of payment keys — or getting them back.
    ///
    /// Cards hold a pool of single-use payment keys. When it is exhausted the card cannot pay
    /// until the SDK refreshes them, which is the state `Token.requiresOnline` reports.
    /// `requiresOnline` here is that **same value** — the observer and `tokens()` read one
    /// function, so a callback can never contradict the list you are about to draw.
    ///
    /// **What it covers, and what it does not.** It fires when a payment consumes a key and
    /// when a refresh delivers new ones — the moments the SDK is actually executing. Keys also
    /// expire by *clock*, which happens with no code running at all: a card whose last key
    /// expires while your app sits idle is reported as `requiresOnline` by the next `tokens()`
    /// read, exactly as it is today, and **nothing fires**. Write your UI copy accordingly and
    /// keep reading the card list when a screen appears.
    ///
    /// The first evaluation of a card after launch is a silent baseline — there is nothing to
    /// compare against yet, and at launch you are reading `tokens()` anyway.
    ///
    /// Observation only: there is deliberately no API to trigger a key refresh. The SDK owns
    /// when keys are replenished.
    ///
    /// **A card that can never be re-keyed here.** When the backend refuses this device payment
    /// keys for a card — it was added on another device, or before this app was reinstalled —
    /// the event carries `deviceNotBound == true` and `requiresOnline == false` (going online
    /// cannot help): prompt the user to add the card again.
    ///
    /// One listener receives every change as a `TokenKeyStateEvent`, as on Android and React
    /// Native. Callbacks arrive on the main thread. Observing again replaces the previous
    /// observer; `stopObservingTokenKeyStateChanged()` clears it.
    public func observeTokenKeyStateChanged(
        onTokenKeyStateChanged: @escaping (_ event: TokenKeyStateEvent) -> Void
    ) throws {
        let kmp = try requireKmp()
        kmp.observeCardKeyState { tokenUniqueReference, requiresOnline, deviceNotBound in
            onTokenKeyStateChanged(Self.tokenKeyStateEvent(
                tokenUniqueReference: tokenUniqueReference,
                requiresOnline: requiresOnline.boolValue,
                deviceNotBound: deviceNotBound.boolValue
            ))
        }
    }

    /// The event one key-state change delivers. A card the backend will not re-key on this
    /// device is never "requires online", whatever the core reported alongside it.
    static func tokenKeyStateEvent(tokenUniqueReference: String, requiresOnline: Bool, deviceNotBound: Bool) -> TokenKeyStateEvent {
        TokenKeyStateEvent(
            tokenUniqueReference: tokenUniqueReference,
            requiresOnline: deviceNotBound ? false : requiresOnline,
            deviceNotBound: deviceNotBound
        )
    }

    /// Stop observing card key state changes; no further callbacks fire.
    public func stopObservingTokenKeyStateChanged() throws {
        try requireKmp().stopObservingCardKeyState()
    }

    // ── Scan-to-pay: inspect → authenticate (Face ID / Touch ID) → pay ─────────────────

    /// Inspect a scanned merchant QR payload. Verification happens **on-device** (gateway
    /// signature against the SDK's pinned key + expiry). Only `.verified` may be shown on a
    /// confirm screen; every `.rejected` must end the flow.
    public func inspectScannedQr(_ payload: String) throws -> ScanInspection {
        let kmp = try requireKmp()
        let result = kmp.inspectScannedQr(payload: payload)
        if let verified = result as? ScanInspectionVerified {
            let ctx = verified.context
            return .verified(VerifiedPayment(
                txRef: ctx.txRef,
                merchantID: ctx.merchantId,
                merchantName: ctx.merchantName,
                merchantCity: ctx.merchantCity,
                amountDisplay: ctx.amountDisplay,
                amountMinorUnits: ctx.amountMinorUnits,
                currencyCode: ctx.currencyCode,
                expiresAtEpochSeconds: ctx.expiresAtEpochSeconds,
                merchantOrderID: ctx.merchantOrderId,
                raw: ctx
            ))
        }
        if let rejected = result as? ScanInspectionRejected {
            let reason = ScanRejectionReason(rawValue: rejected.reason.name) ?? .malformed
            return .rejected(reason, detail: rejected.detail)
        }
        return .rejected(.malformed, detail: "unrecognised inspection result")
    }

    // `authenticateForScannedPayment` was removed. It was the call an app had
    // to make before paying; skipping it, or letting its single-use authentication go stale
    // while the customer read the confirm screen, refused the payment. `payScannedContext` and
    // `showQrToPay` now raise the same system sheet themselves.

    /// Pay a verified scanned payment with the wallet's **active token**.
    ///
    /// **The SDK asks for the customer's authentication itself** — it raises the system
    /// sheet (Face ID / Touch ID, falling back to the device passcode) before it builds the
    /// payment, naming the merchant and amount so the gesture is bound to what it authorizes.
    /// You make no authentication call. One gesture per payment attempt: a retry asks again.
    ///
    /// Every payment ends with an outcome — branch on `responseStatus`. `NOT_SENT` means nothing
    /// was sent: `AUTH_CANCELLED` (the customer dismissed the sheet), `AUTH_FAILED`,
    /// `AUTH_UNAVAILABLE` (no passcode or biometry), `ONLINE_REQUIRED`, `AMOUNT_EXCEEDS_CARD_LIMIT`,
    /// `TOKEN_NOT_ACTIVE`, `DEVICE_NOT_BOUND`, `NO_ACTIVE_CARD`, `CARD_CANNOT_PAY`,
    /// `NO_NETWORK_CONNECTION`, `SDK_UNABLE_TO_CONNECT`… — fix it and pay the same QR again.
    /// `PENDING` means the push may have gone through: never pay again; the SDK resolves it.
    ///
    /// Whatever the gateway states — approved, declined, failed or still pending — also
    /// lands in the paying token's `transactions(tokenUniqueReference:limit:)`; a pending row keeps being polled by the
    /// SDK until the gateway states a final outcome.
    ///
    /// To cancel it while it is still on the device, call ``cancelPayment(merchantOrderID:)`` with
    /// ``VerifiedPayment/merchantOrderID``, or cancel the Swift `Task` awaiting this call; it then
    /// returns `NOT_SENT` / `CANCELLED`. A QR with no order ID cannot be cancelled.
    public func payScannedContext(_ payment: VerifiedPayment) async throws -> PaymentOutcome {
        guard let orderID = payment.merchantOrderID?.trimmingCharacters(in: .whitespaces).nilIfEmpty else {
            return try await pay(payment)
        }
        return try await TaskCancelBridge.run(
            cancel: { [self] in cancelPayment(merchantOrderID: orderID) },
            notFound: .noPaymentInProgressForOrderID
        ) { try await pay(payment) }
    }

    private func pay(_ payment: VerifiedPayment) async throws -> PaymentOutcome {
        try await call { kmp in
            let outcome = try await kmp.payScannedContext(verified: payment.raw)
            return PaymentOutcome(
                approved: outcome.approved,
                responseCode: outcome.responseCode,
                responseStatus: outcome.responseStatus,
                responseStatusReason: outcome.responseStatusReason,
                message: outcome.message,
                merchantName: outcome.merchantName,
                merchantLocation: outcome.merchantLocation,
                creditTransactionID: outcome.creditTransactionId,
                isCreditConfirmationSupported: outcome.isCreditConfirmationSupported?.boolValue
            )
        }
    }

    /// Render a **show QR to pay** code (dynamic CPM): key the merchant-stated amount first —
    /// it rides inside the QR's cryptogram, so the merchant's scan charges exactly that
    /// amount or fails verification. The SDK raises the system authentication sheet itself
    /// (one gesture per QR — a regenerate after `expiresAtEpochMillis` is a fresh payment
    /// attempt and asks again). Fully offline: nothing is sent; the merchant's SoftPOS
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
                currencyCode: qr.currencyCode,
                expiresAtEpochMillis: qr.expiresAtEpochMillis,
                transactionHash: qr.transactionHash,
                responseStatus: qr.responseStatus,
                responseStatusReason: qr.responseStatusReason,
                message: qr.message
            )
        }
    }

    /// Stop the active show-to-pay QR expiry watch started by `showQrToPay`. Call on
    /// teardown (the QR screen is dismissed) so the `onExpired` callback can't fire into dead
    /// UI. Idempotent; a new `showQrToPay` also supersedes any prior watch.
    public func cancelQrExpiry() {
        (try? requireKmp())?.cancelQrExpiry()
    }

    // ── Receipts & transaction history ─────────────────────────────────────

    /// Process a scanned merchant-receipt QR: decode/validate, verify it matches a transaction
    /// this wallet made, dedupe, and store. Raw JSON or base64. Checked on the phone; nothing is
    /// sent. Answers a ``ReceiptScan``: `APPROVED` with the stored receipt, or `FAILED` with the
    /// reason (`INVALID_RECEIPT`, `RECEIPT_NOT_FROM_THIS_WALLET`, `RECEIPT_MISMATCH`,
    /// `PAYMENT_NOT_CONFIRMED`, `RECEIPT_FOR_ANOTHER_TRANSACTION`). Only a setup mistake throws.
    /// - Parameter expectedTransactionHash: set when the scan was launched FROM a specific
    /// transaction's screen — a receipt belonging to a different transaction is
    /// rejected (and not stored) instead of silently linking elsewhere. Nil = unscoped.
    @discardableResult
    public func processReceipt(_ qrPayload: String, expectedTransactionHash: String? = nil) async throws -> ReceiptScan {
        try await call { kmp in
            let r = try await kmp.processReceipt(qrPayload: qrPayload, expectedTransactionHash: expectedTransactionHash)
            return ReceiptScan(receipt: r.receipt.map(map), responseStatus: r.responseStatus,
                               responseStatusReason: r.responseStatusReason, message: r.message)
        }
    }

    /// The last `limit` stored receipts, most recent first. Local read, no network.
    public func receipts(limit: Int = 100) async throws -> [TransactionReceipt] {
        try await call { kmp in try await kmp.receipts(limit: Int32(limit)).map(map) }
    }

    /// The receipt linked to a transaction by its hash, or nil. Local read. The same call as
    /// Android's and React Native's `getReceiptForTransaction`.
    public func receiptForTransaction(_ transactionHash: String) async throws -> TransactionReceipt? {
        try await call { kmp in
            try await kmp.receiptForTransaction(transactionHash: transactionHash).map(map)
        }
    }

    /// A card's transaction history: the last `limit` payments made with it, on every rail this
    /// platform has (payment QR, scan-to-pay), most recent first. Each `TransactionSummary` carries
    /// the outcome, the merchant and, where the merchant's bank supports it, the credit
    /// confirmation — as the SDK last recorded them; the SDK keeps open rows up to date by itself.
    ///
    /// Local read — no network call. Empty when no card on this device has that reference, or the
    /// card has no payments yet. Android's and React Native's `getTransactions`, with the same
    /// default.
    public func transactions(tokenUniqueReference: String, limit: Int = 50) async throws -> [TransactionSummary] {
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
    /// A check that could not be made is not thrown: ``VeyraLookup/failureReason`` says why
    /// (`NO_NETWORK_CONNECTION` when offline). A failed check never changes the stored row.
    public func refreshTransactionStatus(transactionHash: String) async throws -> VeyraLookup<TransactionSummary> {
        try await call { kmp in
            let r = try await kmp.refreshTransactionStatus(transactionHash: transactionHash)
            return VeyraLookup(value: r.transaction.map(Self.map), failureReason: r.failureReason, message: r.message)
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
    /// A check that could not be made is not thrown: ``VeyraLookup/failureReason`` says why
    /// (`NO_NETWORK_CONNECTION` when offline). A failed check never changes the stored row.
    public func refreshCreditConfirmation(transactionHash: String) async throws -> VeyraLookup<TransactionSummary> {
        try await call { kmp in
            let r = try await kmp.refreshCreditConfirmation(transactionHash: transactionHash)
            return VeyraLookup(value: r.transaction.map(Self.map), failureReason: r.failureReason, message: r.message)
        }
    }

    private static func map(_ r: VeyraKMP.TransactionSummary) -> TransactionSummary {
        TransactionSummary(
            merchantName: r.merchantName,
            amountMinorUnits: r.amountMinorUnits,
            currencyCode: r.currencyCode,
            transactionHash: r.transactionHash,
            tokenUniqueReference: r.tokenUniqueReference,
            authorizationStatus: r.authorizationStatus,
            responseCode: r.responseCode,
            responseStatusReason: r.responseStatusReason,
            localTransactionDateTime: r.localTransactionDateTime,
            atEpochMillis: r.atEpochMillis?.int64Value,
            entryMethod: r.entryMethod,
            merchantLocation: r.merchantLocation,
            merchantTransactionReference: r.merchantTransactionReference,
            merchantID: r.merchantId,
            creditTransactionID: r.creditTransactionId,
            isCreditConfirmationSupported: r.isCreditConfirmationSupported?.boolValue,
            creditConfirmationStatus: r.creditConfirmationStatus,
            creditedAt: r.creditedAt,
            bankReference: r.bankReference,
            merchantOrderID: r.merchantOrderId
        )
    }

    /// Reconcile still-PENDING transactions against the backend. It asks about **every** open
    /// transaction on the device, so call it on an occasion (scene-active, history opened), never
    /// on a loop: a screen waiting for one payment — a displayed CPM QR — should call
    /// ``refreshTransactionStatus(transactionHash:)`` with that payment's hash instead, which is
    /// one request rather than one per open transaction. If the gateway throttles (`429`), the
    /// pass stops and the rest wait for the SDK's next sweep. Best-effort: a row whose check fails
    /// is left as it is. Answers a ``ReconcileResult``: `failureReason` is set only when the
    /// reconcile itself could not run. Only a setup mistake throws.
    @discardableResult
    public func reconcilePendingTransactions() async throws -> ReconcileResult {
        try await call { kmp in
            let r = try await kmp.reconcilePendingTransactions()
            return ReconcileResult(failureReason: r.failureReason, message: r.message)
        }
    }

    private func map(_ r: VeyraKMP.TransactionReceipt) -> TransactionReceipt {
        TransactionReceipt(
            merchantName: r.merchantName,
            merchantID: r.merchantId,
            merchantAddress: r.merchantAddress,
            transactionType: r.transactionType,
            transactionStatus: r.transactionStatus,
            transactionTime: r.transactionTime,
            totalAmountMinorUnits: r.totalAmountMinorUnits,
            totalAmountFormatted: r.totalAmountFormatted,
            currencyCode: r.currencyCode,
            maskedToken: r.maskedToken,
            merchantTransactionReference: r.merchantTransactionReference,
            cdcvmApprovedByWallet: r.cdcvmApprovedByWallet?.boolValue,
            cdcvmOutcome: r.cdcvmOutcome,
            transactionID: r.transactionId,
            transactionHash: r.transactionHash
        )
    }

    /// Shared guard + setup-error mapping. Every operation returns its outcome; what the shared
    /// core still throws is a setup error, whose message starts with its code
    /// (`INVALID_CONFIGURATION: …`). Anything else would be an SDK defect and is passed on
    /// unchanged rather than dressed up as an outcome.
    private func call<T>(_ body: (WalletKmp) async throws -> T) async throws -> T {
        let kmp = try requireKmp()
        do {
            return try await body(kmp)
        } catch let error as VeyraError {
            throw error
        } catch {
            let message = error.localizedDescription
            if message.hasPrefix("NOT_SIGNED_IN") { throw VeyraError.notSignedIn }
            if message.hasPrefix("NOT_CONFIGURED") { throw VeyraError.notConfigured }
            if message.hasPrefix("SESSION_REQUIRED") { throw VeyraError.sessionRequired }
            if message.hasPrefix("UNSUPPORTED_ON_PLATFORM") { throw VeyraError.unsupportedOnPlatform }
            if message.hasPrefix("INVALID_CONFIGURATION") { throw VeyraError.invalidConfiguration(message: message) }
            throw error
        }
    }
}

private extension String {
    /// `nil` for an empty string — a blank reference names nothing.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
