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
  DigitiseParams,
  DigitiseResult,
  PaymentOutcome,
  PaymentQr,
  QrExpiredEvent,
  ScanInspection,
  TransactionReceipt,
  TransactionSummary,
  VerifyAccountParams,
  VerifyAccountResponse,
  WalletTapEvent,
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

  /**
   * Fresh, single-use device authentication (biometric/passcode) for the next
   * scanned payment or QR render.
   */
  authenticateForPayment(
    title: string,
    subtitle: string | null = null,
    allowDeviceCredential = true
  ): Promise<void> {
    return nativeCall(() =>
      VeyraNative.walletAuthenticateForPayment(title, subtitle, allowDeviceCredential)
    );
  },

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

  // ── History & receipts ─────────────────────────────────────────────────────

  getTransactions(tokenUniqueReference: string, limit = 50): Promise<TransactionSummary[]> {
    return nativeCall(() => VeyraNative.walletGetTransactions(tokenUniqueReference, limit));
  },

  /** Refreshes PENDING rows against the backend. */
  reconcilePendingTransactions(): Promise<void> {
    return nativeCall(() => VeyraNative.walletReconcilePendingTransactions());
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
