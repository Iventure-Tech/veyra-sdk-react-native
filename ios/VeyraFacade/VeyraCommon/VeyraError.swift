// VeyraCommon — the one setup error the Veyra SDKs throw on iOS.

import Foundation

/// A setup error — a mistake in the app's integration, found in development. It is the **only**
/// thing an SDK operation throws: everything that happens to a call (refused on the phone, offline,
/// declined, no answer…) is an outcome the call returns. The same type, with the same codes, as
/// Android and React Native `VeyraError`.
public enum VeyraError: Error, Sendable, Equatable {
    /// The SDK has not been configured — call `configure(customerID:config:provider:)` at launch.
    case notConfigured
    /// No customer is signed in — `signOut()` was called. Call `configure(customerID:config:provider:)`
    /// with the customer to use the SDK again.
    case notSignedIn
    /// The configuration cannot be used — the message names the problem: an unusable provider, a
    /// provider of a different kind from an earlier `configure`, a blank customer ID, or a missing
    /// required setting (payment app provider ID, token requestor ID, Apple Team ID…).
    case invalidConfiguration(message: String)
    /// A payment call made without its screen session (raised by the React Native bridge).
    case sessionRequired
    /// A method this platform cannot perform — e.g. wallet tap-to-pay on iOS.
    case unsupportedOnPlatform

    /// The code, as Android's `VeyraError.code` and React Native's `VeyraError.code` name it.
    public var code: String {
        switch self {
        case .notConfigured: return "NOT_CONFIGURED"
        case .notSignedIn: return "NOT_SIGNED_IN"
        case .invalidConfiguration: return "INVALID_CONFIGURATION"
        case .sessionRequired: return "SESSION_REQUIRED"
        case .unsupportedOnPlatform: return "UNSUPPORTED_ON_PLATFORM"
        }
    }
}

extension VeyraError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "The Veyra SDK is not configured — call configure(customerID:config:provider:) at launch."
        case .notSignedIn:
            return "No customer is signed in — call configure(customerID:config:provider:) with the customer."
        case .invalidConfiguration(let message):
            return message
        case .sessionRequired:
            return "This payment call needs its screen session."
        case .unsupportedOnPlatform:
            return "This method is not supported on iOS."
        }
    }
}
