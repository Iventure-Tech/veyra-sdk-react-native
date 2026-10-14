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
  TapEvent,
  MerchantTransaction,
  MerchantUpdate,
  PaymentContextQr,
  PaymentContextStatus,
  QrExpiredEvent,
  SettlementBankList,
  StoredMerchant,
  TapRequest,
  TransactionResolvedEvent,
  TransactionStatus,
  CreditConfirmation,
  VeyraLookup,
  OrderPaymentStatus,
} from './types';

let tapSessionCounter = 0;
/** A process-unique id for one tap: its events carry it, and `tap.start` delivers only those. */
function nextTapSessionId(): string {
  tapSessionCounter += 1;
  return `tap-${Date.now().toString(36)}-${tapSessionCounter}-${Math.random().toString(36).slice(2, 10)}`;
}

/** A live subscription — `.remove()` ends it, as the matching `stopObservingX()` does. */
export type VeyraSubscription = { remove(): void };

/**
 * The listeners each `observeX` added, so `stopObservingX()` can end them all. A subscription that is
 * `.remove()`d leaves its set; one ended by `stopObservingX()` is removed exactly once.
 */
type Channel = Set<EmitterSubscription>;
const observers = {
  transactionResolved: new Set() as Channel,
  creditConfirmation: new Set() as Channel,
  merchantStatus: new Set() as Channel,
};

/**
 * The one-shot expiry callback of the latest {@link softpos.createPaymentContext}. Native fires the
 * expiry on the qr-expired event it shares with the wallet's QR, so only a `scope: 'softpos'` event
 * is ours. A new create replaces the slot, {@link softpos.cancelQrExpiry} clears it, and it fires at
 * most once.
 */
let qrExpirySlot: (() => void) | null = null;
let qrExpiryListener: EmitterSubscription | null = null;

function armQrExpiry(onExpired: (() => void) | undefined): void {
  qrExpirySlot = onExpired ?? null;
  if (qrExpiryListener || !onExpired) return;
  qrExpiryListener = veyraEmitter.addListener(Events.qrExpired, (e: QrExpiredEvent) => {
    if (e?.scope !== 'softpos') return;
    const fire = qrExpirySlot;
    qrExpirySlot = null;
    fire?.();
  });
}

function observe<E>(channel: Channel, event: string, listener: (e: E) => void): VeyraSubscription {
  const sub = veyraEmitter.addListener(event, listener);
  channel.add(sub);
  return {
    remove() {
      if (!channel.delete(sub)) return; // already ended — remove() is idempotent
      sub.remove();
    },
  };
}

function stopObserving(channel: Channel): void {
  for (const sub of channel) sub.remove();
  channel.clear();
}

/**
 * SoftPOS (Get paid) — registration, tap acceptance, QR rails, history. The same operations, under
 * the same names, as Android `VeyraSoftPOSSdk` and iOS `VeyraSoftPOS.shared`.
 *
 * Every operation resolves with its outcome — branch on `responseStatus`, then
 * `responseStatusReason`. A promise rejects only with a setup error (`VeyraError`).
 *
 * An operation that needs the stored merchant (the one {@link register} stored) and finds none
 * answers `MISSING_MANDATORY_CONFIG` and never rejects: `'NOT_SENT'` for a payment
 * ({@link tap}.start, {@link chargeCustomerQr}, {@link createPaymentContext}), `'FAILED'` for every
 * other call (and `failureReason` on a read).
 */
export const softpos = {
  // ── Registration & profile ─────────────────────────────────────────────────

  /** Registers the merchant. A missing field or unknown `merchantType` is `'NOT_SENT'` / `INVALID_REQUEST`. */
  register(registration: MerchantRegistration): Promise<MerchantRegistrationResult> {
    return nativeCall(() => VeyraNative.softposRegister(registration));
  },

  /** The settlement banks — `banks` on `'APPROVED'`, else the reason there are none. */
  getBanks(): Promise<SettlementBankList> {
    return nativeCall(() => VeyraNative.softposGetBanks());
  },

  /**
   * True when a merchant is stored with every field a payment needs (merchant id, terminal id,
   * name, acquirer id, category code, country code) — the same answer as {@link isMerchantRegistered}.
   */
  isRegistered(): Promise<boolean> {
    return nativeCall(() => VeyraNative.softposIsRegistered());
  },

  /**
   * The stored merchant, or `null` when there is none on this device.
   *
   * With a `customerId`, reads **that customer's** merchant **without initialising the SDK** —
   * callable before `Veyra.initialize`; nothing is signed in, started or claimed. For the Home
   * screen: decide whether to offer "Get paid" before the payment screen initialises the SDK. `null`
   * when that customer has none on this device, or `customerId` is blank. Without one, it reads the
   * signed-in customer's merchant (rejects `NOT_CONFIGURED` / `NOT_SIGNED_IN` like every call).
   */
  getStoredMerchantData(customerId?: string): Promise<StoredMerchant | null> {
    return customerId === undefined
      ? nativeCall(() => VeyraNative.softposGetStoredMerchantData())
      : nativeCall(() => VeyraNative.softposGetStoredMerchantDataFor(customerId));
  },

  /** The stored merchant's id, or `null` when there is none. */
  getStoredMerchantId(): Promise<string | null> {
    return nativeCall(() => VeyraNative.softposGetStoredMerchantId());
  },

  /** True when a merchant is stored — complete or not (gate payments on {@link isRegistered}). */
  hasStoredMerchant(): Promise<boolean> {
    return nativeCall(() => VeyraNative.softposHasStoredMerchant());
  },

  /**
   * True when the stored merchant may take payments, by its last known status — the same reading the
   * SDK's own payment gate makes. `false` when no merchant is stored; a merchant stored before
   * statuses were kept reads as active.
   */
  isMerchantActive(): Promise<boolean> {
    return nativeCall(() => VeyraNative.softposIsMerchantActive());
  },

  /**
   * Whether `customerId` has a merchant registered on this device with every field a payment needs —
   * {@link isRegistered} for a customer, read **without initialising the SDK** (callable before
   * `Veyra.initialize`), like {@link getStoredMerchantData} with a `customerId`. The documented
   * Home-screen gate for "Get paid".
   */
  isMerchantRegistered(customerId: string): Promise<boolean> {
    return nativeCall(() => VeyraNative.softposIsMerchantRegistered(customerId));
  },

  /**
   * Reads the stored merchant's current status from the gateway (and updates the stored profile; a
   * change fires {@link observeMerchantStatusChanged}). `'FAILED'` / `MISSING_MANDATORY_CONFIG` when no
   * merchant is stored. Never `'PENDING'`.
   */
  refreshStatus(): Promise<MerchantStatusResult> {
    return nativeCall(() => VeyraNative.softposRefreshStatus());
  },

  /** Activates the stored merchant; see {@link MerchantStatusResult} for the outcomes (`'FAILED'` / `MISSING_MANDATORY_CONFIG` with none stored). */
  activate(): Promise<MerchantStatusResult> {
    return nativeCall(() => VeyraNative.softposActivate());
  },

  /** Deactivates the stored merchant; see {@link MerchantStatusResult} for the outcomes. */
  deactivate(): Promise<MerchantStatusResult> {
    return nativeCall(() => VeyraNative.softposDeactivate());
  },

  /**
   * Updates the stored merchant's profile; a missing field is `'FAILED'` / `INVALID_REQUEST`, no merchant
   * stored `'FAILED'` / `MISSING_MANDATORY_CONFIG`.
   */
  updateMerchant(update: MerchantUpdate): Promise<MerchantStatusResult> {
    return nativeCall(() => VeyraNative.softposUpdateMerchant(update));
  },

  // ── Tap acceptance ─────────────────────────────────────────────────────────

  tap: {
    /**
     * Arms the reader for one tap payment and reports what happens to `onEvent` — the same call as
     * Android `softpos.tap.start(TapRequest) { event -> }` and iOS
     * `VeyraSoftPOS.shared.tap.start(_:onEvent:)`. Requires an open get-paid session
     * (`SESSION_REQUIRED` otherwise).
     *
     * `onEvent` hears only this tap's events, in order, and every tap ends with exactly one `result`
     * (or, on iOS, `ended` — the reader sheet closed without a card); nothing is delivered after it.
     * `cardContactLost` / `unsupportedCard` mean it stays armed for a re-tap. A tap refused before
     * anything was sent (blank order id, an invalid argument, no merchant stored, the other mode's
     * payment in flight) still resolves and ends with a `'NOT_SENT'` `result`. Cancel it with
     * {@link cancelPayment} and the request's `merchantOrderId`.
     *
     * Rejects only with a setup error, and then `onEvent` hears nothing.
     */
    start(request: TapRequest, onEvent: (e: TapEvent) => void): Promise<{ sessionId: string }> {
      // The session id is minted here and handed to native, so the subscription exists — and knows
      // which events are this tap's — before native can fire anything, an immediate NOT_SENT
      // result included.
      const sessionId = nextTapSessionId();
      let sub: EmitterSubscription | null = veyraEmitter.addListener(Events.softposTap, (e: TapEvent) => {
        if (!sub || e?.sessionId !== sessionId) return;
        if (e.type === 'result' || e.type === 'ended') {
          sub.remove();
          sub = null;
        }
        onEvent(e);
      });
      return nativeCall(() => VeyraNative.softposTapStart({ ...request, sessionId })).then(
        () => ({ sessionId }),
        (err) => {
          sub?.remove();
          sub = null;
          throw err;
        }
      );
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
    return cancelCall(() => VeyraNative.softposCancelPayment(merchantOrderId));
  },

  // ── Get-paid QR (merchant-presented, MPM) ──────────────────────────────────

  /**
   * Creates a payment context QR for the stored merchant: `mpmPayload` on `'APPROVED'`, else the
   * outcome says why there is none (see {@link PaymentContextQr}). Expiry fires once on the
   * `onExpired` callback.
   *
   * @param merchantOrderId your own order/basket/invoice id for this sale. **Required** and
   *   non-blank — a blank one is `'NOT_SENT'` / `INVALID_REQUEST`, nothing sent. Pass `undefined` for
   *   `currency` to keep the default. Stored by the gateway against the context and carried onto the
   *   transaction when the wallet's push settles. `'FAILED'` / `DUPLICATE_MERCHANT_ORDER_ID` when a
   *   payment already uses it, whatever that payment's outcome (several QRs may share one until one
   *   of them is paid). The transaction reference is minted by the SDK and comes back on the
   *   settled row. `'NOT_SENT'` / `MISSING_MANDATORY_CONFIG` when no merchant is stored.
   * @param currency ISO 4217 numeric, default `'566'`.
   * @param onExpired called once when the QR expires — blank it then. A new `createPaymentContext`
   *   replaces it (only the latest QR's expiry is reported) and {@link cancelQrExpiry} stops it.
   */
  createPaymentContext(
    amountMinorUnits: number,
    currency: string | undefined = '566',
    merchantOrderId: string,
    onExpired?: () => void
  ): Promise<PaymentContextQr> {
    armQrExpiry(onExpired);
    return nativeCall(() =>
      VeyraNative.softposCreatePaymentContext(amountMinorUnits, currency ?? '566', merchantOrderId)
    );
  },

  /** Stops the expiry watch {@link createPaymentContext} armed — call when the QR page goes away. Idempotent. */
  cancelQrExpiry(): Promise<void> {
    qrExpirySlot = null;
    return nativeCall(() => VeyraNative.softposCancelQrExpiry());
  },

  /**
   * Polls a QR's lifecycle. `value` is the state; a poll that could not be made carries
   * `failureReason` and no state — keep the QR as it is and poll again.
   */
  contextStatus(txRef: string): Promise<VeyraLookup<PaymentContextStatus>> {
    return nativeCall(() => VeyraNative.softposContextStatus(txRef));
  },

  // ── Charge a customer QR (consumer-presented, CPM) ─────────────────────────

  /**
   * Inspects a scanned customer payment QR; card data stays native (opaque handle). Not a Veyra
   * payment QR → `'FAILED'` / `INVALID_REQUEST` with no `qr`: show a hint and stay armed. Nothing is
   * sent either way.
   */
  inspectCustomerQr(payload: string): Promise<CustomerQrInspection> {
    return nativeCall(() => VeyraNative.softposInspectCustomerQr(payload));
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
      VeyraNative.softposChargeCustomerQr(handle, merchantOrderId)
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
  observeTransactionResolved(listener: (e: TransactionResolvedEvent) => void): VeyraSubscription {
    return observe(observers.transactionResolved, Events.transactionResolved, listener);
  },

  /** Ends every {@link observeTransactionResolved} subscription. */
  stopObservingTransactionResolved(): void {
    stopObserving(observers.transactionResolved);
  },

  /**
   * Fires when the funds of an approved sale are confirmed in the merchant's bank account
   * (`RECEIVED`), or once with `UNABLE_TO_CONFIRM` if the 30-day window closes unconfirmed.
   * Settlement confirmation, never a change to the payment outcome; the SDK owns the polling
   * (app-scoped, on both platforms) — subscribe and match the event to its sale by
   * `merchantTransactionReference`. Fires on Android and iOS alike; the answer is also written to
   * the stored row's `creditConfirmationStatus`, which is what a screen opened later reads.
   */
  observeCreditConfirmation(listener: (e: CreditConfirmationEvent) => void): VeyraSubscription {
    return observe(observers.creditConfirmation, Events.creditConfirmation, listener);
  },

  /** Ends every {@link observeCreditConfirmation} subscription. */
  stopObservingCreditConfirmation(): void {
    stopObserving(observers.creditConfirmation);
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
  observeMerchantStatusChanged(listener: (e: MerchantStatusEvent) => void): VeyraSubscription {
    return observe(observers.merchantStatus, Events.merchantStatus, listener);
  },

  /** Ends every {@link observeMerchantStatusChanged} subscription. */
  stopObservingMerchantStatusChanged(): void {
    stopObserving(observers.merchantStatus);
  },

  getTransactions(limit = 50): Promise<MerchantTransaction[]> {
    return nativeCall(() => VeyraNative.softposGetTransactions(limit));
  },

  getTransaction(merchantTransactionReference: string): Promise<MerchantTransaction | null> {
    return nativeCall(() => VeyraNative.softposGetTransaction(merchantTransactionReference));
  },

  /**
   * What happened to a merchant order, by **your own order id** — the `merchantOrderId` you passed to
   * the tap, `createPaymentContext` or `chargeCustomerQr`. One call for every rail; you don't say which.
   * The same operation as Android `softpos.paymentStatus` and iOS
   * `VeyraSoftPOS.shared.paymentStatus(merchantOrderID:)`.
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
    return nativeCall(() => VeyraNative.softposPaymentStatus(merchantOrderId));
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
      VeyraNative.softposRefreshTransactionStatus(merchantTransactionReference)
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
      VeyraNative.softposRefreshCreditConfirmation(merchantTransactionReference)
    );
  },

  getReceipt(merchantTransactionReference: string): Promise<MerchantReceipt | null> {
    return nativeCall(() => VeyraNative.softposGetReceipt(merchantTransactionReference));
  },

  /**
   * The gateway's own record of one of the stored merchant's transactions — a raw read that writes
   * nothing ({@link refreshTransactionStatus} is the check that updates the stored row).
   *
   * @param transactionDate the sale's date, `YYYY-MM-DD`.
   * @returns `value` lists the gateway's records for the reference (at most one; empty when it has
   *   none). A lookup that could not be made carries `failureReason` — `MISSING_MANDATORY_CONFIG`
   *   when no merchant is stored, `NO_NETWORK_CONNECTION` when offline — and `value` `null`.
   */
  getTransactionStatus(
    merchantTransactionReference: string,
    transactionDate: string
  ): Promise<VeyraLookup<TransactionStatus[]>> {
    return nativeCall(() =>
      VeyraNative.softposGetTransactionStatus(merchantTransactionReference, transactionDate)
    );
  },

  /**
   * Whether the stored merchant's bank has received an approved sale's funds, by the sale's
   * `creditTransactionId` and its amount in minor units — a raw read that writes nothing. The SDK
   * already asks this itself and reports through {@link observeCreditConfirmation};
   * {@link refreshCreditConfirmation} is the check that updates the stored row. `'RECEIVED'` is
   * final; anything else means ask again later. A lookup that could not be made carries
   * `failureReason` (`MISSING_MANDATORY_CONFIG` when no merchant is stored).
   */
  getCreditConfirmation(
    creditTransactionId: string,
    amountMinorUnits: number
  ): Promise<VeyraLookup<CreditConfirmation>> {
    return nativeCall(() =>
      VeyraNative.softposGetCreditConfirmation(creditTransactionId, amountMinorUnits)
    );
  },

  // ── Tap state ──────────────────────────────────────────────────────────────

  /**
   * True while a tap payment is mid-flight — a card is being read, or the payment is online. A tap
   * armed and waiting for a card is not in progress (see {@link isAwaitingCardTap}).
   */
  isTransactionInProgress(): Promise<boolean> {
    return nativeCall(() => VeyraNative.softposIsTransactionInProgress());
  },

  /** True while a tap payment is armed and waiting for a card (started, no card seen yet). */
  isAwaitingCardTap(): Promise<boolean> {
    return nativeCall(() => VeyraNative.softposIsAwaitingCardTap());
  },
};
