import Foundation
import React
import VeyraKMP

// No `import VeyraSDK` / `VeyraSoftPOS` / `VeyraWallet`: the Swift facade is compiled into this
// pod alongside the bridge, so its types are in the same module. (Swift Package Manager consumers
// still get the three separate modules from the SPM package.)

/**
 * The Veyra native module (iOS). Classic RCTEventEmitter module; new-architecture apps
 * consume it via RN's interop layer.
 *
 * Mode handling: on iOS the SDK claims a mode at the point of use (tap-session start,
 * wallet payment execution) and releases it at completion, with a background-inert
 * guard — so the focus session here only mirrors the cross-platform contract: it tracks
 * which experience is open and gates the calls Android gates (`softposTapStart`,
 * `walletSetActiveCard` — SESSION_REQUIRED), keeping the JS integration identical on both
 * platforms. It never calls a mode verb.
 *
 * Outcomes: every operation resolves with the facade's outcome (`responseStatus` /
 * `responseStatusReason`); a promise rejects only with one of the five setup errors. A bad call
 * argument — an unknown handle or enum value, a missing field — resolves `NOT_SENT` /
 * `INVALID_REQUEST` in the call's own shape, exactly as the Android module's `Mappers` builds it.
 */
@objc(VeyraSdkReactNative)
class VeyraSdkReactNative: RCTEventEmitter {

  private enum EventName {
    static let activation = "VeyraActivationEvent"
    static let walletTap = "VeyraWalletTapEvent"
    static let softposTap = "VeyraSoftposTapEvent"
    static let qrExpired = "VeyraQrExpiredEvent"
    /// A payment refused before any proof was built. Its own channel rather than a `walletTap`
    /// phase: refusals are per card and fire on the QR rails, neither of which is a tap.
    static let paymentRefusal = "VeyraPaymentRefusalEvent"
    /// A payment the app was left waiting on has resolved. Same name and payload as Android's.
    static let transactionResolved = "VeyraTransactionResolvedEvent"
    /// An approved sale's funds were confirmed in the merchant's bank account (or the 30-day
    /// window closed unconfirmed). Same name and payload as Android's.
    static let creditConfirmation = "VeyraCreditConfirmationEvent"
    /// The issuer changed a card's status. Same name/payload as Android's.
    static let tokenStatusChanged = "VeyraTokenStatusChangedEvent"
    /// A **wallet** payment left pending reached a final outcome. Distinct
    /// from `transactionResolved`, which is the merchant's side of a payment and keys on a
    /// reference the wallet never sees.
    static let walletTransactionResolved = "VeyraWalletTransactionResolvedEvent"
    /// A card's payment keys ran out, or a refresh replenished them.
    static let tokenKeyState = "VeyraTokenKeyStateEvent"
    /// The merchant was deactivated, suspended or activated.
    static let merchantStatus = "VeyraMerchantStatusEvent"
    /// Native asks JS to run a connection callback (an assertion, or a relay forward).
    static let connectionRequest = VeyraConnectionBridge.event
  }

  /// The SDKs' assertion providers and relays, answered by the JS functions in the config.
  private let connections = VeyraConnectionBridge()

  override init() {
    super.init()
    // Failure lines from this process say they came through React Native.
    OperationFailureLog.shared.surface = OperationFailureLog.shared.SURFACE_RN
    connections.attach { [weak self] body in
      self?.sendEvent(withName: EventName.connectionRequest, body: body)
    }
  }

  override func startObserving() { connections.setListening(true) }
  override func stopObserving() { connections.setListening(false) }

  /// The JS runtime is torn down (reload, destroy): fail whatever it was still answering.
  override func invalidate() {
    connections.failAllPending()
    super.invalidate()
  }

  /// Ready for calls: configured, with a customer signed in. False after `signOut`.
  private var initialized = false
  /// Whether `initialize` ever succeeded — picks `NOT_SIGNED_IN` over `NOT_CONFIGURED`.
  private var configuredOnce = false
  private var openSessionKind: String?
  /// Open tap sessions by `sessionId`, with the order ID each was started with — a tap is
  /// cancelled by its order ID (`cancelPayment(merchantOrderID:)`), so teardown needs it.
  private var tapSessions: [String: String] = [:]
  private var mpmContexts: [String: VerifiedPayment] = [:]
  private var cpmQrs: [String: ScannedCustomerQr] = [:]

  override static func requiresMainQueueSetup() -> Bool { false }

  override func supportedEvents() -> [String] {
    [
      EventName.activation,
      EventName.walletTap,
      EventName.softposTap,
      EventName.qrExpired,
      EventName.paymentRefusal,
      EventName.transactionResolved,
      EventName.creditConfirmation,
      EventName.tokenStatusChanged,
      EventName.walletTransactionResolved,
      EventName.tokenKeyState,
      EventName.merchantStatus,
      EventName.connectionRequest,
    ]
  }

  // ── Setup errors: the only rejections ───────────────────────────────────────

  private func reject(_ rejecter: RCTPromiseRejectBlock, _ error: Error) {
    let (code, message) = classify(error)
    rejecter(code, message, error)
  }

  /// The five setup errors — the same codes the Android module maps from `VeyraError.code`. Anything else is an SDK defect, never an outcome: `UNKNOWN`.
  private func classify(_ error: Error) -> (String, String) {
    switch error {
    case VeyraError.notConfigured:
      return ("NOT_CONFIGURED", "Call Veyra.initialize first")
    case VeyraError.notSignedIn:
      return ("NOT_SIGNED_IN", "No customer is signed in — call Veyra.initialize with the customerId first")
    case let VeyraError.invalidConfiguration(message):
      return ("INVALID_CONFIGURATION", message)
    case let e as VeyraError:
      return (e.code, error.localizedDescription)
    default:
      return ("UNKNOWN", error.localizedDescription)
    }
  }

  private func rejectNotInitialized(_ rejecter: RCTPromiseRejectBlock) {
    if configuredOnce {
      rejecter("NOT_SIGNED_IN", "No customer is signed in — call Veyra.initialize with the customerId first", nil)
    } else {
      rejecter("NOT_CONFIGURED", "Call Veyra.initialize first", nil)
    }
  }

  private func rejectInvalidConfiguration(_ rejecter: RCTPromiseRejectBlock, _ message: String) {
    rejecter("INVALID_CONFIGURATION", message, nil)
  }

  // ── Outcome shapes (key-for-key the Android module's `Mappers`) ─────────────

  private static let notSentStatus = "NOT_SENT"
  private static let invalidRequest = "INVALID_REQUEST"

  /// `nil` as JS `null`.
  private func opt(_ value: Any?) -> Any { value ?? NSNull() }

  /// A `NOT_SENT` outcome the bridge itself gives for a bad call argument — nothing reached the
  /// SDK. `falseKeys` / `nullKeys` are the type's other keys, present and empty.
  private func notSent(_ reason: String, _ message: String,
                       falseKeys: [String] = [], nullKeys: [String] = [],
                       status: String = notSentStatus, operation: String? = nil) -> [String: Any] {
    // The SDK never sees a call the bridge refuses itself, so the bridge logs the failure line.
    if let operation = operation {
      OperationFailureLog.shared.reportBridgeRefusal(operation: operation, status: status, reason: reason)
    }
    var body: [String: Any] = [
      "responseStatus": status,
      "responseStatusReason": reason,
      "message": message,
    ]
    falseKeys.forEach { body[$0] = false }
    nullKeys.forEach { body[$0] = NSNull() }
    return body
  }

  private func paymentOutcomeNotSent(_ message: String) -> [String: Any] {
    notSent(Self.invalidRequest, message, falseKeys: ["approved"],
            nullKeys: ["responseCode", "merchantName", "merchantLocation"],
            operation: SdkOperation.shared.SCAN_TO_PAY)
  }

  private func customerQrChargeNotSent(_ message: String) -> [String: Any] {
    notSent(Self.invalidRequest, message, falseKeys: ["approved"],
            nullKeys: ["responseCode", "transactionId", "merchantTransactionReference", "merchantOrderId",
                       "creditTransactionId", "isCreditConfirmationSupported", "originalPayment"],
            operation: SdkOperation.shared.CPM_CHARGE)
  }

  /// Not a payment or digitisation, so a refusal is `FAILED`, never `NOT_SENT` (devices §15.2).
  private static let failedStatus = "FAILED"

  private func merchantRegistrationRefused(_ message: String) -> [String: Any] {
    notSent(Self.invalidRequest, message, falseKeys: ["success"],
            nullKeys: ["merchantId", "terminalId", "merchantStatus"], status: Self.failedStatus,
            operation: SdkOperation.shared.MERCHANT_REGISTER)
  }

  private func merchantStatusRefused(_ reason: String, _ message: String) -> [String: Any] {
    notSent(reason, message, nullKeys: ["merchantId", "merchantStatus"], status: Self.failedStatus,
            operation: SdkOperation.shared.MERCHANT_STATUS)
  }

  private func tapResultNotSent(_ message: String) -> [String: Any] {
    notSent(Self.invalidRequest, message,
                       nullKeys: ["responseCode", "amountMinorUnits", "cardScheme", "maskedTokenLast4",
                                  "merchantTransactionReference", "transactionId", "merchantStatus",
                                  "creditTransactionId", "isCreditConfirmationSupported", "originalPayment"],
                       operation: SdkOperation.shared.MERCHANT_TAP)
  }

  /// `OriginalPayment`: on a `DUPLICATE_MERCHANT_ORDER_ID` refusal, the payment already holding the
  /// order ID (its `responseStatus` says paid or still being confirmed); `null` otherwise.
  private func originalPaymentDict(_ o: OriginalPayment?) -> Any {
    guard let o else { return NSNull() }
    return [
      "responseCode": opt(o.responseCode),
      "responseStatus": opt(o.responseStatus),
      "responseStatusReason": opt(o.responseStatusReason),
      "amountMinorUnits": o.amountMinorUnits.map { $0 as Any } ?? NSNull(),
      "merchantTransactionReference": opt(o.merchantTransactionReference),
      "transactionId": opt(o.transactionID),
    ] as [String: Any]
  }

  /// A `VeyraLookup`: the value, or why the read could not be made.
  private func lookupDict(_ value: Any?, failureReason: String?, message: String?) -> [String: Any] {
    ["value": opt(value), "failureReason": opt(failureReason), "message": opt(message), "checked": failureReason == nil]
  }

  private func merchantStatusDict(_ s: MerchantStatusResult) -> [String: Any] {
    [
      "merchantId": opt(s.merchantID),
      "merchantStatus": opt(s.merchantStatus),
      "responseStatus": s.responseStatus,
      "responseStatusReason": opt(s.responseStatusReason),
      "message": opt(s.message),
    ]
  }

  // ── Init & mode ─────────────────────────────────────────────────────────────

  @objc(initialize:resolver:rejecter:)
  func initialize(_ config: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                  rejecter reject: @escaping RCTPromiseRejectBlock) {
    // Every problem with the config is the app's configuration: INVALID_CONFIGURATION, naming it
    // (the Android module maps the same reads the same way).
    guard let customerID = config["customerId"] as? String,
          !customerID.trimmingCharacters(in: .whitespaces).isEmpty
    else { return rejectInvalidConfiguration(reject, "customerId is required") }
    guard let softposMap = config["softpos"] as? NSDictionary,
          let walletMap = config["wallet"] as? NSDictionary
    else { return rejectInvalidConfiguration(reject, "softpos and wallet configs are required") }
    guard let softposEnv = VeyraEnvironment(rawValue: softposMap["environment"] as? String ?? ""),
          let walletEnv = VeyraEnvironment(rawValue: walletMap["environment"] as? String ?? "")
    else { return rejectInvalidConfiguration(reject, "environment must be TEST or LIVE") }
    guard let appleTeamID = walletMap["appleTeamId"] as? String, !appleTeamID.isEmpty
    else { return rejectInvalidConfiguration(reject, "wallet.appleTeamId is required on iOS") }

    guard let softposProviderID = softposMap["paymentAppProviderId"] as? String, !softposProviderID.isEmpty
    else { return rejectInvalidConfiguration(reject, "softpos.paymentAppProviderId is required") }
    // One provider for both SDKs, answered by the app's one JS provider (JS registers it for
    // both; the native requests are tagged "wallet").
    let provider: any VeyraProvider
    do {
      provider = try connections.provider(sdk: "wallet", map: config["provider"] as? NSDictionary)
    } catch let e as VeyraConnectionBridge.InvalidProvider {
      return rejectInvalidConfiguration(reject, e.message)
    } catch {
      return rejectInvalidConfiguration(reject, error.localizedDescription)
    }
    // JS numbers arrive as NSNumber; a fractional value is refused here, naming the SDK. The 5–60
    // range is the SDK's own rule, checked by `configure` like on every other platform.
    let softposTimeout: Int?
    let walletTimeout: Int?
    switch (requestTimeoutSeconds(softposMap, sdk: "softpos"), requestTimeoutSeconds(walletMap, sdk: "wallet")) {
    case (.failure(let message), _), (_, .failure(let message)):
      return rejectInvalidConfiguration(reject, message.text)
    case (.success(let s), .success(let w)):
      softposTimeout = s
      walletTimeout = w
    }
    let softpos = VeyraSoftPOSConfiguration(
      environment: softposEnv,
      paymentAppProviderID: softposProviderID,
      requestTimeoutSeconds: softposTimeout
    )
    let wallet = VeyraWalletConfiguration(
      environment: walletEnv,
      paymentAppProviderID: walletMap["paymentAppProviderId"] as? String,
      tokenRequestorID: walletMap["tokenRequestorId"] as? String,
      appVersion: walletMap["appVersion"] as? String ?? "1.0.0",
      appleTeamID: appleTeamID,
      allowedAcquirerIDs: walletMap["allowedAcquirerIds"] as? [String] ?? [],
      allowedMerchantIDs: walletMap["allowedMerchantIds"] as? [String] ?? [],
      cdcvmAllowDeviceCredential: walletMap["cdcvmAllowDeviceCredential"] as? Bool ?? true,
      cdcvmPayTitle: walletMap["cdcvmPayTitle"] as? String,
      cdcvmPaySubtitle: walletMap["cdcvmPaySubtitle"] as? String,
      cdcvmShowQrTitle: walletMap["cdcvmShowQrTitle"] as? String,
      cdcvmShowQrSubtitle: walletMap["cdcvmShowQrSubtitle"] as? String,
      requestTimeoutSeconds: walletTimeout
    )

    do {
      // Throws on an unusable provider or a change of kind within the process (no fallback).
      try VeyraSDK.configure(customerID: customerID, config: VeyraSDKConfiguration(softpos: softpos, wallet: wallet), provider: provider)
    } catch {
      return self.reject(reject, error)
    }
    initialized = true
    configuredOnce = true
    // After every initialise: a switch of customer drops every observer registration.
    observeDeferredAnswers()
    resolve(nil)
  }

  /// The customer has logged out: both SDKs stop everything they run for them and drop every
  /// observer; their data stays on the device. Open tap sessions are cancelled and the payment
  /// handles this bridge holds are dropped. Every data call rejects with `NOT_SIGNED_IN` until
  /// the next `initialize`.
  @objc(signOut:rejecter:)
  func signOut(_ resolve: @escaping RCTPromiseResolveBlock,
               rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    cancelOpenTaps()
    VeyraSDK.signOut()
    mpmContexts.removeAll()
    cpmQrs.removeAll()
    initialized = false
    resolve(nil)
  }

  /// Subscribe to the SDK's two deferred-answer channels and re-emit them as the **same** JS
  /// events the Android module emits, so shared JS code is identical on both platforms.
  ///
  /// Registered here rather than in `init()` because both forwarders live on the configured
  /// SoftPOS facade — this is the earliest point they exist. Registration is single-listener
  /// ("last registration wins"), so a re-`initialize` simply replaces these, never stacks them.
  ///
  /// The events are notifications, not the source of truth: there is no replay, so JS screens
  /// keep reading `softpos.getTransaction(s)` when they appear (`devices/CLAUDE.md` §16).
  private func observeDeferredAnswers() {
    try? VeyraSoftPOS.shared.observeTransactionResolved { [weak self] resolution in
      self?.sendEvent(withName: EventName.transactionResolved, body: [
        "merchantTransactionReference": resolution.merchantTransactionReference,
        "responseCode": resolution.responseCode.map { $0 as Any } ?? NSNull(),
        "status": resolution.status,
        "reason": resolution.reason.map { $0 as Any } ?? NSNull(),
      ])
    }
    try? VeyraSoftPOS.shared.observeCreditConfirmation { [weak self] confirmation in
      self?.sendEvent(withName: EventName.creditConfirmation, body: [
        "merchantTransactionReference": confirmation.merchantTransactionReference,
        "creditTransactionId": confirmation.creditTransactionID.map { $0 as Any } ?? NSNull(),
        "status": confirmation.status,
        "amountMinorUnits": confirmation.amountMinorUnits.map { NSNumber(value: $0) } ?? NSNull(),
        "bankReference": confirmation.bankReference.map { $0 as Any } ?? NSNull(),
        "creditedAt": confirmation.creditedAt.map { $0 as Any } ?? NSNull(),
      ])
    }
    observeStateChanges()
  }

  /// Subscribe to the four "stored truth changed" channels and re-emit them as the same
  /// JS events the Android module emits.
  ///
  /// Key names here are hand-written and must match `Mappers.tokenStatusChanged` /
  /// `walletTransactionResolved` / `tokenKeyState` / `merchantStatusChanged` on Android exactly —
  /// shared JS reads one shape. Android's side is pinned by `MappersTest`; this side is pinned by
  /// the guides and by the RN sample subscribing to both.
  ///
  /// Same contract as the two deferred answers above: single-listener, no replay, notifications
  /// rather than the source of truth — screens keep reading the store when they appear (§16).
  private func observeStateChanges() {
    try? VeyraWallet.shared.observeTokenStatusChanged { [weak self] change in
      self?.sendEvent(withName: EventName.tokenStatusChanged, body: [
        "tokenUniqueReference": change.tokenUniqueReference,
        "status": change.status,
        "rawStatus": change.rawStatus,
        "canPay": change.canPay,
        "previousStatus": change.previousStatus.map { $0 as Any } ?? NSNull(),
      ])
    }
    try? VeyraWallet.shared.observeTransactionResolved { [weak self] resolution in
      self?.sendEvent(withName: EventName.walletTransactionResolved, body: [
        "transactionHash": resolution.transactionHash,
        "tokenUniqueReference": resolution.tokenUniqueReference.map { $0 as Any } ?? NSNull(),
        "status": resolution.status,
        "responseCode": resolution.responseCode.map { $0 as Any } ?? NSNull(),
        "reason": resolution.reason.map { $0 as Any } ?? NSNull(),
        "amountMinorUnits": NSNumber(value: resolution.amountMinorUnits),
        "merchantName": resolution.merchantName,
      ])
    }
    try? VeyraWallet.shared.observeTokenKeyStateChanged { [weak self] event in
      self?.sendEvent(withName: EventName.tokenKeyState, body: [
        "tokenUniqueReference": event.tokenUniqueReference,
        "requiresOnline": event.requiresOnline,
        "deviceNotBound": event.deviceNotBound,
      ])
    }
    try? VeyraSoftPOS.shared.observeMerchantStatusChanged { [weak self] change in
      self?.sendEvent(withName: EventName.merchantStatus, body: [
        "merchantId": change.merchantID,
        "status": change.status,
        "canAcceptPayments": change.canAcceptPayments,
        "previousStatus": change.previousStatus.map { $0 as Any } ?? NSNull(),
      ])
    }
  }

  // ── Connection callbacks (answers from JS) ──────────────────────────────────

  /// JS answered a connection request; a nil value is a valid "no assertion" answer.
  @objc(resolveConnectionRequest:value:)
  func resolveConnectionRequest(_ id: String, value: String?) {
    connections.resolve(id: id, value: value)
  }

  /// JS rejected a connection request. `httpStatus` -1 means none.
  @objc(rejectConnectionRequest:kind:neverSent:httpStatus:message:)
  func rejectConnectionRequest(_ id: String, kind: String, neverSent: Bool, httpStatus: Double, message: String?) {
    connections.reject(id: id, kind: kind, neverSent: neverSent, httpStatus: Int(httpStatus), message: message)
  }

  @objc(currentMode:rejecter:)
  func currentMode(_ resolve: @escaping RCTPromiseResolveBlock,
                   rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(reject) }
    do { resolve(try VeyraSDK.shared.currentMode().rawValue) }
    catch { self.reject(reject, error) }
  }

  // ── Sessions (contract parity; iOS claims at point of use) ──────────────────

  @objc(sessionOpen:resolver:rejecter:)
  func sessionOpen(_ kind: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                   rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(reject) }
    openSessionKind = kind
    resolve(nil)
  }

  @objc(sessionClose:resolver:rejecter:)
  func sessionClose(_ kind: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                    rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(reject) }
    if openSessionKind == kind {
      openSessionKind = nil
      if kind == "getPaid" {
        // Leaving the get-paid screen cancels any tap not yet sent; one already with the bank
        // runs to its normal result.
        cancelOpenTaps()
      }
    }
    resolve(nil)
  }

  // ── Pay session: the same three calls as Android ────────────────────────────
  //
  // iOS has no tap-to-pay (Apple keeps card emulation to itself), so there is nothing to arm. The
  // calls exist so one JS integration runs unchanged on both platforms: opening answers the same
  // `NFC_UNAVAILABLE` an Android phone without NFC gives, closing has nothing to do, and the session
  // is never open. None of them touches the `pay` focus session the hook opens — on iOS that only
  // gates `setActiveToken` for the QR rails.

  @objc(walletOpenPaySession:rejecter:)
  func walletOpenPaySession(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(reject) }
    resolve([
      "responseStatus": "FAILED",
      "responseStatusReason": "NFC_UNAVAILABLE",
      "message": "iPhone cannot pay by tap; pay with a QR code",
    ])
  }

  @objc(walletClosePaySession:rejecter:)
  func walletClosePaySession(_ resolve: @escaping RCTPromiseResolveBlock,
                             rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(reject) }
    resolve(nil)
  }

  @objc(walletIsPaySessionOpen:rejecter:)
  func walletIsPaySessionOpen(_ resolve: @escaping RCTPromiseResolveBlock,
                              rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(reject) }
    resolve(VeyraWallet.shared.isPaySessionOpen())
  }

  /// Cancels every open tap by its order ID. A tap not yet sent ends `NOT_SENT` / `CANCELLED`
  /// on its own `result` event; one already sent is refused by the SDK and runs to its normal
  /// result — so its session stays held here until that `result` arrives, never dropped
  /// mid-payment. (Each entry also leaves on its own `result` / `ended` event.)
  private func cancelOpenTaps() {
    for (sessionId, merchantOrderID) in tapSessions {
      let answer = merchantOrderID.isEmpty
        ? nil
        : VeyraSoftPOS.shared.cancelPayment(merchantOrderID: merchantOrderID).rawValue
      if answer != "TOO_LATE_TO_CANCEL_REQUEST_ALREADY_SENT" {
        tapSessions.removeValue(forKey: sessionId)
      }
    }
  }

  private func requireSession(_ kind: String, _ reject: RCTPromiseRejectBlock) -> Bool {
    guard openSessionKind == kind else {
      let hook = kind == "pay" ? "usePaySession" : "useGetPaidSession"
      reject("SESSION_REQUIRED",
             "This payment API needs its screen session open — mount \(hook) on the payment screen",
             nil)
      return false
    }
    return true
  }

  // ── Wallet: add card / digitise ─────────────────────────────────────────────

  @objc(walletGetBanks:resolver:rejecter:)
  func walletGetBanks(_ accountNumber: String?, resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let list = try await VeyraWallet.shared.banks(accountNumber: accountNumber)
        resolve([
          "banks": list.banks.map { ["slug": $0.slug, "name": $0.name, "institutionCode": $0.institutionCode] },
          "responseStatus": list.responseStatus,
          "responseStatusReason": self.opt(list.responseStatusReason),
          "message": self.opt(list.message),
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletVerifyAccount:resolver:rejecter:)
  func walletVerifyAccount(_ params: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                           rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard let accountNumber = params["accountNumber"] as? String,
          let institutionCode = params["institutionCode"] as? String,
          let walletAccountID = params["walletAccountId"] as? String
    else {
      return resolve(notSent(Self.invalidRequest, "accountNumber, institutionCode and walletAccountId are required",
                             falseKeys: ["isApproved"], nullKeys: ["responseCode"],
                             status: Self.failedStatus, operation: SdkOperation.shared.VERIFY_ACCOUNT))
    }
    Task {
      do {
        let response = try await VeyraWallet.shared.verifyAccount(VerifyAccountParams(
          accountNumber: accountNumber,
          institutionCode: institutionCode,
          walletAccountID: walletAccountID,
          accountHolderName: params["accountHolderName"] as? String,
          accountNumberSource: (params["accountNumberSource"] as? String).flatMap(AccountNumberSource.init(rawValue:))
        ))
        resolve([
          "responseCode": response.responseCode as Any,
          "message": response.message as Any,
          // What the call did, and why it decided that — carried verbatim to JS.
          "responseStatus": response.responseStatus as Any,
          "responseStatusReason": response.responseStatusReason as Any,
          "isApproved": response.responseCode == "APPROVED" || response.responseCode == "APPROVE_REQUIRE_AUTH",
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletDigitise:resolver:rejecter:)
  func walletDigitise(_ params: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard let accountNumber = params["accountNumber"] as? String,
          let institutionCode = params["institutionCode"] as? String,
          let accountHolderName = params["accountHolderName"] as? String,
          let walletAccountID = params["walletAccountId"] as? String,
          let emailAddress = params["emailAddress"] as? String,
          let recommendationRaw = params["recommendation"] as? String,
          let recommendation = TokenizationRecommendation(rawValue: recommendationRaw)
    else {
      var refused = notSent(Self.invalidRequest, "required digitise fields missing",
                            falseKeys: ["isApproved", "requiresActivation"],
                            nullKeys: ["responseCode", "tokenUniqueReference", "tokenStored", "clientRequestId"],
                            operation: SdkOperation.shared.DIGITISE)
      refused["activationMethods"] = [Any]()
      return resolve(refused)
    }
    Task {
      do {
        let result = try await VeyraWallet.shared.digitise(DigitiseParams(
          accountNumber: accountNumber,
          institutionCode: institutionCode,
          accountHolderName: accountHolderName,
          walletAccountID: walletAccountID,
          emailAddress: emailAddress,
          recommendation: recommendation,
          consumerIdentifier: params["consumerIdentifier"] as? String,
          bvn: params["bvn"] as? String,
          accountHolderAddress: params["accountHolderAddress"] as? String,
          mobileNumber: params["mobileNumber"] as? String,
          // The app's own id, so `wallet.cancelDigitise` can name this add-card; absent → the
          // SDK generates one and the add-card cannot be cancelled.
          clientRequestID: (params["clientRequestId"] as? String).flatMap { $0.isEmpty ? nil : $0 },
          accountNumberSource: (params["accountNumberSource"] as? String).flatMap(AccountNumberSource.init(rawValue:)),
          deviceScore: (params["deviceScore"] as? String).flatMap { TrustScore(rawValue: $0) },
          accountScore: (params["accountScore"] as? String).flatMap { TrustScore(rawValue: $0) },
          recommendationReasons: (params["recommendationReasons"] as? [String])?
            .compactMap { TokenizationRecommendationReason(rawValue: $0) } ?? [],
          bankName: params["bankName"] as? String
        ))
        resolve([
          "responseCode": result.responseCode as Any,
          // The issuer's decision, what the call did, and why it decided that.
          "responseStatus": result.responseStatus as Any,
          "responseStatusReason": result.responseStatusReason as Any,
          "tokenUniqueReference": result.tokenUniqueReference as Any,
          "activationMethods": result.activationMethods.map {
            ["medium": $0.medium, "contact": $0.contact as Any]
          },
          "message": result.message as Any,
          "isApproved": result.isApproved,
          "requiresActivation": result.requiresActivation,
          "tokenStored": result.tokenStored,
          "clientRequestId": result.clientRequestID as Any,
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  // ── Wallet: activation ──────────────────────────────────────────────────────

  @objc(walletRequestActivationCode:medium:reason:resolver:rejecter:)
  func walletRequestActivationCode(_ ref: String, medium: String, reason: String,
                                   resolver resolve: @escaping RCTPromiseResolveBlock,
                                   rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard let activationMedium = ActivationMedium(rawValue: medium) else {
      // A bad argument on this platform: refused before anything was sent. Not a payment or
      // digitisation, so FAILED, never NOT_SENT (the Android bridge's verify-account refusal agrees).
      return resolve(notSent(
        Self.invalidRequest, "On iOS the activation medium must be MASKED_EMAIL or MASKED_MOBILE_PHONE",
        nullKeys: ["tokenUniqueReference", "expirationDateTime", "status", "failureCode"],
        status: Self.failedStatus, operation: SdkOperation.shared.ACTIVATION
      ))
    }
    let activationReason = ActivationReason(rawValue: reason) ?? .other
    Task {
      do {
        let response = try await VeyraWallet.shared.requestActivationCode(
          tokenUniqueReference: ref, medium: activationMedium, reason: activationReason
        )
        resolve([
          "tokenUniqueReference": response.tokenUniqueReference as Any,
          "expirationDateTime": response.expirationDateTime as Any,
          "status": response.status as Any,
          "message": response.message as Any,
          // Raw wire value: JS carries codes verbatim (unknown codes included).
          "failureCode": response.failureCodeRaw as Any,
          "failureCodeRaw": response.failureCodeRaw as Any,
          "responseStatus": response.responseStatus,
          "responseStatusReason": response.responseStatusReason as Any,
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletActivate:code:resolver:rejecter:)
  func walletActivate(_ ref: String, code: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let response = try await VeyraWallet.shared.activate(
          tokenUniqueReference: ref, activationCode: code
        )
        resolve([
          "tokenUniqueReference": response.tokenUniqueReference as Any,
          "status": response.status as Any,
          "message": response.message as Any,
          // Raw wire values: JS carries codes verbatim (unknown codes included).
          "failureCode": response.failureCodeRaw as Any,
          "failureCodeRaw": response.failureCodeRaw as Any,
          "attemptsRemaining": response.attemptsRemaining as Any,
          "recommendDelete": response.recommendDeleteRaw as Any,
          "recommendDeleteRaw": response.recommendDeleteRaw as Any,
          "responseStatus": response.responseStatus,
          "responseStatusReason": response.responseStatusReason as Any,
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletTokenStatus:resolver:rejecter:)
  func walletTokenStatus(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                         rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        // Verbatim server status — JS carries values it does not know unchanged.
        let result = try await VeyraWallet.shared.tokenStatus(tokenUniqueReference: ref)
        resolve([
          "tokenStatus": self.opt(result.tokenStatus),
          "responseStatus": result.responseStatus,
          "responseStatusReason": self.opt(result.responseStatusReason),
          "message": self.opt(result.message),
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletObserveActivation:resolver:rejecter:)
  func walletObserveActivation(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                               rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    do {
      try VeyraWallet.shared.observeActivation(
        tokenUniqueReference: ref,
        onActivated: { [weak self] in
          self?.sendEvent(withName: EventName.activation,
                          body: ["tokenUniqueReference": ref, "event": "activated"])
        },
        onTimeout: { [weak self] in
          self?.sendEvent(withName: EventName.activation,
                          body: ["tokenUniqueReference": ref, "event": "timeout"])
        },
        onError: { [weak self] message in
          self?.sendEvent(withName: EventName.activation,
                          body: ["tokenUniqueReference": ref, "event": "error", "message": message])
        }
      )
      resolve(nil)
    } catch { self.reject(rejecter, error) }
  }

  @objc(walletPauseActivationObserver:resolver:rejecter:)
  func walletPauseActivationObserver(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                     rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    do { try VeyraWallet.shared.pauseActivationObserver(tokenUniqueReference: ref); resolve(nil) }
    catch { self.reject(rejecter, error) }
  }

  @objc(walletResumeActivationObserver:resolver:rejecter:)
  func walletResumeActivationObserver(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    do { try VeyraWallet.shared.resumeActivationObserver(tokenUniqueReference: ref); resolve(nil) }
    catch { self.reject(rejecter, error) }
  }

  @objc(walletStopActivationObserver:resolver:rejecter:)
  func walletStopActivationObserver(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    do { try VeyraWallet.shared.stopActivationObserver(tokenUniqueReference: ref); resolve(nil) }
    catch { self.reject(rejecter, error) }
  }

  @objc(walletHasActivationObserver:resolver:rejecter:)
  func walletHasActivationObserver(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                   rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraWallet.shared.hasActivationObserver(tokenUniqueReference: ref))
  }

  // ── Wallet: tokens ──────────────────────────────────────────────────────────

  private func tokenDict(_ token: Token) -> [String: Any] {
    [
      "tokenUniqueReference": token.tokenUniqueReference,
      "maskedPan": token.maskedPAN,
      "panLastFour": token.panLastFour,
      "cardHolderName": token.cardHolderName,
      "expiry": token.expiry,
      "bankName": token.bankName as Any,
      "cardScheme": token.cardScheme?.rawValue as Any,
      "status": token.status?.rawValue as Any,
      "isActive": token.isActive,
      "isSelected": token.isSelected,
      "requiresActivation": token.requiresActivation,
      "activationMethods": token.activationMethods.map { methods in
        methods.map { ["medium": $0.medium, "contact": $0.contact as Any] }
      } as Any,
      "requiresOnline": token.requiresOnline,
      "deviceNotBound": token.deviceNotBound,
    ]
  }

  /// `WalletPaymentRefusal` — one payload for the three refusals, as on Android.
  static func refusalDict(_ r: WalletPaymentRefusal) -> [String: Any] {
    var body: [String: Any] = [
      "type": r.type,
      "tokenUniqueReference": r.tokenUniqueReference as Any,
      "amountMinorUnits": r.amountMinorUnits,
      "rail": r.rail,
      "message": r.message,
    ]
    if r.type == "amountExceedCardLimit" { body["cardLimitMinorUnits"] = r.cardLimitMinorUnits as Any }
    return body
  }

  @objc(walletGetTokens:rejecter:)
  func walletGetTokens(_ resolve: @escaping RCTPromiseResolveBlock,
                       rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do { resolve(try await VeyraWallet.shared.tokens().map(self.tokenDict)) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletGetActiveToken:rejecter:)
  func walletGetActiveToken(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    Task {
      do {
        if let card = try await VeyraWallet.shared.activeToken() {
          resolve(self.tokenDict(card))
        } else {
          resolve(nil)
        }
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletGetToken:resolver:rejecter:)
  func walletGetToken(_ tokenUniqueReference: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    Task {
      do {
        if let card = try await VeyraWallet.shared.token(tokenUniqueReference) {
          resolve(self.tokenDict(card))
        } else {
          resolve(nil)
        }
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletGetPaymentApplicationInstanceId:rejecter:)
  func walletGetPaymentApplicationInstanceId(_ resolve: @escaping RCTPromiseResolveBlock,
                                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    do { resolve(try VeyraWallet.shared.paymentApplicationInstanceID()) }
    catch { reject(rejecter, error) }
  }

  @objc(walletSetActiveToken:resolver:rejecter:)
  func walletSetActiveToken(_ tokenUniqueReference: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    // Gated like Android's, so one JS integration behaves the same on both: the pay screen's
    // session must be open. (On iOS the selection arms no tap — it picks the card the QR rails use.)
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard requireSession("pay", rejecter) else { return }
    Task {
      do {
        let selection = try await VeyraWallet.shared.setActiveToken(tokenUniqueReference)
        // Refusals are NOT armed here: they are per card and reach JS through
        // `wallet.observePaymentRefusals`, which observes whichever card the app is listening to
        // rather than only the active one.
        resolve([
          "responseStatus": selection.responseStatus,
          "responseStatusReason": self.opt(selection.responseStatusReason),
          "message": self.opt(selection.message),
        ])
      }
      catch { self.reject(rejecter, error) }
    }
  }

  /// Arm refusal delivery for one card. JS keeps the listener map; this decides whether a
  /// refusal for that card crosses the bridge at all.
  @objc(walletObservePaymentRefusals:resolver:rejecter:)
  func walletObservePaymentRefusals(_ tokenUniqueReference: String,
                                    resolver resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    do {
      try VeyraWallet.shared.observePaymentRefusals(
        forTokenUniqueReference: tokenUniqueReference,
        onRequireOnline: { [weak self] in self?.sendEvent(withName: EventName.paymentRefusal, body: Self.refusalDict($0)) },
        onAmountExceedCardLimit: { [weak self] in self?.sendEvent(withName: EventName.paymentRefusal, body: Self.refusalDict($0)) },
        onDeviceNotBound: { [weak self] in self?.sendEvent(withName: EventName.paymentRefusal, body: Self.refusalDict($0)) }
      )
      resolve(nil)
    } catch { self.reject(rejecter, error) }
  }

  /// Release one card's refusal registration; other cards are unaffected.
  @objc(walletStopObservingPaymentRefusals:resolver:rejecter:)
  func walletStopObservingPaymentRefusals(_ tokenUniqueReference: String,
                                          resolver resolve: @escaping RCTPromiseResolveBlock,
                                          rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    do {
      try VeyraWallet.shared.stopObservingPaymentRefusals(
        forTokenUniqueReference: tokenUniqueReference
      )
      resolve(nil)
    } catch { self.reject(rejecter, error) }
  }

  @objc(walletDeactivateDigitise:resolver:rejecter:)
  func walletDeactivateDigitise(_ clientRequestId: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let response = try await VeyraWallet.shared.deactivateDigitise(clientRequestID: clientRequestId)
        resolve([
          "tokenUniqueReference": response.tokenUniqueReference as Any,
          "status": response.status as Any,
          "message": response.message as Any,
          "responseStatus": response.responseStatus,
          "responseStatusReason": response.responseStatusReason as Any,
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletDeactivateToken:resolver:rejecter:)
  func walletDeactivateToken(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        // The backend's answer reaches JS, as it does on the two native surfaces.
        let response = try await VeyraWallet.shared.deactivateToken(ref)
        resolve([
          "tokenUniqueReference": response.tokenUniqueReference as Any,
          "status": response.status as Any,
          "message": response.message as Any,
          "responseStatus": response.responseStatus,
          "responseStatusReason": response.responseStatusReason as Any,
        ])
      }
      catch { self.reject(rejecter, error) }
    }
  }

  // ── Wallet: scan-to-pay (MPM) ───────────────────────────────────────────────

  @objc(walletInspectScannedQr:resolver:rejecter:)
  func walletInspectScannedQr(_ payload: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                              rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    do {
      switch try VeyraWallet.shared.inspectScannedQr(payload) {
      case .verified(let payment):
        let handle = UUID().uuidString
        mpmContexts[handle] = payment
        resolve([
          "verified": true,
          "handle": handle,
          "merchantName": payment.merchantName,
          "merchantCity": payment.merchantCity as Any,
          "amountDisplay": payment.amountDisplay,
          "amountMinorUnits": payment.amountMinorUnits,
          "currencyCode": payment.currencyCode,
          "expiresAtEpochSeconds": payment.expiresAtEpochSeconds,
          // What wallet.cancelPayment takes; null on a QR that carries none.
          "merchantOrderId": payment.merchantOrderID as Any,
        ])
      case .rejected(let reason, let detail):
        resolve(["verified": false, "reason": reason.rawValue, "detail": detail as Any])
      }
    } catch { self.reject(rejecter, error) }
  }

  // `walletAuthenticateForPayment` was removed — the SDK raises the
  // LocalAuthentication sheet itself inside walletPayScannedContext / walletShowQrToPay.

  @objc(walletPayScannedContext:resolver:rejecter:)
  func walletPayScannedContext(_ handle: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                               rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard let payment = mpmContexts.removeValue(forKey: handle) else {
      return resolve(paymentOutcomeNotSent("Unknown or already-used payment handle — re-inspect the QR"))
    }
    Task {
      do {
        let outcome = try await VeyraWallet.shared.payScannedContext(payment)
        resolve([
          "approved": outcome.approved,
          "responseCode": outcome.responseCode as Any,
          // the status is what the payment IS — `approved` alone cannot tell a decline
          // from a push the gateway answered PENDING.
          "responseStatus": outcome.responseStatus as Any,
          "responseStatusReason": outcome.responseStatusReason as Any,
          "message": outcome.message as Any,
          "merchantName": outcome.merchantName as Any,
          "merchantLocation": outcome.merchantLocation as Any,
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  // ── Wallet: show-QR-to-pay (CPM) ────────────────────────────────────────────

  @objc(walletShowQrToPay:resolver:rejecter:)
  func walletShowQrToPay(_ amountMinorUnits: Double, resolver resolve: @escaping RCTPromiseResolveBlock,
                         rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let qr = try await VeyraWallet.shared.showQrToPay(
          amountMinorUnits: Int64(amountMinorUnits),
          onExpired: { [weak self] in
            self?.sendEvent(withName: EventName.qrExpired, body: ["scope": "wallet", "handle": NSNull()])
          }
        )
        // A QR to render on APPROVED; otherwise the reason none was made, and no payload.
        resolve([
          "tokenUniqueReference": self.opt(qr.tokenUniqueReference),
          "payload": self.opt(qr.payload),
          "amountMinorUnits": qr.amountMinorUnits,
          "currencyCode": self.opt(qr.currencyCode),
          "expiresAtEpochMillis": qr.expiresAtEpochMillis,
          "transactionHash": self.opt(qr.transactionHash),
          "responseStatus": qr.responseStatus,
          "responseStatusReason": self.opt(qr.responseStatusReason),
          "message": self.opt(qr.message),
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  /// Cancels the scan-to-pay of the QR carrying `merchantOrderId`; resolves with the
  /// `CancelResult` name. `walletPayScannedContext` still resolves with its own outcome.
  @objc(walletCancelPayment:resolver:rejecter:)
  func walletCancelPayment(_ merchantOrderId: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                           rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraWallet.shared.cancelPayment(merchantOrderID: merchantOrderId).rawValue)
  }

  /// Cancels the digitise started with `clientRequestId`; resolves with the `CancelResult` name.
  /// `walletDigitise` still resolves with its own outcome.
  @objc(walletCancelDigitise:resolver:rejecter:)
  func walletCancelDigitise(_ clientRequestId: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraWallet.shared.cancelDigitise(clientRequestID: clientRequestId).rawValue)
  }

  @objc(walletCancelQrExpiry:rejecter:)
  func walletCancelQrExpiry(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    VeyraWallet.shared.cancelQrExpiry()
    resolve(nil)
  }

  // ── Wallet: history & receipts ──────────────────────────────────────────────

  private func summaryDict(_ s: TransactionSummary) -> [String: Any] {
    [
      "merchantName": s.merchantName,
      "amountMinorUnits": s.amountMinorUnits,
      "currencyCode": s.currencyCode as Any,
      "transactionHash": s.transactionHash as Any,
      "tokenUniqueReference": s.tokenUniqueReference as Any,
      "authorizationStatus": s.authorizationStatus as Any,
      // These two are declared in `types.ts` and mapped on Android, but were never mapped here —
      // an RN app on iOS read `undefined` for both and could not show why a payment ended as it
      // did. Keep this dictionary's key list matched against the TypeScript type, not against the
      // Swift struct alone.
      "responseCode": s.responseCode as Any,
      "responseStatusReason": s.responseStatusReason as Any,
      // The contactless date/time from the card exchange (EMV tags 9A + 9F21) — iOS has no tap
      // rail, so it is null on every iOS row; QR rows use `atEpochMillis`.
      "localTransactionDateTime": s.localTransactionDateTime as Any,
      "atEpochMillis": s.atEpochMillis as Any,
      "entryMethod": s.entryMethod as Any,
      "merchantLocation": s.merchantLocation as Any,
      "merchantTransactionReference": s.merchantTransactionReference as Any,
      "merchantId": s.merchantID as Any,
      // Beneficiary credit confirmation. `isCreditConfirmationSupported` is the gate a screen
      // reads — true means the SDK is polling and the credit line should render; false/null means
      // show nothing at all. `creditConfirmationStatus` stays null until terminal.
      "creditTransactionId": s.creditTransactionID as Any,
      "isCreditConfirmationSupported": s.isCreditConfirmationSupported as Any,
      "creditConfirmationStatus": s.creditConfirmationStatus as Any,
      "creditedAt": s.creditedAt as Any,
      "bankReference": s.bankReference as Any,
      // The merchant's order id — from the verified QR at payment time (MPM) or the status
      // poll (CPM). Display only; null until the row learns it.
      "merchantOrderId": s.merchantOrderID as Any,
    ]
  }

  private func receiptDict(_ r: TransactionReceipt) -> [String: Any] {
    [
      "merchantName": r.merchantName,
      "merchantId": r.merchantID as Any,
      "merchantAddress": r.merchantAddress as Any,
      "transactionType": r.transactionType,
      "transactionStatus": r.transactionStatus,
      "transactionTime": r.transactionTime,
      "totalAmountMinorUnits": r.totalAmountMinorUnits,
      "totalAmountFormatted": r.totalAmountFormatted,
      "currencyCode": r.currencyCode as Any,
      "maskedToken": r.maskedToken as Any,
      "merchantTransactionReference": r.merchantTransactionReference as Any,
      "cdcvmApprovedByWallet": r.cdcvmApprovedByWallet as Any,
      "transactionId": r.transactionID as Any,
      "transactionHash": r.transactionHash as Any,
    ]
  }

  @objc(walletGetTransactions:limit:resolver:rejecter:)
  func walletGetTransactions(_ ref: String, limit: Double, resolver resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let rows = try await VeyraWallet.shared.transactions(
          tokenUniqueReference: ref, limit: Int(limit)
        )
        resolve(rows.map(self.summaryDict))
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletReconcilePendingTransactions:rejecter:)
  func walletReconcilePendingTransactions(_ resolve: @escaping RCTPromiseResolveBlock,
                                          rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let r = try await VeyraWallet.shared.reconcilePendingTransactions()
        resolve(["checked": r.checked, "failureReason": self.opt(r.failureReason), "message": self.opt(r.message)])
      }
      catch { self.reject(rejecter, error) }
    }
  }

  /// The per-transaction counterpart to the reconcile above — one row, keyed by hash,
  /// resolving with the updated stored row rather than nothing. A check that could not be made
  /// resolves with its `failureReason` (`NO_NETWORK_CONNECTION` when offline), the row untouched.
  @objc(walletRefreshTransactionStatus:resolver:rejecter:)
  func walletRefreshTransactionStatus(_ transactionHash: String,
                                      resolver resolve: @escaping RCTPromiseResolveBlock,
                                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let lookup = try await VeyraWallet.shared.refreshTransactionStatus(
          transactionHash: transactionHash
        )
        resolve(self.lookupDict(lookup.value.map(self.summaryDict),
                                failureReason: lookup.failureReason, message: lookup.message))
      } catch { self.reject(rejecter, error) }
    }
  }

  /// "Check merchant credit now" for one wallet payment. Settlement only — it can never
  /// change the row's outcome triple. A check that could not be made resolves with its
  /// `failureReason` (`NO_NETWORK_CONNECTION` when offline), the row untouched; an ineligible row
  /// makes no call at all and resolves unchanged.
  @objc(walletRefreshCreditConfirmation:resolver:rejecter:)
  func walletRefreshCreditConfirmation(_ transactionHash: String,
                                       resolver resolve: @escaping RCTPromiseResolveBlock,
                                       rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let lookup = try await VeyraWallet.shared.refreshCreditConfirmation(
          transactionHash: transactionHash
        )
        resolve(self.lookupDict(lookup.value.map(self.summaryDict),
                                failureReason: lookup.failureReason, message: lookup.message))
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletProcessReceipt:expectedHash:resolver:rejecter:)
  func walletProcessReceipt(_ payload: String, expectedHash: String?,
                            resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let scan = try await VeyraWallet.shared.processReceipt(
          payload, expectedTransactionHash: expectedHash
        )
        resolve([
          "receipt": scan.receipt.map(self.receiptDict) as Any? ?? NSNull(),
          "responseStatus": scan.responseStatus,
          "responseStatusReason": self.opt(scan.responseStatusReason),
          "message": self.opt(scan.message),
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletGetReceipts:resolver:rejecter:)
  func walletGetReceipts(_ limit: Double, resolver resolve: @escaping RCTPromiseResolveBlock,
                         rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do { resolve(try await VeyraWallet.shared.receipts(limit: Int(limit)).map(self.receiptDict)) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletGetReceiptForTransaction:resolver:rejecter:)
  func walletGetReceiptForTransaction(_ hash: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let receipt = try await VeyraWallet.shared.receiptForTransaction(hash)
        resolve(receipt.map(self.receiptDict))
      } catch { self.reject(rejecter, error) }
    }
  }

  // ── SoftPOS: registration & profile ─────────────────────────────────────────
  //
  // Every call below goes through `VeyraSoftPOS.shared` — the same calls a native iOS app makes. A
  // call that needs the stored merchant and finds none is answered by the facade itself
  // (`MISSING_MANDATORY_CONFIG`: `NOT_SENT` for a payment, `FAILED` otherwise).

  @objc(softposRegister:resolver:rejecter:)
  func softposRegister(_ registration: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                       rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard let typeRaw = registration["merchantType"] as? String,
          let merchantType = MerchantRegistration.MerchantType(rawValue: typeRaw)
    else { return resolve(merchantRegistrationRefused("merchantType must be PERSONAL or BUSINESS")) }
    guard
          let merchantName = registration["merchantName"] as? String,
          let emailAddress = registration["emailAddress"] as? String,
          let phoneNumber = registration["phoneNumber"] as? String,
          let addressLine1 = registration["addressLine1"] as? String,
          let city = registration["city"] as? String,
          let state = registration["state"] as? String,
          let countryCode = registration["countryCode"] as? String,
          let accountNumber = registration["accountNumber"] as? String,
          let institutionCode = registration["institutionCode"] as? String
    else { return resolve(merchantRegistrationRefused("required merchant registration fields missing")) }
    let reg = MerchantRegistration(
      merchantType: merchantType,
      merchantName: merchantName,
      emailAddress: emailAddress,
      phoneNumber: phoneNumber,
      addressLine1: addressLine1,
      addressLine2: registration["addressLine2"] as? String ?? "",
      city: city,
      state: state,
      countryCode: countryCode,
      bvn: registration["bvn"] as? String,
      cacNumber: registration["cacNumber"] as? String,
      accountNumber: accountNumber,
      institutionCode: institutionCode,
      walletAccountID: registration["walletAccountId"] as? String
    )
    Task {
      do {
        let result = try await VeyraSoftPOS.shared.register(reg)
        resolve([
          "success": result.success,
          "merchantId": result.merchantID as Any,
          "terminalId": result.terminalID as Any,
          "merchantStatus": result.merchantStatus as Any,
          "message": result.message as Any,
          "responseStatus": result.responseStatus,
          "responseStatusReason": result.responseStatusReason as Any,
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(softposGetBanks:rejecter:)
  func softposGetBanks(_ resolve: @escaping RCTPromiseResolveBlock,
                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let list = try await VeyraSoftPOS.shared.banks()
        resolve([
          "banks": list.banks.map { ["slug": $0.slug, "name": $0.name, "institutionCode": $0.institutionCode] },
          "responseStatus": list.responseStatus,
          "responseStatusReason": self.opt(list.responseStatusReason),
          "message": self.opt(list.message),
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(softposIsRegistered:rejecter:)
  func softposIsRegistered(_ resolve: @escaping RCTPromiseResolveBlock,
                           rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraSoftPOS.shared.isRegistered())
  }

  private func storedMerchantDict(_ m: StoredMerchant) -> [String: Any] {
    [
      "merchantId": m.merchantID,
      "merchantType": m.merchantType,
      "merchantName": m.merchantName,
      "emailAddress": m.emailAddress,
      "phoneNumber": m.phoneNumber,
      "addressLine1": m.addressLine1,
      "addressLine2": m.addressLine2,
      "city": m.city,
      "state": m.state,
      "countryCode": m.countryCode,
      "accountNumber": m.accountNumber,
      "institutionCode": m.institutionCode,
      "acquirerId": m.acquirerID,
      "merchantCategoryCode": m.merchantCategoryCode,
      "terminalId": m.terminalID,
      "merchantStatus": m.merchantStatus as Any,
      "walletAccountId": m.walletAccountID as Any,
      "bvn": m.bvn as Any,
      "cacNumber": m.cacNumber as Any,
    ]
  }

  @objc(softposGetStoredMerchantData:rejecter:)
  func softposGetStoredMerchantData(_ resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(opt(VeyraSoftPOS.shared.storedMerchantData().map(storedMerchantDict)))
  }

  @objc(softposGetStoredMerchantId:rejecter:)
  func softposGetStoredMerchantId(_ resolve: @escaping RCTPromiseResolveBlock,
                                  rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(opt(VeyraSoftPOS.shared.storedMerchantID()))
  }

  @objc(softposHasStoredMerchant:rejecter:)
  func softposHasStoredMerchant(_ resolve: @escaping RCTPromiseResolveBlock,
                                rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraSoftPOS.shared.hasStoredMerchant())
  }

  @objc(softposIsMerchantActive:rejecter:)
  func softposIsMerchantActive(_ resolve: @escaping RCTPromiseResolveBlock,
                               rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraSoftPOS.shared.isMerchantActive())
  }

  /// Init-free: `customerId`'s stored merchant, read before `Veyra.initialize` — no init or
  /// sign-in gate, nothing started (the Home-screen "Get paid" decision).
  @objc(softposGetStoredMerchantDataFor:resolver:rejecter:)
  func softposGetStoredMerchantDataFor(_ customerId: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                       rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    resolve(opt(VeyraSoftPOS.storedMerchantData(customerID: customerId).map(storedMerchantDict)))
  }

  /// Init-free: whether `customerId` has a merchant registered on this device.
  @objc(softposIsMerchantRegistered:resolver:rejecter:)
  func softposIsMerchantRegistered(_ customerId: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                   rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    resolve(VeyraSoftPOS.isMerchantRegistered(customerID: customerId))
  }

  @objc(softposRefreshStatus:rejecter:)
  func softposRefreshStatus(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    Task {
      do { resolve(self.merchantStatusDict(try await VeyraSoftPOS.shared.refreshStatus())) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(softposActivate:rejecter:)
  func softposActivate(_ resolve: @escaping RCTPromiseResolveBlock,
                       rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    Task {
      do { resolve(self.merchantStatusDict(try await VeyraSoftPOS.shared.activate())) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(softposDeactivate:rejecter:)
  func softposDeactivate(_ resolve: @escaping RCTPromiseResolveBlock,
                         rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    Task {
      do { resolve(self.merchantStatusDict(try await VeyraSoftPOS.shared.deactivate())) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(softposUpdateMerchant:resolver:rejecter:)
  func softposUpdateMerchant(_ update: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard let merchantName = update["merchantName"] as? String,
          let emailAddress = update["emailAddress"] as? String,
          let phoneNumber = update["phoneNumber"] as? String,
          let addressLine1 = update["addressLine1"] as? String,
          let city = update["city"] as? String,
          let state = update["state"] as? String,
          let countryCode = update["countryCode"] as? String,
          let accountNumber = update["accountNumber"] as? String,
          let institutionCode = update["institutionCode"] as? String
    else { return resolve(merchantStatusRefused(Self.invalidRequest, "required merchant update fields missing")) }
    let merchantUpdate = MerchantUpdate(
      merchantName: merchantName,
      emailAddress: emailAddress,
      phoneNumber: phoneNumber,
      addressLine1: addressLine1,
      addressLine2: update["addressLine2"] as? String ?? "",
      city: city,
      state: state,
      countryCode: countryCode,
      accountNumber: accountNumber,
      institutionCode: institutionCode,
      walletAccountID: update["walletAccountId"] as? String,
      bvn: update["bvn"] as? String
    )
    Task {
      do { resolve(self.merchantStatusDict(try await VeyraSoftPOS.shared.updateMerchant(merchantUpdate))) }
      catch { self.reject(rejecter, error) }
    }
  }

  // ── SoftPOS: tap acceptance ─────────────────────────────────────────────────

  /// The JS name of each `TapEvent` — the native spellings, the same as the Android module's.
  static func tapEventType(_ event: TapEvent) -> String {
    switch event {
    case .cardDetected: return "cardDetected"
    case .cardContactLost: return "cardContactLost"
    case .unsupportedCard: return "unsupportedCard"
    case .cardReadingComplete: return "cardReadingComplete"
    case .sendingRequestOnline: return "sendingRequestOnline"
    case .receivingOnlineResponse: return "receivingOnlineResponse"
    case .result: return "result"
    case .ended: return "ended"
    }
  }

  private func tapResultDict(_ result: TapResult) -> [String: Any] {
    // The outcome as the SDK stated it — a refusal before sending (blank order id, no merchant
    // stored, the other mode's payment in flight, cancelled) is NOT_SENT with its reason and no code.
    return [
      "responseCode": opt(result.responseCode),
      "responseStatus": result.responseStatus,
      "responseStatusReason": opt(result.responseStatusReason),
      "message": opt(result.message),
      "amountMinorUnits": result.amountMinorUnits.map { $0 as Any } ?? NSNull(),
      "cardScheme": opt(result.cardScheme),
      "maskedTokenLast4": opt(result.maskedTokenLast4),
      "merchantTransactionReference": opt(result.merchantTransactionReference),
      "transactionId": opt(result.transactionID),
      "merchantStatus": opt(result.merchantStatus),
      // The settlement response's credit facts, so an iOS tap sale can show the same
      // "confirming credit…" wait its CPM/MPM siblings do; the answer then arrives on the
      // credit-confirmation event (and on the stored row).
      "creditTransactionId": result.creditTransactionID.map { $0 as Any } ?? NSNull(),
      "isCreditConfirmationSupported": result.isCreditConfirmationSupported.map { $0 as Any } ?? NSNull(),
      "originalPayment": originalPaymentDict(result.originalPayment),
    ]
  }

  @objc(softposTapStart:resolver:rejecter:)
  func softposTapStart(_ request: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                       rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard requireSession("getPaid", rejecter) else { return }
    // JS mints the session id and listens for it before calling, so no event — an immediate
    // NOT_SENT result included — can arrive before JS knows which tap it belongs to.
    let sessionId = (request["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
    guard let amount = request["amountMinorUnits"] as? Double else {
      // A bad argument ends the tap the way the SDK ends a blank order id: a NOT_SENT result on
      // the event stream, with nothing armed (the Android module does the same).
      resolve(["sessionId": sessionId])
      sendEvent(withName: EventName.softposTap, body: [
        "sessionId": sessionId,
        "type": "result",
        "result": tapResultNotSent("amountMinorUnits is required"),
      ])
      return
    }
    // Required. Missing from untyped JS → blank → the SDK refuses it with INVALID_REQUEST; a
    // currency that is not ISO 4217 numeric is refused by the SDK the same way.
    let merchantOrderID = (request["merchantOrderId"] as? String) ?? ""
    let tapRequest = TapRequest(
      amountMinorUnits: Int64(amount),
      currency: (request["currency"] as? String) ?? "566",
      merchantOrderID: merchantOrderID
    )
    do {
      tapSessions[sessionId] = merchantOrderID
      try VeyraSoftPOS.shared.tap.start(tapRequest) { [weak self] event in
        guard let self else { return }
        var body: [String: Any] = ["sessionId": sessionId, "type": Self.tapEventType(event)]
        switch event {
        case .ended(let outcome):
          body["outcome"] = outcome.rawValue
          self.tapSessions.removeValue(forKey: sessionId)
        case .result(let result):
          body["result"] = self.tapResultDict(result)
          self.tapSessions.removeValue(forKey: sessionId)
        default:
          break
        }
        self.sendEvent(withName: EventName.softposTap, body: body)
      }
      resolve(["sessionId": sessionId])
    } catch {
      tapSessions.removeValue(forKey: sessionId)
      self.reject(rejecter, error)
    }
  }

  @objc(softposIsTransactionInProgress:rejecter:)
  func softposIsTransactionInProgress(_ resolve: @escaping RCTPromiseResolveBlock,
                                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraSoftPOS.shared.isTransactionInProgress())
  }

  @objc(softposIsAwaitingCardTap:rejecter:)
  func softposIsAwaitingCardTap(_ resolve: @escaping RCTPromiseResolveBlock,
                                rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraSoftPOS.shared.isAwaitingCardTap())
  }

  /// Cancels the SoftPOS payment started with `merchantOrderId` — tap, customer-QR charge or
  /// payment-QR create alike. Resolves with the `CancelResult` name; the payment itself still
  /// ends with its own outcome (a tap's on its `result` event). Needs no session.
  @objc(softposCancelPayment:resolver:rejecter:)
  func softposCancelPayment(_ merchantOrderId: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraSoftPOS.shared.cancelPayment(merchantOrderID: merchantOrderId).rawValue)
  }

  // ── SoftPOS: get-paid QR (MPM) ──────────────────────────────────────────────

  @objc(softposCreatePaymentContext:currency:merchantOrderId:resolver:rejecter:)
  func softposCreatePaymentContext(_ amountMinorUnits: Double, currency: String,
                                   merchantOrderId: String?,
                                   resolver resolve: @escaping RCTPromiseResolveBlock,
                                   rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    Task {
      do {
        let context = try await VeyraSoftPOS.shared.createPaymentContext(
          amountMinorUnits: Int64(amountMinorUnits),
          currency: currency,
          merchantOrderID: merchantOrderId ?? "",
          onExpired: { [weak self] in
            self?.sendEvent(withName: EventName.qrExpired, body: ["scope": "softpos", "handle": NSNull()])
          }
        )
        // txRef / mpmPayload only on APPROVED; otherwise the reason there is no QR.
        resolve([
          "txRef": self.opt(context.txRef),
          "mpmPayload": self.opt(context.mpmPayload),
          "expiry": self.opt(context.expiry),
          "responseStatus": context.responseStatus,
          "responseStatusReason": self.opt(context.responseStatusReason),
          "message": self.opt(context.message),
          "originalPayment": self.originalPaymentDict(context.originalPayment),
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(softposCancelQrExpiry:rejecter:)
  func softposCancelQrExpiry(_ resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    VeyraSoftPOS.shared.cancelQrExpiry()
    resolve(nil)
  }

  @objc(softposContextStatus:resolver:rejecter:)
  func softposContextStatus(_ txRef: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        // A poll's own failure is never the payment's state: a lookup, with the reason.
        let lookup = try await VeyraSoftPOS.shared.contextStatus(txRef: txRef)
        let value: [String: Any]? = lookup.value.map { state in
          [
            "txRef": state.txRef,
            "state": state.state,
            "responseCode": state.responseCode as Any,
            "transactionHash": state.transactionHash as Any,
            "isSettled": state.isSettled,
            "isApproved": state.isApproved,
          ]
        }
        resolve(self.lookupDict(value, failureReason: lookup.failureReason, message: lookup.message))
      } catch { self.reject(rejecter, error) }
    }
  }

  // ── SoftPOS: charge a customer QR (CPM) ─────────────────────────────────────

  @objc(softposInspectCustomerQr:resolver:rejecter:)
  func softposInspectCustomerQr(_ payload: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let inspection = try await VeyraSoftPOS.shared.inspectCustomerQr(payload)
        // A handle is issued only for a QR that can be charged; the card data stays native.
        var qr: [String: Any]?
        if let scanned = inspection.qr {
          let handle = UUID().uuidString
          self.cpmQrs[handle] = scanned
          qr = [
            "handle": handle,
            // Same display form as the Android module: bullets + the last four.
            "maskedCard": scanned.maskedCard,
            "amountMinorUnits": scanned.amountMinorUnits,
            "currencyCode": scanned.currencyCode,
            "cardholderName": scanned.cardholderName as Any,
          ]
        }
        resolve([
          "qr": self.opt(qr),
          "responseStatus": inspection.responseStatus,
          "responseStatusReason": self.opt(inspection.responseStatusReason),
          "message": self.opt(inspection.message),
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(softposChargeCustomerQr:merchantOrderId:resolver:rejecter:)
  func softposChargeCustomerQr(_ handle: String, merchantOrderId: String?,
                               resolver resolve: @escaping RCTPromiseResolveBlock,
                               rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard let scanned = cpmQrs.removeValue(forKey: handle) else {
      return resolve(customerQrChargeNotSent("Unknown or already-used QR handle — re-scan"))
    }
    Task {
      do {
        let outcome = try await VeyraSoftPOS.shared.chargeCustomerQr(scanned, merchantOrderID: merchantOrderId ?? "")
        resolve([
          // `approved` is the facade's reading of the status, never of the code.
          "approved": outcome.approved,
          "responseCode": outcome.responseCode as Any,
          "responseStatus": outcome.responseStatus,
          "responseStatusReason": outcome.responseStatusReason as Any,
          "message": self.opt(outcome.message),
          "transactionId": outcome.transactionID as Any,
          "merchantTransactionReference": self.opt(outcome.merchantTransactionReference),
          "merchantOrderId": self.opt(outcome.merchantOrderID),
          // An approved answer carries the merchant-bank credit id + supported flag — the
          // result screen's cue to wait for the credit-confirmation event.
          "creditTransactionId": outcome.creditTransactionID as Any,
          "isCreditConfirmationSupported": outcome.isCreditConfirmationSupported as Any,
          "originalPayment": self.originalPaymentDict(outcome.originalPayment),
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  // ── SoftPOS: transactions & receipts ────────────────────────────────────────

  private func merchantTransactionDict(_ t: MerchantTransaction) -> [String: Any] {
    [
      "merchantTransactionReference": t.merchantTransactionReference,
      // the app's own order id, from the stored row — the detail and history screens
      // need it, not just the screen that took the payment.
      "merchantOrderId": t.merchantOrderID as Any? ?? NSNull(),
      "amountMinorUnits": t.amountMinorUnits,
      "status": t.status,
      "responseCode": t.responseCode as Any,
      "transactionTime": t.transactionTime as Any,
      "currencyCode": t.currencyCode as Any,
      "transactionId": t.transactionID as Any,
      "rail": t.rail,
      "railLabel": t.railLabel,
      "maskedTokenLast4": t.maskedTokenLast4,
      "transactionHash": t.transactionHash as Any,
      "cardholderName": t.cardholderName as Any,
      // Settlement facts: the credit id, the supported flag (the result screen's cue to wait)
      // and the terminal confirmation state — null while unconfirmed ("not confirmed yet",
      // never "not received").
      "creditTransactionId": t.creditTransactionID as Any,
      "isCreditConfirmationSupported": t.isCreditConfirmationSupported as Any,
      "creditConfirmationStatus": t.creditConfirmationStatus as Any,
    ]
  }

  @objc(softposGetTransactions:resolver:rejecter:)
  func softposGetTransactions(_ limit: Double, resolver resolve: @escaping RCTPromiseResolveBlock,
                              rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let rows = try await VeyraSoftPOS.shared.transactions(limit: Int(limit))
        resolve(rows.map(self.merchantTransactionDict))
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(softposGetTransaction:resolver:rejecter:)
  func softposGetTransaction(_ reference: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let row = try await VeyraSoftPOS.shared.transaction(merchantTransactionReference: reference)
        resolve(self.opt(row.map(self.merchantTransactionDict)))
      } catch { self.reject(rejecter, error) }
    }
  }

  /// Lookup by the app's own order id — a read: resolves a `VeyraLookup<OrderPaymentStatus>`.
  @objc(softposPaymentStatus:resolver:rejecter:)
  func softposPaymentStatus(_ merchantOrderId: String,
                            resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    Task {
      do {
        let lookup = try await VeyraSoftPOS.shared.paymentStatus(merchantOrderID: merchantOrderId)
        resolve(self.lookupDict(lookup.value.map(self.orderPaymentStatusDict),
                                failureReason: lookup.failureReason, message: lookup.message))
      } catch { self.reject(rejecter, error) }
    }
  }

  private func orderPaymentStatusDict(_ o: OrderPaymentStatus) -> [String: Any] {
    [
      "merchantOrderId": o.merchantOrderID,
      "responseStatus": o.responseStatus,
      "responseStatusReason": opt(o.responseStatusReason),
      "responseCode": opt(o.responseCode),
      "merchantTransactionReference": opt(o.merchantTransactionReference),
      "transactionId": opt(o.transactionID),
      "amountMinorUnits": o.amountMinorUnits.map { $0 as Any } ?? NSNull(),
      "answeredBy": o.answeredBy,
      "attempts": o.attempts.map { a -> [String: Any] in
        [
          "merchantTransactionReference": opt(a.merchantTransactionReference),
          "transactionId": opt(a.transactionID),
          "amountMinorUnits": a.amountMinorUnits.map { $0 as Any } ?? NSNull(),
          "responseCode": opt(a.responseCode),
          "responseStatus": opt(a.responseStatus),
          "responseStatusReason": opt(a.responseStatusReason),
        ]
      },
    ]
  }

  /// The on-demand "check status now" for one transaction. Unlike `softposGetTransaction` — a
  /// local read — this goes to the gateway; a check that could not be made resolves with its
  /// `failureReason` (`NO_NETWORK_CONNECTION`).
  @objc(softposRefreshTransactionStatus:resolver:rejecter:)
  func softposRefreshTransactionStatus(_ reference: String,
                                       resolver resolve: @escaping RCTPromiseResolveBlock,
                                       rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let lookup = try await VeyraSoftPOS.shared.refreshTransactionStatus(merchantTransactionReference: reference)
        resolve(self.lookupDict(lookup.value.map(self.merchantTransactionDict),
                                failureReason: lookup.failureReason, message: lookup.message))
      } catch { self.reject(rejecter, error) }
    }
  }

  /// "Check merchant credit now" for one sale. Unlike `softposGetTransaction` — a local
  /// read — this goes to the gateway; a check that could not be made resolves with its
  /// `failureReason` (`NO_NETWORK_CONNECTION`). An ineligible row makes no call and resolves unchanged.
  @objc(softposRefreshCreditConfirmation:resolver:rejecter:)
  func softposRefreshCreditConfirmation(_ reference: String,
                                        resolver resolve: @escaping RCTPromiseResolveBlock,
                                        rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let lookup = try await VeyraSoftPOS.shared.refreshCreditConfirmation(merchantTransactionReference: reference)
        resolve(self.lookupDict(lookup.value.map(self.merchantTransactionDict),
                                failureReason: lookup.failureReason, message: lookup.message))
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(softposGetReceipt:resolver:rejecter:)
  func softposGetReceipt(_ reference: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                         rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let receipt = try await VeyraSoftPOS.shared.receipt(merchantTransactionReference: reference)
        resolve(self.opt(receipt.map { r in
          [
            "merchantName": r.merchantName,
            "merchantAddress": r.merchantAddress,
            "transactionType": r.transactionType,
            "totalAmountMinorUnits": r.totalAmountMinorUnits,
            "totalAmountFormatted": r.totalAmountFormatted,
            "maskedToken": r.maskedToken,
            "merchantTransactionReference": r.merchantTransactionReference,
            "transactionHash": r.transactionHash as Any,
            "cardholderName": r.cardholderName as Any,
            "qrCodeBase64": NSNull(),
            "qrPayload": r.qrPayload,
          ] as [String: Any]
        }))
      } catch { self.reject(rejecter, error) }
    }
  }

  /// The gateway's raw record of one transaction — a read: `VeyraLookup<TransactionStatus[]>`.
  @objc(softposGetTransactionStatus:transactionDate:resolver:rejecter:)
  func softposGetTransactionStatus(_ reference: String, transactionDate: String,
                                   resolver resolve: @escaping RCTPromiseResolveBlock,
                                   rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let lookup = try await VeyraSoftPOS.shared.transactionStatus(
          merchantTransactionReference: reference, transactionDate: transactionDate
        )
        let value: [[String: Any]]? = lookup.value.map { items in
          items.map { i in
            [
              "merchantTransactionReference": i.merchantTransactionReference,
              "merchantId": i.merchantID,
              "amountMinorUnits": i.amountMinorUnits.map { $0 as Any } ?? NSNull(),
              "responseCode": i.responseCode,
              "responseStatus": self.opt(i.responseStatus),
              "responseStatusReason": self.opt(i.responseStatusReason),
              "merchantStatus": self.opt(i.merchantStatus),
              "transactionId": self.opt(i.transactionID),
              "creditTransactionId": self.opt(i.creditTransactionID),
              "isCreditConfirmationSupported": i.isCreditConfirmationSupported.map { $0 as Any } ?? NSNull(),
            ]
          }
        }
        resolve(self.lookupDict(value, failureReason: lookup.failureReason, message: lookup.message))
      } catch { self.reject(rejecter, error) }
    }
  }

  /// The merchant bank's raw credit confirmation for one sale — a read: `VeyraLookup<CreditConfirmation>`.
  @objc(softposGetCreditConfirmation:amountMinorUnits:resolver:rejecter:)
  func softposGetCreditConfirmation(_ creditTransactionId: String, amountMinorUnits: Double,
                                    resolver resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let lookup = try await VeyraSoftPOS.shared.creditConfirmation(
          creditTransactionID: creditTransactionId, amountMinorUnits: Int64(amountMinorUnits)
        )
        let value: [String: Any]? = lookup.value.map { c in
          [
            "creditTransactionId": c.creditTransactionID,
            "status": c.status,
            "amountMinorUnits": c.amountMinorUnits.map { $0 as Any } ?? NSNull(),
            "creditedAt": self.opt(c.creditedAt),
            "bankReference": self.opt(c.bankReference),
            "message": self.opt(c.message),
          ]
        }
        resolve(self.lookupDict(value, failureReason: lookup.failureReason, message: lookup.message))
      } catch { self.reject(rejecter, error) }
    }
  }
}

/// A bridge-side refusal message (an `Error` so it can ride a `Result`).
private struct BridgeMessage: Error { let text: String }

/// `requestTimeoutSeconds` from an SDK's config map: nil when absent, a refusal naming the SDK when
/// it is not a whole number.
private func requestTimeoutSeconds(_ map: NSDictionary, sdk: String) -> Result<Int?, BridgeMessage> {
  guard let raw = map["requestTimeoutSeconds"], !(raw is NSNull) else { return .success(nil) }
  guard let number = raw as? NSNumber else {
    return .failure(BridgeMessage(text: "\(sdk).requestTimeoutSeconds must be a whole number of seconds"))
  }
  let value = number.doubleValue
  guard value.rounded() == value, let whole = Int(exactly: value) else {
    return .failure(BridgeMessage(text: "\(sdk).requestTimeoutSeconds must be a whole number of seconds (was \(value))"))
  }
  return .success(whole)
}
