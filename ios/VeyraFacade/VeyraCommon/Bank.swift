// VeyraCommon — one bank in a bank list, shared by the wallet and SoftPOS SDKs.

import Foundation

/// One bank in a bank list — the wallet's `banks(accountNumber:)` (banks a card can be added from)
/// and SoftPOS's `banks()` (the merchant's settlement banks). The same type, with the same fields,
/// as Android and React Native `Bank`.
public struct Bank: Sendable, Hashable, Identifiable {
    /// Bank slug identifier (e.g. `"9_payment_service_bank"`).
    public let slug: String
    /// Display name (e.g. `"9 payment service Bank"`).
    public let name: String
    /// Institution code (e.g. `"120001"`) — what account verification, add-card and registration take.
    public let institutionCode: String

    public var id: String { institutionCode }

    public init(slug: String, name: String, institutionCode: String) {
        self.slug = slug
        self.name = name
        self.institutionCode = institutionCode
    }
}
