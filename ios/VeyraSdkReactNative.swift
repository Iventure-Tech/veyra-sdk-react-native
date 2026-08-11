import Foundation
import React

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
 * which experience is open and gates the tap APIs (SESSION_REQUIRED), keeping the JS
 * integration identical on both platforms. It never calls a mode verb.
 */
@objc(VeyraSdkReactNative)
class VeyraSdkReactNative: RCTEventEmitter {

  private enum EventName {
    static let activation = "VeyraActivationEvent"
    static let walletTap = "VeyraWalletTapEvent"
    static let merchantTap = "VeyraMerchantTapEvent"
    static let qrExpired = "VeyraQrExpiredEvent"
    /// A payment the app was left waiting on has resolved. Same name and payload as Android's.
    static let transactionResolved = "VeyraTransactionResolvedEvent"
    /// An approved sale's funds were confirmed in the merchant's bank account (or the 30-day
    /// window closed unconfirmed). Same name and payload as Android's.
    static let creditConfirmation = "VeyraCreditConfirmationEvent"
  }

  private var initialized = false
  private var openSessionKind: String?
  private var tapSessions: [String: TapPaymentSession] = [:]
  private var mpmContexts: [String: VerifiedPayment] = [:]
  private var cpmQrs: [String: ScannedCustomerQr] = [:]

  override static func requiresMainQueueSetup() -> Bool { false }

  override func supportedEvents() -> [String] {
    [
      EventName.activation,
      EventName.walletTap,
      EventName.merchantTap,
      EventName.qrExpired,
      EventName.transactionResolved,
      EventName.creditConfirmation,
    ]
  }

  // ── Error normalisation ─────────────────────────────────────────────────────

  private func reject(_ rejecter: RCTPromiseRejectBlock, _ error: Error) {
    let (code, message) = classify(error)
    rejecter(code, message, error)
  }

  private func classify(_ error: Error) -> (String, String) {
    switch error {
    case VeyraWalletError.notConfigured, VeyraSoftPOSError.notConfigured, VeyraSDKError.notConfigured:
      return ("NOT_CONFIGURED", "Call Veyra.initialize first")
    // both SDKs report the same condition under the same code, so JS branches on one
    // value whichever half of the SDK the call came from.
    case let VeyraWalletError.noNetworkConnection(message):
      return ("NO_NETWORK_CONNECTION", message)
    case let VeyraSoftPOSError.noNetworkConnection(message):
      return ("NO_NETWORK_CONNECTION", message)
    case let VeyraWalletError.onlineRequired(message):
      return ("ONLINE_REQUIRED", message)
    case let VeyraWalletError.amountExceedsCardLimit(message):
      return ("AMOUNT_EXCEEDS_CARD_LIMIT", message)
    case let VeyraWalletError.tokenNotActive(message):
      return ("TOKEN_NOT_ACTIVE", message)
    case let VeyraWalletError.authenticationFailed(message):
      return (message.lowercased().contains("cancel") ? "AUTH_CANCELLED" : "AUTH_FAILED", message)
    case let VeyraWalletError.requestFailed(message):
      if message.hasPrefix("No active card") { return ("NO_ACTIVE_CARD", message) }
      if message.contains("can't show a payment QR") { return ("CARD_CANNOT_SHOW_QR", message) }
      return ("REQUEST_FAILED", message)
    case let VeyraSoftPOSError.tapRefused(message):
      return ("MODE_REFUSED", message)
    case let VeyraSoftPOSError.requestFailed(message):
      return ("REQUEST_FAILED", message)
    default:
      return ("UNKNOWN", error.localizedDescription)
    }
  }

  private func rejectNotInitialized(_ rejecter: RCTPromiseRejectBlock) {
    rejecter("NOT_CONFIGURED", "Call Veyra.initialize first", nil)
  }

  private func rejectValidation(_ rejecter: RCTPromiseRejectBlock, _ message: String) {
    rejecter("VALIDATION", message, nil)
  }

  // ── Init & mode ─────────────────────────────────────────────────────────────

  @objc(initialize:resolver:rejecter:)
  func initialize(_ config: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                  rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard let softposMap = config["softpos"] as? NSDictionary,
          let walletMap = config["wallet"] as? NSDictionary
    else { return rejectValidation(reject, "softpos and wallet configs are required") }
    guard let softposEnv = VeyraSoftPOSConfiguration.Environment(rawValue: softposMap["environment"] as? String ?? ""),
          let walletEnv = VeyraWalletConfiguration.Environment(rawValue: walletMap["environment"] as? String ?? "")
    else { return rejectValidation(reject, "environment must be TEST or LIVE") }
    guard let appleTeamID = walletMap["appleTeamId"] as? String, !appleTeamID.isEmpty
    else { return rejectValidation(reject, "wallet.appleTeamId is required on iOS") }

    let softpos = VeyraSoftPOSConfiguration(
      environment: softposEnv,
      clientID: softposMap["clientId"] as? String,
      clientSecret: softposMap["clientSecret"] as? String
    )
    let wallet = VeyraWalletConfiguration(
      environment: walletEnv,
      clientID: walletMap["clientId"] as? String,
      clientSecret: walletMap["clientSecret"] as? String,
      paymentAppProviderID: walletMap["paymentAppProviderId"] as? String,
      tokenRequestorID: walletMap["tokenRequestorId"] as? String,
      appVersion: walletMap["appVersion"] as? String ?? "1.0.0",
      appleTeamID: appleTeamID,
      allowedAcquirerIDs: walletMap["allowedAcquirerIds"] as? [String] ?? [],
      allowedMerchantIDs: walletMap["allowedMerchantIds"] as? [String] ?? [],
      allowedCountryCodes: walletMap["allowedCountryCodes"] as? [String] ?? [],
      allowedMCCs: walletMap["allowedMccs"] as? [String] ?? []
    )

    VeyraSDK.configure(softpos: softpos, wallet: wallet)
    initialized = true
    observeDeferredAnswers()
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
  }

  @objc(currentMode:rejecter:)
  func currentMode(_ resolve: @escaping RCTPromiseResolveBlock,
                   rejecter reject: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(reject) }
    resolve(VeyraSDK.shared.currentMode.rawValue)
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
        // Leaving the get-paid screen cancels any armed (untapped) session.
        tapSessions.values.forEach { $0.cancel() }
        tapSessions.removeAll()
      }
    }
    resolve(nil)
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
        let banks = try await VeyraWallet.shared.tokenisation.banks(accountNumber: accountNumber)
        resolve(banks.map { ["slug": $0.slug, "name": $0.name, "institutionCode": $0.institutionCode] })
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletVerifyAccount:resolver:rejecter:)
  func walletVerifyAccount(_ params: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                           rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard let accountNumber = params["accountNumber"] as? String,
          let institutionCode = params["institutionCode"] as? String,
          let walletAccountID = params["walletAccountId"] as? String
    else { return rejectValidation(rejecter, "accountNumber, institutionCode and walletAccountId are required") }
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
    else { return rejectValidation(rejecter, "required digitise fields missing") }
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
          bankName: params["bankName"] as? String
        )
        resolve([
          "responseCode": result.responseCode as Any,
          "tokenUniqueReference": result.tokenUniqueReference as Any,
          "activationMethods": result.activationMethods.map {
            ["medium": $0.medium, "contact": $0.contact as Any]
          },
          "message": result.message as Any,
          "isApproved": result.isApproved,
          "requiresActivation": result.requiresActivation,
          "tokenStored": result.tokenStored,
          "error": NSNull(),
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
      return rejectValidation(
        rejecter,
        "On iOS the activation medium must be MASKED_EMAIL or MASKED_MOBILE_PHONE"
      )
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
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletCheckTokenActive:resolver:rejecter:)
  func walletCheckTokenActive(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                              rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let status = try await VeyraWallet.shared.tokenisation.tokenStatus(tokenUniqueReference: ref)
        resolve(status == "ACTIVE")
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletTokenStatus:resolver:rejecter:)
  func walletTokenStatus(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                         rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        // Verbatim server status — JS carries values it does not know unchanged.
        let status = try await VeyraWallet.shared.tokenisation.tokenStatus(tokenUniqueReference: ref)
        resolve(status as Any)
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
    // iOS has no tap-to-pay: selecting the active card arms nothing, so no session gate.
    Task {
      do {
        try await VeyraWallet.shared.tokenisation.setActiveToken(cardId)
        // Android registers its refusal callbacks as part of setActiveToken, so JS gets the same
        // `walletTap` phases from the same call on both platforms. iOS emits them from the QR
        // rails only — there is no tap rail here — so `rail` is never "TAP".
        self.observeWalletPaymentRefusals()
        resolve(nil)
      }
      catch { self.reject(rejecter, error) }
    }
  }

  /// Bridge payment refusals to the same `walletTap` phases the Android module emits.
  /// Re-observing replaces the previous observer, so repeated `setActiveCard` calls do not stack.
  private func observeWalletPaymentRefusals() {
    try? VeyraWallet.shared.tokenisation.observePaymentRefusals(
      onRequireOnline: { [weak self] tokenUniqueReference, amountMinorUnits, rail in
        self?.sendEvent(withName: EventName.walletTap, body: [
          "type": "requireOnline",
          "tokenId": NSNull(),
          "tokenUniqueReference": tokenUniqueReference ?? NSNull(),
          "amountMinorUnits": amountMinorUnits,
          "rail": rail,
          "message": "ONLINE_REQUIRED: Connect to the internet — the wallet needs to refresh this card before it can pay",
        ])
      },
      onAmountExceedsCardLimit: { [weak self] tokenUniqueReference, amountMinorUnits, cardLimitMinorUnits, rail in
        self?.sendEvent(withName: EventName.walletTap, body: [
          "type": "amountExceedCardLimit",
          "tokenId": NSNull(),
          "tokenUniqueReference": tokenUniqueReference ?? NSNull(),
          "amountMinorUnits": amountMinorUnits,
          "cardLimitMinorUnits": cardLimitMinorUnits ?? NSNull(),
          "rail": rail,
          "message": "AMOUNT_EXCEEDS_CARD_LIMIT: This amount is too large for this card — try a smaller amount, or another card",
        ])
      }
    )
  }

  @objc(walletDeactivateCard:resolver:rejecter:)
  func walletDeactivateCard(_ ref: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do { _ = try await VeyraWallet.shared.tokenisation.deactivate(ref); resolve(nil) }
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
        ])
      case .rejected(let reason, let detail):
        resolve(["verified": false, "reason": reason.rawValue, "detail": detail as Any])
      }
    } catch { self.reject(rejecter, error) }
  }

  @objc(walletAuthenticateForPayment:subtitle:allowDeviceCredential:resolver:rejecter:)
  func walletAuthenticateForPayment(_ title: String, subtitle: String?, allowDeviceCredential: Bool,
                                    resolver resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        try await VeyraWallet.shared.tokenisation.authenticateForScannedPayment(
          reason: title, allowDeviceCredential: allowDeviceCredential
        )
        resolve(nil)
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletPayScannedContext:resolver:rejecter:)
  func walletPayScannedContext(_ handle: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                               rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard let payment = mpmContexts.removeValue(forKey: handle) else {
      return rejectValidation(rejecter, "Unknown or already-used payment handle — re-inspect the QR")
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
        resolve([
          "tokenUniqueReference": qr.tokenUniqueReference,
          "payload": qr.payload,
          "amountMinorUnits": qr.amountMinorUnits,
          "currencyNumeric": qr.currencyNumeric,
          "expiresAtEpochMillis": qr.expiresAtEpochMillis,
          "transactionHash": qr.transactionHash,
        ])
      } catch { self.reject(rejecter, error) }
    }
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
      do { try await VeyraWallet.shared.tokenisation.reconcilePendingTransactions(); resolve(nil) }
      catch { self.reject(rejecter, error) }
    }
  }

  /// The per-transaction counterpart to the reconcile above — one row, keyed by hash,
  /// resolving with the updated stored row rather than nothing. A transport failure rejects with the
  /// typed code (`NO_NETWORK_CONNECTION` when offline) and leaves the row untouched.
  @objc(walletRefreshTransactionStatus:resolver:rejecter:)
  func walletRefreshTransactionStatus(_ transactionHash: String,
                                      resolver resolve: @escaping RCTPromiseResolveBlock,
                                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let row = try await VeyraWallet.shared.tokenisation.refreshTransactionStatus(
          transactionHash: transactionHash
        )
        resolve(row.map(self.summaryDict))
      } catch { self.reject(rejecter, error) }
    }
  }

  /// "Check merchant credit now" for one wallet payment. Settlement only — it can never
  /// change the row's outcome triple. A transport failure rejects with the typed code
  /// (`NO_NETWORK_CONNECTION` when offline) and leaves the row untouched; an ineligible row makes no
  /// call at all and resolves unchanged.
  @objc(walletRefreshCreditConfirmation:resolver:rejecter:)
  func walletRefreshCreditConfirmation(_ transactionHash: String,
                                       resolver resolve: @escaping RCTPromiseResolveBlock,
                                       rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let row = try await VeyraWallet.shared.tokenisation.refreshCreditConfirmation(
          transactionHash: transactionHash
        )
        resolve(row.map(self.summaryDict))
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(walletProcessReceipt:expectedHash:resolver:rejecter:)
  func walletProcessReceipt(_ payload: String, expectedHash: String?,
                            resolver resolve: @escaping RCTPromiseResolveBlock,
                            rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let receipt = try await VeyraWallet.shared.tokenisation.processReceipt(
          payload, expectedTransactionHash: expectedHash
        )
        resolve(self.receiptDict(receipt))
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
          let merchantType = MerchantRegistration.MerchantType(rawValue: typeRaw),
          let merchantName = registration["merchantName"] as? String,
          let emailAddress = registration["emailAddress"] as? String,
          let phoneNumber = registration["phoneNumber"] as? String,
          let addressLine1 = registration["addressLine1"] as? String,
          let city = registration["city"] as? String,
          let state = registration["state"] as? String,
          let countryCode = registration["countryCode"] as? String,
          let accountNumber = registration["accountNumber"] as? String,
          let institutionCode = registration["institutionCode"] as? String,
          let acquirerID = registration["acquirerId"] as? String
    else { return rejectValidation(rejecter, "required merchant registration fields missing") }
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
      acquirerID: acquirerID
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
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(merchantGetSettlementBanks:rejecter:)
  func merchantGetSettlementBanks(_ resolve: @escaping RCTPromiseResolveBlock,
                                  rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let banks = try await VeyraSoftPOS.shared.merchant.banks()
        resolve(banks.map { ["slug": $0.slug, "name": $0.name, "institutionCode": $0.institutionCode] })
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
    ]
  }

  @objc(merchantGetStored:rejecter:)
  func merchantGetStored(_ resolve: @escaping RCTPromiseResolveBlock,
                         rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    resolve(VeyraSoftPOS.shared.merchant.stored.map(storedMerchantDict))
  }

  @objc(merchantClearStored:rejecter:)
  func merchantClearStored(_ resolve: @escaping RCTPromiseResolveBlock,
                           rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    VeyraSoftPOS.shared.merchant.clearStored()
    resolve(nil)
  }

  private func requireMerchantID(_ rejecter: RCTPromiseRejectBlock) -> String? {
    guard let merchantID = VeyraSoftPOS.shared.merchant.stored?.merchantID else {
      rejectValidation(rejecter, "No registered merchant — register first")
      return nil
    }
    return merchantID
  }

  @objc(merchantRefreshStatus:rejecter:)
  func merchantRefreshStatus(_ resolve: @escaping RCTPromiseResolveBlock,
                             rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard let merchantID = requireMerchantID(rejecter) else { return }
    Task {
      do { resolve(try await VeyraSoftPOS.shared.merchant.status(merchantID: merchantID).status) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(merchantActivate:rejecter:)
  func merchantActivate(_ resolve: @escaping RCTPromiseResolveBlock,
                        rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard let merchantID = requireMerchantID(rejecter) else { return }
    Task {
      do { resolve(try await VeyraSoftPOS.shared.merchant.activate(merchantID: merchantID).status) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(merchantDeactivate:rejecter:)
  func merchantDeactivate(_ resolve: @escaping RCTPromiseResolveBlock,
                          rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard let merchantID = requireMerchantID(rejecter) else { return }
    Task {
      do { resolve(try await VeyraSoftPOS.shared.merchant.deactivate(merchantID: merchantID).status) }
      catch { self.reject(rejecter, error) }
    }
  }

  @objc(merchantUpdate:resolver:rejecter:)
  func merchantUpdate(_ update: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard let merchantID = requireMerchantID(rejecter) else { return }
    guard let merchantName = update["merchantName"] as? String,
          let emailAddress = update["emailAddress"] as? String,
          let phoneNumber = update["phoneNumber"] as? String,
          let addressLine1 = update["addressLine1"] as? String,
          let city = update["city"] as? String,
          let state = update["state"] as? String,
          let countryCode = update["countryCode"] as? String,
          let accountNumber = update["accountNumber"] as? String,
          let institutionCode = update["institutionCode"] as? String
    else { return rejectValidation(rejecter, "required merchant update fields missing") }
    let acquirerID = VeyraSoftPOS.shared.merchant.stored?.acquirerID ?? ""
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
      acquirerID: acquirerID
    )
    Task {
      do { resolve(try await VeyraSoftPOS.shared.merchant.update(merchantID: merchantID, merchantUpdate).status) }
      catch { self.reject(rejecter, error) }
    }
  }

  // ── Merchant: tap acceptance ────────────────────────────────────────────────

  @objc(merchantTapStart:resolver:rejecter:)
  func merchantTapStart(_ request: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock,
                        rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard requireSession("getPaid", rejecter) else { return }
    guard let amount = request["amountMinorUnits"] as? Double else {
      return rejectValidation(rejecter, "amountMinorUnits is required")
    }
    let currencyCode = Int32((request["currency"] as? String).flatMap(Int.init) ?? 566)
    let sessionId = UUID().uuidString

    let session = VeyraSoftPOS.shared.tap.session(
      amountMinorUnits: Int64(amount),
      currencyCode: currencyCode
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
        body["result"] = [
          "responseCode": NSNull(),
          "status": result.status,
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
        ]
        self.tapSessions.removeValue(forKey: sessionId)
      @unknown default:
        return
      }
      self.sendEvent(withName: EventName.merchantTap, body: body)
    }

    do {
      tapSessions[sessionId] = session
      try session.start()
      resolve(["sessionId": sessionId])
    } catch {
      tapSessions.removeValue(forKey: sessionId)
      self.reject(rejecter, error)
    }
  }

  @objc(merchantTapCancel:resolver:rejecter:)
  func merchantTapCancel(_ sessionId: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                         rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    tapSessions.removeValue(forKey: sessionId)?.cancel()
    resolve(nil)
  }

  // ── Merchant: get-paid QR (MPM) ─────────────────────────────────────────────

  @objc(merchantCreatePaymentContext:currency:merchantOrderId:resolver:rejecter:)
  func merchantCreatePaymentContext(_ amountMinorUnits: Double, currency: String,
                                    merchantOrderId: String?,
                                    resolver resolve: @escaping RCTPromiseResolveBlock,
                                    rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard initialized else { return rejectNotInitialized(rejecter) }
    guard let merchantID = requireMerchantID(rejecter) else { return }
    Task {
      do {
        let context = try await VeyraSoftPOS.shared.payments.createContext(
          merchantID: merchantID,
          amountMinorUnits: Int64(amountMinorUnits),
          currency: currency,
          onExpired: { [weak self] in
            self?.sendEvent(withName: EventName.qrExpired, body: ["scope": "merchant", "handle": NSNull()])
          },
          merchantOrderID: merchantOrderId
        )
        resolve(["txRef": context.txRef, "mpmPayload": context.mpmPayload, "expiry": context.expiry as Any])
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
        let state = try await VeyraSoftPOS.shared.payments.contextStatus(txRef: txRef)
        resolve([
          "txRef": state.txRef,
          "state": state.state,
          "responseCode": state.responseCode as Any,
          "transactionHash": NSNull(),
          "isSettled": state.isSettled,
          "isApproved": state.isApproved,
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  // ── Merchant: charge a customer QR (CPM) ────────────────────────────────────

  @objc(merchantInspectCustomerQr:resolver:rejecter:)
  func merchantInspectCustomerQr(_ payload: String, resolver resolve: @escaping RCTPromiseResolveBlock,
                                 rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let scanned = try await VeyraSoftPOS.shared.payments.inspectCustomerQr(payload)
        let handle = UUID().uuidString
        self.cpmQrs[handle] = scanned
        resolve([
          "handle": handle,
          "maskedCard": scanned.maskedCard,
          "amountMinorUnits": scanned.amountMinorUnits,
          "currencyNumeric": scanned.currencyNumeric,
          "cardholderName": scanned.cardholderName as Any,
        ])
      } catch { self.reject(rejecter, error) }
    }
  }

  @objc(merchantChargeCustomerQr:merchantOrderId:resolver:rejecter:)
  func merchantChargeCustomerQr(_ handle: String, merchantOrderId: String?,
                                resolver resolve: @escaping RCTPromiseResolveBlock,
                                rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    guard let scanned = cpmQrs.removeValue(forKey: handle) else {
      return rejectValidation(rejecter, "Unknown or already-used QR handle — re-scan")
    }
    Task {
      do {
        let outcome = try await VeyraSoftPOS.shared.payments
          .chargeCustomerQr(scanned, merchantOrderID: merchantOrderId)
        resolve([
          "approved": outcome.approved,
          "responseCode": outcome.responseCode as Any,
          "transactionId": outcome.transactionID as Any,
          "merchantTransactionReference": outcome.reference,
          // An approved answer carries the merchant-bank credit id + supported flag — the
          // result screen's cue to wait for confirmation (on iOS the app polls the manual
          // fetch itself; there is no background poller).
          "creditTransactionId": outcome.creditTransactionID as Any,
          "isCreditConfirmationSupported": outcome.isCreditConfirmationSupported as Any,
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
  /// `merchantGetTransaction` above — a local read over `history` — this goes to the gateway, so a
  /// transport failure is a real rejection carrying the typed code (`NO_NETWORK_CONNECTION`).
  @objc(merchantRefreshTransactionStatus:resolver:rejecter:)
  func merchantRefreshTransactionStatus(_ reference: String,
                                        resolver resolve: @escaping RCTPromiseResolveBlock,
                                        rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let row = try await VeyraSoftPOS.shared.transactions.refreshStatus(reference: reference)
        resolve(row.map(self.merchantTransactionDict))
      } catch { self.reject(rejecter, error) }
    }
  }

  /// "Check merchant credit now" for one sale. Unlike `merchantGetTransaction` — a local
  /// read — this goes to the gateway, so a transport failure is a real rejection carrying the typed
  /// code (`NO_NETWORK_CONNECTION`). An ineligible row makes no call and resolves unchanged.
  @objc(merchantRefreshCreditConfirmation:resolver:rejecter:)
  func merchantRefreshCreditConfirmation(_ reference: String,
                                         resolver resolve: @escaping RCTPromiseResolveBlock,
                                         rejecter rejecter: @escaping RCTPromiseRejectBlock) {
    Task {
      do {
        let row = try await VeyraSoftPOS.shared.transactions.refreshCreditConfirmation(
          reference: reference
        )
        resolve(row.map(self.merchantTransactionDict))
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
