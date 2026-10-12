import type { EmitterSubscription } from 'react-native';
import { cancelCall, nativeCall } from './errors';
import { Events, VeyraNative, veyraEmitter } from './native';
import type {
  CancelResult,
  CreditConfirmationEvent,
  MerchantStatusEvent,
  CustomerQrChargeOutcome,
  CustomerQrInspection,
  MerchantReceipt,
  MerchantRegistration,
  MerchantRegistrationResult,
  MerchantStatusResult,
  MerchantTapEvent,
  MerchantTransaction,
  MerchantUpdate,
  PaymentContextQr,
  PaymentContextStatus,
  QrExpiredEvent,
  SettlementBankList,
  StoredMerchant,
  TapRequest,
  TransactionResolvedEvent,
  VeyraLookup,
  OrderPaymentStatus,
} from './types';

/**
 * Merchant (Get paid) domain — registration, tap acceptance, QR rails, history.
 *
 * Every operation resolves with its outcome — branch on `responseStatus`, then
 * `responseStatusReason`. A promise rejects only with a setup error (`VeyraError`).
 */
export const merchant = {
  // ── Registration & profile ─────────────────────────────────────────────────

  /** Registers the merchant. A missing field or unknown `merchantType` is `'NOT_SENT'` / `INVALID_REQUEST`. */
  register(registration: MerchantRegistration): Promise<MerchantRegistrationResult> {
    return nativeCall(() => VeyraNative.merchantRegister(registration));
  },

  /** The settlement banks — `banks` on `'APPROVED'`, else the reason there are none. */
  getSettlementBanks(): Promise<SettlementBankList> {
    return nativeCall(() => VeyraNative.merchantGetSettlementBanks());
  },

  isRegistered(): Promise<boolean> {
    return nativeCall(() => VeyraNative.merchantIsRegistered());
  },

  getStored(): Promise<StoredMerchant | null> {
    return nativeCall(() => VeyraNative.merchantGetStored());
  },

  /**
   * Fetches the stored merchant's current status from the backend (and updates the stored profile).
   * `'NOT_SENT'` / `MISSING_MANDATORY_CONFIG` when no merchant is registered.
   */
  refreshStatus(): Promise<MerchantStatusResult> {
    return nativeCall(() => VeyraNative.merchantRefreshStatus());
  },

  /** Activates the stored merchant; see {@link MerchantStatusResult} for the outcomes. */
  activate(): Promise<MerchantStatusResult> {
    return nativeCall(() => VeyraNative.merchantActivate());
  },

  /** Deactivates the stored merchant; see {@link MerchantStatusResult} for the outcomes. */
  deactivate(): Promise<MerchantStatusResult> {
    return nativeCall(() => VeyraNative.merchantDeactivate());
  },

  /** Updates the stored merchant's profile; a missing field is `'NOT_SENT'` / `INVALID_REQUEST`. */
  update(update: MerchantUpdate): Promise<MerchantStatusResult> {
    return nativeCall(() => VeyraNative.merchantUpdate(update));
  },

  // ── Tap acceptance ─────────────────────────────────────────────────────────

  tap: {
    /**
     * Arms the reader for one tap payment. Requires an open get-paid session
     * (`SESSION_REQUIRED` otherwise). Events stream on {@link onEvent}; only
     * `result` (and iOS `ended`) are terminal — `cardContactLost` /
     * `unsupportedCard` mean it stays armed for a re-tap. A tap refused before anything was
     * sent (blank order id, an invalid argument, the other mode's payment in flight) still
     * resolves with a `sessionId` and ends with a `'NOT_SENT'` `result` event.
     */
    start(request: TapRequest): Promise<{ sessionId: string }> {
      return nativeCall(() => VeyraNative.merchantTapStart(request));
    },

    onEvent(listener: (e: MerchantTapEvent) => void): EmitterSubscription {
      return veyraEmitter.addListener(Events.merchantTap, listener);
    },
  },

  // ── Cancelling a payment ───────────────────────────────────────────────────

  /**
   * Cancels the payment started with `merchantOrderId` — a card tap ({@link tap}.start), a
   * customer-QR charge ({@link chargeCustomerQr}) or a payment-QR create
   * ({@link createPaymentContext}); you don't say which. Answers at once with a {@link CancelResult}:
   *
   * - `'CANCELLED'` — nothing was sent. The payment itself still ends with its own outcome,
   *   `'NOT_SENT'` / `CANCELLED` (for a tap, as its `result` event); the order ID can be used again.
   * - `'TOO_LATE_TO_CANCEL_REQUEST_ALREADY_SENT'` — the request has already left the device. The
   *   payment carries on and delivers its normal result: tell the user it can no longer be
   *   cancelled and keep waiting.
   * - `'NO_PAYMENT_IN_PROGRESS_FOR_ORDER_ID'` — no payment with that order ID is armed or running
   *   (wrong ID, never started, or already finished).
   *
   * Needs no session, so a screen can always cancel on its way out.
   */
  cancelPayment(merchantOrderId: string): Promise<CancelResult> {
    return cancelCall(() => VeyraNative.merchantCancelPayment(merchantOrderId));
  },

  // ── Get-paid QR (merchant-presented, MPM) ──────────────────────────────────

  /**
   * Creates a payment context QR for the stored merchant: `mpmPayload` on `'APPROVED'`, else the
   * outcome says why there is none (see {@link PaymentContextQr}). Expiry fires once on the
   * qr-expired channel ({@link onQrExpired}).
   *
   * @param merchantOrderId your own order/basket/invoice id for this sale. **Required** and
   *   non-blank — a blank one is `'NOT_SENT'` / `INVALID_REQUEST`, nothing sent. Pass `undefined` for
   *   `currency` to keep the default. Stored by the gateway against the context and carried onto the
   *   transaction when the wallet's push settles. `'FAILED'` / `DUPLICATE_MERCHANT_ORDER_ID` when a
   *   payment already uses it, whatever that payment's outcome (several QRs may share one until one
   *   of them is paid). The transaction reference is minted by the SDK and comes back on the
   *   settled row. `'NOT_SENT'` / `MISSING_MANDATORY_CONFIG` when no merchant is registered.
   */
  createPaymentContext(
    amountMinorUnits: number,
    currency: string | undefined = '566',
    merchantOrderId: string
  ): Promise<PaymentContextQr> {
    return nativeCall(() =>
      VeyraNative.merchantCreatePaymentContext(amountMinorUnits, currency ?? '566', merchantOrderId)
    );
  },

  cancelQrExpiry(): Promise<void> {
    return nativeCall(() => VeyraNative.merchantCancelQrExpiry());
  },

  /**
   * Polls a QR's lifecycle. `value` is the state; a poll that could not be made carries
   * `failureReason` and no state — keep the QR as it is and poll again.
   */
  contextStatus(txRef: string): Promise<VeyraLookup<PaymentContextStatus>> {
    return nativeCall(() => VeyraNative.merchantContextStatus(txRef));
  },

  onQrExpired(listener: (e: QrExpiredEvent) => void): EmitterSubscription {
    return veyraEmitter.addListener(Events.qrExpired, (e: QrExpiredEvent) => {
      if (e.scope === 'merchant') listener(e);
    });
  },

  // ── Charge a customer QR (consumer-presented, CPM) ─────────────────────────

  /**
   * Inspects a scanned customer payment QR; card data stays native (opaque handle). Not a Veyra
   * payment QR → `'NOT_SENT'` / `INVALID_REQUEST` with no `qr`: show a hint and stay armed.
   */
  inspectCustomerQr(payload: string): Promise<CustomerQrInspection> {
    return nativeCall(() => VeyraNative.merchantInspectCustomerQr(payload));
  },

  /**
   * Charges an inspected customer QR. Resolves with the outcome — an unknown or already-used handle
   * is `'NOT_SENT'` / `INVALID_REQUEST`.
   *
   * @param merchantOrderId your own order/basket/invoice id for this sale. **Required** and
   *   non-blank — a blank one is `'NOT_SENT'` / `INVALID_REQUEST`, nothing sent. The SDK
   *   mints the transaction reference itself — the gateway makes `(merchantId, reference)` unique
   *   and only the SDK can promise that — and returns it on the outcome. This is the field for
   *   *your* identifier. Reusable until the order is `APPROVED` or `PENDING`; after that a reused
   *   one is refused `94` / `FAILED` / `DUPLICATE_MERCHANT_ORDER_ID` — do not take another payment
   *   for the order.
   */
  chargeCustomerQr(
    handle: string,
    merchantOrderId: string
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
   * What happened to a merchant order, by **your own order id** — the `merchantOrderId` you passed to
   * the tap, `createPaymentContext` or `chargeCustomerQr`. One call for every rail; you don't say which.
   * The same operation as Android `TransactionService.paymentStatus` and iOS
   * `transactions.paymentStatus(merchantOrderID:)`.
   *
   * The order's `responseStatus` is decided by precedence over all its attempts: any `'APPROVED'`, else
   * any `'PENDING'`, else the latest attempt (`'DECLINED'`, `'FAILED'` or `'RETRY'`); an order with no
   * attempts is `'RETRY'` / `25` / `UNABLE_TO_LOCATE_RECORD`. `attempts` lists every attempt, newest
   * first. Answered from this device's own record when it is final, otherwise from the gateway
   * (`answeredBy`) — combined with this device's own attempts, so a payment whose request is still on
   * its way answers `'PENDING'`.
   *
   * A read: when the gateway could not be asked, `failureReason` says why and `value` is what this
   * device holds for the order, if anything. Rejects only on a setup error.
   */
  paymentStatus(merchantOrderId: string): Promise<VeyraLookup<OrderPaymentStatus>> {
    return nativeCall(() => VeyraNative.merchantPaymentStatus(merchantOrderId));
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
   * `value` is `null` when this device has no such reference; a row that already has a final
   * outcome comes back unchanged without a network call. A check that could not be made carries
   * `failureReason` (`NO_NETWORK_CONNECTION` when offline) — a failed check never changes the stored
   * row, so show the reason and leave the row pending.
   */
  refreshTransactionStatus(
    merchantTransactionReference: string
  ): Promise<VeyraLookup<MerchantTransaction>> {
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
   * `value` is `null` when this device has no such reference. A check that could not be made
   * carries `failureReason` (`NO_NETWORK_CONNECTION` when offline) — a failed check never changes
   * the stored row, so show the reason and leave the credit line reading "not confirmed yet".
   */
  refreshCreditConfirmation(
    merchantTransactionReference: string
  ): Promise<VeyraLookup<MerchantTransaction>> {
    return nativeCall(() =>
      VeyraNative.merchantRefreshCreditConfirmation(merchantTransactionReference)
    );
  },

  getReceipt(merchantTransactionReference: string): Promise<MerchantReceipt | null> {
    return nativeCall(() => VeyraNative.merchantGetReceipt(merchantTransactionReference));
  },
};
