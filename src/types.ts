/**
 * Veyra React Native SDK — public types.
 *
 * One promise-based surface over both native SDKs. Where the platforms diverge, fields
 * are marked platform-nullable and methods carry their availability in the doc comment;
 * calling an unsupported method fails with code `UNSUPPORTED_ON_PLATFORM`.
 *
 * **One outcome shape.** Every operation resolves with its outcome — it never rejects for one.
 * Branch on `responseStatus` first (see {@link ResponseStatus}), then on `responseStatusReason`.
 * A promise rejects only with a setup error (`VeyraError`, see `VeyraErrorCode`): a mistake in the
 * app's integration, found in development.
 */

export type VeyraEnvironment = 'TEST' | 'LIVE';

/** The exclusive NFC mode of the app. Read-only — the SDK owns all transitions. */
export type VeyraMode = 'NONE' | 'SOFTPOS' | 'WALLET';

// ── Outcomes ──────────────────────────────────────────────────────────────────

/**
 * What happened to a call — the field to branch on, carried verbatim from the SDK.
 *
 * | Status | Meaning | Your reference (merchant order ID) | What to do |
 * |---|---|---|---|
 * | `APPROVED` | done | used — paid | complete |
 * | `DECLINED` | done; someone with authority refused; no money moved | free | show the reason; another card or method may be tried under the **same** reference |
 * | `FAILED` | Veyra received it and did not perform it, and retrying with the same reference won't help | free, except after `94` (the order is paid or possibly paid) | fix the reason |
 * | `PENDING` | may have been done; not known yet | used | **never retry**; the SDK resolves it in the background |
 * | `RETRY` | Veyra received it and did not send it to the bank; nothing was done | **unused** | fix the reason; retry with the **same** reference |
 * | `NOT_SENT` | never reached Veyra; nothing was done | **unused** | fix the reason; retry with the **same** reference |
 *
 * `RETRY` is stated by Veyra and carries its `responseCode` (e.g. `91`, `25`); the payment is recorded
 * in history. `NOT_SENT` never left the phone and is not recorded. Handle the two the same way: nothing
 * was debited; retry with the same order id. An order id can be used again until the order is
 * `APPROVED` or `PENDING`; after that a new attempt is refused `94` / `FAILED` /
 * `DUPLICATE_MERCHANT_ORDER_ID`.
 *
 * `NOT_SENT` is the SDK's own status — no service states it — and never carries a `responseCode`. Its
 * `responseStatusReason` says what to fix: `INVALID_REQUEST`, `NO_NETWORK_CONNECTION`,
 * `SDK_UNABLE_TO_CONNECT`, `NOT_AUTHENTICATED`, `AUTH_CANCELLED` / `AUTH_FAILED` / `AUTH_UNAVAILABLE`,
 * `CANCELLED`, `MODE_REFUSED`, `ONLINE_REQUIRED`, `TOKEN_NOT_ACTIVE`, `AMOUNT_EXCEEDS_CARD_LIMIT`,
 * `DEVICE_NOT_BOUND`, `MISSING_MANDATORY_CONFIG`, `CARD_READ_FAILED`, `SDK_INTERNAL_ERROR`, …
 *
 * The `(string & {})` arm keeps a status added after this SDK shipped flowing through verbatim; treat
 * one you don't know as unresolved.
 */
export type ResponseStatus =
  | 'APPROVED'
  | 'DECLINED'
  | 'FAILED'
  | 'PENDING'
  | 'RETRY'
  | 'NOT_SENT'
  | (string & {});

/**
 * The answer to a read — a status check, a credit check, a context poll.
 *
 * A read carries no status of its own: when it is about a payment, the payment's status is inside
 * `value`, and a check that could not be made never changes it. When the check could not be made,
 * `failureReason` says why (`NO_NETWORK_CONNECTION`, `SDK_UNABLE_TO_CONNECT`, `NOT_AUTHENTICATED`,
 * `UPSTREAM_ERROR`…) and `value` is what the device already holds, if anything. A read changes
 * nothing, so retrying it as is is always safe.
 */
export interface VeyraLookup<T> {
  /** The answer; for a refresh, the stored row as it now stands. `null` when there is none. */
  value: T | null;
  /** Why the check could not be made; `null` when it was made. */
  failureReason: string | null;
  /** A human-readable description of the failure, for logs and error text. */
  message: string | null;
  /** `true` when the check was made and answered (`failureReason` is `null`). */
  checked: boolean;
}

/**
 * The answer to a cancel — `softpos.cancelPayment`, `wallet.cancelPayment`, `wallet.cancelDigitise`.
 * It is the reply to the **cancel**, never the call's status: the cancelled call still resolves (or,
 * for a tap, ends its event stream) with its own outcome.
 *
 * A call can be cancelled only while its request is still on the device:
 *
 * | Answer | Meaning | What to show |
 * |---|---|---|
 * | `CANCELLED` | stopped before anything was sent; the call ends `'NOT_SENT'` / `CANCELLED` | go back; the same order ID / `clientRequestId` can be used again |
 * | `TOO_LATE_TO_CANCEL_REQUEST_ALREADY_SENT` | the request has left the device; the call carries on | "This can no longer be cancelled" — keep waiting for its result |
 * | `TOO_LATE_TO_CANCEL_TASK_ALREADY_PROCESSED` | the call had already finished | the result it already delivered |
 * | `NO_PAYMENT_IN_PROGRESS_FOR_ORDER_ID` | no payment with that order ID is armed or running | nothing is in progress |
 * | `NO_DIGITISATION_IN_PROGRESS_FOR_CLIENT_REQUEST_ID` | no add-card with that `clientRequestId` is running | nothing is in progress |
 */
export type CancelResult =
  | 'CANCELLED'
  | 'TOO_LATE_TO_CANCEL_REQUEST_ALREADY_SENT'
  | 'TOO_LATE_TO_CANCEL_TASK_ALREADY_PROCESSED'
  | 'NO_PAYMENT_IN_PROGRESS_FOR_ORDER_ID'
  | 'NO_DIGITISATION_IN_PROGRESS_FOR_CLIENT_REQUEST_ID';

// ── Configuration ─────────────────────────────────────────────────────────────

/** Which kind of {@link VeyraProvider} an object is. The SDK reads it to decide how it reaches Veyra. */
export type VeyraProviderType = 'AUTHENTICATION' | 'PROXY';

/**
 * How the SDK reaches Veyra: the one object you pass to `Veyra.initialize` as `provider`, shared
 * by the softpos and wallet SDKs. **Required, with no default.** Implement exactly one kind:
 *
 * - {@link VeyraAssertionProvider} (`providerType: 'AUTHENTICATION'`) — the SDK calls Veyra itself,
 *   with a short-lived assertion your backend signs for the signed-in user.
 * - {@link VeyraProxyProvider} (`providerType: 'PROXY'`) — the SDK calls nothing
 *   itself; every backend call is handed to your `send`, which forwards it through your bank's API
 *   gateway to the Veyra Issuer Token Gateway (ITG).
 *
 * `Veyra.initialize` rejects with `INVALID_CONFIGURATION`, naming the problem: no provider; an object with
 * both `assertion` and `send`; a `providerType` that does not match the functions
 * present; a blank `clientId`; and a provider of a different kind than an earlier `initialize`
 * in the same app process.
 */
export type VeyraProvider = VeyraAssertionProvider | VeyraProxyProvider | VeyraClientSecretProvider;

/**
 * **Assertion** — "I prove who the user is." The SDK calls Veyra itself, with an access token
 * bound to a key generated on this device that cannot be exported.
 */
export interface VeyraAssertionProvider {
  providerType: 'AUTHENTICATION';
  /** The OAuth client id Veyra issued to your app. Public, not a secret. */
  clientId: string;
  /**
   * A short-lived JWT your backend signed for the signed-in user, or `null` when nobody is signed
   * in — the SDK then fails the call with `NOT_AUTHENTICATED` and sends nothing. Rejecting has the
   * same effect. Called only when the SDK holds no valid token, never more than once at a time.
   *
   * @param audience required in the assertion as `aud`: the base URL of the Veyra API the
   *   assertion will be redeemed at (e.g. `https://api.veyra.co`). Check it before you sign.
   * @param jkt optional to use: this install's device-key thumbprint; put it in `cnf.jkt` to bind
   *   the assertion to this device (recommended). The SDK uses DPoP with Veyra either way.
   */
  assertion(audience: string, jkt: string): Promise<string | null>;
}

/**
 * Forwards one SDK backend call. `request` is the JSON envelope (version 1) documented in the
 * README — it names the Veyra service, the HTTP method and the path; resolve with the response
 * body, unmodified (including the ITG's own `PROXY_FAILED` body, which the SDK recognises). To fail, reject with a
 * {@link VeyraRelayError} (or any object carrying `kind`, `neverSent` and optionally
 * `httpStatus`). Any other rejection counts as "may have been delivered".
 *
 * Called from the SDK's background work too (status polling, key refresh, confirmations).
 */
export type VeyraRelayFunction = (request: string) => Promise<string>;

/**
 * **Via your backend** — "I process every request through my backend." The SDK makes no network
 * call to Veyra of its own: every backend call goes to {@link send}, whatever its HTTP method —
 * the envelope names the method.
 */
export interface VeyraProxyProvider {
  providerType: 'PROXY';
  send: VeyraRelayFunction;
}

/**
 * @deprecated A client secret inside an app can be extracted from it. Use a
 * {@link VeyraAssertionProvider} or a {@link VeyraProxyProvider}. Still supported only until your
 * payment app provider's cut-over date.
 */
export interface VeyraClientSecretProvider {
  providerType: 'AUTHENTICATION';
  clientId: string;
  clientSecret: string;
}

/** What a failed relay call observed — the advice the SDK gives the user follows from it. */
export type VeyraRelayFailureKind = 'NO_NETWORK' | 'TIMEOUT' | 'CONNECTION_REFUSED' | 'OTHER';


export interface VeyraSoftposConfig {
  environment: VeyraEnvironment;
  /**
   * The payment app provider's globally unique identifier, as issued by the platform — the same
   * identifier the wallet config carries. Required: the gateway links every registered merchant
   * to this provider and resolves the acquirer id and MCC from it; the app never supplies an
   * acquirer id.
   */
  paymentAppProviderId: string;
  /** Android only. Defaults to true. */
  enableNfc?: boolean;
  /**
   * The longest the SDK waits for one backend call, start to finish, in whole seconds (5–60).
   * Omit it to keep the SDK's own timeouts. A value outside 5–60 makes `initialize` reject with
   * `INVALID_CONFIGURATION`. A payment that runs out of time is **pending**, not failed: the
   * request may have reached the server, so the SDK checks the result later. A shorter timeout
   * answers sooner but leaves more payments pending.
   */
  requestTimeoutSeconds?: number;
}

export interface VeyraWalletConfig {
  environment: VeyraEnvironment;
  paymentAppProviderId: string;
  tokenRequestorId: string;
  /** Android: required before digitising. iOS: fixed by the SDK. */
  recommendationStandardVersion?: string;
  appVersion?: string;
  /** iOS only: your Apple Developer Team ID. Required on iOS (`INVALID_CONFIGURATION` without it). */
  appleTeamId?: string;
  /**
   * Digitise provision-context allow-lists your app decides. Country, currency and merchant
   * category code are NOT configurable: the SDK declares Veyra's provisioning domain itself.
   */
  allowedAcquirerIds?: string[];
  allowedMerchantIds?: string[];
  /** Android only. Defaults to true. */
  enableNfc?: boolean;
  /**
   * Whether the payment authentication sheet offers the device passcode as well as biometrics.
   * Defaults to `true`.
   */
  cdcvmAllowDeviceCredential?: boolean;
  /** The authentication sheet's title and subtitle for a scan-to-pay; the SDK's own wording when omitted. */
  cdcvmPayTitle?: string;
  cdcvmPaySubtitle?: string;
  /** The authentication sheet's title and subtitle for showing a QR to pay; the SDK's own wording when omitted. */
  cdcvmShowQrTitle?: string;
  cdcvmShowQrSubtitle?: string;
  /**
   * The longest the SDK waits for one backend call, start to finish, in whole seconds (5–60).
   * Omit it to keep the SDK's own timeouts. A value outside 5–60 makes `initialize` reject with
   * `INVALID_CONFIGURATION`. A payment that runs out of time is **pending**, not failed: the
   * request may have reached the server, so the SDK checks the result later. A shorter timeout
   * answers sooner but leaves more payments pending.
   */
  requestTimeoutSeconds?: number;
}

/**
 * The two SDKs' settings for {@link Veyra.initialize} — `Veyra.initialize(customerId, config, provider)`,
 * the same order as Android `VeyraSdk.initialize` and iOS `VeyraSDK.configure`.
 */
export interface VeyraSdkConfig {
  softpos: VeyraSoftposConfig;
  wallet: VeyraWalletConfig;
}

// ── Wallet: add card / digitise ───────────────────────────────────────────────

export interface Bank {
  slug: string;
  name: string;
  institutionCode: string;
}

/**
 * A bank list (a read): `'APPROVED'` with `banks`, or `'FAILED'` / `'NOT_SENT'` with
 * `responseStatusReason` (`NO_NETWORK_CONNECTION`…) and no banks. Never `'PENDING'`; retrying as is is
 * always safe. Returned by `wallet.getBanks`.
 */
export interface BankList {
  banks: Bank[];
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
  message: string | null;
}

/** The merchant's settlement banks — same shape and rules as {@link BankList}. */
export interface SettlementBankList {
  banks: Bank[];
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
  message: string | null;
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
  /** See {@link DigitiseParams.walletAccountId} — the account's registered email or phone. */
  walletAccountId: string;
  accountHolderName?: string;
  accountNumberSource?: AccountNumberSource;
}

export interface VerifyAccountResponse {
  responseCode: DigitiseResponseCode | null;
  message: string | null;
  /**
   * What the **call** did, as distinct from what the issuer decided: `'APPROVED'`, `'DECLINED'`
   * (the check ran, the answer is no), `'FAILED'` (it could not be run, so nothing was decided
   * about the account) or `'NOT_SENT'` (it never reached Veyra — `responseStatusReason` says why,
   * e.g. `INVALID_REQUEST` for a missing argument). A read, so never `'PENDING'`.
   */
  responseStatus: ResponseStatus;
  /**
   * **Why** — the symbolic cause, and the field to branch on. Same vocabulary as
   * {@link DigitiseResult.responseStatusReason}.
   */
  responseStatusReason: string | null;
  /** `true` when the account can be tokenised — `responseStatus` is `'APPROVED'`. */
  isApproved: boolean;
}

export interface DigitiseParams {
  accountNumber: string;
  institutionCode: string;
  accountHolderName: string;
  /**
   * The wallet's own identifier for this user — **use the account's registered email address or
   * phone number**. The SDK hashes it and the issuer recomputes that hash from the email/phone on
   * its own record and compares. A value the bank does not hold (a GUID, an internal user id, a
   * placeholder) hashes fine and matches nothing, costing the digitisation its identity-match
   * signal and raising its risk score.
   */
  walletAccountId: string;
  emailAddress: string;
  /** The wallet provider's own judgement — never defaulted by the SDK. */
  recommendation: TokenizationRecommendation;
  /** Required on Android; optional on iOS. */
  consumerIdentifier?: string;
  /**
   * The account holder's BVN. Optional when your payment app provider is registered as the account
   * issuer; otherwise the backend refuses with `'BVN_REQUIRED'` (`responseStatusReason`). Blank is
   * sent as absent.
   */
  bvn?: string;
  accountHolderAddress?: string;
  mobileNumber?: string;
  /**
   * Your own unique ID for this add-card request. Pass one if you want to be able to cancel it:
   * `wallet.cancelDigitise(clientRequestId)`. Without one the SDK generates an ID and the request
   * cannot be cancelled.
   */
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
  /**
   * What the **call** did, as distinct from what the issuer decided: `'APPROVED'`, `'DECLINED'`,
   * `'FAILED'` or `'NOT_SENT'`. A digitise that got no answer after sending ends `'FAILED'`
   * (`NO_RESPONSE_RECEIVED` / `UPSTREAM_ERROR`), never `'PENDING'` — digitise again. Carried
   * verbatim — a value this SDK has never heard of still reaches you.
   */
  responseStatus: ResponseStatus;
  /**
   * **Why** — the symbolic cause, and the field to branch on.
   *
   * Carries the issuer's own cause verbatim (`'ACCOUNT_NAME_MISMATCH'`, `'BVN_MISMATCH'`,
   * `'ACCOUNT_NOT_LINKED_TO_BVN'`, `'ACCOUNT_ADDRESS_MISMATCH'`, `'ACCOUNT_BLOCKED'`,
   * `'MAX_ACTIVE_TOKENS_EXCEEDED'`, `'RISK_SCORE_BELOW_THRESHOLD'`, …), the token provider's when
   * it decided this itself (`'INVALID_ACCOUNT_NUMBER'`, `'UNKNOWN_ISSUER'`, `'BVN_REQUIRED'` — no
   * `bvn` and your payment app provider is not registered as the account issuer, …), or an API
   * failure on a `'FAILED'` call.
   *
   * **Present on `'APPROVE_REQUIRE_AUTH'` too**, which is the case worth handling: it says why
   * step-up is required — usually an identity mismatch — so your activation screen can say
   * something truthful instead of a generic "verification needed".
   *
   * Typed as a plain `string` on purpose: the vocabulary grows without an SDK release, so keep a
   * default branch.
   */
  responseStatusReason: string | null;
  tokenUniqueReference: string | null;
  activationMethods: ActivationMethodInfo[];
  message: string | null;
  isApproved: boolean;
  requiresActivation: boolean;
  /** iOS only. */
  tokenStored: boolean | null;
  /**
   * The `clientRequestId` this digitise was sent with — yours, or the one the SDK generated. Keep it
   * when the result is `'FAILED'` with `NO_RESPONSE_RECEIVED` or `UPSTREAM_ERROR`: the token provider
   * may have created a token whose details never reached the phone, and
   * {@link WalletApi.deactivateDigitise} switches it off. Then digitise again with a new id.
   */
  clientRequestId: string | null;
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
  /** The failure code exactly as the backend sent it — quote it in logs and support. */
  failureCodeRaw: string | null;
  /** What the call did — `'NOT_SENT'` when it never reached Veyra (`responseStatusReason` says why). */
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
}

export interface ActivateResponse {
  tokenUniqueReference: string | null;
  status: 'SUCCESS' | 'FAILURE' | null;
  message: string | null;
  /** Why activation failed — branch on this, never on `message`. */
  failureCode: ActivationFailureCode | null;
  /** The failure code exactly as the backend sent it — quote it in logs and support. */
  failureCodeRaw: string | null;
  /** Code attempts left in this cycle, where an attempt cap applies (0 when exhausted/locked). */
  attemptsRemaining: number | null;
  /** Delete recommendation after an exhausted cycle. */
  recommendDelete: RecommendDelete | null;
  /** The delete recommendation exactly as the backend sent it. */
  recommendDeleteRaw: string | null;
  /** What the call did — `'NOT_SENT'` when it never reached Veyra (`responseStatusReason` says why). */
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
}

/**
 * The backend's answer to a token status change — today, {@link WalletApi.deactivateToken}.
 * `status` is the token's status as token-provider reports it, carried verbatim.
 */
export interface TokenStatusUpdateResponse {
  tokenUniqueReference: string | null;
  status: string | null;
  message: string | null;
  /**
   * What the call did: `'APPROVED'` (done), `'FAILED'`, `'PENDING'` (sent, no usable answer — check
   * `tokenStatus` before trying again) or `'NOT_SENT'` (never reached Veyra).
   */
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
}

/**
 * A card's status on the server (a read): `'APPROVED'` with `tokenStatus` (`'ACTIVE'`,
 * `'SUSPENDED'`, `'PENDING_ACTIVATION'`…, carried verbatim — a value this build does not know still
 * reaches you), or `'FAILED'` / `'NOT_SENT'` with `responseStatusReason` and no status. Never `'PENDING'`.
 */
export interface TokenStatusResult {
  tokenStatus: TokenStatus | string | null;
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
  message: string | null;
}

// ── Wallet: cards ─────────────────────────────────────────────────────────────

export type TokenStatus =
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
 * A stored token (a card added to this wallet). Union-superset of the two platforms' token DTOs.
 * `tokenUniqueReference` is the identity every wallet call takes — `setActiveToken`, `getToken`,
 * `tokenStatus`, `getTransactions` and the rest.
 */
export interface Token {
  /** The token's identity — pass it back into every wallet call. */
  tokenUniqueReference: string;
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
  /** The token's lifecycle status as the SDK last saw it; `null` when it has never been status-synced. */
  status: TokenStatus | string | null;
  /** `true` when the token is activated and can pay. */
  isActive: boolean;
  /** `true` on the token payments use (`wallet.setActiveToken`). */
  isSelected: boolean;
  /** Card must be activated (OTP) before first use. */
  requiresActivation: boolean;
  activationMethods: ActivationMethodInfo[] | null;
  /**
   * True when the card temporarily cannot pay and needs the device online — grey it
   * out and disable pay affordances; the SDK self-heals, there is nothing to call.
   */
  requiresOnline: boolean;
  /**
   * True when the card was added on another device (or before this app was reinstalled) and the
   * Veyra backend will not issue it new payment keys here. It cannot pay on this phone again:
   * prompt the user to remove it and add it again. Going online does not help, so such a card
   * always reads `requiresOnline: false`; payments with it are refused with `DEVICE_NOT_BOUND`.
   */
  deviceNotBound: boolean;
}

// ── Wallet: payments ──────────────────────────────────────────────────────────

/**
 * Wallet payment events.
 *
 * **Android only** — tap-to-pay is not available on iOS, where `wallet.observeTapEvents` throws
 * `UNSUPPORTED_ON_PLATFORM`. A card-reading event, not a call's outcome: the payment's outcome
 * arrives in the transaction history and on `wallet.observeTransactionResolved`.
 */
export type WalletTapEvent =
  | { type: 'transactionStarted'; tokenUniqueReference: string }
  | {
      type: 'transactionCompleted';
      status: 'APPROVED' | 'DECLINED' | 'ERROR';
      message: string | null;
      amountMinorUnits: number | null;
      tokenUniqueReference: string | null;
      cardScheme: CardScheme | null;
      reference: string | null;
    };

/** Which rail a payment was refused on. `TAP` is Android only. */
export type WalletPayRail = 'TAP' | 'CPM_QR' | 'MPM_QR';

/**
 * A payment refused **before any proof was built**, delivered to the handler registered for that
 * card with `wallet.observePaymentRefusals`.
 *
 * Separate shapes, not one, because the advice differs and a host that cannot tell them apart will
 * misdirect the payer. The first two describe **this payment**, not the card: `Token.requiresOnline`
 * answers the different question "can this card pay anything offline at all?" and stays `false`
 * for a card that can still make smaller payments — so don't grey a card out on the strength of
 * one refusal.
 *
 * `tokenUniqueReference` is `null` when the SDK could not attribute the refusal to a card. Such a
 * refusal reaches **every** registered handler rather than none: the payer was refused either way.
 */
export type WalletPaymentRefusal =
  /**
   * The card's payment keys need refreshing and the wallet could not reach the server. Tell the
   * payer to connect and try again.
   *
   * On the tap rail this arrives at the earliest moment it is actually true: immediately when the
   * device is already offline, otherwise only once the automatic background refresh has failed. A
   * refresh that succeeds fires **nothing** — the next tap simply works.
   */
  | {
      type: 'requireOnline';
      tokenUniqueReference: string | null;
      amountMinorUnits: number;
      rail: WalletPayRail;
      /** Machine-matchable, prefixed `ONLINE_REQUIRED`. */
      message: string;
    }
  /**
   * The amount is larger than this card can carry in one payment.
   *
   * **Never tell the payer to go online here** — a refreshed key carries the same cap, so they
   * would connect, retry and fail identically. Tell them to pay a smaller amount or use another
   * card. `cardLimitMinorUnits` is that cap when known, `null` when it could not be read.
   */
  | {
      type: 'amountExceedCardLimit';
      tokenUniqueReference: string | null;
      amountMinorUnits: number;
      cardLimitMinorUnits: number | null;
      rail: WalletPayRail;
      /** Machine-matchable, prefixed `AMOUNT_EXCEEDS_CARD_LIMIT`. */
      message: string;
    }
  /**
   * The card was added on another device (or before this app was reinstalled), and the Veyra
   * backend will not issue it payment keys on this one. Neither going online nor a smaller amount
   * helps — ask the payer to remove the card and add it again on this phone. Unlike the other two
   * this *is* a card state: the card reads `deviceNotBound: true` too.
   */
  | {
      type: 'deviceNotBound';
      tokenUniqueReference: string | null;
      amountMinorUnits: number;
      rail: WalletPayRail;
      /** Machine-matchable, prefixed `DEVICE_NOT_BOUND`. */
      message: string;
    };

/**
 * What a wallet `observeX` call returns; call `remove()` to stop that one listener. The matching
 * `stopObservingX()` removes every listener of that kind at once.
 */
export interface VeyraSubscription {
  remove(): void;
}

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
      /** ISO 4217 numeric, three digits, e.g. `'566'`. */
      currencyCode: string;
      expiresAtEpochSeconds: number;
      /**
       * The merchant's order ID, signed into the QR — what `wallet.cancelPayment` takes to cancel
       * paying this QR. `null` for a QR from an older merchant app that carries none; that payment
       * cannot be cancelled.
       */
      merchantOrderId: string | null;
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
   * What the payment **is** — `'APPROVED'`, `'DECLINED'`, `'FAILED'`, `'PENDING'` or `'NOT_SENT'`.
   * A push is a synchronous call, but it can still answer `PENDING` (a hop below the gateway timed
   * out, errored or is still settling, or the answer was lost): that means *not yet known*, never
   * refused. The SDK stores such a payment open and keeps asking until the gateway states a final
   * outcome; the row's final status shows up in the wallet's transaction history. `'NOT_SENT'` means
   * nothing was paid (refused on the phone, offline, authentication dismissed, an unknown or
   * already-used handle — `INVALID_REQUEST`…): fix the reason and pay again.
   *
   * `null` only if the gateway stated none.
   */
  responseStatus: ResponseStatus;
  /** The stated cause (`'INSUFFICIENT_FUNDS'`, `'NO_RESPONSE_RECEIVED'`, `'AUTH_CANCELLED'`…) — display and log. */
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
  /** The merchant-bank credit's identifier; `null` unless the payment was approved and the gateway sent one. */
  creditTransactionId: string | null;
  /** Whether the merchant's bank can confirm the credit at all. Settlement news only — never the outcome. */
  isCreditConfirmationSupported: boolean | null;
}

/**
 * The outcome of rendering a show-to-pay QR: `'APPROVED'` with `payload` to render, or `'NOT_SENT'`
 * with `responseStatusReason` (`ONLINE_REQUIRED`, `TOKEN_NOT_ACTIVE`, `AMOUNT_EXCEEDS_CARD_LIMIT`,
 * `AUTH_CANCELLED`, `NO_ACTIVE_CARD`…) and no QR. Nothing is sent either way — the merchant submits
 * the payment.
 */
export interface PaymentQr {
  /** Set when a QR was made. */
  tokenUniqueReference: string | null;
  /** The QR to render; `null` when none was made (`responseStatus` is not `'APPROVED'`). */
  payload: string | null;
  amountMinorUnits: number;
  /** ISO 4217 numeric, three digits, e.g. `'566'`. */
  currencyCode: string | null;
  expiresAtEpochMillis: number;
  transactionHash: string | null;
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
  message: string | null;
}

export type QrExpiredEvent = { scope: 'wallet' | 'softpos'; handle: string | null };

/**
 * A payment the app was left waiting on has resolved — the push half of
 * `softpos.getTransactions()`.
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
  status: 'APPROVED' | 'DECLINED' | 'FAILED' | 'RETRY' | string;
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

/**
 * The issuer changed a card's status — it was suspended, reactivated, expired or deactivated.
 *
 * The case this exists for: a card suspended server-side while the customer is looking at a card
 * screen. Without the event the app finds out only when it reads the card list again, which a
 * screen already on-screen never does — so the customer taps a card the UI still shows as usable.
 */
export type TokenStatusChangedEvent = {
  /** Which card. Fires per card, so check it if you hold more than one. */
  tokenUniqueReference: string;
  /** `'UNKNOWN'` for a status added to the backend after this SDK shipped. */
  status:
    | 'ACTIVE'
    | 'PENDING_ACTIVATION'
    | 'SUSPENDED'
    | 'DEACTIVATED'
    | 'EXPIRED'
    | 'UNKNOWN'
    | string;
  /** The literal as stored. For `'UNKNOWN'` this is the only thing identifying it — log this. */
  rawStatus: string;
  /**
   * Whether the card can pay right now, as the SDK's own payment gates read it.
   *
   * Branch on this rather than on `status`: it already accounts for statuses this SDK build does
   * not recognise, so you cannot end up more permissive than the gate that will refuse the tap.
   * It answers "is the card alive", not "can it pay this amount" — see {@link TokenKeyStateEvent}.
   */
  canPay: boolean;
  /** What the card held before, or null when this is its first status. */
  previousStatus: string | null;
};

/**
 * A **wallet** payment that was left `PENDING` reached its final outcome.
 *
 * The payer-side twin of {@link TransactionResolvedEvent}, which is the *merchant's* side of a
 * payment. They are separate channels on purpose: a merchant identifies a sale by the reference
 * its own app supplied, and a wallet never sees that reference — it keys on `transactionHash`.
 */
export type WalletTransactionResolvedEvent = {
  /** Identifies this payment on every rail — the value a receipt links on. */
  transactionHash: string;
  /** The card that paid. */
  tokenUniqueReference: string | null;
  /** Always one of the three finals — never `'PENDING'`. */
  status: 'APPROVED' | 'DECLINED' | 'FAILED' | 'RETRY' | string;
  /** The response code exactly as the backend sent it. */
  responseCode: string | null;
  /** Why it ended that way, e.g. `'INSUFFICIENT_FUNDS'`. Display and log it; never parse it. */
  reason: string | null;
  /** What was paid, in minor units — so you can render without a second store read. */
  amountMinorUnits: number;
  /** The merchant, as the stored row records it. */
  merchantName: string;
};

/**
 * A card ran out of payment keys, or a refresh replenished them.
 *
 * `requiresOnline` is the same value the token carries in `getTokens()` — the SDK reads one
 * function for both, so this can never contradict the list you are about to draw.
 *
 * **Covers key consumption and refresh, not expiry by clock.** Keys also expire on a timer, which
 * happens with no SDK code running, so nothing fires for it; such a card simply reads as
 * `requiresOnline` on your next card read. Keep reading the card list when a screen appears.
 */
export type TokenKeyStateEvent = {
  tokenUniqueReference: string;
  /** True when the card cannot pay until the SDK refreshes its keys. */
  requiresOnline: boolean;
  /**
   * True when the backend has refused this device payment keys for the card — it was added on
   * another device, or before this app was reinstalled. Going online cannot fix it, so
   * `requiresOnline` is `false` alongside it; prompt the user to add the card again.
   */
  deviceNotBound: boolean;
};

/**
 * The merchant's backend status changed — deactivated, suspended, or activated.
 *
 * Lets an app stop offering to take payments the moment the merchant is deactivated, rather than
 * at the next screen load; it is also how the post-registration activation moment arrives.
 */
export type MerchantStatusEvent = {
  merchantId: string;
  /** e.g. `'ACTIVE'`, `'INACTIVE'`, `'SUSPENDED'`. */
  status: string;
  /**
   * Whether the merchant may take payments now. Branch on this, not on `status` — it is the same
   * reading the SDK's payment gate uses, so you cannot be more permissive than it. Anything that
   * is not `'ACTIVE'`, including a status newer than this SDK, is false.
   */
  canAcceptPayments: boolean;
  /** What was stored before, or null when this device had no status for the merchant yet. */
  previousStatus: string | null;
};

// ── Wallet: history & receipts ────────────────────────────────────────────────

export type EntryMethod = 'TAP' | 'QR_GENERATED' | 'QR_SCANNED';

export interface TransactionSummary {
  merchantName: string;
  amountMinorUnits: number;
  /** ISO 4217 numeric, three digits, e.g. `'566'`; `null` on legacy rows. */
  currencyCode: string | null;
  transactionHash: string | null;
  /** The token that paid. */
  tokenUniqueReference: string | null;
  authorizationStatus: 'PENDING' | 'APPROVED' | 'DECLINED' | 'FAILED' | 'RETRY' | (string & {}) | null;
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
  /**
   * The merchant's own order/basket id for this sale, as the merchant's app supplied it at charge
   * time — the id the merchant's systems know the sale by. A scanned-QR (MPM) row carries it from
   * payment time; tap/CPM rows learn it from the status poll, so `null` on a still-open row means
   * "not learned yet", not "no order id". For display and reconciliation; receipts and
   * refreshes key off `transactionHash`/`merchantTransactionReference`.
   */
  merchantOrderId: string | null;
}

/**
 * The outcome of choosing the active token (`wallet.setActiveToken`) — on the phone, nothing is sent.
 * `'APPROVED'`, or `'FAILED'` with `CARD_NOT_FOUND` (not in this wallet) or `CARD_DATA_MISSING`
 * (Android: the card's payment data is not on this phone — remove it and add it again).
 */
export interface TokenSelection {
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
  message: string | null;
}

/**
 * The answer to `wallet.openPaySession` — on the phone, nothing is sent. `'APPROVED'`: tap-to-pay
 * is armed on the pay screen. `'FAILED'` (nothing changed) with `NFC_DISABLED` (turn NFC on),
 * `NFC_UNAVAILABLE` (no NFC — always on iOS, which cannot pay by tap; offer QR), `MODE_REFUSED`
 * (a SoftPOS payment is in progress) or `SCREEN_NOT_ACTIVE` (no screen in front).
 */
export interface PaySessionResult {
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
  message: string | null;
}

/**
 * The answer to `wallet.reconcilePendingTransactions` — a read, so no status of its own.
 * `failureReason` is set only when the reconcile itself could not run.
 */
export interface ReconcileResult {
  checked: boolean;
  failureReason: string | null;
  message: string | null;
}

/**
 * The outcome of scanning a merchant receipt QR (`wallet.processReceipt`) — checked on the phone,
 * nothing is sent. `'APPROVED'` with `receipt`, or `'FAILED'` with the reason: `INVALID_RECEIPT`,
 * `RECEIPT_NOT_FROM_THIS_WALLET`, `RECEIPT_MISMATCH`, `PAYMENT_NOT_CONFIRMED` (scan again shortly) or
 * `RECEIPT_FOR_ANOTHER_TRANSACTION`.
 */
export interface ReceiptScan {
  receipt: TransactionReceipt | null;
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
  message: string | null;
}

export interface TransactionReceipt {
  merchantName: string;
  merchantId: string | null;
  merchantAddress: string | null;
  transactionType: string;
  transactionStatus: string;
  transactionTime: string;
  totalAmountMinorUnits: number;
  totalAmountFormatted: string;
  /** ISO 4217 numeric, three digits, e.g. `'566'`. */
  currencyCode: string | null;
  maskedToken: string | null;
  merchantTransactionReference: string | null;
  cdcvmApprovedByWallet: boolean | null;
  transactionId: string | null;
  transactionHash: string | null;
}

// ── SoftPOS: merchant ────────────────────────────────────────────────────────────

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
  /**
   * Bank Verification Number, for either merchant type. Optional when your payment app provider is
   * registered as the account issuer; otherwise the backend refuses with `'BVN_REQUIRED'`. Blank is
   * sent as absent.
   */
  bvn?: string;
  /** Required for BUSINESS. */
  cacNumber?: string;
  /** Optional — the merchant's wallet account id, stored verbatim by the gateway. */
  walletAccountId?: string;
}

/**
 * Branch on `responseStatus`: `'APPROVED'` (registered — `merchantId` is set; the same fact as
 * `success`), `'FAILED'` (refused — `responseStatusReason` names the field or rule), `'PENDING'`
 * (sent, no usable answer — check `refreshStatus` before registering again) or `'NOT_SENT'` (never
 * reached Veyra). A missing field or an unknown `merchantType` is refused before sending: `'FAILED'` /
 * `INVALID_REQUEST`.
 */
export interface MerchantRegistrationResult {
  success: boolean;
  merchantId: string | null;
  terminalId: string | null;
  merchantStatus: MerchantStatus | string | null;
  message: string | null;
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
}

/**
 * The outcome of `softpos.refreshStatus` / `activate` / `deactivate` / `updateMerchant`. Branch on
 * `responseStatus`: `'APPROVED'` (answered — `merchantStatus` is set), `'FAILED'` (refused, e.g.
 * `MERCHANT_NOT_FOUND`; also refused on the phone, nothing sent — `MISSING_MANDATORY_CONFIG` when no
 * merchant is stored, `INVALID_REQUEST` for a missing update field) or `'PENDING'` (activate /
 * deactivate / update sent with no usable answer — read the status before trying again). A status
 * read is never `'PENDING'`.
 */
export interface MerchantStatusResult {
  merchantId: string | null;
  merchantStatus: MerchantStatus | string | null;
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
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
  /** Gateway-resolved from the payment app provider; learned from responses, never app-supplied. */
  acquirerId: string;
  merchantCategoryCode: string;
  /** The merchant's BVN, when one was supplied. */
  bvn: string | null;
  /** The business's CAC number — a `BUSINESS` merchant only. */
  cacNumber: string | null;
  terminalId: string;
  merchantStatus: MerchantStatus | string | null;
  /** The merchant's wallet account id as stored by the gateway, if any. */
  walletAccountId?: string | null;
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
  /** Optional — stored verbatim by the gateway when supplied. */
  walletAccountId?: string;
  /**
   * Optional — how an already-registered merchant supplies its BVN; absent keeps the stored one.
   * When your payment app provider is not registered as the account issuer, an update that leaves
   * the merchant with no BVN is refused with `'BVN_REQUIRED'`.
   */
  bvn?: string;
}

// ── SoftPOS: tap acceptance ───────────────────────────────────────────────────

/** One tap payment — a purchase. The same request as Android and iOS `TapRequest`. */
export interface TapRequest {
  amountMinorUnits: number;
  /** ISO 4217 numeric, e.g. '566'. Default '566'. */
  currency?: string;
  /**
   * Your own order / basket / invoice id for this sale. **Required** and non-blank — a blank one
   * ends the tap with a `'NOT_SENT'` / `INVALID_REQUEST` result before the reader arms.
   *
   * Echoed back on the result and shown on the transaction detail and receipt. An order can have
   * several attempts: reuse the order id after `DECLINED`, `FAILED`, `RETRY` or `NOT_SENT`. Once the
   * order is `APPROVED` or `PENDING`, a reused one ends the payment `94` / `FAILED` /
   * `DUPLICATE_MERCHANT_ORDER_ID` — do not take another payment for the order.
   *
   * The transaction **reference** is not yours to supply: the SDK mints it
   * (`{terminalId}-YYYYMMDDHHmmssSSS`) so the gateway can guarantee it is unique per merchant, and
   * it comes back as `merchantTransactionReference` on the result. Key receipts, status refreshes
   * and credit confirmation off that.
   */
  merchantOrderId: string;
}

/**
 * Tap acceptance events (the `onEvent` of `softpos.tap.start`) — the same names as Android `TapEvent` and iOS
 * `TapEvent`, identical on both platforms. `cardContactLost` / `unsupportedCard` mean
 * the reader stays armed for a re-tap — show a transient hint, keep the waiting screen up. Only
 * `result` (and iOS `ended`) are terminal. A tap refused before it was sent (a blank order id, the
 * other mode's payment in flight, cancelled) still ends with a `result`, whose `responseStatus` is
 * `'NOT_SENT'` — `INVALID_REQUEST`, `MODE_REFUSED`, `CANCELLED`, `CARD_READ_FAILED`….
 *
 * One iOS nuance worth knowing: `cardContactLost` there is reported when CoreNFC says the tag left
 * the field, which ends that card's dialogue — the session stays armed for a fresh tap, but the
 * interrupted attempt still reports its own `result`.
 */
export type TapEvent =
  /** A card or phone was tapped; reading it is starting. */
  | { type: 'cardDetected'; sessionId: string }
  /** Contact was lost before the card could be read — still armed, ask for a re-tap. */
  | { type: 'cardContactLost'; sessionId: string }
  /** The tapped target is not a usable payment card — still armed, ask for another card. */
  | { type: 'unsupportedCard'; sessionId: string }
  /** The card has been read; the customer can take it away. */
  | { type: 'cardReadingComplete'; sessionId: string }
  /** The payment request is being sent to the bank. */
  | { type: 'sendingRequestOnline'; sessionId: string }
  /** The bank's answer is arriving; the outcome still comes in `result`. */
  | { type: 'receivingOnlineResponse'; sessionId: string }
  /** iOS only: session ended without a payment result. */
  | {
      type: 'ended';
      sessionId: string;
      outcome: 'CANCELLED' | 'TIMEOUT' | 'ERROR' | 'UNAVAILABLE';
    }
  | { type: 'result'; sessionId: string; result: TapResult };

/** The outcome of a tap payment, carried by the `result` {@link TapEvent}. */
export interface TapResult {
  /**
   * The response code as reported for this tap. Branch on `responseStatus`, never on this: a
   * `'06'`, `'68'` or `'96'` with `'PENDING'` means the outcome is unknown and the sale must not be
   * re-charged — it is not a failure. `null` on `'NOT_SENT'` (nothing went on the wire).
   */
  responseCode: string | null;
  /**
   * The outcome — what you branch on: `'APPROVED'`, `'DECLINED'`, `'FAILED'`, `'PENDING'`, `'RETRY'`
   * or `'NOT_SENT'` (the payment never reached the gateway — retry with the **same** order id).
   */
  responseStatus: ResponseStatus;
  /** Why it ended as it did (`'INSUFFICIENT_FUNDS'`, `'CANCELLED'`, `'NO_NETWORK_CONNECTION'`…). */
  responseStatusReason: string | null;
  message: string | null;
  /** The amount tapped, in minor units. */
  amountMinorUnits: number | null;
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
   * and fires `softpos.observeCreditConfirmation` — show a "confirming credit…" state on the result
   * screen and flip it from that event. `false`/`null` means there is nothing to wait for.
   */
  isCreditConfirmationSupported: boolean | null;
  /**
   * On a `DUPLICATE_MERCHANT_ORDER_ID` refusal, the payment already holding the order id: its
   * `responseStatus` says whether the order is already paid (`'APPROVED'`) or still being confirmed
   * (`'PENDING'`). Do not take another payment for the order either way. `null` otherwise.
   */
  originalPayment: OriginalPayment | null;
}

/**
 * The payment that already holds a merchant order id, carried on a `'FAILED'` /
 * `DUPLICATE_MERCHANT_ORDER_ID` refusal from a card tap, a customer-QR charge or a merchant QR.
 * `null` on the refusal when the gateway could not read it (two attempts raced for the order id).
 */
export interface OriginalPayment {
  /** The original payment's wire code, e.g. `00`. For receipts and support only. */
  responseCode: string | null;
  /** `'APPROVED'` (already paid), `'PENDING'` (still being confirmed), `'DECLINED'` or `'FAILED'`. */
  responseStatus: string | null;
  /** Why the original payment ended as it did, e.g. `INSUFFICIENT_FUNDS`. */
  responseStatusReason: string | null;
  amountMinorUnits: number | null;
  merchantTransactionReference: string | null;
  transactionId: string | null;
}

// ── SoftPOS: QR rails ─────────────────────────────────────────────────────────

/**
 * The outcome of creating a get-paid QR: `'APPROVED'` (render `mpmPayload`), `'FAILED'` (the
 * gateway refused it — e.g. `DUPLICATE_MERCHANT_ORDER_ID`), `'PENDING'` (sent, no usable answer —
 * create a new QR) or `'NOT_SENT'` (never reached the gateway — `INVALID_REQUEST` for a blank order
 * id, `MISSING_MANDATORY_CONFIG` when no merchant is registered…; retry with the same order id).
 * `txRef` and `mpmPayload` are set only on `'APPROVED'`.
 */
export interface PaymentContextQr {
  txRef: string | null;
  mpmPayload: string | null;
  expiry: string | null;
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
  message: string | null;
  /**
   * On a `DUPLICATE_MERCHANT_ORDER_ID` refusal, the payment already holding the order id: its
   * `responseStatus` says whether the order is already paid (`'APPROVED'`) or still being confirmed
   * (`'PENDING'`). Do not take another payment for the order either way. `null` otherwise.
   */
  originalPayment: OriginalPayment | null;
}

export interface PaymentContextStatus {
  txRef: string;
  state: 'PENDING' | 'IN_FLIGHT' | 'APPROVED' | 'DECLINED' | 'EXPIRED' | 'RETRY' | (string & {});
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
  /** ISO 4217 numeric, three digits, e.g. `'566'`. */
  currencyCode: string;
  /**
   * The paying card's display name (EMV tag `5F20`), e.g. `AFRIGO ****1234` — the same value a
   * tap presents. `null` when the QR carries none.
   *
   * Display only: unlike the amount and currency it rides outside the QR's cryptogram, so show it
   * on the confirm screen and receipt but never branch a payment decision on it.
   */
  cardholderName: string | null;
}

/**
 * The outcome of inspecting a scanned customer QR: `'APPROVED'` with `qr` — show its amount for the
 * merchant to confirm — or `'FAILED'` / `INVALID_REQUEST` when the payload is not a Veyra payment
 * QR (show a transient hint and stay armed). Nothing is sent either way.
 */
export interface CustomerQrInspection {
  qr: ScannedCustomerQr | null;
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
  message: string | null;
}

/**
 * The outcome of charging a scanned customer QR — branch on `responseStatus` (see
 * {@link ResponseStatus}): `'NOT_SENT'` means the order id is unused (an unknown or already-used
 * handle is `'NOT_SENT'` / `INVALID_REQUEST`).
 */
export interface CustomerQrChargeOutcome {
  /** `true` only when `responseStatus` is `'APPROVED'` — never worked out from the code. */
  approved: boolean;
  responseStatus: ResponseStatus;
  /** Why it ended as it did (`'INSUFFICIENT_FUNDS'`, `'NO_RESPONSE_RECEIVED'`…). Show and log. */
  responseStatusReason: string | null;
  /** The wire code (`'00'`, `'51'`, `'68'`…) — for receipts and support, never to branch on. `null` on `'NOT_SENT'`. */
  responseCode: string | null;
  /** A human-readable description, for logs. */
  message: string | null;
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
   * credit…" state on the result screen and flip it from `softpos.observeCreditConfirmation`
   * or the re-read row (`creditConfirmationStatus`).
   */
  isCreditConfirmationSupported: boolean | null;
  /**
   * On a `DUPLICATE_MERCHANT_ORDER_ID` refusal, the payment already holding the order id: its
   * `responseStatus` says whether the order is already paid (`'APPROVED'`) or still being confirmed
   * (`'PENDING'`). Do not take another payment for the order either way. `null` otherwise.
   */
  originalPayment: OriginalPayment | null;
}

// ── SoftPOS: transactions & receipts ──────────────────────────────────────────

/** One payment attempt made under a merchant order id. */
export interface OrderPaymentAttempt {
  merchantTransactionReference: string | null;
  transactionId: string | null;
  amountMinorUnits: number | null;
  /** The wire code — receipts and support only. */
  responseCode: string | null;
  /** `'APPROVED'`, `'DECLINED'`, `'FAILED'`, `'PENDING'` or `'RETRY'`. */
  responseStatus: ResponseStatus | null;
  responseStatusReason: string | null;
}

/**
 * What happened to a merchant order (`softpos.paymentStatus`). Branch on `responseStatus`:
 * `'APPROVED'` — paid, never take another payment; `'PENDING'` — may have moved money, never retry;
 * `'DECLINED'` / `'FAILED'` / `'RETRY'` — no money moved, pay again with the **same** order id. The
 * other top-level fields are the deciding attempt's; `attempts` lists them all, newest first.
 */
export interface OrderPaymentStatus {
  merchantOrderId: string;
  responseStatus: ResponseStatus;
  responseStatusReason: string | null;
  responseCode: string | null;
  merchantTransactionReference: string | null;
  transactionId: string | null;
  amountMinorUnits: number | null;
  attempts: OrderPaymentAttempt[];
  /** `'DEVICE'` (this device's own final record) or `'GATEWAY'`. */
  answeredBy: 'DEVICE' | 'GATEWAY' | (string & {});
}

export interface MerchantTransaction {
  merchantTransactionReference: string;
  /**
   * Your own order / basket / invoice id for this sale, echoed back, or null when none was
   * supplied (and on every sale recorded before it existed). Display it and reconcile with it; key
   * receipts and status refreshes off `merchantTransactionReference`.
   */
  merchantOrderId: string | null;
  amountMinorUnits: number;
  status: 'APPROVED' | 'DECLINED' | 'PENDING' | 'FAILED' | 'RETRY' | (string & {});
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

/**
 * The gateway's own record of one of the stored merchant's transactions
 * (`softpos.getTransactionStatus`). A raw read: it writes nothing to the stored row.
 */
export interface TransactionStatus {
  merchantTransactionReference: string;
  merchantId: string;
  /** In minor units; `null` on a not-found answer (`25`), where the gateway holds no transaction. */
  amountMinorUnits: number | null;
  /** The wire code — for receipts and support, never to branch on. */
  responseCode: string;
  /** The payment's outcome as the gateway stated it — what you branch on. `null` from an older gateway. */
  responseStatus: ResponseStatus | null;
  /** Why it ended as it did, e.g. `UNABLE_TO_LOCATE_RECORD`. */
  responseStatusReason: string | null;
  merchantStatus: MerchantStatus | string | null;
  transactionId: string | null;
  /** The merchant-bank credit's identifier — sent when the transaction is approved. */
  creditTransactionId: string | null;
  /** Whether the merchant's bank can confirm the credit at all — the gate for `getCreditConfirmation`. */
  isCreditConfirmationSupported: boolean | null;
}

/**
 * The merchant bank's answer to `softpos.getCreditConfirmation` — has an approved sale's money
 * arrived? Settlement news only: it never changes the payment's outcome.
 */
export interface CreditConfirmation {
  creditTransactionId: string;
  /** `'RECEIVED'` is final; anything else means ask again later. */
  status: 'RECEIVED' | (string & {});
  /** Credited amount in minor units, as the bank reported it. */
  amountMinorUnits: number | null;
  /** When the bank posted the credit (ISO date-time). */
  creditedAt: string | null;
  /** The bank's own reference for the credit. */
  bankReference: string | null;
  message: string | null;
}
