import type { EmitterSubscription } from 'react-native';
import { nativeCall } from './errors';
import { Events, VeyraNative, veyraEmitter } from './native';
import type {
  Bank,
  CreditConfirmationEvent,
  MerchantStatusEvent,
  CustomerQrChargeOutcome,
  MerchantReceipt,
  MerchantRegistration,
  MerchantRegistrationResult,
  MerchantStatus,
  MerchantTapEvent,
  MerchantTransaction,
  MerchantUpdate,
  PaymentContextQr,
  PaymentContextStatus,
  QrExpiredEvent,
  ScannedCustomerQr,
  StoredMerchant,
  TapRequest,
  TransactionResolvedEvent,
} from './types';

/** Merchant (Get paid) domain — registration, tap acceptance, QR rails, history. */
export const merchant = {
  // ── Registration & profile ─────────────────────────────────────────────────

  register(registration: MerchantRegistration): Promise<MerchantRegistrationResult> {
    return nativeCall(() => VeyraNative.merchantRegister(registration));
  },

  getSettlementBanks(): Promise<Bank[]> {
    return nativeCall(() => VeyraNative.merchantGetSettlementBanks());
  },

  isRegistered(): Promise<boolean> {
    return nativeCall(() => VeyraNative.merchantIsRegistered());
  },

  getStored(): Promise<StoredMerchant | null> {
    return nativeCall(() => VeyraNative.merchantGetStored());
  },

  /** Clears the locally stored merchant (does not deactivate server-side). */
  clearStored(): Promise<void> {
    return nativeCall(() => VeyraNative.merchantClearStored());
  },

  /** Fetches the current status from the backend and updates the stored profile. */
  refreshStatus(): Promise<MerchantStatus | null> {
    return nativeCall(() => VeyraNative.merchantRefreshStatus());
  },

  activate(): Promise<MerchantStatus | null> {
    return nativeCall(() => VeyraNative.merchantActivate());
  },

  deactivate(): Promise<MerchantStatus | null> {
    return nativeCall(() => VeyraNative.merchantDeactivate());
  },

  update(update: MerchantUpdate): Promise<MerchantStatus | null> {
    return nativeCall(() => VeyraNative.merchantUpdate(update));
  },

  // ── Tap acceptance ─────────────────────────────────────────────────────────

  tap: {
    /**
     * Arms the reader for one tap payment. Requires an open get-paid session
     * (`SESSION_REQUIRED` otherwise). Events stream on {@link onEvent}; only
     * `result` (and iOS `ended`) are terminal — `cardContactLost` /
     * `unsupportedCard` mean it stays armed for a re-tap.
     */
    start(request: TapRequest): Promise<{ sessionId: string }> {
      return nativeCall(() => VeyraNative.merchantTapStart(request));
    },

    /** Cancels an armed (untapped) payment; the stream ends with a cancelled result. */
    cancel(sessionId: string): Promise<void> {
      return nativeCall(() => VeyraNative.merchantTapCancel(sessionId));
    },

    onEvent(listener: (e: MerchantTapEvent) => void): EmitterSubscription {
      return veyraEmitter.addListener(Events.merchantTap, listener);
    },
  },

  // ── Get-paid QR (merchant-presented, MPM) ──────────────────────────────────

  /**
   * Creates a payment context QR for the stored merchant. Expiry fires once on the
   * qr-expired channel ({@link onQrExpired}).
   */
  /**
   * @param merchantOrderId your own order/basket/invoice id for this sale (optional).
   *   Stored by the gateway against the context and carried onto the transaction when the wallet's
   *   push settles. Never validated for uniqueness and never a lookup key — the transaction
   *   reference is minted by the SDK and comes back on the settled row.
   */
  createPaymentContext(
    amountMinorUnits: number,
    currency = '566',
    merchantOrderId: string | null = null
  ): Promise<PaymentContextQr> {
    return nativeCall(() =>
      VeyraNative.merchantCreatePaymentContext(amountMinorUnits, currency, merchantOrderId)
    );
  },

  cancelQrExpiry(): Promise<void> {
    return nativeCall(() => VeyraNative.merchantCancelQrExpiry());
  },

  contextStatus(txRef: string): Promise<PaymentContextStatus> {
    return nativeCall(() => VeyraNative.merchantContextStatus(txRef));
  },

  onQrExpired(listener: (e: QrExpiredEvent) => void): EmitterSubscription {
    return veyraEmitter.addListener(Events.qrExpired, (e: QrExpiredEvent) => {
      if (e.scope === 'merchant') listener(e);
    });
  },

  // ── Charge a customer QR (consumer-presented, CPM) ─────────────────────────

  /** Inspects a scanned customer payment QR; card data stays native (opaque handle). */
  inspectCustomerQr(payload: string): Promise<ScannedCustomerQr> {
    return nativeCall(() => VeyraNative.merchantInspectCustomerQr(payload));
  },

  /**
   * Charges an inspected customer QR.
   *
   * @param merchantOrderId your own order/basket/invoice id for this sale (optional). The SDK
   *   mints the transaction reference itself — the gateway makes `(merchantId, reference)` unique
   *   and only the SDK can promise that — and returns it on the outcome. This is the field for
   *   *your* identifier: it is never used as a key, so you may reuse it across the attempts of one
   *   sale, which is what links them.
   */
  chargeCustomerQr(
    handle: string,
    merchantOrderId: string | null = null
  ): Promise<CustomerQrChargeOutcome> {
    return nativeCall(() =>
      VeyraNative.merchantChargeCustomerQr(handle, merchantOrderId)
    );
  },

  // ── Transactions & receipts ────────────────────────────────────────────────

  /**
   * Fires when a payment the app was left waiting on resolves — a `PENDING` sale reaching
   * `APPROVED` / `DECLINED` / `FAILED`. Fires on Android and iOS alike, for any transaction that
   * settles (including one started in an earlier app launch), so match the event to its sale by
   * `merchantTransactionReference`.
   *
   * There is no replay on subscription: a screen still reads {@link getTransaction} when it
   * appears, and uses this as the live update while it is up. Subscribe once, at start-up.
   */
  onTransactionResolved(listener: (e: TransactionResolvedEvent) => void): EmitterSubscription {
    return veyraEmitter.addListener(Events.transactionResolved, listener);
  },

  /**
   * Fires when the funds of an approved sale are confirmed in the merchant's bank account
   * (`RECEIVED`), or once with `UNABLE_TO_CONFIRM` if the 30-day window closes unconfirmed.
   * Settlement confirmation, never a change to the payment outcome; the SDK owns the polling
   * (app-scoped, on both platforms) — subscribe and match the event to its sale by
   * `merchantTransactionReference`. Fires on Android and iOS alike; the answer is also written to
   * the stored row's `creditConfirmationStatus`, which is what a screen opened later reads.
   */
  onCreditConfirmation(listener: (e: CreditConfirmationEvent) => void): EmitterSubscription {
    return veyraEmitter.addListener(Events.creditConfirmation, listener);
  },

  /**
   * Fires when the merchant's backend status changes — deactivated, suspended, or activated.
   *
   * Two uses. It lets you stop offering to take payments the moment a merchant is deactivated
   * mid-session, instead of at the next screen load; and it is how the **activation** moment
   * arrives after registration, without your app polling for it.
   *
   * Branch on `canAcceptPayments`, not on `status` — it is the same reading the SDK's own payment
   * gate uses, so you cannot end up more permissive than the gate that will refuse the sale.
   *
   * The SDK owns the polling and it is app-scoped on both platforms. On iOS it pauses while the
   * app is suspended and resumes on foreground; nothing is lost, because the comparison is against
   * the stored status, so a change that happened while you were away still arrives on the first
   * poll after you return. Subscribe once, at start-up; there is no replay.
   */
  onMerchantStatusChanged(listener: (e: MerchantStatusEvent) => void): EmitterSubscription {
    return veyraEmitter.addListener(Events.merchantStatus, listener);
  },

  getTransactions(limit = 50): Promise<MerchantTransaction[]> {
    return nativeCall(() => VeyraNative.merchantGetTransactions(limit));
  },

  getTransaction(merchantTransactionReference: string): Promise<MerchantTransaction | null> {
    return nativeCall(() => VeyraNative.merchantGetTransaction(merchantTransactionReference));
  },

  /**
   * Ask the gateway about **one** pending transaction now, and resolve with the updated stored row.
   *
   * The on-demand counterpart to `getTransaction`, which only reads what the device already knows.
   * The SDK polls a pending transaction for you with exponential backoff and **stops after 30
   * days**; this is how a merchant staring at a row gets an answer sooner than the next rung, and
   * the only route to one once that window has closed.
   *
   * Runs the SDK's own background sweep for this single row — same query, same reading of the
   * answer, same write into the same local store — so an on-demand check and a background check
   * cannot disagree. It is **not** a way to force an outcome: a payment that is still unsettled
   * answers `PENDING` again.
   *
   * Resolves `null` when this device has no such reference; a row that already has a final outcome
   * comes back unchanged without a network call. Rejects with `NO_NETWORK_CONNECTION` when the
   * device is offline — a failed check never changes the stored row, so show the error and leave
   * the row pending.
   */
  refreshTransactionStatus(
    merchantTransactionReference: string
  ): Promise<MerchantTransaction | null> {
    return nativeCall(() =>
      VeyraNative.merchantRefreshTransactionStatus(merchantTransactionReference)
    );
  },

  /**
   * Check the merchant credit **now** for one approved sale — "has my bank actually received the
   * funds?" — and resolve with the updated stored row.
   *
   * The SDK already asks this in the background, with exponential backoff, for **30 days** after the
   * sale, and then records the row as `'UNABLE_TO_CONFIRM'` — which means *"we stopped asking"*,
   * never *"the funds were not received"*. This is the escape hatch from that give-up and a
   * convenience long before it: it still works once the window has closed, and a later `'RECEIVED'`
   * replaces the give-up state.
   *
   * **Check `isCreditConfirmationSupported` on the transaction first.** Not every merchant's bank is
   * on the confirmation rail. Offer the action only while
   * ```ts
   * txn.status === 'APPROVED' &&
   *   txn.isCreditConfirmationSupported === true &&
   *   txn.creditConfirmationStatus !== 'RECEIVED'
   * ```
   * A call on a row that fails that predicate makes **no network request** and resolves with the row
   * unchanged rather than rejecting.
   *
   * Settlement only: nothing on this path can change the sale's `status`, `responseCode` or
   * `responseStatusReason`.
   *
   * Resolves `null` when this device has no such reference. Rejects with `NO_NETWORK_CONNECTION`
   * when the device is offline — a failed check never changes the stored row, so show the error and
   * leave the credit line reading "not confirmed yet".
   */
  refreshCreditConfirmation(
    merchantTransactionReference: string
  ): Promise<MerchantTransaction | null> {
    return nativeCall(() =>
      VeyraNative.merchantRefreshCreditConfirmation(merchantTransactionReference)
    );
  },

  getReceipt(merchantTransactionReference: string): Promise<MerchantReceipt | null> {
    return nativeCall(() => VeyraNative.merchantGetReceipt(merchantTransactionReference));
  },
};
