// StoredMerchant — SDK-owned persistence of the registered merchant.
//
// iOS twin of Android's MerchantDataStore/StoredMerchantData: a successful
// VeyraSoftPOS.shared.merchant.register(_:) persists the merchant in a protected app-sandbox
// file (moved off the Keychain so it is cleared on uninstall, not carried over) so
// it survives app restarts, and apps gate on merchant.isRegistered instead of re-registering.
// Status/activate/deactivate/update responses keep the stored copy current.
import Foundation
import Security

/// The merchant registered from this device, as persisted by the SDK after a successful
/// `VeyraSoftPOS.Merchant.register(_:)` (mirrors Android `StoredMerchantData`).
public struct StoredMerchant: Sendable, Hashable, Codable {
    public let merchantID: String
    /// `"PERSONAL"` or `"BUSINESS"`.
    public let merchantType: String
    public let merchantName: String
    public let emailAddress: String
    public let phoneNumber: String
    public let addressLine1: String
    public let addressLine2: String
    public let city: String
    public let state: String
    public let countryCode: String
    public let bvn: String?
    public let cacNumber: String?
    public let accountNumber: String
    public let institutionCode: String
    /// Backend-assigned: resolved by the gateway from the payment app provider.
    public let acquirerID: String
    /// The merchant's wallet account id, as stored by the gateway.
    public let walletAccountID: String?
    /// Backend-assigned at registration.
    public let merchantCategoryCode: String
    /// Backend-assigned at registration.
    public let terminalID: String
    /// Last known backend status (e.g. `"ACTIVE"`); refreshed by status/activate/deactivate.
    public let merchantStatus: String?

    public init(
        merchantID: String,
        merchantType: String,
        merchantName: String,
        emailAddress: String,
        phoneNumber: String,
        addressLine1: String,
        addressLine2: String,
        city: String,
        state: String,
        countryCode: String,
        bvn: String?,
        cacNumber: String?,
        accountNumber: String,
        institutionCode: String,
        acquirerID: String,
        merchantCategoryCode: String,
        terminalID: String,
        merchantStatus: String?,
        walletAccountID: String? = nil
    ) {
        self.merchantID = merchantID
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
        self.walletAccountID = walletAccountID
        self.merchantCategoryCode = merchantCategoryCode
        self.terminalID = terminalID
        self.merchantStatus = merchantStatus
    }
}

extension StoredMerchant {
    /// Folds a successful registration response over the submitted values (response wins;
    /// terminal ID falls back to the merchant ID) — same fold as Android's `MerchantService`.
    /// The acquirer id has no submitted value to fall back to — it is gateway-resolved
    /// (from the payment app provider) and comes ONLY from the response.
    init(
        registration: MerchantRegistration,
        merchantID: String,
        terminalID: String?,
        merchantStatus: String?,
        merchantCategoryCode: String?,
        countryCode: String?,
        acquirerID: String?,
        walletAccountID: String? = nil
    ) {
        self.init(
            merchantID: merchantID,
            merchantType: registration.merchantType.rawValue,
            merchantName: registration.merchantName,
            emailAddress: registration.emailAddress,
            phoneNumber: registration.phoneNumber,
            addressLine1: registration.addressLine1,
            addressLine2: registration.addressLine2,
            city: registration.city,
            state: registration.state,
            countryCode: countryCode ?? registration.countryCode,
            bvn: registration.bvn,
            cacNumber: registration.cacNumber,
            accountNumber: registration.accountNumber,
            institutionCode: registration.institutionCode,
            acquirerID: acquirerID ?? "",
            merchantCategoryCode: merchantCategoryCode ?? "",
            terminalID: terminalID ?? merchantID,
            merchantStatus: merchantStatus,
            walletAccountID: walletAccountID ?? registration.walletAccountID
        )
    }

    /// All transaction-required fields present (mirrors Android `MerchantService.isRegistered()`).
    var isTransactionReady: Bool {
        !merchantID.isEmpty && !terminalID.isEmpty && !merchantName.isEmpty &&
            !acquirerID.isEmpty && !merchantCategoryCode.isEmpty && !countryCode.isEmpty
    }

    /// Copy with a refreshed backend status; a `nil` response status keeps the stored one.
    func updatingStatus(_ status: String?) -> StoredMerchant {
        StoredMerchant(
            merchantID: merchantID,
            merchantType: merchantType,
            merchantName: merchantName,
            emailAddress: emailAddress,
            phoneNumber: phoneNumber,
            addressLine1: addressLine1,
            addressLine2: addressLine2,
            city: city,
            state: state,
            countryCode: countryCode,
            bvn: bvn,
            cacNumber: cacNumber,
            accountNumber: accountNumber,
            institutionCode: institutionCode,
            acquirerID: acquirerID,
            merchantCategoryCode: merchantCategoryCode,
            terminalID: terminalID,
            merchantStatus: status ?? merchantStatus,
            walletAccountID: walletAccountID
        )
    }

    /// Folds a successful profile update over the stored copy; backend-assigned fields
    /// (terminalID, merchantCategoryCode, acquirerID) are preserved unless the response
    /// re-states them (mirrors Android `updateMerchant`). The update carries no
    /// acquirer id — it is gateway-resolved and arrives on the response.
    func applying(
        _ update: MerchantUpdate,
        status: String?,
        terminalID responseTerminalID: String? = nil,
        acquirerID responseAcquirerID: String? = nil,
        walletAccountID responseWalletAccountID: String? = nil
    ) -> StoredMerchant {
        StoredMerchant(
            merchantID: merchantID,
            merchantType: merchantType,
            merchantName: update.merchantName,
            emailAddress: update.emailAddress,
            phoneNumber: update.phoneNumber,
            addressLine1: update.addressLine1,
            addressLine2: update.addressLine2,
            city: update.city,
            state: update.state,
            countryCode: update.countryCode,
            bvn: update.bvn ?? bvn,
            cacNumber: cacNumber,
            accountNumber: update.accountNumber,
            institutionCode: update.institutionCode,
            acquirerID: responseAcquirerID ?? acquirerID,
            merchantCategoryCode: merchantCategoryCode,
            terminalID: responseTerminalID ?? terminalID,
            merchantStatus: status ?? merchantStatus,
            walletAccountID: responseWalletAccountID ?? update.walletAccountID ?? walletAccountID
        )
    }
}

/// Persistence seam for the stored merchant (Keychain in production; in-memory in tests).
protocol MerchantStorage {
    func load() -> StoredMerchant?
    func save(_ merchant: StoredMerchant)
    func clear()
}

/// File-backed storage in the app's Application Support directory — the replacement for
/// the legacy `KeychainMerchantStorage`.
///
/// The merchant registration is **profile data, not an auth secret**, so the Keychain was the
/// wrong medium: Keychain items survive app deletion, so an uninstalled merchant silently came
/// back on reinstall. A protected file in the app sandbox is removed on uninstall —
/// the SDK guaranteeing "uninstall = clean state" without any app-developer action. The payload
/// still includes the BVN, so the file is written with Data Protection
/// (`completeUntilFirstUnlock`, matching the old Keychain accessibility and the softpos
/// `FilePersistentStore`); it never goes to UserDefaults.
///
/// On first use it deletes the legacy Keychain item once (clean-slate migration — the old
/// registration is wiped, not carried over).
final class FileMerchantStorage: MerchantStorage {
    private let fileURL: URL

    init() {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("co.veyra.softpos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("stored-merchant.json")
        // one-time wipe of the legacy Keychain merchant (which would otherwise survive
        // uninstall). Clean slate — the old value is discarded, not migrated.
        LegacyKeychainMerchantStorage().clear()
    }

    func load() -> StoredMerchant? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StoredMerchant.self, from: data)
    }

    func save(_ merchant: StoredMerchant) {
        guard let data = try? JSONEncoder().encode(merchant) else { return }
        // completeUntilFirstUserAuthentication = the file equivalent of the old Keychain's
        // kSecAttrAccessibleAfterFirstUnlock (readable after the first unlock post-boot).
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// The legacy Keychain store — retained ONLY so the file store can wipe it once on
/// migration. Not used for reads/writes anymore.
final class LegacyKeychainMerchantStorage: MerchantStorage {
    private let service = "co.veyra.softpos"
    private let account = "stored-merchant"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() -> StoredMerchant? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(StoredMerchant.self, from: data)
    }

    func save(_ merchant: StoredMerchant) {
        guard let data = try? JSONEncoder().encode(merchant) else { return }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}