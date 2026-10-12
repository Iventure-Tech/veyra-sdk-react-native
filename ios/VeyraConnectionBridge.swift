import Foundation

/// Bridges the app's provider — `assertion()` of an AUTHENTICATION provider, or `send()` of a
/// PROXY provider — to the JavaScript functions the app passed to `initialize`. Functions cannot cross the bridge, so
/// JS keeps them (per SDK) and this asks for each call over the `VeyraConnectionRequest` event;
/// JS answers through `resolveConnectionRequest` / `rejectConnectionRequest`.
///
/// The relay and assertion provider built here are called from the SDK's background work as well
/// as from JS-initiated calls. With nobody listening (no JavaScript runtime, or it has not
/// subscribed yet) a request cannot be delivered: a relay request then fails `neverSent = true`
/// — nothing left the device, so a background cycle just skips — and an assertion request fails,
/// which the SDK reports as `notAuthenticated`. Requests already handed to JS when the runtime
/// goes away fail `neverSent = false`: JS may have forwarded them.
final class VeyraConnectionBridge: @unchecked Sendable {
  static let event = "VeyraConnectionRequest"

  struct InvalidProvider: Error { let message: String }

  private let lock = NSLock()
  private var pending: [String: CheckedContinuation<String?, Error>] = [:]
  private var listening = false
  /// Delivers a request to JS. Set by the module; nil once it is torn down.
  private var emit: (([String: Any]) -> Void)?

  func attach(emit: @escaping ([String: Any]) -> Void) {
    lock.lock(); self.emit = emit; lock.unlock()
  }

  func setListening(_ value: Bool) {
    lock.lock(); listening = value; lock.unlock()
  }

  /// Build the native provider from the bridge-safe map JS sent for the app's one provider.
  /// Validates defensively — JS already did — naming the field. `sdk` tags the requests it sends.
  func provider(sdk: String, map: NSDictionary?) throws -> any VeyraProvider {
    guard let map else {
      throw InvalidProvider(message: "provider is required: pass an AUTHENTICATION or a PROXY provider")
    }
    func nonBlank(_ key: String) -> String? {
      guard let v = map[key] as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
      return v
    }
    switch map["kind"] as? String {
    case "clientSecret":
      guard let id = nonBlank("clientId") else {
        throw InvalidProvider(message: "provider.clientId must not be blank (VeyraClientSecretProvider)")
      }
      guard let secret = nonBlank("clientSecret") else {
        throw InvalidProvider(message: "provider.clientSecret must not be blank (VeyraClientSecretProvider)")
      }
      return Self.clientSecretProvider(clientId: id, clientSecret: secret)
    case "auth":
      guard let id = nonBlank("clientId") else {
        throw InvalidProvider(message: "provider.clientId must not be blank (VeyraAssertionProvider)")
      }
      guard (map["hasAssertion"] as? Bool) == true else {
        throw InvalidProvider(message: "provider.assertion is required (VeyraAssertionProvider)")
      }
      return Auth(bridge: self, sdk: sdk, clientId: id)
    case "request":
      // JS has already checked that `send` exists; it is the provider's only function.
      return Relay(bridge: self, sdk: sdk)
    case let kind:
      throw InvalidProvider(
        message: "provider.providerType must be 'AUTHENTICATION' or 'PROXY' (got \(kind ?? "nothing"))"
      )
    }
  }

  // Deprecated provider, still fully supported: the one deprecation warning in this file is expected.
  @available(*, deprecated)
  private static func clientSecretProvider(clientId: String, clientSecret: String) -> any VeyraProvider {
    ClientSecret(clientId: clientId, clientSecret: clientSecret)
  }

  @available(*, deprecated)
  private struct ClientSecret: VeyraClientSecretProvider {
    let clientId: String
    let clientSecret: String
  }

  fileprivate func assertion(sdk: String, audience: String, jkt: String) async throws -> String? {
    do {
      return try await request(sdk: sdk, kind: "assertion", payload: jkt, audience: audience)
    } catch let e as VeyraRelayError {
      // The SDK turns any assertion failure into notAuthenticated; keep the cause readable.
      throw InvalidProvider(message: "assertion provider failed (\(e.kind.rawValue))")
    }
  }

  fileprivate func forward(sdk: String, envelope: String) async throws -> String {
    guard let body = try await request(sdk: sdk, kind: "relay", payload: envelope) else {
      throw VeyraRelayError(kind: .other, neverSent: false)
    }
    return body
  }

  /// `audience` travels with an assertion request only (the API base URL the assertion is for).
  private func request(sdk: String, kind: String, payload: String, audience: String? = nil) async throws -> String? {
    let id = UUID().uuidString
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, Error>) in
        lock.lock()
        guard listening, let emit else {
          lock.unlock()
          // Could not hand it to JS: it never left the device.
          cont.resume(throwing: VeyraRelayError(kind: .other, neverSent: true))
          return
        }
        pending[id] = cont
        lock.unlock()
        // Cancelled before we registered: the cancellation handler found nothing to resume.
        if Task.isCancelled {
          take(id)?.resume(throwing: CancellationError())
          return
        }
        var event: [String: Any] = [
          "id": id,
          "sdk": sdk,
          "kind": kind,
          "payload": payload,
        ]
        if let audience { event["audience"] = audience }
        emit(event)
      }
    } onCancel: {
      // The SDK's own timeout cancelled the wait; a late JS answer then finds nothing.
      take(id)?.resume(throwing: CancellationError())
    }
  }

  private func take(_ id: String) -> CheckedContinuation<String?, Error>? {
    lock.lock(); defer { lock.unlock() }
    return pending.removeValue(forKey: id)
  }

  /// JS answered `id`; `nil` is a valid assertion answer ("no user signed in").
  func resolve(id: String, value: String?) {
    take(id)?.resume(returning: value)
  }

  /// JS rejected `id`. `httpStatus` -1 means none.
  func reject(id: String, kind: String, neverSent: Bool, httpStatus: Int, message: String?) {
    guard let cont = take(id) else { return }
    let mapped: VeyraRelayError.Kind
    switch kind {
    case "NO_NETWORK": mapped = .noNetwork
    case "TIMEOUT": mapped = .timeout
    case "CONNECTION_REFUSED": mapped = .connectionRefused
    default: mapped = .other
    }
    cont.resume(throwing: VeyraRelayError(kind: mapped, neverSent: neverSent, httpStatus: httpStatus >= 0 ? httpStatus : nil))
  }

  /// The JavaScript runtime is going away: everything already handed to it may have been forwarded.
  func failAllPending() {
    lock.lock()
    let all = pending.values
    pending.removeAll()
    emit = nil
    listening = false
    lock.unlock()
    all.forEach { $0.resume(throwing: VeyraRelayError(kind: .other, neverSent: false)) }
  }

  private struct Auth: VeyraAssertionProvider {
    let bridge: VeyraConnectionBridge
    let sdk: String
    let clientId: String
    func assertion(audience: String, jkt: String) async throws -> String? {
      try await bridge.assertion(sdk: sdk, audience: audience, jkt: jkt)
    }
  }

  private struct Relay: VeyraProxyProvider {
    let bridge: VeyraConnectionBridge
    let sdk: String
    func send(_ request: String) async throws -> String { try await bridge.forward(sdk: sdk, envelope: request) }
  }
}
