/**
 * Veyra React Native SDK — public types.
 *
 * One promise-based surface over both native SDKs. Where the platforms diverge, fields
 * are marked platform-nullable and methods carry their availability in the doc comment;
 * calling an unsupported method rejects with code `UNSUPPORTED_ON_PLATFORM`.
 */

export type VeyraEnvironment = 'TEST' | 'LIVE';

/** The exclusive NFC mode of the app. Read-only — the SDK owns all transitions. */
export type VeyraMode = 'NONE' | 'SOFTPOS' | 'WALLET';

// ── Configuration ─────────────────────────────────────────────────────────────

export interface VeyraSoftposConfig {
  environment: VeyraEnvironment;
  clientId: string;
  clientSecret: string;
  /** Android only. Defaults to true. */
  enableNfc?: boolean;
}

export interface VeyraWalletConfig {
  environment: VeyraEnvironment;
  clientId: string;
  clientSecret: string;
  paymentAppProviderId: string;
  tokenRequestorId: string;
  /** ISO 3166-1 numeric (4-digit, zero-padded). Android: required (may be empty). */
  allowedCountryCodes?: string[];
  /** Android: required before digitising. iOS: fixed by the SDK. */
  recommendationStandardVersion?: string;
  appVersion?: string;
  /** iOS only: your Apple Developer Team ID. Required on iOS. */
  appleTeamId?: string;
  allowedAcquirerIds?: string[];
  allowedMerchantIds?: string[];
  allowedMccs?: string[];
  /** Android only. Defaults to true. */
  enableNfc?: boolean;
}

export interface VeyraConfig {
  softpos: VeyraSoftposConfig;
  wallet: VeyraWalletConfig;
}

// ── Wallet: add card / digitise ───────────────────────────────────────────────

export interface Bank {
  slug: string;
  name: string;
  institutionCode: string;
}

export type TokenizationRecommendation =
  | 'APPROVE'
  | 'DECLINE'
  | 'REQUIRE_ADDITIONAL_AUTHENTICATION';

export type TrustScore =
  | 'UNTRUSTED'
  | 'LOW_TRUST'
  | 'MODERATE_TRUST'
  | 'TRUSTED'
  | 'HIGHLY_TRUSTED';

export type AccountNumberSource =
  | 'CARD_ON_FILE'
  | 'MANUAL'
  | 'RECENT'
  | 'SCAN'
  | 'APPLICATION'
  | 'EXISTING_TOKEN'
  | 'OTHER';

export type TokenizationRecommendationReason =
  | 'LONG_ACCOUNT_TENURE'
  | 'GOOD_ACTIVITY_HISTORY'
  | 'CARDHOLDER_UNAVAILABLE'
  | 'AUTHENTICATION_NOT_SUPPORTED'
  | 'RECENT_CARDHOLDER_AUTHENTICATION'
  | 'RECENT_APPROVED_TOKEN'
  | 'DEVICE_AUTHENTICATION_VERIFIED'
  | 'ADDITIONAL_DEVICE'
  | 'SOFTWARE_UPDATE'
  | 'ACCOUNT_TOO_NEW_SINCE_LAUNCH'
  | 'ACCOUNT_TOO_NEW'
  | 'ACCOUNT_CARD_TOO_NEW'
  | 'ACCOUNT_RECENTLY_CHANGED'
  | 'SUSPICIOUS_ACTIVITY'
  | 'INACTIVE_ACCOUNT'
  | 'HAS_SUSPENDED_TOKENS'
  | 'DEVICE_RECENTLY_LOST'
  | 'TOO_MANY_RECENT_ATTEMPTS'
  | 'TOO_MANY_RECENT_TOKENS'
  | 'TOO_MANY_DIFFERENT_CARDHOLDERS'
  | 'LOW_DEVICE_SCORE'
  | 'LOW_ACCOUNT_SCORE'
  | 'OUTSIDE_HOME_TERRITORY'
  | 'UNABLE_TO_ASSESS'
  | 'HIGH_RISK_DIGITIZATION'
  | 'OTHER';

export interface VerifyAccountParams {
  accountNumber: string;
  institutionCode: string;
  walletAccountId: string;
  accountHolderName?: string;
  accountNumberSource?: AccountNumberSource;
}

export interface VerifyAccountResponse {
  responseCode: DigitiseResponseCode | null;
  message: string | null;
  isApproved: boolean;
}

export interface DigitiseParams {
  accountNumber: string;
  institutionCode: string;
  accountHolderName: string;
  walletAccountId: string;
  emailAddress: string;
  /** The wallet provider's own judgement — never defaulted by the SDK. */
  recommendation: TokenizationRecommendation;
  /** Required on Android; optional on iOS. */
  consumerIdentifier?: string;
  bvn?: string;
  accountHolderAddress?: string;
  mobileNumber?: string;
  clientRequestId?: string;
  accountNumberSource?: AccountNumberSource;
  deviceScore?: TrustScore;
  accountScore?: TrustScore;
  recommendationReasons?: TokenizationRecommendationReason[];
  /** iOS only: shown on the stored card. */
  bankName?: string;
}

export type DigitiseResponseCode = 'APPROVED' | 'APPROVE_REQUIRE_AUTH' | 'DECLINED';

export interface ActivationMethodInfo {
  medium: ActivationMedium;
  contact: string | null;
}

export type ActivationMedium =
  | 'MASKED_EMAIL'
  | 'MASKED_MOBILE_PHONE'
  | 'AUTOMATED_CALL_CENTER_PHONE'
  | 'CALL_CENTER_PHONE'
  | 'WEBSITE'
  | 'MOBILE_APPLICATION';

export interface DigitiseResult {
  responseCode: DigitiseResponseCode | null;
  tokenUniqueReference: string | null;
  activationMethods: ActivationMethodInfo[];
  message: string | null;
  isApproved: boolean;
  requiresActivation: boolean;
  /** iOS only. */
  tokenStored: boolean | null;
  /** Android only: { code: 'CONFIG_ERROR' | 'TOKENIZATION_ERROR' | 'UNEXPECTED_ERROR', … }. */
  error: { code: string; message: string | null; details: string | null } | null;
}

// ── Wallet: activation ────────────────────────────────────────────────────────

export type ActivationReason = 'ADD_CARD' | 'VERIFY_ACCOUNT' | 'OTHER';

export interface ActivationCodeResponse {
  tokenUniqueReference: string | null;
  expirationDateTime: string | null;
  status: 'SUCCESS' | 'FAILURE' | null;
  message: string | null;
}

export interface ActivateResponse {
  tokenUniqueReference: string | null;
  status: 'SUCCESS' | 'FAILURE' | null;
  message: string | null;
}

export type ActivationEvent =
  | { tokenUniqueReference: string; event: 'activated' }
  | { tokenUniqueReference: string; event: 'timeout' }
  | { tokenUniqueReference: string; event: 'error'; message: string };

// ── Wallet: cards ─────────────────────────────────────────────────────────────

export type CardStatus =
  | 'ACTIVE'
  | 'SUSPENDED'
  | 'EXPIRED'
  | 'PENDING_ACTIVATION'
  | 'DEACTIVATED';

export type CardScheme =
  | 'IVENTUREPAY'
  | 'VISA'
  | 'MASTERCARD'
  | 'AMEX'
  | 'DISCOVER'
  | 'UNKNOWN';

/**
 * A stored card. Union-superset of the two platforms' card DTOs: `tokenId` is the
 * Android identity, `tokenUniqueReference` the cross-platform one — pass `id` (always
 * populated) back into card APIs and the SDK resolves it per platform.
 */
export interface Card {
  /** Stable identifier to pass back into card APIs (platform-appropriate). */
  id: string;
  tokenUniqueReference: string | null;
  /** Android only. */
  tokenId: string | null;
  maskedPan: string;
  panLastFour: string;
  /**
   * The card's display name — the scheme's application label and the masked last four of the
   * device PAN, e.g. `AFRIGO ****1234`. Not a person's name: a token is not a named credential,
   * so this carries no personal data. It is also what the card presents to a terminal in EMV tag
   * `5F20`. Empty on cards digitised before it existed.
   */
  cardHolderName: string | null;
  expiry: string | null;
  /** iOS only. */
  bankName: string | null;
  /** Android only. */
  cardScheme: CardScheme | null;
  status: CardStatus | string | null;
  isActive: boolean;
  /** Card must be activated (OTP) before first use. */
  requiresActivation: boolean;
  activationMethods: ActivationMethodInfo[] | null;
  /**
   * True when the card temporarily cannot pay and needs the device online — grey it
   * out and disable pay affordances; the SDK self-heals, there is nothing to call.
   */
  requiresOnline: boolean;
}

// ── Wallet: payments ──────────────────────────────────────────────────────────

/** Android only (tap-to-pay is not available on iOS). */
export type WalletTapEvent =
  | { type: 'transactionStarted'; tokenId: string }
  | {
      type: 'transactionCompleted';
      status: 'APPROVED' | 'DECLINED' | 'ERROR';
      message: string | null;
      amountMinorUnits: number | null;
      tokenId: string | null;
      cardScheme: CardScheme | null;
      reference: string | null;
    }
  | { type: 'activationFailed'; message: string };

export type ScanRejectionReason =
  | 'MALFORMED'
  | 'MISSING_SIGNATURE'
  | 'UNKNOWN_KEY'
  | 'BAD_SIGNATURE'
  | 'EXPIRED';

/**
 * Result of inspecting a scanned merchant QR. When verified, `handle` is an opaque
 * reference to the natively-held payment context — it never round-trips the signed
 * payload through JS. Pass it to `payScannedContext` within the same app session.
 */
export type ScanInspection =
  | {
      verified: true;
      handle: string;
      merchantName: string;
      merchantCity: string | null;
      amountDisplay: string;
      amountMinorUnits: number;
      currencyNumeric: string;
      expiresAtEpochSeconds: number;
    }
  | { verified: false; reason: ScanRejectionReason; detail: string | null };

export interface PaymentOutcome {
  approved: boolean;
  responseCode: string | null;
  message: string | null;
  /**
   * Registered merchant name returned by the gateway — authoritative over the name printed in
   * the scanned QR. `null` when the gateway did not supply one.
   */
  merchantName: string | null;
  /**
   * Registered merchant location (`"city, state"`) returned by the gateway. `null` when the
   * gateway did not supply one — fall back to the scanned QR's `merchantCity`.
   */
  merchantLocation: string | null;
}

export interface PaymentQr {
  tokenUniqueReference: string;
  payload: string;
  amountMinorUnits: number;
  currencyNumeric: string;
  expiresAtEpochMillis: number;
  transactionHash: string;
}

export type QrExpiredEvent = { scope: 'wallet' | 'merchant'; handle: string | null };

// ── Wallet: history & receipts ────────────────────────────────────────────────

export type EntryMethod = 'TAP' | 'QR_GENERATED' | 'QR_SCANNED';

export interface TransactionSummary {
  merchantName: string;
  amountMinorUnits: number;
  transactionCurrencyCode: string | null;
  transactionHash: string | null;
  authorizationStatus: 'PENDING' | 'APPROVED' | 'DECLINED' | 'FAILED' | null;
  /**
   * Contactless date/time from the card exchange (EMV tags 9A + 9F21). Android tap rows only —
   * always `null` on iOS (no tap rail) and on QR rows, which carry `atEpochMillis` instead.
   */
  localTransactionDateTime: string | null;
  atEpochMillis: number | null;
  entryMethod: EntryMethod | null;
  merchantLocation: string | null;
  merchantTransactionReference: string | null;
  merchantId: string | null;
}

export interface TransactionReceipt {
  merchantName: string;
  merchantId: string | null;
  merchantAddress: string | null;
  transactionType: string;
  transactionStatus: string;
  transactionTime: string;
  totalAmountMinorUnits: string;
  totalAmountFormatted: string;
  currency: string | null;
  maskedToken: string | null;
  merchantTransactionReference: string | null;
  cdcvmApprovedByWallet: boolean | null;
  transactionId: string | null;
  transactionHash: string | null;
}

// ── Merchant (SoftPOS) ────────────────────────────────────────────────────────

export type MerchantType = 'PERSONAL' | 'BUSINESS';

export type MerchantStatus = 'ACTIVE' | 'INACTIVE' | 'SUSPENDED' | 'DEACTIVATED';

export interface MerchantRegistration {
  merchantType: MerchantType;
  merchantName: string;
  emailAddress: string;
  phoneNumber: string;
  addressLine1: string;
  addressLine2?: string;
  city: string;
  state: string;
  countryCode: string;
  accountNumber: string;
  institutionCode: string;
  acquirerId: string;
  /** Required for PERSONAL. */
  bvn?: string;
  /** Required for BUSINESS. */
  cacNumber?: string;
}

export interface MerchantRegistrationResult {
  success: boolean;
  merchantId: string | null;
  terminalId: string | null;
  merchantStatus: MerchantStatus | string | null;
  message: string | null;
}

export interface StoredMerchant {
  merchantId: string;
  merchantType: MerchantType | string;
  merchantName: string;
  emailAddress: string;
  phoneNumber: string;
  addressLine1: string;
  addressLine2: string;
  city: string;
  state: string;
  countryCode: string;
  accountNumber: string;
  institutionCode: string;
  acquirerId: string;
  merchantCategoryCode: string;
  terminalId: string;
  merchantStatus: MerchantStatus | string | null;
}

export interface MerchantUpdate {
  merchantName: string;
  emailAddress: string;
  phoneNumber: string;
  addressLine1: string;
  addressLine2?: string;
  city: string;
  state: string;
  countryCode: string;
  accountNumber: string;
  institutionCode: string;
}

// ── Merchant: tap acceptance ──────────────────────────────────────────────────

export interface TapRequest {
  amountMinorUnits: number;
  /** ISO 4217 numeric, e.g. '566'. Default '566'. */
  currency?: string;
  /** Android only: caller-supplied reference. iOS generates one (see result). */
  merchantTransactionReference?: string;
  /** Android only. Default 'PURCHASE'. */
  txType?:
    | 'PURCHASE'
    | 'RECURRING_PURCHASE'
    | 'REFUND'
    | 'CASH_ADVANCE'
    | 'PRE_AUTH_COMPLETION'
    | 'OTHER';
}

/**
 * Tap acceptance events. `cardContactLost` / `unsupportedCard` mean the reader stays
 * armed for a re-tap — show a transient hint, keep the waiting screen up. Only
 * `result` (and iOS `ended`) are terminal.
 */
export type MerchantTapEvent =
  | { type: 'cardDetected'; sessionId: string }
  | { type: 'cardContactLost'; sessionId: string }
  | { type: 'unsupportedCard'; sessionId: string }
  | { type: 'readingComplete'; sessionId: string }
  | { type: 'sendingOnline'; sessionId: string }
  | { type: 'receivingOnline'; sessionId: string }
  /** iOS only: session ended without a payment result. */
  | {
      type: 'ended';
      sessionId: string;
      outcome: 'CANCELLED' | 'TIMEOUT' | 'ERROR' | 'UNAVAILABLE';
    }
  | { type: 'result'; sessionId: string; result: MerchantTapResult };

export interface MerchantTapResult {
  /** Normalised across platforms: '00' approved, '05' declined, '06' failed pre-issuer, '99' pending, '91' issuer unavailable, '96' ambiguous, … */
  responseCode: string | null;
  status: 'APPROVED' | 'DECLINED' | 'PENDING' | 'FAILED' | null;
  message: string | null;
  amountDisplay: string | null;
  cardScheme: string | null;
  maskedTokenLast4: string | null;
  merchantTransactionReference: string | null;
  transactionId: string | null;
  merchantStatus: MerchantStatus | string | null;
}

// ── Merchant: QR rails ────────────────────────────────────────────────────────

export interface PaymentContextQr {
  txRef: string;
  mpmPayload: string;
  expiry: string | null;
}

export interface PaymentContextStatus {
  txRef: string;
  state: 'PENDING' | 'IN_FLIGHT' | 'APPROVED' | 'DECLINED' | 'EXPIRED';
  responseCode: string | null;
  transactionHash: string | null;
  isSettled: boolean;
  isApproved: boolean;
}

/**
 * A scanned customer payment QR. Opaque `handle` (the card data never crosses into
 * JS); display fields for the confirm screen.
 */
export interface ScannedCustomerQr {
  handle: string;
  maskedCard: string;
  amountMinorUnits: number;
  currencyNumeric: string;
  /**
   * The paying card's display name (EMV tag `5F20`), e.g. `AFRIGO ****1234` — the same value a
   * tap presents. `null` when the QR carries none.
   *
   * Display only: unlike the amount and currency it rides outside the QR's cryptogram, so show it
   * on the confirm screen and receipt but never branch a payment decision on it.
   */
  cardholderName: string | null;
}

export interface CustomerQrChargeOutcome {
  approved: boolean;
  responseCode: string | null;
  transactionId: string | null;
  merchantTransactionReference: string | null;
}

// ── Merchant: transactions & receipts ─────────────────────────────────────────

export interface MerchantTransaction {
  merchantTransactionReference: string;
  amountMinorUnits: number;
  status: 'APPROVED' | 'DECLINED' | 'PENDING' | 'FAILED';
  responseCode: string | null;
  transactionTime: string | null;
  currencyCode: string | null;
  transactionId: string | null;
  /** Which rail took the payment: 'TAP' | 'QR_MPM' | 'QR_CPM'. Display `railLabel`. */
  rail: string;
  /**
   * Human label for `rail` — 'Tap' / 'QR' / 'Scan'. Derived by the SDK so both platforms word it
   * identically; an unrecognised rail code is passed through unchanged.
   */
  railLabel: string;
  /** iOS only. */
  maskedTokenLast4: string | null;
  /** iOS only. */
  transactionHash: string | null;
  /**
   * Cardholder Name (EMV tag `5F20`) as the card presented it — on a Veyra token the card's
   * display name (application label + masked last four, e.g. `AFRIGO ****1234`), not a person's
   * name. `null` on QR-MPM payments (the merchant never reads the card), on transactions
   * recorded before this field existed, and when the card carried no `5F20`.
   */
  cardholderName: string | null;
}

export interface MerchantReceipt {
  merchantName: string;
  merchantAddress: string | null;
  transactionType: string;
  totalAmountMinorUnits: number;
  totalAmountFormatted: string;
  maskedToken: string | null;
  merchantTransactionReference: string;
  transactionHash: string | null;
  /**
   * Cardholder Name (EMV tag `5F20`) as the card presented it — on a Veyra token the card's
   * display name (e.g. `AFRIGO ****1234`), not a person's name. `null` on QR-MPM payments and on
   * transactions recorded before the SDK captured it. Merchant-side display only: it is not part
   * of the receipt QR the customer's wallet scans.
   */
  cardholderName: string | null;
  /** Android only: ready-made 512×512 PNG. */
  qrCodeBase64: string | null;
  /** iOS only: raw payload for the app to render. */
  qrPayload: string | null;
}

// ── Sessions (focus-bridged mode) ─────────────────────────────────────────────

/**
 * Which payment experience a screen hosts. Mounting a session on the screen is how
 * the app declares it — the SDK arms/disarms the device as the screen gains and
 * loses focus. The app never chooses a mode.
 */
export type SessionKind = 'pay' | 'getPaid';
