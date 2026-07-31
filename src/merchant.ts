import type { EmitterSubscription } from 'react-native';
import { nativeCall } from './errors';
import { Events, VeyraNative, veyraEmitter } from './native';
import type {
  Bank,
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

  chargeCustomerQr(
    handle: string,
    merchantTransactionReference: string | null = null
  ): Promise<CustomerQrChargeOutcome> {
    return nativeCall(() =>
      VeyraNative.merchantChargeCustomerQr(handle, merchantTransactionReference)
    );
  },

  // ── Transactions & receipts ────────────────────────────────────────────────

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
