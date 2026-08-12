import type { EmitterSubscription } from 'react-native';
import { nativeCall } from './errors';
import { Events, VeyraNative, veyraEmitter } from './native';
import type {
  ActivateResponse,
  ActivationCodeResponse,
  ActivationEvent,
  ActivationMedium,
  ActivationReason,
  Bank,
  Card,
  CardKeyStateEvent,
  CardStatus,
  DigitiseParams,
  DigitiseResult,
  PaymentOutcome,
  PaymentQr,
  QrExpiredEvent,
  ScanInspection,
  TokenStatusChangedEvent,
  TransactionReceipt,
  TransactionSummary,
  VerifyAccountParams,
  VerifyAccountResponse,
  WalletTapEvent,
  WalletTransactionResolvedEvent,
} from './types';

/** Wallet (Pay) domain — add card, activation, card states, payments, history. */
export const wallet = {
  // ── Add card / digitise ────────────────────────────────────────────────────

  getBanks(accountNumber?: string): Promise<Bank[]> {
    return nativeCall(() => VeyraNative.walletGetBanks(accountNumber ?? null));
  },

  verifyAccount(params: VerifyAccountParams): Promise<VerifyAccountResponse> {
    return nativeCall(() => VeyraNative.walletVerifyAccount(params));
  },

  digitise(params: DigitiseParams): Promise<DigitiseResult> {
    return nativeCall(() => VeyraNative.walletDigitise(params));
  },

  // ── Activation ─────────────────────────────────────────────────────────────

  requestActivationCode(
    tokenUniqueReference: string,
    medium: ActivationMedium,
    contact: string | null = null,
    reason: ActivationReason = 'ADD_CARD'
  ): Promise<ActivationCodeResponse> {
    return nativeCall(() =>
      VeyraNative.walletRequestActivationCode(tokenUniqueReference, medium, contact, reason)
    );
  },

  activate(tokenUniqueReference: string, activationCode: string): Promise<ActivateResponse> {
    return nativeCall(() => VeyraNative.walletActivate(tokenUniqueReference, activationCode));
  },

  /** One-shot server check: true when the token is active. */
  checkTokenActive(tokenUniqueReference: string): Promise<boolean> {
    return nativeCall(() => VeyraNative.walletCheckTokenActive(tokenUniqueReference));
  },

  /**
   * One-shot server check, five-valued: lets the app explain a non-payable card —
   * SUSPENDED ("call your bank") vs PENDING_ACTIVATION ("enter your code") vs EXPIRED
   * ("re-add the card"). Values this build does not know pass through verbatim.
   */
  tokenStatus(tokenUniqueReference: string): Promise<CardStatus | string> {
    return nativeCall(() => VeyraNative.walletTokenStatus(tokenUniqueReference));
  },

  /**
   * Polls activation (every 10s, ≤5min) and emits on the activation event channel.
   * Re-observing the same token replaces the prior observer. Subscribe with
   * {@link onActivationEvent}.
   */
  observeActivation(tokenUniqueReference: string): Promise<void> {
    return nativeCall(() => VeyraNative.walletObserveActivation(tokenUniqueReference));
  },

  pauseActivationObserver(tokenUniqueReference: string): Promise<void> {
    return nativeCall(() => VeyraNative.walletPauseActivationObserver(tokenUniqueReference));
  },

  resumeActivationObserver(tokenUniqueReference: string): Promise<void> {
    return nativeCall(() => VeyraNative.walletResumeActivationObserver(tokenUniqueReference));
  },

  stopActivationObserver(tokenUniqueReference: string): Promise<void> {
    return nativeCall(() => VeyraNative.walletStopActivationObserver(tokenUniqueReference));
  },

  onActivationEvent(listener: (e: ActivationEvent) => void): EmitterSubscription {
    return veyraEmitter.addListener(Events.activation, listener);
  },

  // ── Cards ──────────────────────────────────────────────────────────────────

  getCards(): Promise<Card[]> {
    return nativeCall(() => VeyraNative.walletGetCards());
  },

  getActiveCard(): Promise<Card | null> {
    return nativeCall(() => VeyraNative.walletGetActiveCard());
  },

  /**
   * Selects the active card. On Android this also arms tap-to-pay for it, so it
   * requires an open pay session (`SESSION_REQUIRED` otherwise); tap outcomes
   * arrive via {@link onTapEvent}. On iOS it only marks the card active.
   */
  setActiveCard(cardId: string): Promise<void> {
    return nativeCall(() => VeyraNative.walletSetActiveCard(cardId));
  },

  /** Deactivates the token server-side and removes the card. */
  deactivateCard(tokenUniqueReference: string): Promise<void> {
    return nativeCall(() => VeyraNative.walletDeactivateCard(tokenUniqueReference));
  },

  /** Android-only tap-to-pay outcome stream (armed via {@link setActiveCard}). */
  onTapEvent(listener: (e: WalletTapEvent) => void): EmitterSubscription {
    return veyraEmitter.addListener(Events.walletTap, listener);
  },

  // ── Scan-to-pay (MPM) ──────────────────────────────────────────────────────

  /** Inspect a scanned merchant QR. Verified contexts are held natively (opaque handle). */
  inspectScannedQr(payload: string): Promise<ScanInspection> {
    return nativeCall(() => VeyraNative.walletInspectScannedQr(payload));
  },

  // `authenticateForPayment` was removed. The SDK raises the device
  // authentication sheet itself from inside `payScannedContext` and `showQrToPay`, so there is
  // nothing to call first and no way to forget. Cancel/failure surface as AUTH_CANCELLED /
  // AUTH_FAILED / AUTH_UNAVAILABLE on those calls.

  payScannedContext(handle: string): Promise<PaymentOutcome> {
    return nativeCall(() => VeyraNative.walletPayScannedContext(handle));
  },

  // ── Show-QR-to-pay (CPM) ───────────────────────────────────────────────────

  /**
   * Renders a payment QR for the active card. Expiry fires once on the qr-expired
   * channel ({@link onQrExpired}); a new render supersedes the old.
   */
  showQrToPay(amountMinorUnits: number): Promise<PaymentQr> {
    return nativeCall(() => VeyraNative.walletShowQrToPay(amountMinorUnits));
  },

  cancelQrExpiry(): Promise<void> {
    return nativeCall(() => VeyraNative.walletCancelQrExpiry());
  },

  onQrExpired(listener: (e: QrExpiredEvent) => void): EmitterSubscription {
    return veyraEmitter.addListener(Events.qrExpired, (e: QrExpiredEvent) => {
      if (e.scope === 'wallet') listener(e);
    });
  },

  // ── The SDK tells you when stored truth changes ────────────────────────────

  /**
   * Fires when the issuer changes a card's status — suspended, reactivated, expired, deactivated.
   *
   * Subscribe **once, at start-up**, not per card screen: it fires for any stored card, including
   * ones no screen is showing, and that is the case that matters. An issuer suspending a card
   * while the customer is looking at it is otherwise invisible until something makes the app read
   * the card list again.
   *
   * Branch on `canPay`, not on `status`. There is no replay — read `getCards()` at start-up.
   */
  onTokenStatusChanged(
    listener: (e: TokenStatusChangedEvent) => void
  ): EmitterSubscription {
    return veyraEmitter.addListener(Events.tokenStatusChanged, listener);
  },

  /**
   * Fires when a wallet payment that was left `PENDING` reaches its final outcome — from the
   * SDK's background sweep, an on-demand status check, or the scan-to-pay push.
   *
   * Match the event to its payment by `transactionHash`. Subscribe once, at start-up: a payment
   * can settle days later, long after the screen that made it is gone. No replay, so a screen
   * still reads `getTransactions()` when it appears.
   */
  onTransactionResolved(
    listener: (e: WalletTransactionResolvedEvent) => void
  ): EmitterSubscription {
    return veyraEmitter.addListener(Events.walletTransactionResolved, listener);
  },

  /**
   * Fires when a card runs out of payment keys, or a refresh gives it new ones — `requiresOnline`
   * flipping.
   *
   * Covers key **consumption** and **refresh** only. Keys also expire by clock, with no SDK code
   * running, so nothing fires for that; such a card reads as `requiresOnline` on your next
   * `getCards()`. Do not word your UI as though this were live coverage of every case.
   *
   * Observation only — there is deliberately no API to trigger a key refresh.
   */
  onCardKeyStateChanged(
    listener: (e: CardKeyStateEvent) => void
  ): EmitterSubscription {
    return veyraEmitter.addListener(Events.cardKeyState, listener);
  },

  // ── History & receipts ─────────────────────────────────────────────────────

  getTransactions(tokenUniqueReference: string, limit = 50): Promise<TransactionSummary[]> {
    return nativeCall(() => VeyraNative.walletGetTransactions(tokenUniqueReference, limit));
  },

  /** Refreshes PENDING rows against the backend. */
  reconcilePendingTransactions(): Promise<void> {
    return nativeCall(() => VeyraNative.walletReconcilePendingTransactions());
  },

  /**
   * Ask the backend about **one** pending transaction now, keyed by its transaction hash, and
   * resolve with the updated stored row.
   *
   * The per-transaction counterpart to `reconcilePendingTransactions`, which asks about every open
   * row and resolves with nothing — this one answers about the row the customer is looking at. The
   * SDK polls a pending transaction for you with exponential backoff and **stops after 30 days**;
   * this is how a customer gets an answer sooner than the next rung, and the only route to one once
   * that window has closed.
   *
   * Runs the SDK's own background sweep for this single row — same query, same reading of the
   * answer, same write into the same local history — so an on-demand check and a background check
   * cannot disagree. It is **not** a way to force an outcome: a payment that is still unsettled
   * answers `PENDING` again.
   *
   * Resolves `null` when no row on this device carries that hash; a row that already has a final
   * outcome comes back unchanged without a network call. Rejects with `NO_NETWORK_CONNECTION` when
   * the device is offline — a failed check never changes the stored row.
   */
  refreshTransactionStatus(transactionHash: string): Promise<TransactionSummary | null> {
    return nativeCall(() => VeyraNative.walletRefreshTransactionStatus(transactionHash));
  },

  /**
   * Check the merchant credit **now** for one approved payment — "has the merchant's bank actually
   * received the funds I paid?" — and resolve with the updated stored row.
   *
   * The SDK already asks this in the background, with exponential backoff, for **30 days** after the
   * payment, and then records the row as `'UNABLE_TO_CONFIRM'` — which means *"we stopped asking"*,
   * never *"the merchant was not paid"*. This is how a customer gets an answer sooner than the next
   * rung, and the only route to one once that window has closed: it still works on a row already
   * marked `'UNABLE_TO_CONFIRM'`, and a later `'RECEIVED'` replaces that give-up.
   *
   * **Check `isCreditConfirmationSupported` on the transaction first.** Not every merchant's bank is
   * on the confirmation rail. Offer the action only while
   * ```ts
   * txn.authorizationStatus === 'APPROVED' &&
   *   txn.isCreditConfirmationSupported === true &&
   *   txn.creditConfirmationStatus !== 'RECEIVED'
   * ```
   * A call on a row that fails that predicate makes **no network request** and resolves with the row
   * unchanged rather than rejecting.
   *
   * Settlement only: nothing on this path can change the payment's `authorizationStatus`,
   * `responseCode` or `responseStatusReason`. There is deliberately no event beside it — the
   * resolved row and the SDK's stored history are the whole surface.
   *
   * Resolves `null` when no row on this device carries that hash. Rejects with
   * `NO_NETWORK_CONNECTION` when the device is offline — a failed check never changes the stored row.
   */
  refreshCreditConfirmation(transactionHash: string): Promise<TransactionSummary | null> {
    return nativeCall(() => VeyraNative.walletRefreshCreditConfirmation(transactionHash));
  },

  /** Verifies and stores a merchant receipt QR scanned by the customer. */
  processReceipt(
    qrPayload: string,
    expectedTransactionHash: string | null = null
  ): Promise<TransactionReceipt> {
    return nativeCall(() => VeyraNative.walletProcessReceipt(qrPayload, expectedTransactionHash));
  },

  getReceipts(limit = 100): Promise<TransactionReceipt[]> {
    return nativeCall(() => VeyraNative.walletGetReceipts(limit));
  },

  getReceiptForTransaction(transactionHash: string): Promise<TransactionReceipt | null> {
    return nativeCall(() => VeyraNative.walletGetReceiptForTransaction(transactionHash));
  },
};
