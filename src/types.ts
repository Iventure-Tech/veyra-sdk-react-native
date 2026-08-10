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

/**
 * Machine-readable activation failure kind — branch on this, never on `message`. The
 * `(string & {})` arm keeps codes added after this build flowing through verbatim.
 */
export type ActivationFailureCode =
  | 'TOKEN_NOT_FOUND'
  | 'TOKEN_NOT_ACTIVATABLE'
  | 'ACTIVATION_LOCKED'
  | 'NO_PENDING_ACTIVATION'
  | 'CODE_EXPIRED'
  | 'CODE_INVALID'
  | 'MAX_ATTEMPTS_EXCEEDED'
  | 'CODE_REQUEST_RATE_LIMITED'
  | 'INVALID_REQUEST'
  | 'ACTIVATION_FAILED'
  | (string & {});

/**
 * Server's token-delete recommendation after an exhausted activation cycle: 'MUST' after an
 * exhausted ADD_CARD cycle, 'MAY' after VERIFY_ACCOUNT, absent otherwise.
 */
export type RecommendDelete = 'MUST' | 'MAY' | (string & {});

export interface ActivationCodeResponse {
  tokenUniqueReference: string | null;
  expirationDateTime: string | null;
  status: 'SUCCESS' | 'FAILURE' | null;
  message: string | null;
  /** Why the request failed — e.g. disable "resend" on CODE_REQUEST_RATE_LIMITED, end the flow on ACTIVATION_LOCKED. */
  failureCode: ActivationFailureCode | null;
}

export interface ActivateResponse {
  tokenUniqueReference: string | null;
  status: 'SUCCESS' | 'FAILURE' | null;
  message: string | null;
  /** Why activation failed — branch on this, never on `message`. */
  failureCode: ActivationFailureCode | null;
  /** Code attempts left in this cycle, where an attempt cap applies (0 when exhausted/locked). */
  attemptsRemaining: number | null;
  /** Delete recommendation after an exhausted cycle. */
  recommendDelete: RecommendDelete | null;
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

/**
 * Wallet payment events.
 *
 * The tap phases (`transactionStarted` / `transactionCompleted`) are **Android only** —
 * tap-to-pay is not available on iOS. The two refusal phases fire on **both** platforms, from
 * whichever rails that platform has: tap and QR on Android, QR only on iOS (see `rail`).
 */
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
  | { type: 'activationFailed'; message: string }
  /**
   * A payment was refused because the card's payment keys need refreshing and the wallet could
   * not reach the server. Tell the payer to connect and try again.
   *
   * On the tap rail this arrives at the earliest moment it is actually true: immediately when the
   * device is already offline, otherwise only once the automatic background refresh has failed. A
   * refresh that succeeds fires **nothing** — the next tap simply works.
   *
   * This describes *this payment*, not the card: `WalletCard.requiresOnline` answers the
   * different question "can this card pay anything offline?" and stays `false` for a card that
   * can still make smaller payments. Don't grey the card out on the strength of one refusal.
   */
  | {
      type: 'requireOnline';
      tokenId: string | null;
      tokenUniqueReference: string | null;
      amountMinorUnits: number;
      rail: WalletPayRail;
      /** Machine-matchable, prefixed `ONLINE_REQUIRED`. */
      message: string;
    }
  /**
   * A payment was refused because the amount is larger than this card can carry in one payment.
   *
   * **Never tell the payer to go online here** — a refreshed key carries the same cap, so they
   * would connect, retry and fail identically. Tell them to pay a smaller amount or use another
   * card. `cardLimitMinorUnits` is that cap when known, `null` when it could not be read.
   */
  | {
      type: 'amountExceedCardLimit';
      tokenId: string | null;
      tokenUniqueReference: string | null;
      amountMinorUnits: number;
      cardLimitMinorUnits: number | null;
      rail: WalletPayRail;
      /** Machine-matchable, prefixed `AMOUNT_EXCEEDS_CARD_LIMIT`. */
      message: string;
    };

/** Which rail a payment was refused on. `TAP` is Android only. */
export type WalletPayRail = 'TAP' | 'CPM_QR' | 'MPM_QR';

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
  /**
   * Convenience for the happy path only: `responseStatus === 'APPROVED'`. It is `false` for a
   * declined, failed *and* pending payment alike, so anything that must tell a refusal from an
   * unresolved payment reads `responseStatus`.
   */
  approved: boolean;
  responseCode: string | null;
  /**
   * What the gateway said the payment **is** — `'APPROVED'`, `'DECLINED'`, `'FAILED'` or
   * `'PENDING'`. A push is a synchronous call, but it can still answer `PENDING` (a hop below the
   * gateway timed out, errored or is still settling): that means *not yet known*, never refused.
   * The SDK stores such a payment open and keeps asking until the gateway states a final outcome;
   * the row's final status shows up in the wallet's transaction history.
   *
   * A plain string, not a union, so a value added after this version shipped still reaches you.
   * `null` only if the gateway stated none.
   */
  responseStatus: string | null;
  /** The stated cause (`'INSUFFICIENT_FUNDS'`, `'NO_RESPONSE_RECEIVED'`, …) — display and log. */
  responseStatusReason: string | null;
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

/**
 * A payment the app was left waiting on has resolved — the push half of
 * `merchant.getTransactions()`.
 *
 * A sale that gets no answer resolves to `PENDING`, and the SDK then polls it to a final status in
 * the background. This fires the moment one settles, including for a payment started in an earlier
 * app launch, so match `merchantTransactionReference` to the sale you are showing.
 *
 * A notification, never the source of truth: there is no replay on subscription, so a screen still
 * reads the store when it appears and treats this as the live update while it is up.
 */
export type TransactionResolvedEvent = {
  /** The reference passed when the payment was started — match the event to its sale with this. */
  merchantTransactionReference: string;
  /** The response code exactly as the backend sent it (`'00'`, `'51'`, `'96'`…). */
  responseCode: string | null;
  /** Always one of the three finals — never `'PENDING'`. */
  status: 'APPROVED' | 'DECLINED' | 'FAILED' | string;
  /** Why it ended that way, e.g. `'INSUFFICIENT_FUNDS'`. Null when the backend sent none. */
  reason: string | null;
};

/**
 * The funds of an approved sale were confirmed in the merchant's bank account (`RECEIVED`), or
 * the 30-day confirmation window closed unconfirmed (`UNABLE_TO_CONFIRM` — a give-up, not a
 * reversal). Settlement confirmation only: it never changes the payment outcome. The SDK owns the
 * polling (exponential backoff, up to 30 days, app-scoped on both platforms); the app just
 * reacts. The event fires on Android and iOS alike; the answer is also written to the stored row
 * (`MerchantTransaction.creditConfirmationStatus`), which is what a screen opened later reads.
 */
export type CreditConfirmationEvent = {
  /** The reference passed when the payment was started — match the event to its sale with this. */
  merchantTransactionReference: string;
  /** The beneficiary credit's identifier the payment response carried. */
  creditTransactionId: string | null;
  status: 'RECEIVED' | 'UNABLE_TO_CONFIRM' | string;
  /** Credited amount in minor units, as the merchant's bank reported it. RECEIVED only. */
  amountMinorUnits: number | null;
  /** The merchant bank's own reference for the credit. RECEIVED only. */
  bankReference: string | null;
  /** When the merchant's bank posted the credit (ISO date-time). RECEIVED only. */
  creditedAt: string | null;
};

// ── Wallet: history & receipts ────────────────────────────────────────────────

export type EntryMethod = 'TAP' | 'QR_GENERATED' | 'QR_SCANNED';

export interface TransactionSummary {
  merchantName: string;
  amountMinorUnits: number;
  transactionCurrencyCode: string | null;
  transactionHash: string | null;
  authorizationStatus: 'PENDING' | 'APPROVED' | 'DECLINED' | 'FAILED' | null;
  /**
   * The outcome's response code (`"00"`, `"51"`, `"91"`…), carried verbatim from the rail that
   * resolved this row; `null` on legacy rows and rows still awaiting their reconcile. Receipts
   * and support conversations quote this literal.
   */
  responseCode: string | null;
  /**
   * The outcome's stated cause (`"INSUFFICIENT_FUNDS"`, `"QR_EXPIRED"`…), carried verbatim as a
   * plain string — display it, never parse it; `null` on legacy/unresolved rows.
   */
  responseStatusReason: string | null;
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
  /**
   * The beneficiary credit's identifier (NIP session id inter-bank, batch reference intra-bank) —
   * display and support only. The SDK polls the confirmation itself; never pass this back.
   * `null` on rows that were not approved, and from gateways predating the credit rail.
   */
  creditTransactionId: string | null;
  /**
   * Whether the merchant's (beneficiary) bank can confirm the credit at all — **the gate for
   * everything on this rail**. `true` means the SDK is polling in the background and the app
   * should render the credit line; `false`/`null` means there is nothing to ask, so render no
   * credit UI for this transaction. `null` is "unknown", never "not credited".
   */
  isCreditConfirmationSupported: boolean | null;
  /**
   * The terminal credit-confirmation state: `"RECEIVED"` (the merchant's bank confirmed the funds)
   * or `"UNABLE_TO_CONFIRM"` (the 30-day window closed without a confirmation — the give-up state,
   * *not* a statement that the money never arrived).
   *
   * `null` while in flight: an unconfirmed attempt is never stored. With
   * `isCreditConfirmationSupported === true`, `null` is the "confirming…" state.
   */
  creditConfirmationStatus: string | null;
  /** When the beneficiary bank posted the credit (ISO date-time). `"RECEIVED"` only. */
  creditedAt: string | null;
  /** The beneficiary bank's own reference for the credit. `"RECEIVED"` only. */
  bankReference: string | null;
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
 * Tap acceptance events, identical on Android and iOS. `cardContactLost` / `unsupportedCard` mean
 * the reader stays armed for a re-tap — show a transient hint, keep the waiting screen up. Only
 * `result` (and iOS `ended`) are terminal.
 *
 * One iOS nuance worth knowing: `cardContactLost` there is reported when CoreNFC says the tag left
 * the field, which ends that card's dialogue — the session stays armed for a fresh tap, but the
 * interrupted attempt still reports its own `result`.
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
  /**
   * The merchant-bank credit's identifier (NIP session id inter-bank, batch reference
   * intra-bank). `null` unless the sale was approved and the gateway sent one.
   */
  creditTransactionId: string | null;
  /**
   * Whether the merchant's (beneficiary) bank can confirm the credit at all — the backend's
   * payment-time decision. When `true`, the SDK polls the confirmation rail in the background
   * and fires `merchant.onCreditConfirmation` — show a "confirming credit…" state on the result
   * screen and flip it from that event. `false`/`null` means there is nothing to wait for.
   */
  isCreditConfirmationSupported: boolean | null;
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
  /**
   * The reference this payment was recorded under — **minted by the SDK** and echoed
   * by the gateway, not a value you supplied. This is the key a receipt lookup or status poll
   * must use, because it is the value the gateway actually stored.
   */
  merchantTransactionReference: string | null;
  /** Your own order/basket id, echoed back exactly as you passed it to `chargeCustomerQr`. */
  merchantOrderId: string | null;
  /**
   * The merchant-bank credit's identifier. `null` unless the charge was approved and the
   * gateway sent one.
   */
  creditTransactionId: string | null;
  /**
   * Whether the merchant's (beneficiary) bank can confirm the credit — the backend's
   * payment-time decision. `true` means the SDK's app-scoped background sweep polls the
   * confirmation rail and stamps the answer onto the sale's stored row — show a "confirming
   * credit…" state on the result screen and flip it from `merchant.onCreditConfirmation`
   * (Android) or the re-read row (`creditConfirmationStatus`).
   */
  isCreditConfirmationSupported: boolean | null;
}

// ── Merchant: transactions & receipts ─────────────────────────────────────────

export interface MerchantTransaction {
  merchantTransactionReference: string;
  amountMinorUnits: number;
  status: 'APPROVED' | 'DECLINED' | 'PENDING' | 'FAILED';
  responseCode: string | null;
  /**
   * The outcome's stated cause (`"INSUFFICIENT_FUNDS"`, `"QR_EXPIRED"`…), carried verbatim as a
   * plain string — display it, never parse it; `null` on legacy/unresolved rows.
   */
  responseStatusReason: string | null;
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
  /**
   * The beneficiary credit's identifier (NIP session id inter-bank, batch reference intra-bank).
   * `null` on non-approved rows and from gateways predating the credit-confirmation rail.
   */
  creditTransactionId: string | null;
  /**
   * Whether the merchant's (beneficiary) bank can confirm the credit at all — the backend's
   * payment-time decision. `true` means the SDK is polling the confirmation rail in the
   * background for this sale (show a "confirming credit…" state until
   * `creditConfirmationStatus` resolves); `false`/`null` means there is nothing to wait for. On
   * MPM rows the flag is learned from the transaction-status rail shortly after the settle (the
   * contexts endpoint never carries it), so it can be `null` for a few seconds on a
   * freshly-settled row.
   */
  isCreditConfirmationSupported: boolean | null;
  /**
   * Terminal credit-confirmation state: `'RECEIVED'` when the merchant's bank confirmed the
   * funds, `'UNABLE_TO_CONFIRM'` only as the final give-up after the 30-day window. **`null`
   * while unconfirmed** — render it as "not confirmed yet" (or nothing), never as "not
   * received". Settlement fact only; `status` remains the payment outcome.
   */
  creditConfirmationStatus: string | null;
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
