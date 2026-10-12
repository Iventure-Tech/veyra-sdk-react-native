// StoredMerchant — SDK-owned persistence of the registered merchant.
//
// iOS twin of Android's MerchantDataStore/StoredMerchantData: a successful
// VeyraSoftPOS.shared.merchant.register(_:) persists the merchant in a protected app-sandbox
// file (moved off the Keychain so it is cleared on uninstall, not carried over) so
// it survives app restarts, and apps gate on merchant.isRegistered instead of re-registering.
// Status/activate/deactivate/update responses keep the stored copy current.
import CryptoKit
import Foundation
import Security
import VeyraKMP

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

/// Persistence seam for the stored merchant (protected sandbox file in production; in-memory in tests).
protocol MerchantStorage {
    func load() -> StoredMerchant?
    func save(_ merchant: StoredMerchant)
    func clear()
}

/// File-backed storage in the app's Application Support directory — the replacement for
/// the legacy Keychain store (`LegacyKeychainMerchantStorage`).
///
/// The merchant registration is **profile data, not an auth secret**, so the Keychain was the
/// wrong medium: Keychain items survive app deletion, so an uninstalled merchant silently came
/// back on reinstall. A file in the app sandbox is removed on uninstall — the SDK guaranteeing
/// "uninstall = clean state" without any app-developer action. It never goes to UserDefaults.
///
/// The payload carries the BVN, so the file is:
/// - **encrypted** with AES-GCM under a 256-bit key held in the Keychain
///   ([KeychainMerchantKeyStore], `AfterFirstUnlockThisDeviceOnly`). Only the key lives in the
///   Keychain: one that outlives an uninstall decrypts nothing, because the file is gone.
/// - **excluded from backup**, so it never reaches iCloud or a (possibly unencrypted) Finder
///   backup — the same never-leaves-the-device posture the old `ThisDeviceOnly` item had.
/// - written with Data Protection (`completeUntilFirstUserAuthentication`) as well.
///
/// Fail-closed: without a key the merchant is not written at all — never in clear.
///
/// One file per customer: `stored-merchant__c_<partition>.enc`, the partition coming from the
/// shared customer scope, so customer B never reads customer A's merchant. With nobody signed
/// in the SDK holds a [NoCustomerMerchantStorage] instead: no merchant, and writes are dropped.
/// The Keychain key is install-level and shared — it encrypts each customer's file.
///
/// [eraseUnpartitionedStores] deletes what earlier SDK versions left — the legacy Keychain item
/// and the unpartitioned `stored-merchant.json` / `stored-merchant.enc` — so no customer
/// inherits a merchant registered before customers were partitioned.
final class FileMerchantStorage: MerchantStorage {
    static let defaultDirectoryName = "co.veyra.softpos"
    private static let baseName = "stored-merchant"

    private let fileURL: URL
    private let keyStore: MerchantKeyStore

    init(partition: String,
         keyStore: MerchantKeyStore = KeychainMerchantKeyStore(),
         directoryName: String = FileMerchantStorage.defaultDirectoryName) {
        self.keyStore = keyStore
        let dir = FileMerchantStorage.directory(directoryName)
        let name = CustomerScope.shared.scopedName(baseName: FileMerchantStorage.baseName, partition: partition)
        fileURL = dir.appendingPathComponent("\(name).enc")
    }

    func load() -> StoredMerchant? {
        guard let sealed = try? Data(contentsOf: fileURL),
              let key = keyStore.existingKey(),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let data = try? AES.GCM.open(box, using: key) else { return nil }
        return try? JSONDecoder().decode(StoredMerchant.self, from: data)
    }

    func save(_ merchant: StoredMerchant) {
        guard let data = try? JSONEncoder().encode(merchant),
              let key = keyStore.key(),
              let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        // completeUntilFirstUserAuthentication = the file equivalent of the old Keychain's
        // kSecAttrAccessibleAfterFirstUnlock (readable after the first unlock post-boot).
        guard (try? sealed.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
        else { return }
        // An atomic write replaces the file, dropping resource values — re-mark it every time.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try? url.setResourceValues(values)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Delete every merchant store that belongs to no customer: the legacy Keychain item (which
    /// would otherwise survive uninstall) and the unpartitioned files earlier SDK versions wrote.
    /// Erased, never migrated. Idempotent, so it is safe on every configure.
    static func eraseUnpartitionedStores(directoryName: String = defaultDirectoryName) {
        LegacyKeychainMerchantStorage().clear()
        let dir = directory(directoryName)
        for name in ["\(baseName).json", "\(baseName).enc"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    private static func directory(_ name: String) -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// The merchant store with nobody signed in: holds nothing and keeps nothing, so a write
/// never lands where the next customer would see it.
final class NoCustomerMerchantStorage: MerchantStorage {
    func load() -> StoredMerchant? { nil }
    func save(_ merchant: StoredMerchant) {}
    func clear() {}
}

/// Source of the stored-merchant encryption key (Keychain in production; in-memory in tests,
/// where the hostless xctest runner has no Keychain entitlement).
protocol MerchantKeyStore {
    /// The key if one exists — never creates one (a read must not mint a key it can't use).
    func existingKey() -> SymmetricKey?
    /// The existing key, or a newly generated and persisted one; nil if it can't be persisted.
    func key() -> SymmetricKey?
}

/// The stored-merchant AES-256 key as a Keychain generic password,
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable whenever the protected file
/// is, never synced or restored to another device.
final class KeychainMerchantKeyStore: MerchantKeyStore {
    private let service = "co.veyra.softpos"
    private let account = "stored-merchant-key"

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func existingKey() -> SymmetricKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// The App ID prefix (normally the Apple Team ID) this app's Keychain items are filed under:
    /// the leading component of the stored-merchant key's access group. App Attest binds to
    /// `prefix.bundleID`, so this is what the device attestation needs — detected, not configured.
    /// Nil when there is no Keychain (hostless tests) or the group cannot be read.
    func appIDPrefix() -> String? {
        guard key() != nil else { return nil }
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String,
              let prefix = group.split(separator: ".").first, !prefix.isEmpty
        else { return nil }
        return String(prefix)
    }

    func key() -> SymmetricKey? {
        if let key = existingKey() { return key }
        let key = SymmetricKey(size: .bits256)
        var add = baseQuery
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        switch SecItemAdd(add as CFDictionary, nil) {
        case errSecSuccess: return key
        // Lost a race with another writer: use whichever key landed.
        case errSecDuplicateItem: return existingKey()
        default: return nil
        }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
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