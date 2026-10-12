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
 * which experience is open and gates the calls Android gates (`merchantTapStart`,
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
    static let merchantTap = "VeyraMerchantTapEvent"
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
    static let cardKeyState = "VeyraCardKeyStateEvent"
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
  private var tapSessions: [String: (session: TapPaymentSession, merchantOrderID: String)] = [:]
  private var mpmContexts: [String: VerifiedPayment] = [:]
  private var cpmQrs: [String: ScannedCustomerQr] = [:]

  override static func requiresMainQueueSetup() -> Bool { false }

  override func supportedEvents() -> [String] {
    [
      EventName.activation,
      EventName.walletTap,
      EventName.merchantTap,
      EventName.qrExpired,
      EventName.paymentRefusal,
      EventName.transactionResolved,
      EventName.creditConfirmation,
      EventName.tokenStatusChanged,
      EventName.walletTransactionResolved,
      EventName.cardKeyState,
      EventName.merchantStatus,
      EventName.connectionRequest,
    ]
  }

  // ── Setup errors: the only rejections ───────────────────────────────────────

  private func reject(_ rejecter: RCTPromiseRejectBlock, _ error: Error) {
    let (code, message) = classify(error)
    rejecter(code, message, error)
  }

  /// The five setup errors, by case — the same codes the Android module maps from
  /// `VeyraSetupException.code`. Anything else is an SDK defect, never an outcome: `UNKNOWN`.
  private func classify(_ error: Error) -> (String, String) {
    switch error {
    case VeyraWalletError.notConfigured, VeyraSoftPOSError.notConfigured, VeyraSDKError.notConfigured:
      return ("NOT_CONFIGURED", "Call Veyra.initialize first")
    case VeyraWalletError.notSignedIn, VeyraSoftPOSError.notSignedIn:
      return ("NOT_SIGNED_IN", "No customer is signed in — call Veyra.initialize with the customerId first")
    case let VeyraWalletError.invalidConfiguration(message):
      return ("INVALID_CONFIGURATION", message)
    case let VeyraSoftPOSError.invalidConfiguration(message):
      return ("INVALID_CONFIGURATION", message)
    case VeyraWalletError.sessionRequired, VeyraSoftPOSError.sessionRequired:
      return ("SESSION_REQUIRED", error.localizedDescription)
    case VeyraWalletError.unsupportedOnPlatform, VeyraSoftPOSError.unsupportedOnPlatform:
      return ("UNSUPPORTED_ON_PLATFORM", error.localizedDescription)
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
  private static let missingMandatoryConfig = "MISSING_MANDATORY_CONFIG"

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

  private func paymentContextQrNotSent(_ reason: String, _ message: String) -> [String: Any] {
    notSent(reason, message, nullKeys: ["txRef", "mpmPayload", "expiry", "originalPayment"],
            operation: SdkOperation.shared.MPM_CONTEXT)
  }

  private func tapResultNotSent(_ message: String) -> [String: Any] {
    var body = notSent(Self.invalidRequest, message,
                       nullKeys: ["responseCode", "amountDisplay", "cardScheme", "maskedTokenLast4",
                                  "merchantTransactionReference", "transactionId", "merchantStatus",
                                  "creditTransactionId", "isCreditConfirmationSupported", "originalPayment"],
                       operation: SdkOperation.shared.MERCHANT_TAP)
    body["status"] = Self.notSentStatus
    return body
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
      "merchantTransactionReference": opt(o.reference),
      "transactionId": opt(o.transactionID),
    ] as [String: Any]
  }

  /// A `VeyraLookup`: the value, or why the read could not be made.
  private func lookupDict(_ value: Any?, failureReason: String?, message: String?) -> [String: Any] {
    ["value": opt(value), "failureReason": opt(failureReason), "message": opt(message)]
  }

  private func merchantStatusDict(_ s: MerchantStatus) -> [String: Any] {
    [
      "merchantId": opt(s.merchantID),
      "merchantStatus": opt(s.status),
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
    guard let softposEnv = VeyraSoftPOSConfiguration.Environment(rawValue: softposMap["environment"] as? String ?? ""),
          let walletEnv = VeyraWalletConfiguration.Environment(rawValue: walletMap["environment"] as? String ?? "")
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
    let softpos = VeyraSoftPOSConfiguration(
      environment: softposEnv,
      paymentAppProviderID: softposProviderID
    )
    let wallet = VeyraWalletConfiguration(
      environment: walletEnv,
      paymentAppProviderID: walletMap["paymentAppProviderId"] as? String,
      tokenRequestorID: walletMap["tokenRequestorId"] as? String,
      appVersion: walletMap["appVersion"] as? String ?? "1.0.0",
      appleTeamID: appleTeamID,
      allowedAcquirerIDs: walletMap["allowedAcquirerIds"] as? [String] ?? [],
      allowedMerchantIDs: walletMap["allowedMerchantIds"] as? [String] ?? []
    )

    do {
      // Throws on an unusable provider or a change of kind within the process (no fallback).
      try VeyraSDK.configure(customerID: customerID, provider: provider, softpos: softpos, wallet: wallet)
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
  /// keep reading `merchant.getTransaction(s)` when they appear (`devices/CLAUDE.md` §16).
  private func observeDeferredAnswers() {
    try? VeyraSoftPOS.shared.transactions.onTransactionResolved { [weak self] resolution in
      self?.sendEvent(withName: EventName.transactionResolved, body: [
        "merchantTransactionReference": resolution.reference,
        "responseCode": resolution.responseCode.map { $0 as Any } ?? NSNull(),
        "status": resolution.status,
        "reason": resolution.reason.map { $0 as Any } ?? NSNull(),
      ])
    }
    try? VeyraSoftPOS.shared.transactions.onCreditConfirmation { [weak self] confirmation in
      self?.sendEvent(withName: EventName.creditConfirmation, body: [
        "merchantTransactionReference": confirmation.reference,
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
  /// `walletTransactionResolved` / `cardKeyState` / `merchantStatusChanged` on Android exactly —
  /// shared JS reads one shape. Android's side is pinned by `MappersTest`; this side is pinned by
  /// the guides and by the RN sample subscribing to both.
  ///
  /// Same contract as the two deferred answers above: single-listener, no replay, notifications
  /// rather than the source of truth — screens keep reading the store when they appear (§16).
  private func observeStateChanges() {
    try? VeyraWallet.shared.tokenisation.observeTokenLifecycle { [weak self] change in
      self?.sendEvent(withName: EventName.tokenStatusChanged, body: [
        "tokenUniqueReference": change.tokenUniqueReference,
        "status": change.status,
        "rawStatus": change.rawStatus,
        "canPay": change.canPay,
        "previousStatus": change.previousStatus.map { $0 as Any } ?? NSNull(),
      ])
    }
    try? VeyraWallet.shared.tokenisation.observeTransactionResolved { [weak self] resolution in
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
    try? VeyraWallet.shared.tokenisation.observeCardKeyState(
      onKeyStateChanged: { [weak self] tokenUniqueReference, requiresOnline in
        self?.sendEvent(withName: EventName.cardKeyState, body: [
          "tokenUniqueReference": tokenUniqueReference,
          "requiresOnline": requiresOnline,
          "deviceNotBound": false,
        ])
      },
      onDeviceNotBound: { [weak self] tokenUniqueReference in
        // the backend will not re-key this card on this device: never "requires online".
        self?.sendEvent(withName: EventName.cardKeyState, body: [
          "tokenUniqueReference": tokenUniqueReference,
          "requiresOnline": false,
          "deviceNotBound": true,
        ])
      }
    )
    try? VeyraSoftPOS.shared.merchant.onMerchantStatusChanged { [weak self] change in
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
    do { resolve(try VeyraSDK.shared.currentMode.rawValue) }
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

  /// Cancels every open tap by its order ID. A tap not yet sent ends `NOT_SENT` / `CANCELLED`
  /// on its own `result` event; one already sent is refused by the SDK and runs to its normal
  /// result — so its session stays held here until that `result` arrives, never dropped
  /// mid-payment. (Each entry also leaves on its own `result` / `ended` event.)
  private func cancelOpenTaps() {
    for (sessionId, open) in tapSessions {
      let answer = open.merchantOrderID.isEmpty
        ? nil
        : VeyraSoftPOS.shared.payments.cancelPayment(merchantOrderID: open.merchantOrderID).rawValue
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
        let list = try await VeyraWallet.shared.tokenisation.banks(accountNumber: accountNumber)
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
        let response = try await VeyraWallet.shared.tokenisation.verifyAccount(
          accountNumber: accountNumber,
          institutionCode: institutionCode,
          walletAccountID: walletAccountID,
          accountHolderName: params["accountHolderName"] as? String ?? "",
          accountNumberSource: params["accountNumberSource"] as? String
        )
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
                            nullKeys: ["responseCode", "tokenUniqueReference", "tokenStored"],
                            operation: SdkOperation.shared.DIGITISE)
      refused["activationMethods"] = [Any]()
      return resolve(refused)
    }
    Task {
      do {
        let result = try await VeyraWallet.shared.tokenisation.digitise(
          accountNumber: accountNumber,
          institutionCode: institutionCode,
          walletAccountID: walletAccountID,
          accountHolderName: accountHolderName,
          emailAddress: emailAddress,
          recommendation: recommendation,
          mobileNumber: params["mobileNumber"] as? String,
          bvn: params["bvn"] as? String,
          accountHolderAddress: params["accountHolderAddress"] as? String,
          accountNumberSource: params["accountNumberSource"] as? String,
          consumerIdentifier: params["consumerIdentifier"] as? String,
          deviceScore: (params["deviceScore"] as? String).flatMap { TrustScore(rawValue: $0) },
          accountScore: (params["accountScore"] as? String).flatMap { TrustScore(rawValue: $0) },
          recommendationReasons: (params["recommendationReasons"] as? [String])?
            .compactMap { TokenizationRecommendationReason(rawValue: $0) } ?? [],
          bankName: params["bankName"] as? String,
          // The app's own id, so `wallet.cancelDigitise` can name this add-card; absent → the
          // SDK generates one and the add-card cannot be cancelled.
          clientRequestID: (params["clientRequestId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
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
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  // ── Wallet: activation ──────────────────────────────────────────────────────

  @objc(walletRequestActivationCode:medium:contact:reason:resolver:rejecter:)
  func walletRequestActivationCode(_ ref: String, medium: String, contact: String?, reason: String,
                                   resolver resolve: @escaping RCTPromiseResolveBlock,
                                   rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard let method = ActivationMethod(rawValue: medium) else {
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
        let response = try await VeyraWallet.shared.tokenisation.requestActivationCode(
          tokenUniqueReference: ref, method: method, reason: activationReason
        )
        resolve([
          "tokenUniqueReference": response.tokenUniqueReference as Any,
          "expirationDateTime": response.expirationDateTime as Any,
          "status": response.status as Any,
          "message": response.message as Any,
          // Raw wire value: JS carries codes verbatim (unknown codes included).
          "failureCode": response.failureCodeRaw as Any,
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
        let response = try await VeyraWallet.shared.tokenisation.activate(
          tokenUniqueReference: ref, activationCode: code
        )
        resolve([
          "tokenUniqueReference": response.tokenUniqueReference as Any,
          "status": response.status as Any,
          "message": response.message as Any,
          // Raw wire values: JS carries codes verbatim (unknown codes included).
          "failureCode": response.failureCodeRaw as Any,
          "attemptsRemaining": response.attemptsRemaining as Any,
          "recommendDelete": response.recommendDeleteRaw as Any,
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
        let result = try await VeyraWallet.shared.tokenisation.tokenStatus(tokenUniqueReference: ref)
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
      try VeyraWallet.shared.tokenisation.observeActivation(
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
    do { try VeyraWallet.shared.tokenisation.pauseActivationObserver(tokenUniqueReference: ref); resolve(nil) }
    catch { self.reject(rejecter, error) }
  }

  @objc(walletResumeActivationObserver:resolver:rejecter:)
  func walletResumeActivationObserver(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    do { try VeyraWallet.shared.tokenisation.resumeActivationObserver(tokenUniqueReference: ref); resolve(nil) }
    catch { self.reject(rejecter, error) }
  }

  @objc(walletStopActivationObserver:resolver:rejecter:)
  func walletStopActivationObserver(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    do { try VeyraWallet.shared.tokenisation.stopActivationObserver(tokenUniqueReference: ref); resolve(nil) }
    catch { self.reject(rejecter, error) }
  }

  // ── Wallet: cards ───────────────────────────────────────────────────────────

  private func cardDict(_ card: StoredCard) -> [String: Any] {
    [
      "id": card.tokenUniqueReference,
      "tokenUniqueReference": card.tokenUniqueReference,
      "tokenId": NSNull(),
      "maskedPan": card.maskedPAN,
      "panLastFour": card.panLastFour,
      "cardHolderName": card.cardHolderName,
      "expiry": card.expiry,
      "bankName": card.bankName as Any,
      "cardScheme": NSNull(),
      "status": card.status,
      "isActive": card.isActive,
      "requiresActivation": card.requiresActivation,
      "activationMethods": NSNull(),
      "requiresOnline": card.requiresOnline,
      "deviceNotBound": card.deviceNotBound,
    ]
  }

  @objc(walletGetCards:rejecter:)
  func walletGetCards(_ resolve: @escaping RCTPromiseResolveBlock,
                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do { resolve(try await VeyraWallet.shared.tokenisation.tokens().map(self.cardDict)) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletGetActiveCard:rejecter:)
  func walletGetActiveCard(_ resolve: @escaping RCTPromiseResolveBlock,
                           rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    Task {
      do {
        // `activeToken` is an async throwing property (it reads the stored token list).
        if let card = try await VeyraWallet.shared.tokenisation.activeToken {
          resolve(self.cardDict(card))
        } else {
          resolve(nil)
        }
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletSetActiveCard:resolver:rejecter:)
  func walletSetActiveCard(_ cardId: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                           rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    // Gated like Android's, so one JS integration behaves the same on both: the pay screen's
    // session must be open. (On iOS the selection arms no tap — it picks the card the QR rails use.)
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard requireSession("pay", rejecter) else { return }
    Task {
      do {
        let selection = try await VeyraWallet.shared.tokenisation.setActiveToken(cardId)
        // Refusals are NOT armed here any more: they are per card and reach JS through
        // `wallet.onPaymentRefusal`, which observes whichever card the app is listening to
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
      try VeyraWallet.shared.tokenisation.observePaymentRefusals(
        forTokenUniqueReference: tokenUniqueReference,
        onRequireOnline: { [weak self] tokenUniqueReference, amountMinorUnits, rail in
          self?.sendEvent(withName: EventName.paymentRefusal, body: [
            "type": "requireOnline",
            // iOS has no local card id; the reference is the identifier on this platform.
            "tokenId": NSNull(),
            "tokenUniqueReference": tokenUniqueReference ?? NSNull(),
            "amountMinorUnits": amountMinorUnits,
            "rail": rail,
            "message": "ONLINE_REQUIRED: Connect to the internet — the wallet needs to refresh this card before it can pay",
          ])
        },
        onAmountExceedsCardLimit: { [weak self] tokenUniqueReference, amountMinorUnits, cardLimitMinorUnits, rail in
          self?.sendEvent(withName: EventName.paymentRefusal, body: [
            "type": "amountExceedCardLimit",
            "tokenId": NSNull(),
            "tokenUniqueReference": tokenUniqueReference ?? NSNull(),
            "amountMinorUnits": amountMinorUnits,
            "cardLimitMinorUnits": cardLimitMinorUnits ?? NSNull(),
            "rail": rail,
            "message": "AMOUNT_EXCEEDS_CARD_LIMIT: This amount is too large for this card — try a smaller amount, or another card",
          ])
        },
        onDeviceNotBound: { [weak self] tokenUniqueReference, amountMinorUnits, rail in
          self?.sendEvent(withName: EventName.paymentRefusal, body: [
            "type": "deviceNotBound",
            "tokenId": NSNull(),
            "tokenUniqueReference": tokenUniqueReference ?? NSNull(),
            "amountMinorUnits": amountMinorUnits,
            "rail": rail,
            "message": "DEVICE_NOT_BOUND: This card was added on another device — add it again on this phone to pay with it",
          ])
        }
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
      try VeyraWallet.shared.tokenisation.stopObservingPaymentRefusals(
        forTokenUniqueReference: tokenUniqueReference
      )
      resolve(nil)
    } catch { self.reject(rejecter, error) }
  }

  @objc(walletDeactivateToken:resolver:rejecter:)
  func walletDeactivateToken(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        // The backend's answer reaches JS, as it does on the two native surfaces.
        let response = try await VeyraWallet.shared.tokenisation.deactivateToken(ref)
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
      switch try VeyraWallet.shared.tokenisation.inspectScannedQr(payload) {
      case .verified(let payment):
        let handle = UUID().uuidString
        mpmContexts[handle] = payment
        resolve([
          "verified": true,
          "handle": handle,
          "merchantName": payment.merchantName,
          "merchantCity": payment.merchantCity as Any,
          "amountDisplay": payment.amount,
          "amountMinorUnits": payment.amountMinorUnits,
          "currencyNumeric": payment.currencyNumeric,
          "expiresAtEpochSeconds": payment.expiryEpochSeconds,
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
        let outcome = try await VeyraWallet.shared.tokenisation.payScannedContext(payment)
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
        let qr = try await VeyraWallet.shared.tokenisation.showQrToPay(
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
          "currencyNumeric": self.opt(qr.currencyNumeric),
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
    resolve(VeyraWallet.shared.tokenisation.cancelPayment(merchantOrderID: merchantOrderId).rawValue)
  }

  /// Cancels the digitise started with `clientRequestId`; resolves with the `CancelResult` name.
  /// `walletDigitise` still resolves with its own outcome.
  @objc(walletCancelDigitise:resolver:rejecter:)
  func walletCancelDigitise(_ clientRequestId: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraWallet.shared.tokenisation.cancelDigitise(clientRequestID: clientRequestId).rawValue)
  }

  @objc(walletCancelQrExpiry:rejecter:)
  func walletCancelQrExpiry(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    VeyraWallet.shared.tokenisation.cancelQrExpiry()
    resolve(nil)
  }

  // ── Wallet: history & receipts ──────────────────────────────────────────────

  private func summaryDict(_ s: TransactionSummary) -> [String: Any] {
    [
      "merchantName": s.merchantName,
      "amountMinorUnits": s.amountInMinorUnit,
      "transactionCurrencyCode": s.transactionCurrencyCode as Any,
      "transactionHash": s.transactionHash as Any,
      "authorizationStatus": s.authorizationStatus as Any,
      // These two are declared in `types.ts` and mapped on Android, but were never mapped here —
      // an RN app on iOS read `undefined` for both and could not show why a payment ended as it
      // did. Keep this dictionary's key list matched against the TypeScript type, not against the
      // Swift struct alone.
      "responseCode": s.responseCode as Any,
      "responseStatusReason": s.responseStatusReason as Any,
      // Always null on iOS: the field carries the contactless date/time from the card exchange
      // (EMV tags 9A + 9F21), and there is no tap rail on iOS — QR rows use `atEpochMillis`.
      "localTransactionDateTime": NSNull(),
      "atEpochMillis": s.atEpochMillis as Any,
      "entryMethod": s.entryMethod as Any,
      "merchantLocation": s.merchantLocation as Any,
      "merchantTransactionReference": s.merchantTransactionReference as Any,
      "merchantId": s.merchantId as Any,
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
      "merchantId": r.merchantId as Any,
      "merchantAddress": r.merchantAddress as Any,
      "transactionType": r.transactionType,
      "transactionStatus": r.transactionStatus,
      "transactionTime": r.transactionTime,
      "totalAmountMinorUnits": r.totalAmount,
      "totalAmountFormatted": r.totalAmountFormatted,
      "currency": r.currency as Any,
      "maskedToken": r.maskedToken as Any,
      "merchantTransactionReference": r.merchantTransactionReference as Any,
      "cdcvmApprovedByWallet": r.cdcvmApprovedByWallet as Any,
      "transactionId": r.transactionId as Any,
      "transactionHash": r.transactionHash as Any,
    ]
  }

  @objc(walletGetTransactions:limit:resolver:rejecter:)
  func walletGetTransactions(_ ref: String, limit: Double, resolver resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let rows = try await VeyraWallet.shared.tokenisation.transactionHistory(
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
        let r = try await VeyraWallet.shared.tokenisation.reconcilePendingTransactions()
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
        let lookup = try await VeyraWallet.shared.tokenisation.refreshTransactionStatus(
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
        let lookup = try await VeyraWallet.shared.tokenisation.refreshCreditConfirmation(
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
        let scan = try await VeyraWallet.shared.tokenisation.processReceipt(
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
      do { resolve(try await VeyraWallet.shared.tokenisation.receipts(limit: Int(limit)).map(self.receiptDict)) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletGetReceiptForTransaction:resolver:rejecter:)
  func walletGetReceiptForTransaction(_ hash: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let receipt = try await VeyraWallet.shared.tokenisation.receipt(forTransactionHash: hash)
        resolve(receipt.map(self.receiptDict))
      } catch { self.reject(rejecter, error) }
    }
  }

  // ── Merchant: registration & profile ────────────────────────────────────────

  @objc(merchantRegister:resolver:rejecter:)
  func merchantRegister(_ registration: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
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
        let result = try await VeyraSoftPOS.shared.merchant.register(reg)
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

  @objc(merchantGetSettlementBanks:rejecter:)
  func merchantGetSettlementBanks(_ resolve: @escaping RCTPromiseResolveBlock,
                                  rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let list = try await VeyraSoftPOS.shared.merchant.banks()
        resolve([
          "banks": list.banks.map { ["slug": $0.slug, "name": $0.name, "institutionCode": $0.institutionCode] },
          "responseStatus": list.responseStatus,
          "responseStatusReason": self.opt(list.responseStatusReason),
          "message": self.opt(list.message),
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(merchantIsRegistered:rejecter:)
  func merchantIsRegistered(_ resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraSoftPOS.shared.merchant.isRegistered)
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
    ]
  }

  @objc(merchantGetStored:rejecter:)
  func merchantGetStored(_ resolve: @escaping RCTPromiseResolveBlock,
                         rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraSoftPOS.shared.merchant.stored.map(storedMerchantDict))
  }

  /// The stored merchant's ID, or nil when none is registered — which each caller answers as its
  /// own `NOT_SENT` / `MISSING_MANDATORY_CONFIG` outcome (nothing sent), as Android's SDK does.
  private var storedMerchantID: String? {
    VeyraSoftPOS.shared.merchant.stored?.merchantID.trimmingCharacters(in: .whitespaces).nilIfEmpty
  }

  private static let noMerchantMessage = "No merchant is registered on this device"

  @objc(merchantRefreshStatus:rejecter:)
  func merchantRefreshStatus(_ resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard let merchantID = storedMerchantID else {
      return resolve(merchantStatusRefused(Self.missingMandatoryConfig, Self.noMerchantMessage))
    }
    Task {
      do { resolve(self.merchantStatusDict(try await VeyraSoftPOS.shared.merchant.status(merchantID: merchantID))) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(merchantActivate:rejecter:)
  func merchantActivate(_ resolve: @escaping RCTPromiseResolveBlock,
                        rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard let merchantID = storedMerchantID else {
      return resolve(merchantStatusRefused(Self.missingMandatoryConfig, Self.noMerchantMessage))
    }
    Task {
      do { resolve(self.merchantStatusDict(try await VeyraSoftPOS.shared.merchant.activate(merchantID: merchantID))) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(merchantDeactivate:rejecter:)
  func merchantDeactivate(_ resolve: @escaping RCTPromiseResolveBlock,
                          rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard let merchantID = storedMerchantID else {
      return resolve(merchantStatusRefused(Self.missingMandatoryConfig, Self.noMerchantMessage))
    }
    Task {
      do { resolve(self.merchantStatusDict(try await VeyraSoftPOS.shared.merchant.deactivate(merchantID: merchantID))) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(merchantUpdate:resolver:rejecter:)
  func merchantUpdate(_ update: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard let merchantID = storedMerchantID else {
      return resolve(merchantStatusRefused(Self.missingMandatoryConfig, Self.noMerchantMessage))
    }
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
      do { resolve(self.merchantStatusDict(try await VeyraSoftPOS.shared.merchant.update(merchantID: merchantID, merchantUpdate))) }
      catch { self.reject(rejecter, error) }
    }
  }

  // ── Merchant: tap acceptance ────────────────────────────────────────────────

  @objc(merchantTapStart:resolver:rejecter:)
  func merchantTapStart(_ request: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                        rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard requireSession("getPaid", rejecter) else { return }
    let sessionId = UUID().uuidString
    guard let amount = request["amountMinorUnits"] as? Double else {
      // A bad argument ends the tap the way the SDK ends a blank order id: a NOT_SENT result on
      // the event stream, with nothing armed (the Android module does the same).
      resolve(["sessionId": sessionId])
      sendEvent(withName: EventName.merchantTap, body: [
        "sessionId": sessionId,
        "type": "result",
        "result": tapResultNotSent("amountMinorUnits is required"),
      ])
      return
    }
    let currencyCode = Int32((request["currency"] as? String).flatMap(Int.init) ?? 566)
    // Required. Missing from untyped JS → blank → start() refuses it with INVALID_REQUEST.
    let merchantOrderID = (request["merchantOrderId"] as? String) ?? ""

    let session = VeyraSoftPOS.shared.tap.session(
      amountMinorUnits: Int64(amount),
      currencyCode: currencyCode,
      merchantOrderID: merchantOrderID
    ) { [weak self] event in
      guard let self else { return }
      var body: [String: Any] = ["sessionId": sessionId]
      switch event {
      case .cardDetected:
        body["type"] = "cardDetected"
      case .unsupportedTarget:
        body["type"] = "unsupportedCard"
      case .cardContactLost:
        body["type"] = "cardContactLost"
      case .cardReadingComplete:
        body["type"] = "readingComplete"
      case .sendingRequestOnline:
        body["type"] = "sendingOnline"
      case .receivingOnlineResponse:
        body["type"] = "receivingOnline"
      case .ended(let outcome):
        body["type"] = "ended"
        body["outcome"] = outcome.rawValue
        self.tapSessions.removeValue(forKey: sessionId)
      case .result(let result):
        body["type"] = "result"
        // The outcome as the SDK stated it — a refusal before sending (blank order id, the
        // other mode's payment in flight, cancelled) is NOT_SENT with its reason and no code.
        let status = result.responseStatus ?? result.status
        body["result"] = [
          "responseCode": self.opt(result.responseCode),
          "responseStatus": status,
          "responseStatusReason": self.opt(result.responseStatusReason),
          // Deprecated alias of responseStatus, kept for one release.
          "status": status,
          "message": result.errorMessage as Any,
          "amountDisplay": NSNull(),
          "cardScheme": NSNull(),
          "maskedTokenLast4": result.pan.map { String($0.suffix(4)) } as Any,
          "merchantTransactionReference": result.reference as Any,
          "transactionId": NSNull(),
          "merchantStatus": NSNull(),
          // The settlement response's credit facts, so an iOS tap sale can show the same
          // "confirming credit…" wait its CPM/MPM siblings do; the answer then arrives on the
          // credit-confirmation event (and on the stored row).
          "creditTransactionId": result.creditTransactionID.map { $0 as Any } ?? NSNull(),
          "isCreditConfirmationSupported": result.isCreditConfirmationSupported.map { $0 as Any } ?? NSNull(),
          "originalPayment": self.originalPaymentDict(result.originalPayment),
        ]
        self.tapSessions.removeValue(forKey: sessionId)
      @unknown default:
        return
      }
      self.sendEvent(withName: EventName.merchantTap, body: body)
    }

    do {
      tapSessions[sessionId] = (session, merchantOrderID)
      try session.start()
      resolve(["sessionId": sessionId])
    } catch {
      tapSessions.removeValue(forKey: sessionId)
      self.reject(rejecter, error)
    }
  }

  /// Cancels the SoftPOS payment started with `merchantOrderId` — tap, customer-QR charge or
  /// payment-QR create alike. Resolves with the `CancelResult` name; the payment itself still
  /// ends with its own outcome (a tap's on its `result` event). Needs no session.
  @objc(merchantCancelPayment:resolver:rejecter:)
  func merchantCancelPayment(_ merchantOrderId: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraSoftPOS.shared.payments.cancelPayment(merchantOrderID: merchantOrderId).rawValue)
  }

  // ── Merchant: get-paid QR (MPM) ─────────────────────────────────────────────

  @objc(merchantCreatePaymentContext:currency:merchantOrderId:resolver:rejecter:)
  func merchantCreatePaymentContext(_ amountMinorUnits: Double, currency: String,
                                    merchantOrderId: String?,
                                    resolver resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard let merchantID = storedMerchantID else {
      return resolve(paymentContextQrNotSent(Self.missingMandatoryConfig, Self.noMerchantMessage))
    }
    Task {
      do {
        let context = try await VeyraSoftPOS.shared.payments.createContext(
          merchantID: merchantID,
          amountMinorUnits: Int64(amountMinorUnits),
          currency: currency,
          onExpired: { [weak self] in
            self?.sendEvent(withName: EventName.qrExpired, body: ["scope": "merchant", "handle": NSNull()])
          },
          merchantOrderID: merchantOrderId ?? ""
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

  @objc(merchantCancelQrExpiry:rejecter:)
  func merchantCancelQrExpiry(_ resolve: @escaping RCTPromiseResolveBlock,
                              rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    VeyraSoftPOS.shared.payments.cancelQrExpiry()
    resolve(nil)
  }

  @objc(merchantContextStatus:resolver:rejecter:)
  func merchantContextStatus(_ txRef: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        // A poll's own failure is never the payment's state: a lookup, with the reason.
        let lookup = try await VeyraSoftPOS.shared.payments.contextStatus(txRef: txRef)
        let value: [String: Any]? = lookup.value.map { state in
          [
            "txRef": state.txRef,
            "state": state.state,
            "responseCode": state.responseCode as Any,
            "transactionHash": NSNull(),
            "isSettled": state.isSettled,
            "isApproved": state.isApproved,
          ]
        }
        resolve(self.lookupDict(value, failureReason: lookup.failureReason, message: lookup.message))
      } catch { self.reject(rejecter, error) }
    }
  }

  // ── Merchant: charge a customer QR (CPM) ────────────────────────────────────

  @objc(merchantInspectCustomerQr:resolver:rejecter:)
  func merchantInspectCustomerQr(_ payload: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                 rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let inspection = try await VeyraSoftPOS.shared.payments.inspectCustomerQr(payload)
        // A handle is issued only for a QR that can be charged; the card data stays native.
        var qr: [String: Any]?
        if let scanned = inspection.qr {
          let handle = UUID().uuidString
          self.cpmQrs[handle] = scanned
          qr = [
            "handle": handle,
            // Same display form as the Android module: bullets + the last four.
            "maskedCard": "•••• " + scanned.maskedCard,
            "amountMinorUnits": scanned.amountMinorUnits,
            "currencyNumeric": scanned.currencyNumeric,
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

  @objc(merchantChargeCustomerQr:merchantOrderId:resolver:rejecter:)
  func merchantChargeCustomerQr(_ handle: String, merchantOrderId: String?,
                                resolver resolve: @escaping RCTPromiseResolveBlock,
                                rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard let scanned = cpmQrs.removeValue(forKey: handle) else {
      return resolve(customerQrChargeNotSent("Unknown or already-used QR handle — re-scan"))
    }
    Task {
      do {
        let outcome = try await VeyraSoftPOS.shared.payments
          .chargeCustomerQr(scanned, merchantOrderID: merchantOrderId ?? "")
        resolve([
          // `approved` is the facade's reading of the status, never of the code.
          "approved": outcome.approved,
          "responseCode": outcome.responseCode as Any,
          "responseStatus": outcome.responseStatus as Any,
          "responseStatusReason": outcome.responseStatusReason as Any,
          "message": NSNull(),
          "transactionId": outcome.transactionID as Any,
          "merchantTransactionReference": outcome.reference,
          // The app's own order id, echoed as it was passed (the iOS outcome carries no echo).
          "merchantOrderId": self.opt(merchantOrderId),
          // An approved answer carries the merchant-bank credit id + supported flag — the
          // result screen's cue to wait for confirmation (on iOS the app polls the manual
          // fetch itself; there is no background poller).
          "creditTransactionId": outcome.creditTransactionID as Any,
          "isCreditConfirmationSupported": outcome.isCreditConfirmationSupported as Any,
          "originalPayment": self.originalPaymentDict(outcome.originalPayment),
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  // ── Merchant: transactions & receipts ───────────────────────────────────────

  private func merchantTransactionDict(_ t: MerchantTransaction) -> [String: Any] {
    [
      "merchantTransactionReference": t.reference,
      // the app's own order id, from the stored row — the detail and history screens
      // need it, not just the screen that took the payment.
      "merchantOrderId": t.merchantOrderID as Any? ?? NSNull(),
      "amountMinorUnits": t.amountMinorUnits,
      "status": t.status,
      "responseCode": t.responseCode as Any,
      "transactionTime": t.transactionTime as Any,
      "currencyCode": t.currencyNumeric as Any,
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

  @objc(merchantGetTransactions:resolver:rejecter:)
  func merchantGetTransactions(_ limit: Double, resolver resolve: @escaping RCTPromiseResolveBlock,
                               rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let rows = try await VeyraSoftPOS.shared.transactions.history(limit: Int(limit))
        resolve(rows.map(self.merchantTransactionDict))
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(merchantGetTransaction:resolver:rejecter:)
  func merchantGetTransaction(_ reference: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                              rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let rows = try await VeyraSoftPOS.shared.transactions.history(limit: 500)
        resolve(rows.first { $0.reference == reference }.map(self.merchantTransactionDict))
      } catch { self.reject(rejecter, error) }
    }
  }

  /// The on-demand "check status now" for one merchant transaction. Unlike
  /// `merchantGetTransaction` above — a local read over `history` — this goes to the gateway; a
  /// check that could not be made resolves with its `failureReason` (`NO_NETWORK_CONNECTION`).
  /// Lookup by the app's own order id — a read: resolves a `VeyraLookup<OrderPaymentStatus>`.
  @objc(merchantPaymentStatus:resolver:rejecter:)
  func merchantPaymentStatus(_ merchantOrderId: String,
                             resolver resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    Task {
      do {
        let lookup = try await VeyraSoftPOS.shared.transactions.paymentStatus(merchantOrderID: merchantOrderId)
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
      "merchantTransactionReference": opt(o.reference),
      "transactionId": opt(o.transactionID),
      "amountMinorUnits": o.amountMinorUnits.map { $0 as Any } ?? NSNull(),
      "answeredBy": o.answeredBy,
      "attempts": o.attempts.map { a -> [String: Any] in
        [
          "merchantTransactionReference": opt(a.reference),
          "transactionId": opt(a.transactionID),
          "amountMinorUnits": a.amountMinorUnits.map { $0 as Any } ?? NSNull(),
          "responseCode": opt(a.responseCode),
          "responseStatus": opt(a.responseStatus),
          "responseStatusReason": opt(a.responseStatusReason),
        ]
      },
    ]
  }

  @objc(merchantRefreshTransactionStatus:resolver:rejecter:)
  func merchantRefreshTransactionStatus(_ reference: String,
                                        resolver resolve: @escaping RCTPromiseResolveBlock,
                                        rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let lookup = try await VeyraSoftPOS.shared.transactions.refreshStatus(reference: reference)
        resolve(self.lookupDict(lookup.value.map(self.merchantTransactionDict),
                                failureReason: lookup.failureReason, message: lookup.message))
      } catch { self.reject(rejecter, error) }
    }
  }

  /// "Check merchant credit now" for one sale. Unlike `merchantGetTransaction` — a local
  /// read — this goes to the gateway; a check that could not be made resolves with its
  /// `failureReason` (`NO_NETWORK_CONNECTION`). An ineligible row makes no call and resolves unchanged.
  @objc(merchantRefreshCreditConfirmation:resolver:rejecter:)
  func merchantRefreshCreditConfirmation(_ reference: String,
                                         resolver resolve: @escaping RCTPromiseResolveBlock,
                                         rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let lookup = try await VeyraSoftPOS.shared.transactions.refreshCreditConfirmation(
          reference: reference
        )
        resolve(self.lookupDict(lookup.value.map(self.merchantTransactionDict),
                                failureReason: lookup.failureReason, message: lookup.message))
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(merchantGetReceipt:resolver:rejecter:)
  func merchantGetReceipt(_ reference: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                          rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let receipt = try await VeyraSoftPOS.shared.transactions.receipt(forReference: reference)
        resolve(receipt.map { r in
          [
            "merchantName": r.merchantName,
            "merchantAddress": r.merchantAddress,
            "transactionType": r.transactionType,
            "totalAmountMinorUnits": r.totalAmountMinorUnits,
            "totalAmountFormatted": r.totalAmountFormatted,
            "maskedToken": r.maskedToken,
            "merchantTransactionReference": r.reference,
            "transactionHash": r.transactionHash as Any,
            "cardholderName": r.cardholderName as Any,
            "qrCodeBase64": NSNull(),
            "qrPayload": r.qrPayload,
          ] as [String: Any]
        })
      } catch { self.reject(rejecter, error) }
    }
  }
}

private extension String {
  /// nil for an empty string.
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
