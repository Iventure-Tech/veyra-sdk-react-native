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

/// Response to an activation-code request.
public struct ActivationCodeResponse: Sendable, Hashable {
    public let tokenUniqueReference: String?
    public let expirationDateTime: String?
    public let status: String?
    public let message: String?

    public init(tokenUniqueReference: String?, expirationDateTime: String?, status: String?, message: String?) {
        self.tokenUniqueReference = tokenUniqueReference
        self.expirationDateTime = expirationDateTime
        self.status = status
        self.message = message
    }
}

/// Response to a token activation.
public struct ActivateResponse: Sendable, Hashable {
    public let tokenUniqueReference: String?
    public let status: String?
    public let message: String?

    public init(tokenUniqueReference: String?, status: String?, message: String?) {
        self.tokenUniqueReference = tokenUniqueReference
        self.status = status
        self.message = message
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

/// Terminal outcome of a scan-to-pay push. `approved` when the rail returned response code 00.
public struct PaymentOutcome: Sendable, Hashable {
    public let approved: Bool
    public let responseCode: String?
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
    /// Amount in minor units (e.g. kobo).
    public let amountInMinorUnit: Int
    /// ISO 4217 numeric currency in the stored 4-digit shape (e.g. `"0566"`), or nil.
    public let transactionCurrencyCode: String?
    /// SHA-256(cryptogram‖ATC‖UN) hex — the join key to a `TransactionReceipt`, or nil.
    public let transactionHash: String?
    /// `"PENDING"`, `"APPROVED"`, `"DECLINED"`, `"FAILED"`, or nil for unknown.
    public let authorizationStatus: String?
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
        case .authenticationFailed(let message):
            return message
        case .onlineRequired(let message):
            return message
        case .tokenNotActive(let message):
            return message
        case .amountExceedsCardLimit(let message):
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
                    message: r.message
                )
            }
        }

        /// Activate a token with the code the customer received.
        public func activate(tokenUniqueReference: String, activationCode: String) async throws -> ActivateResponse {
            try await call { kmp in
                let r = try await kmp.activate(tokenUniqueReference: tokenUniqueReference, activationCode: activationCode)
                return ActivateResponse(tokenUniqueReference: r.tokenUniqueReference, status: r.status, message: r.message)
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
        /// it). The delivered outcome — approved or declined — also lands in the paying token's
        /// `recentActivity`.
        public func payScannedContext(_ payment: VerifiedPayment) async throws -> PaymentOutcome {
            try await call { kmp in
                let outcome = try await kmp.payScannedContext(verified: payment.raw)
                return PaymentOutcome(
                    approved: outcome.approved,
                    responseCode: outcome.responseCode,
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
                try await kmp.transactionHistory(tokenUniqueReference: tokenUniqueReference, limit: Int32(limit)).map {
                    TransactionSummary(
                        merchantName: $0.merchantName,
                        amountInMinorUnit: Int($0.amountInMinorUnit),
                        transactionCurrencyCode: $0.transactionCurrencyCode,
                        transactionHash: $0.transactionHash,
                        authorizationStatus: $0.authorizationStatus,
                        atEpochMillis: $0.atEpochMillis?.int64Value,
                        entryMethod: $0.entryMethod,
                        merchantLocation: $0.merchantLocation,
                        merchantTransactionReference: $0.merchantTransactionReference,
                        merchantId: $0.merchantId
                    )
                }
            }
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
                throw VeyraWalletError.requestFailed(message: message)
            }
        }
    }
}
