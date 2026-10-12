// VeyraCommon — public types shared by the Veyra wallet and SoftPOS SDKs on iOS.
//
// Re-exported by `import VeyraWallet` and `import VeyraSoftPOS`, so apps never import it directly.
import Foundation

/// Which kind of `VeyraProvider` an object is. The SDK reads it to decide how it reaches Veyra.
public enum VeyraProviderType: String, Sendable {
    /// A `VeyraAssertionProvider`: the SDK calls Veyra itself and asks the provider for assertions.
    case authentication = "AUTHENTICATION"
    /// A `VeyraProxyProvider`: the SDK calls nothing itself and hands every request to the provider.
    case proxy = "PROXY"
}

/// How the SDK reaches Veyra: the one object you pass to `configure`. **Required, with no
/// default.** Conform to exactly one of `VeyraAssertionProvider` or `VeyraProxyProvider`, never both;
/// the protocol you conform to *is* the method, so there is no separate mode to set. A combined app
/// passes the same provider to both SDKs.
///
/// `configure` throws `invalidConfiguration`, naming the problem, for: a type that conforms to
/// both protocols; a `providerType` that does not match the protocol conformed to; a blank
/// `clientId`; and a provider of a different kind than an earlier `configure` in this process.
public protocol VeyraProvider: Sendable {
    /// Supplied by `VeyraAssertionProvider` and `VeyraProxyProvider`; you never implement it.
    var providerType: VeyraProviderType { get }
}

/// **Assertion** — "I prove who the user is." The SDK calls Veyra itself, with an access token
/// bound to a key generated on this device that cannot be exported. It obtains that token by
/// redeeming an assertion your backend signs for the signed-in user.
///
/// `assertion(audience:jkt:)` is called only when the SDK holds no valid token (first call,
/// expiry, or a token Veyra refused), never more than once at a time per SDK, off the main actor.
public protocol VeyraAssertionProvider: VeyraProvider {
    /// The OAuth client id Veyra issued to your app. Public, not a secret.
    var clientId: String { get }

    /// A short-lived JWT your backend signed for the signed-in user, or `nil` when nobody is
    /// signed in — the call then fails with `notAuthenticated` and nothing is sent. Throwing has
    /// the same effect.
    ///
    /// - Parameters:
    ///   - audience: required in the assertion as `aud`: the base URL of the Veyra API the
    ///     assertion will be redeemed at (e.g. `https://api.veyra.co`). Check it before you sign.
    ///   - jkt: optional to use: the thumbprint of this install's proof-of-possession key. Your
    ///     backend may bind the assertion to it (`cnf.jkt`, recommended); the SDK uses DPoP with
    ///     Veyra either way.
    func assertion(audience: String, jkt: String) async throws -> String?
}

public extension VeyraAssertionProvider {
    var providerType: VeyraProviderType { .authentication }
}

/// **Via your backend** — "I process every request through my backend." The SDK makes no network
/// call to Veyra of its own: every backend call is handed to `send(_:)`, which posts it to your
/// API gateway — and on to the Veyra Issuer Token Gateway (ITG) — and returns Veyra's answer.
///
/// Each `request` is a JSON envelope (version 1) that says everything about the call:
/// ```json
/// { "version": 1,
///   "service": "WALLET",
///   "method": "POST",
///   "path": "/digitize",
///   "query": { "name": "value" },
///   "headers": { "X-Veyra-Sdk-Version": "…", "X-Veyra-Provider-Type": "PROXY" },
///   "body": "<request JSON, as a string>" }
/// ```
/// `service` (`WALLET` or `SOFTPOS`) names the Veyra API, `method` the HTTP verb; `path` is
/// relative to the service, never a full URL; `query` is omitted when there is none; `body` is
/// absent on `GET` and `DELETE`. Return the response body exactly as it came back — including the
/// ITG's own `PROXY_FAILED` body, which the SDK recognises — and forward the bytes unmodified.
///
/// To fail, throw `VeyraRelayError`, saying whether the request provably never left the device.
/// Any other error — and a call that outlives the SDK's own timeout — counts as "may have been
/// delivered", so a payment stays pending and is reconciled rather than reported failed.
///
/// Also called from the SDK's background work (status polling, key refresh, confirmations), so an
/// implementation must not depend on a screen being up.
public protocol VeyraProxyProvider: VeyraProvider {
    /// Send one envelope and return the response body.
    func send(_ request: String) async throws -> String
}

public extension VeyraProxyProvider {
    var providerType: VeyraProviderType { .proxy }
}

/// **Deprecated.** The SDK calls Veyra itself with a client id and secret held in the app. It
/// exists only so apps already on client credentials keep working until their cut-over date; it is
/// retired per payment app provider. Use a `VeyraAssertionProvider` or a `VeyraProxyProvider`.
@available(*, deprecated, message: "A client secret inside an app can be extracted. Conform to VeyraAssertionProvider (your backend signs a short-lived assertion for the signed-in user) or VeyraProxyProvider (your backend forwards every call).")
public protocol VeyraClientSecretProvider: VeyraProvider {
    /// The OAuth client id Veyra issued to your app.
    var clientId: String { get }
    /// The OAuth client secret.
    var clientSecret: String { get }
}

@available(*, deprecated)
public extension VeyraClientSecretProvider {
    var providerType: VeyraProviderType { .authentication }
}

/// A `VeyraProxyProvider` call failed.
///
/// `neverSent` decides a payment's outcome: `true` only when the request provably never left the
/// device (no network, the connection was refused before anything was written) — the payment
/// then ends failed and may be retried. When in doubt leave it `false`, which keeps the payment
/// pending until it is reconciled. `httpStatus` is Veyra's HTTP status when your backend got a
/// non-200 answer from Veyra; the SDK then treats it exactly as that status on a direct connection.
public struct VeyraRelayError: Error, Sendable {
    public enum Kind: String, Sendable {
        case noNetwork = "NO_NETWORK"
        case timeout = "TIMEOUT"
        case connectionRefused = "CONNECTION_REFUSED"
        case other = "OTHER"
    }

    public let kind: Kind
    public let neverSent: Bool
    public let httpStatus: Int?
    public let message: String?

    public init(kind: Kind, neverSent: Bool, httpStatus: Int? = nil, message: String? = nil) {
        self.kind = kind
        self.neverSent = neverSent
        self.httpStatus = httpStatus
        self.message = message
    }
}

extension VeyraRelayError: LocalizedError {
    public var errorDescription: String? {
        message ?? "Relay failed (\(kind.rawValue), neverSent: \(neverSent))"
    }
}
