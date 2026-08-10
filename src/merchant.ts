import type { EmitterSubscription } from 'react-native';
import { nativeCall } from './errors';
import { Events, VeyraNative, veyraEmitter } from './native';
import type {
  Bank,
  CreditConfirmationEvent,
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
  createPaymentContext(
    amountMinorUnits: number,
    currency = '566'
  ): Promise<PaymentContextQr> {
    return nativeCall(() => VeyraNative.merchantCreatePaymentContext(amountMinorUnits, currency));
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

  getTransactions(limit = 50): Promise<MerchantTransaction[]> {
    return nativeCall(() => VeyraNative.merchantGetTransactions(limit));
  },

  getTransaction(merchantTransactionReference: string): Promise<MerchantTransaction | null> {
    return nativeCall(() => VeyraNative.merchantGetTransaction(merchantTransactionReference));
  },

  getReceipt(merchantTransactionReference: string): Promise<MerchantReceipt | null> {
    return nativeCall(() => VeyraNative.merchantGetReceipt(merchantTransactionReference));
  },
};
