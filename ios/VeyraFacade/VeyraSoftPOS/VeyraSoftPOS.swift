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
    public let clientID: String?
    public let clientSecret: String?

    public init(
        environment: Environment,
        clientID: String? = nil,
        clientSecret: String? = nil
    ) {
        self.environment = environment
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
    public let acquirerID: String

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
        acquirerID: String
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
        self.acquirerID = acquirerID
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
    /// The paying card's display name (EMV tag `5F20`), e.g. `AFRIGO ****1234` — the same value
    /// a tap presents. `nil` when the QR carries none.
    ///
    /// **Display only.** Unlike the amount and currency it rides outside the QR's cryptogram, so
    /// show it on the confirm screen and the receipt but never branch a payment decision on it.
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
    public let acquirerID: String

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
        acquirerID: String
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
        self.acquirerID = acquirerID
    }
}

/// One transaction's backend status. `amount` is in **minor units**.
public struct TransactionStatus: Sendable, Hashable {
    public let merchantTransactionReference: String
    public let merchantID: String
    public let amount: Int64
    public let responseCode: String
    public let merchantStatus: String?
    public let transactionID: String?

    public init(
        merchantTransactionReference: String,
        merchantID: String,
        amount: Int64,
        responseCode: String,
        merchantStatus: String?,
        transactionID: String?
    ) {
        self.merchantTransactionReference = merchantTransactionReference
        self.merchantID = merchantID
        self.amount = amount
        self.responseCode = responseCode
        self.merchantStatus = merchantStatus
        self.transactionID = transactionID
    }
}

/// One payment the merchant has taken, kept locally by the SDK. `amountMinorUnits` is
/// in **minor units**; `rail` is `"TAP"` / `"QR_MPM"` / `"QR_CPM"`; `status` is
/// `"APPROVED"` / `"DECLINED"` / `"PENDING"` / `"FAILED"`.
public struct MerchantTransaction: Sendable, Hashable {
    public let reference: String
    /// Which rail took the payment. Display `railLabel`; use this for logic.
    public let rail: String
    /// Human label for `rail` — "Tap" / "QR" / "Scan". Derived by the SDK so every platform
    /// words the badge identically; an unrecognised rail code is passed through unchanged.
    public let railLabel: String
    public let amountMinorUnits: Int64
    public let currencyNumeric: String?
    public let status: String
    public let responseCode: String?
    public let transactionTime: String?
    public let transactionID: String?
    public let maskedTokenLast4: String
    public let transactionHash: String?
    /// Cardholder Name (EMV tag `5F20`) as the card presented it — on a Veyra token the card's
    /// display name (application label + masked last four, e.g. `AFRIGO ****1234`), not a
    /// person's name. `nil` on QR-MPM payments (the merchant never reads the card), on rows
    /// recorded before this field existed, and when the card carried no `5F20`.
    public let cardholderName: String?

    public init(
        reference: String,
        rail: String,
        railLabel: String,
        amountMinorUnits: Int64,
        currencyNumeric: String?,
        status: String,
        responseCode: String?,
        transactionTime: String?,
        transactionID: String?,
        maskedTokenLast4: String,
        transactionHash: String?,
        cardholderName: String? = nil
    ) {
        self.reference = reference
        self.rail = rail
        self.railLabel = railLabel
        self.amountMinorUnits = amountMinorUnits
        self.currencyNumeric = currencyNumeric
        self.status = status
        self.responseCode = responseCode
        self.transactionTime = transactionTime
        self.transactionID = transactionID
        self.maskedTokenLast4 = maskedTokenLast4
        self.transactionHash = transactionHash
        self.cardholderName = cardholderName
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
    /// Cardholder Name (EMV tag `5F20`) as the card presented it — on a Veyra token the card's
    /// display name (e.g. `AFRIGO ****1234`), not a person's name. `nil` on QR-MPM payments and
    /// on transactions recorded before the SDK captured it. Merchant-side display only: it is
    /// not part of `qrPayload`, the format the customer's wallet scans.
    public let cardholderName: String?
    public let qrPayload: String

    public init(
        merchantName: String,
        merchantAddress: String,
        transactionType: String,
        totalAmountMinorUnits: Int64,
        totalAmountFormatted: String,
        maskedToken: String,
        reference: String,
        transactionHash: String?,
        cardholderName: String? = nil,
        qrPayload: String
    ) {
        self.merchantName = merchantName
        self.merchantAddress = merchantAddress
        self.transactionType = transactionType
        self.totalAmountMinorUnits = totalAmountMinorUnits
        self.totalAmountFormatted = totalAmountFormatted
        self.maskedToken = maskedToken
        self.reference = reference
        self.transactionHash = transactionHash
        self.cardholderName = cardholderName
        self.qrPayload = qrPayload
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

    private init() {}

    /// Configure the SDK. Call once, before any service use (subsequent calls reconfigure).
    public static func configure(_ configuration: VeyraSoftPOSConfiguration) {
        shared.lock.lock()
        defer { shared.lock.unlock() }
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
            throw VeyraSoftPOSError.requestFailed(message: error.localizedDescription)
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
    internal func updateStoredMerchantStatus(merchantID: String, status: String?) {
        withMerchantStorage { storage in
            guard let stored = storage.load(), stored.merchantID == merchantID else { return }
            storage.save(stored.updatingStatus(status))
        }
    }

    /// Fold a successful profile update into storage (same different-merchant guard as above).
    internal func applyStoredMerchantUpdate(merchantID: String, update: MerchantUpdate, status: String?) {
        withMerchantStorage { storage in
            guard let stored = storage.load(), stored.merchantID == merchantID else { return }
            storage.save(stored.applying(update, status: status))
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
                        acquirerId: registration.acquirerID
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
                            acquirerID: r.acquirerId
                        )
                    )
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
                        acquirerId: update.acquirerID
                    )
                )
                return MerchantStatus(merchantID: r.merchantId, status: r.merchantStatus)
            }
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
                        amount: $0.amount,
                        responseCode: $0.responseCode,
                        merchantStatus: $0.merchantStatus,
                        transactionID: $0.transactionId
                    )
                }
            }
        }

        /// The merchant's locally-kept transactions across every rail (tap, QR MPM, QR CPM), most
        /// recent first — the SDK records each payment taken, so this needs no backend round trip.
        /// Mirrors Android's `TransactionService.getLastTransactions`.
        public func history(limit: Int = 50) async throws -> [MerchantTransaction] {
            try await owner.call { kmp in
                try await kmp.merchantTransactions(limit: Int32(limit)).map { r in
                    MerchantTransaction(
                        reference: r.reference,
                        rail: r.rail,
                        railLabel: r.railLabel,
                        amountMinorUnits: r.amountMinorUnits,
                        currencyNumeric: r.currencyNumeric,
                        status: r.status,
                        responseCode: r.responseCode,
                        transactionTime: r.transactionTime,
                        transactionID: r.transactionId,
                        maskedTokenLast4: r.maskedTokenLast4,
                        transactionHash: r.transactionHash,
                        cardholderName: r.cardholderName
                    )
                }
            }
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
                    cardholderName: r.cardholderName,
                    qrPayload: r.qrPayload
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
        public func createContext(
            merchantID: String,
            amountMinorUnits: Int64,
            currency: String,
            onExpired: (() -> Void)? = nil
        ) async throws -> PaymentContextQR {
            try await owner.call { kmp in
                let created = try await kmp.createContextPayment(
                    merchantId: merchantID,
                    amountMinorUnits: amountMinorUnits,
                    currency: currency,
                    onExpired: onExpired
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
        public func chargeCustomerQr(_ scanned: ScannedCustomerQr) async throws -> CustomerQrChargeOutcome {
            // Supplied (not SDK-generated) so the outcome can hand it back for the receipt
            // lookup — mirrors the Android sample's tap-reference idiom.
            let reference = "\(Int(Date().timeIntervalSince1970 * 1000))_\(Int.random(in: 1000...9999))"
            return try await owner.call { kmp in
                // Apply the registered merchant so the /payment request carries
                // merchant_id/acquirer_id/mcc/name/location — the CPM twin of the tap's
                // merchant enrichment.
                let response = try await kmp.chargeCpmQr(
                    scanned: scanned.raw,
                    merchant: owner.storedTapMerchant(),
                    merchantTransactionReference: reference
                )
                return CustomerQrChargeOutcome(
                    approved: response.responseCode == "00",
                    responseCode: response.responseCode,
                    transactionID: response.transactionId,
                    reference: reference
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
            // Settlement capability: the shared payment client the kernel uses to run
            // TERMINAL_ACTION_ANALYSIS → ONLINE_PROCESSING → COMPLETION. nil if not configured —
            // the tap then runs the reader dialogue only.
            let paymentProcessing = try? owner.requireKmp().makePaymentProcessing()
            return TapPaymentSession(
                amountMinorUnits: amountMinorUnits,
                currencyCode: currencyCode,
                merchant: merchant,
                paymentProcessing: paymentProcessing,
                onEvent: onEvent
            )
        }
    }
}

/// A tap-payment lifecycle event. Non-terminal events keep the reader armed —
/// mirror a physical terminal: show a transient hint, keep the waiting screen up.
public enum TapPaymentEvent: Sendable {
    /// Customer's phone connected and the Veyra application selected — dialogue running ("hold steady").
    case cardDetected
    /// Foreign/non-Veyra target — the reader stays armed; show "card not supported, try again".
    case unsupportedTarget
    /// The reader session ended without a card: CANCELLED / TIMEOUT / ERROR / UNAVAILABLE.
    case ended(outcome: String)
    /// The kernel dialogue finished (any status — including the pending-settlement failure
    /// until the shared payment client lands).
    case result(TapPaymentResult)
}

/// Outcome of a tap's kernel dialogue.
public struct TapPaymentResult: Sendable {
    /// APPROVED / DECLINED / PENDING / FAILED (TransactionStatus names).
    public let status: String
    public let pan: String?
    /// Cardholder Name (EMV tag `5F20`) as the card presented it, for display and receipts;
    /// `nil` when the card carried none. On a Veyra token this is the card's display name — the
    /// scheme's application label and the masked last four, e.g. `AFRIGO ****1234` — not a
    /// person's name.
    public let cardholderName: String?
    /// DE55 EMV data (uppercase hex) when the card returned an ARQC — the online leg's input.
    public let iccDataHex: String?
    public let errorMessage: String?
    /// The merchant transaction reference the settlement request carried — pass to
    /// `transactions.receipt(forReference:)` for the receipt QR.
    public let reference: String?
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
        paymentProcessing: PaymentProcessingService?,
        onEvent: @escaping @Sendable (TapPaymentEvent) -> Void
    ) {
        let bridge = EventsBridge(onEvent: onEvent)
        self.bridge = bridge
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
        func onEnded(outcome: String) { emit(.ended(outcome: outcome)) }
        func onResult(result: TapKernelResult) {
            emit(.result(TapPaymentResult(
                status: result.status,
                pan: result.pan,
                cardholderName: result.cardholderName,
                iccDataHex: result.iccDataHex(),
                errorMessage: result.errorMessage,
                reference: result.merchantTransactionReference
            )))
        }
    }
}
