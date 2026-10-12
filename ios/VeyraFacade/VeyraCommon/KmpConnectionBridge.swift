// Maps the app's `VeyraProvider` onto the shared KMP core. SDK plumbing, not developer API:
// exposed to the two facades only through the `VeyraInternal` SPI.
import Foundation
import VeyraKMP

@_spi(VeyraInternal)
public enum KmpConnectionBridge {

    /// The KMP provider for `provider`, or the problem naming it. The method comes from
    /// `providerType`; the protocol actually conformed to must agree, and only one may be.
    public static func kmpProvider(_ provider: any VeyraProvider) -> Result<KmpVeyraProvider, VeyraConnectionConfigError> {
        let isAuth = provider is any VeyraAssertionProvider
        let isRequest = provider is any VeyraProxyProvider
        if isAuth && isRequest {
            return .failure(VeyraConnectionConfigError(
                message: "provider conforms to both VeyraAssertionProvider and VeyraProxyProvider: pass one kind"))
        }
        if (isAuth || isRequest) && isClientSecret(provider) {
            return .failure(VeyraConnectionConfigError(
                message: "provider conforms to VeyraClientSecretProvider as well as "
                    + (isAuth ? "VeyraAssertionProvider" : "VeyraProxyProvider") + ": pass one kind"))
        }
        let kmp: KmpVeyraProvider
        switch provider.providerType {
        case .authentication:
            if let auth = provider as? any VeyraAssertionProvider {
                kmp = IosConnections.shared.assertionProvider(clientId: auth.clientId, callback: AssertionCallback(auth))
            } else if let secret = clientSecretProvider(provider) {
                kmp = secret
            } else {
                return .failure(VeyraConnectionConfigError(
                    message: "provider.providerType is authentication, so the provider must conform to VeyraAssertionProvider"))
            }
        case .proxy:
            guard let request = provider as? any VeyraProxyProvider else {
                return .failure(VeyraConnectionConfigError(
                    message: "provider.providerType is proxy, so the provider must conform to VeyraProxyProvider"))
            }
            kmp = IosConnections.shared.proxyProvider(callback: RelayCallback(request))
        }
        if let problem = IosConnections.shared.problem(provider: kmp) {
            return .failure(VeyraConnectionConfigError(message: problem))
        }
        return .success(kmp)
    }

    @available(*, deprecated)
    private static func isClientSecret(_ provider: any VeyraProvider) -> Bool {
        provider is any VeyraClientSecretProvider
    }

    @available(*, deprecated)
    private static func clientSecretProvider(_ provider: any VeyraProvider) -> KmpVeyraProvider? {
        guard let secret = provider as? any VeyraClientSecretProvider else { return nil }
        return IosConnections.shared.clientSecretProvider(clientId: secret.clientId, clientSecret: secret.clientSecret)
    }
}

/// A provider that cannot be used, naming the problem.
@_spi(VeyraInternal)
public struct VeyraConnectionConfigError: Error, Sendable {
    public let message: String
}

/// Swift `async` assertion → the KMP completion callback. The completion is called exactly once.
private final class AssertionCallback: NSObject, IosAssertionCallback {
    private let provider: any VeyraAssertionProvider

    init(_ provider: any VeyraAssertionProvider) { self.provider = provider }

    func assertion(audience: String, jkt: String, completion: @escaping (String?, String?) -> Void) {
        let provider = self.provider
        Task {
            do {
                completion(try await provider.assertion(audience: audience, jkt: jkt), nil)
            } catch {
                completion(nil, error.localizedDescription)
            }
        }
    }
}

/// Swift `async` request provider → the KMP completion callback. `VeyraRelayError` keeps its `neverSent`;
/// any other error is reported as "may have been delivered" (`neverSent = false`).
private final class RelayCallback: NSObject, IosRelayCallback {
    private let relay: any VeyraProxyProvider

    init(_ relay: any VeyraProxyProvider) { self.relay = relay }

    func send(request: String, completion: @escaping (String?, IosRelayFailure?) -> Void) {
        let relay = self.relay
        Task {
            do {
                // The envelope names the method, so there is one entry point.
                let response = try await relay.send(request)
                completion(response, nil)
            } catch let error as VeyraRelayError {
                completion(nil, IosRelayFailure(
                    kind: error.kind.rawValue,
                    neverSent: error.neverSent,
                    httpStatus: Int32(error.httpStatus ?? 0),
                    message: error.message))
            } catch {
                completion(nil, IosRelayFailure(kind: "OTHER", neverSent: false, httpStatus: 0, message: error.localizedDescription))
            }
        }
    }
}
