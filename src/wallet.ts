import { Platform, type EmitterSubscription } from 'react-native';
import { cancelCall, nativeCall, VeyraError } from './errors';
import { Events, VeyraNative, veyraEmitter } from './native';
import { activationRegistry, observerKind, oneShotSlot } from './observers';
import type {
  ActivateResponse,
  TokenStatusUpdateResponse,
  ActivationCodeResponse,
  ActivationMedium,
  ActivationReason,
  BankList,
  CancelResult,
  TokenKeyStateEvent,
  DigitiseParams,
  DigitiseResult,
  PaymentOutcome,
  PaymentQr,
  QrExpiredEvent,
  ScanInspection,
  Token,
  TokenStatusChangedEvent,
  TokenStatusResult,
  TransactionReceipt,
  TokenSelection,
  PaySessionResult,
  ReceiptScan,
  ReconcileResult,
  TransactionSummary,
  VerifyAccountParams,
  VerifyAccountResponse,
  VeyraLookup,
  VeyraSubscription,
  WalletPaymentRefusal,
  WalletTapEvent,
  WalletTransactionResolvedEvent,
} from './types';

/**
 * Per-card refusal listeners.
 *
 * The native side registers per card, so a refusal only crosses the bridge for a card someone is
 * listening to. This keeps the JS-side fan-out: one emitter subscription for the channel, opened
 * when the first card is observed and closed when the last goes, dispatching by the refusal's own
 * `tokenUniqueReference`. An unattributed refusal (`null`) goes to every listener, matching what
 * the native SDKs do — the payer was refused either way.
 */
const refusalListeners = (() => {
  const byToken = new Map<string, Set<(r: WalletPaymentRefusal) => void>>();
  let channel: EmitterSubscription | null = null;

  const openChannel = () => {
    if (channel) return;
    channel = veyraEmitter.addListener(
      Events.paymentRefusal,
      (refusal: WalletPaymentRefusal) => {
        const targets =
          refusal.tokenUniqueReference == null
            ? Array.from(byToken.values())
            : [byToken.get(refusal.tokenUniqueReference)];
        for (const set of targets) {
          // Copy before iterating: a listener may remove itself while being called.
          if (set) for (const l of Array.from(set)) l(refusal);
        }
      }
    );
  };

  const closeChannelIfIdle = () => {
    if (byToken.size === 0 && channel) {
      channel.remove();
      channel = null;
    }
  };

  return {
    /**
     * Arm the native registration again for every card that still has a JS listener. Called
     * after each `Veyra.initialize`: signing a customer out or switching customer drops every
     * native registration, while JS listeners (a screen that stayed mounted) survive — without
     * this they would never hear another refusal, because only a card's *first* listener arms.
     */
    rearm(): void {
      for (const tokenUniqueReference of byToken.keys()) {
        void nativeCall(() =>
          VeyraNative.walletObservePaymentRefusals(tokenUniqueReference)
        ).catch(() => {});
      }
    },

    /** Remove every listener for one card and release its native registration. */
    removeAll(tokenUniqueReference: string): void {
      if (!byToken.delete(tokenUniqueReference)) return;
      void nativeCall(() =>
        VeyraNative.walletStopObservingPaymentRefusals(tokenUniqueReference)
      ).catch(() => {});
      closeChannelIfIdle();
    },

    add(
      tokenUniqueReference: string,
      listener: (r: WalletPaymentRefusal) => void
    ): VeyraSubscription {
      openChannel();
      let set = byToken.get(tokenUniqueReference);
      if (!set) {
        set = new Set();
        byToken.set(tokenUniqueReference, set);
        // First listener for this card — arm the native registration.
        void nativeCall(() =>
          VeyraNative.walletObservePaymentRefusals(tokenUniqueReference)
        ).catch(() => {
          // A failed arm must not throw from a listener registration; the listener simply
          // never fires, exactly as it would for a card the SDK does not know.
        });
      }
      set.add(listener);
      const registeredIn = set;

      let removed = false;
      return {
        remove() {
          if (removed) return; // remove() is idempotent, as EmitterSubscription's is
          removed = true;
          const current = byToken.get(tokenUniqueReference);
          // Gone already (stopObservingPaymentRefusals) — a later registration for the same card
          // is a different set, and this subscription must not remove from it.
          if (current !== registeredIn || !current.has(listener)) return;
          current.delete(listener);
          if (current.size === 0) {
            byToken.delete(tokenUniqueReference);
            void nativeCall(() =>
              VeyraNative.walletStopObservingPaymentRefusals(tokenUniqueReference)
            ).catch(() => {});
            closeChannelIfIdle();
          }
        },
      };
    },
  };
})();

const activations = activationRegistry(veyraEmitter, Events.activation);
const tapEvents = observerKind<WalletTapEvent>(veyraEmitter, Events.walletTap);
/** The `onExpired` of the wallet QR most recently rendered by `showQrToPay`. */
const qrExpiry = oneShotSlot<QrExpiredEvent>(veyraEmitter, Events.qrExpired, (e) => e.scope === 'wallet');
const tokenStatusEvents = observerKind<TokenStatusChangedEvent>(
  veyraEmitter,
  Events.tokenStatusChanged
);
const transactionResolvedEvents = observerKind<WalletTransactionResolvedEvent>(
  veyraEmitter,
  Events.walletTransactionResolved
);
const tokenKeyStateEvents = observerKind<TokenKeyStateEvent>(veyraEmitter, Events.tokenKeyState);

function requireAndroidTap(): void {
  if (Platform.OS !== 'android') {
    throw new VeyraError(
      'UNSUPPORTED_ON_PLATFORM',
      'Wallet tap-to-pay is not available on iOS — observe wallet tap events on Android only'
    );
  }
}

/**
 * Wallet (Pay) domain — add card, activation, card states, payments, history.
 *
 * Every operation resolves with its outcome — branch on `responseStatus`, then
 * `responseStatusReason`. A promise rejects only with a setup error (`VeyraError`).
 */
export const wallet = {
  // ── Add card / digitise ────────────────────────────────────────────────────

  /** The banks a card can be added from — `banks` on `'APPROVED'`, else the reason there are none. */
  getBanks(accountNumber?: string): Promise<BankList> {
    return nativeCall(() => VeyraNative.walletGetBanks(accountNumber ?? null));
  },

  verifyAccount(params: VerifyAccountParams): Promise<VerifyAccountResponse> {
    return nativeCall(() => VeyraNative.walletVerifyAccount(params));
  },

  /**
   * Adds a card. Pass your own `clientRequestId` in `params` to be able to cancel it with
   * {@link cancelDigitise}; without one the request cannot be cancelled.
   */
  digitise(params: DigitiseParams): Promise<DigitiseResult> {
    return nativeCall(() => VeyraNative.walletDigitise(params));
  },

  /**
   * Cancels the add-card ({@link digitise}) started with `clientRequestId`. Answers at once with a
   * {@link CancelResult}:
   *
   * - `'CANCELLED'` — nothing was sent; `digitise` resolves `'NOT_SENT'` / `CANCELLED`, and the same
   *   `clientRequestId` can be used again.
   * - `'TOO_LATE_TO_CANCEL_REQUEST_ALREADY_SENT'` — the request has left the device; `digitise`
   *   resolves with its normal result (an approved card is stored as usual). Tell the user it can
   *   no longer be cancelled and keep waiting.
   * - `'NO_DIGITISATION_IN_PROGRESS_FOR_CLIENT_REQUEST_ID'` — no add-card with that ID is running
   *   (wrong ID, started without one, or already finished).
   */
  cancelDigitise(clientRequestId: string): Promise<CancelResult> {
    return cancelCall(() => VeyraNative.walletCancelDigitise(clientRequestId));
  },

  /**
   * Deactivates, on the server, the token that the {@link digitise} sent with `clientRequestId`
   * created — for a digitise that ended `'FAILED'` with `NO_RESPONSE_RECEIVED` or `UPSTREAM_ERROR`
   * after it was sent, whose token details never reached this device. Only this device can do it.
   * The same call and shape as Android's and iOS's `deactivateDigitise`:
   *
   * - `'APPROVED'` — deactivated (or already was); `tokenUniqueReference` names it. If that card is
   *   on this device, it is removed with its data.
   * - `'FAILED'` / `NO_TOKEN_CREATED` — the digitise ended before a token was created.
   * - `'FAILED'` / `DIGITISATION_NOT_FOUND` — no finished digitise with that id from this device. One
   *   still running is not found until it ends: call again after it would have timed out.
   * - `'PENDING'` — sent, no usable answer; call again (a repeat is harmless).
   *
   * {@link DigitiseResult.clientRequestId} holds the id, including one the SDK generated.
   */
  deactivateDigitise(clientRequestId: string): Promise<TokenStatusUpdateResponse> {
    return nativeCall(() => VeyraNative.walletDeactivateDigitise(clientRequestId));
  },

  // ── Activation ─────────────────────────────────────────────────────────────

  /**
   * Asks the issuer to send an activation code by `medium` — one of the token's
   * `activationMethods[].medium`. The issuer sends it to the contact it holds for that medium.
   */
  requestActivationCode(
    tokenUniqueReference: string,
    medium: ActivationMedium,
    reason: ActivationReason = 'ADD_CARD'
  ): Promise<ActivationCodeResponse> {
    return nativeCall(() =>
      VeyraNative.walletRequestActivationCode(tokenUniqueReference, medium, reason)
    );
  },

  activate(tokenUniqueReference: string, activationCode: string): Promise<ActivateResponse> {
    return nativeCall(() => VeyraNative.walletActivate(tokenUniqueReference, activationCode));
  },

  /**
   * One-shot server check, five-valued: lets the app explain a non-payable card —
   * SUSPENDED ("call your bank") vs PENDING_ACTIVATION ("enter your code") vs EXPIRED
   * ("re-add the card"). `tokenStatus` on `'APPROVED'`; values this build does not know pass
   * through verbatim. A check that could not be made is `'FAILED'` / `'NOT_SENT'` with the reason.
   */
  tokenStatus(tokenUniqueReference: string): Promise<TokenStatusResult> {
    return nativeCall(() => VeyraNative.walletTokenStatus(tokenUniqueReference));
  },

  /**
   * Watches a token until it is activated — polling every 10s for up to 5 minutes — and calls back
   * once: `onActivated` when it is, `onTimeout` when 5 minutes pass first, `onError` when the
   * check fails. The same callbacks as the Android and iOS SDKs.
   *
   * Each callback ends the observation. Re-observing the same token replaces the earlier callbacks
   * (and restarts the 5-minute clock); {@link pauseActivationObserver} / {@link resumeActivationObserver}
   * keep them; {@link stopActivationObserver}, `Veyra.signOut` and a `Veyra.initialize` that switches
   * customer drop them (a same-customer `initialize` keeps them).
   */
  observeActivation(
    tokenUniqueReference: string,
    onActivated: () => void,
    onTimeout: () => void,
    onError?: (message: string) => void
  ): Promise<void> {
    // Registered before the native call so the first poll's answer can never arrive unheard.
    const registration = activations.set(tokenUniqueReference, { onActivated, onTimeout, onError });
    return nativeCall<void>(() => VeyraNative.walletObserveActivation(tokenUniqueReference)).catch((e) => {
      // Not observing after all — drop these callbacks, unless a newer observe replaced them.
      activations.release(tokenUniqueReference, registration);
      throw e;
    });
  },

  pauseActivationObserver(tokenUniqueReference: string): Promise<void> {
    return nativeCall(() => VeyraNative.walletPauseActivationObserver(tokenUniqueReference));
  },

  resumeActivationObserver(tokenUniqueReference: string): Promise<void> {
    return nativeCall(() => VeyraNative.walletResumeActivationObserver(tokenUniqueReference));
  },

  /** Stops watching the token; its {@link observeActivation} callbacks are dropped and never fire. */
  stopActivationObserver(tokenUniqueReference: string): Promise<void> {
    activations.release(tokenUniqueReference);
    return nativeCall(() => VeyraNative.walletStopActivationObserver(tokenUniqueReference));
  },

  /** Whether an activation observer is running for this token ({@link observeActivation}). */
  hasActivationObserver(tokenUniqueReference: string): Promise<boolean> {
    return nativeCall(() => VeyraNative.walletHasActivationObserver(tokenUniqueReference));
  },

  // ── Tokens ─────────────────────────────────────────────────────────────────

  /** Every token (card) stored in this wallet. Local read — no network call. */
  getTokens(): Promise<Token[]> {
    return nativeCall(() => VeyraNative.walletGetTokens());
  },

  /** The token selected with {@link setActiveToken}, or `null` when none is. */
  getActiveToken(): Promise<Token | null> {
    return nativeCall(() => VeyraNative.walletGetActiveToken());
  },

  /** One stored token, or `null` when no token on this device has that reference. */
  getToken(tokenUniqueReference: string): Promise<Token | null> {
    return nativeCall(() => VeyraNative.walletGetToken(tokenUniqueReference));
  },

  /**
   * Selects the active token. Requires an open pay session on both platforms
   * (`SESSION_REQUIRED` otherwise). On Android this also arms tap-to-pay for it; tap
   * events arrive via {@link observeTapEvents}. On iOS it marks the token the QR rails pay with.
   *
   * Resolves a {@link TokenSelection}: `'APPROVED'`, or `'FAILED'` with `CARD_NOT_FOUND` (not in this
   * wallet) or `CARD_DATA_MISSING` (Android: remove the card and add it again). Rejects only on a
   * setup error.
   */
  setActiveToken(tokenUniqueReference: string): Promise<TokenSelection> {
    return nativeCall(() => VeyraNative.walletSetActiveToken(tokenUniqueReference));
  },

  /**
   * Arms tap-to-pay on the pay screen — the same call as Android's and iOS's `openPaySession`.
   * Mount {@link usePaySession} on the pay screen as before; use this to re-arm within it, for example
   * after {@link closePaySession} on a timeout. While the session is open the screen stays awake.
   *
   * Resolves a {@link PaySessionResult}: `'APPROVED'`, or `'FAILED'` (nothing changed) with
   * `NFC_DISABLED`, `NFC_UNAVAILABLE` (always on iOS — no tap-to-pay there), `MODE_REFUSED` or
   * `SCREEN_NOT_ACTIVE`. Rejects only on a setup error.
   */
  openPaySession(): Promise<PaySessionResult> {
    return nativeCall(() => VeyraNative.walletOpenPaySession());
  },

  /**
   * Disarms tap-to-pay at once — on Cancel, on your own countdown expiring, or when leaving the pay
   * screen. A terminal tapping the phone then gets "application not found"; a tap already under way
   * finishes. Safe with no session open. A no-op on iOS.
   */
  closePaySession(): Promise<void> {
    return nativeCall(() => VeyraNative.walletClosePaySession());
  },

  /** Whether tap-to-pay is armed on the pay screen. Always `false` on iOS. */
  isPaySessionOpen(): Promise<boolean> {
    return nativeCall(() => VeyraNative.walletIsPaySessionOpen());
  },

  /**
   * Deactivates the token server-side and removes the card, returning the backend's answer —
   * the same call and the same shape as Android's `deactivateToken` and iOS's
   * `tokenisation.deactivateToken`.
   */
  deactivateToken(
    tokenUniqueReference: string
  ): Promise<TokenStatusUpdateResponse> {
    return nativeCall(() => VeyraNative.walletDeactivateToken(tokenUniqueReference));
  },

  /**
   * Android-only tap-to-pay event stream (armed via {@link setActiveToken}).
   *
   * Throws `VeyraError` `UNSUPPORTED_ON_PLATFORM` on iOS, which has no tap-to-pay: a listener that
   * could never fire would be a silent no-op. Observe only where `Platform.OS === 'android'`.
   */
  observeTapEvents(listener: (e: WalletTapEvent) => void): VeyraSubscription {
    requireAndroidTap();
    return tapEvents.observe(listener);
  },

  /** Removes every {@link observeTapEvents} listener. Throws `UNSUPPORTED_ON_PLATFORM` on iOS. */
  stopObservingTapEvents(): void {
    requireAndroidTap();
    tapEvents.stopAll();
  },

  /**
   * Observe payments refused **before anything is sent**, for one card.
   *
   * Handlers are per card: a listener registered for one `tokenUniqueReference` never hears about
   * another's. That is the same ownership model the Android and iOS SDKs use, so an integration
   * reads the same on all three.
   *
   * Three refusal shapes, and the difference matters — `requireOnline` means "connect and try
   * again", which genuinely fixes it; `amountExceedCardLimit` means this card can never pay this
   * much, so telling the payer to go online sends them round a loop that cannot succeed; and
   * `deviceNotBound` means the card was added on another device (or before a reinstall) and must
   * be added again on this phone.
   *
   * Fires on whatever rails the platform has: `TAP`, `CPM_QR` and `MPM_QR` on Android; the two QR
   * rails on iOS, which has no tap-to-pay. A refusal the SDK could not attribute to a card
   * (`tokenUniqueReference: null`) reaches **every** registered handler rather than none.
   *
   * Call `remove()` on the returned subscription to stop that one handler, or
   * {@link stopObservingPaymentRefusals} to stop every handler for the card; the native
   * registration is released once the last listener for that card has gone.
   */
  observePaymentRefusals(
    tokenUniqueReference: string,
    listener: (refusal: WalletPaymentRefusal) => void
  ): VeyraSubscription {
    return refusalListeners.add(tokenUniqueReference, listener);
  },

  /** Removes every {@link observePaymentRefusals} handler for this card. */
  stopObservingPaymentRefusals(tokenUniqueReference: string): void {
    refusalListeners.removeAll(tokenUniqueReference);
  },

  // ── Scan-to-pay (MPM) ──────────────────────────────────────────────────────

  /** Inspect a scanned merchant QR. Verified contexts are held natively (opaque handle). */
  inspectScannedQr(payload: string): Promise<ScanInspection> {
    return nativeCall(() => VeyraNative.walletInspectScannedQr(payload));
  },

  // `authenticateForPayment` was removed. The SDK raises the device
  // authentication sheet itself from inside `payScannedContext` and `showQrToPay`, so there is
  // nothing to call first and no way to forget. Cancel/failure arrive as a `'NOT_SENT'` outcome
  // with reason AUTH_CANCELLED / AUTH_FAILED / AUTH_UNAVAILABLE.

  /**
   * Pays an inspected merchant QR. Resolves with the outcome — an unknown or already-used handle is
   * `'NOT_SENT'` / `INVALID_REQUEST`.
   */
  payScannedContext(handle: string): Promise<PaymentOutcome> {
    return nativeCall(() => VeyraNative.walletPayScannedContext(handle));
  },

  /**
   * Cancels the {@link payScannedContext} of the QR whose order ID is `merchantOrderId` (the
   * inspection's `merchantOrderId`). Possible only while the payment is still on the device — key
   * top-up, the authentication sheet, building the payment. Answers at once with a
   * {@link CancelResult}:
   *
   * - `'CANCELLED'` — nothing was paid; `payScannedContext` resolves `'NOT_SENT'` / `CANCELLED`. An
   *   authentication sheet already showing stays until the customer dismisses it.
   * - `'TOO_LATE_TO_CANCEL_REQUEST_ALREADY_SENT'` — the payment has left the device and resolves
   *   with its normal result. Tell the user it can no longer be cancelled and keep waiting.
   * - `'NO_PAYMENT_IN_PROGRESS_FOR_ORDER_ID'` — no scan-to-pay with that order ID is running (wrong
   *   ID, already finished, or a QR that carries no order ID).
   *
   * Show-QR-to-pay has no wallet-side cancel: the merchant's charge is the payment request.
   */
  cancelPayment(merchantOrderId: string): Promise<CancelResult> {
    return cancelCall(() => VeyraNative.walletCancelPayment(merchantOrderId));
  },

  // ── Show-QR-to-pay (CPM) ───────────────────────────────────────────────────

  /**
   * Renders a payment QR for the active card: `payload` on `'APPROVED'`, or `'NOT_SENT'` with the
   * reason no QR was made.
   *
   * `onExpired` fires once, when this QR expires — clear it from the screen and offer a new one.
   * A later `showQrToPay` supersedes the QR and its `onExpired`, and {@link cancelQrExpiry} clears it
   * (call it when the screen goes). A call that renders no QR never fires it.
   */
  showQrToPay(amountMinorUnits: number, onExpired?: () => void): Promise<PaymentQr> {
    // Armed before the native call so an expiry can never slip in between; cleared again if no QR
    // was made, unless a newer render has replaced it meanwhile.
    const token = qrExpiry.arm(onExpired);
    return nativeCall<PaymentQr>(() => VeyraNative.walletShowQrToPay(amountMinorUnits)).then(
      (qr) => {
        if (qr.responseStatus !== 'APPROVED') qrExpiry.clearIf(token);
        return qr;
      },
      (e) => {
        qrExpiry.clearIf(token);
        throw e;
      }
    );
  },

  /** Stops the QR's expiry timer and drops its `onExpired` — call it when the QR screen goes. */
  cancelQrExpiry(): Promise<void> {
    qrExpiry.clear();
    return nativeCall(() => VeyraNative.walletCancelQrExpiry());
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
   * Branch on `canPay`, not on `status`. There is no replay — read `getTokens()` at start-up.
   */
  observeTokenStatusChanged(
    listener: (e: TokenStatusChangedEvent) => void
  ): VeyraSubscription {
    return tokenStatusEvents.observe(listener);
  },

  /** Removes every {@link observeTokenStatusChanged} listener. */
  stopObservingTokenStatusChanged(): void {
    tokenStatusEvents.stopAll();
  },

  /**
   * Fires when a wallet payment that was left `PENDING` reaches its final outcome — from the
   * SDK's background sweep, an on-demand status check, or the scan-to-pay push.
   *
   * Match the event to its payment by `transactionHash`. Subscribe once, at start-up: a payment
   * can settle days later, long after the screen that made it is gone. No replay, so a screen
   * still reads `getTransactions()` when it appears.
   */
  observeTransactionResolved(
    listener: (e: WalletTransactionResolvedEvent) => void
  ): VeyraSubscription {
    return transactionResolvedEvents.observe(listener);
  },

  /** Removes every {@link observeTransactionResolved} listener. */
  stopObservingTransactionResolved(): void {
    transactionResolvedEvents.stopAll();
  },

  /**
   * Fires when a card runs out of payment keys, or a refresh gives it new ones — `requiresOnline`
   * flipping.
   *
   * Covers key **consumption** and **refresh** only. Keys also expire by clock, with no SDK code
   * running, so nothing fires for that; such a token reads as `requiresOnline` on your next
   * `getTokens()`. Do not word your UI as though this were live coverage of every case.
   *
   * Observation only — there is deliberately no API to trigger a key refresh.
   */
  observeTokenKeyStateChanged(
    listener: (e: TokenKeyStateEvent) => void
  ): VeyraSubscription {
    return tokenKeyStateEvents.observe(listener);
  },

  /** Removes every {@link observeTokenKeyStateChanged} listener. */
  stopObservingTokenKeyStateChanged(): void {
    tokenKeyStateEvents.stopAll();
  },

  // ── Identity ───────────────────────────────────────────────────────────────

  /**
   * This install's payment application instance ID — generated by the SDK on first use and kept
   * for the life of the install (a reinstall gets a new one). Read-only.
   */
  getPaymentApplicationInstanceId(): Promise<string> {
    return nativeCall(() => VeyraNative.walletGetPaymentApplicationInstanceId());
  },

  // ── History & receipts ─────────────────────────────────────────────────────

  /**
   * A card's transaction history: the last `limit` payments made with it, on every rail this
   * platform has, most recent first — outcome, merchant and, where the merchant's bank supports
   * it, the credit confirmation, as the SDK last recorded them.
   *
   * Local read — no network call. Empty when no card on this device has that reference, or the
   * card has no payments yet. Same name and default on Android, iOS and React Native.
   */
  getTransactions(tokenUniqueReference: string, limit = 50): Promise<TransactionSummary[]> {
    return nativeCall(() => VeyraNative.walletGetTransactions(tokenUniqueReference, limit));
  },

  /**
   * Refreshes PENDING rows against the backend. It asks about **every** open row on the device, so
   * call it on an occasion (app foregrounded, history opened), never on a loop: a screen waiting for
   * one payment — a displayed CPM QR — should call `refreshTransactionStatus` with that payment's
   * hash instead, which is one request rather than one per open row. If the gateway throttles
   * (`429`), the pass stops and the rest wait for the SDK's next sweep. A read: resolves a
   * {@link ReconcileResult} whose `failureReason` is set only when the reconcile itself could not
   * run. Rejects only on a setup error.
   */
  reconcilePendingTransactions(): Promise<ReconcileResult> {
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
   * `value` is `null` when no row on this device carries that hash; a row that already has a final
   * outcome comes back unchanged without a network call. A check that could not be made carries
   * `failureReason` (`NO_NETWORK_CONNECTION` when offline) and the row as it was — a failed check
   * never changes the stored row.
   */
  refreshTransactionStatus(transactionHash: string): Promise<VeyraLookup<TransactionSummary>> {
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
   * `value` is `null` when no row on this device carries that hash. A check that could not be made
   * carries `failureReason` (`NO_NETWORK_CONNECTION` when offline) — a failed check never changes
   * the stored row.
   */
  refreshCreditConfirmation(transactionHash: string): Promise<VeyraLookup<TransactionSummary>> {
    return nativeCall(() => VeyraNative.walletRefreshCreditConfirmation(transactionHash));
  },

  /**
   * Verifies and stores a merchant receipt QR scanned by the customer — on the phone, nothing is sent.
   * Resolves a {@link ReceiptScan}: `'APPROVED'` with the stored `receipt`, or `'FAILED'` with the
   * reason (`INVALID_RECEIPT`, `RECEIPT_NOT_FROM_THIS_WALLET`, `RECEIPT_MISMATCH`,
   * `PAYMENT_NOT_CONFIRMED`, `RECEIPT_FOR_ANOTHER_TRANSACTION`). Rejects only on a setup error.
   */
  processReceipt(
    qrPayload: string,
    expectedTransactionHash: string | null = null
  ): Promise<ReceiptScan> {
    return nativeCall(() => VeyraNative.walletProcessReceipt(qrPayload, expectedTransactionHash));
  },

  getReceipts(limit = 100): Promise<TransactionReceipt[]> {
    return nativeCall(() => VeyraNative.walletGetReceipts(limit));
  },

  getReceiptForTransaction(transactionHash: string): Promise<TransactionReceipt | null> {
    return nativeCall(() => VeyraNative.walletGetReceiptForTransaction(transactionHash));
  },
};

/** Module-internal (not exported from the package): re-arm per-card refusals after initialise. */
export const rearmPaymentRefusalListeners = (): void => refusalListeners.rearm();

/**
 * Module-internal: drop every activation callback. Called on sign-out and on an initialise that
 * switches customer — exactly when the native SDKs stop every activation observer — so a callback
 * never outlives its observer, and a same-customer initialise keeps them all.
 */
export const releaseActivationObservers = (): void => {
  activations.clearAll();
};
