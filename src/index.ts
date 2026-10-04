import { nativeCall } from './errors';
import { VeyraNative } from './native';
import { merchant } from './merchant';
import { sessions, useGetPaidSession, usePaySession } from './sessions';
import { rearmPaymentRefusalListeners, wallet } from './wallet';
import type { VeyraConfig, VeyraMode } from './types';

export * from './types';
export { VeyraError, type VeyraErrorCode } from './errors';
export { usePaySession, useGetPaidSession, sessions };
export { wallet, merchant };

export const Veyra = {
  /**
   * Initialises both SDKs for `config.customerId`. Call at every app start, with the customer
   * your app has signed in (idempotent for the same customer; safe to call again after the
   * native Activity is recreated). A different customer stops the previous customer's work and
   * opens the new customer's data.
   */
  initialize(config: VeyraConfig): Promise<void> {
    return nativeCall(() => VeyraNative.initialize(config)).then(() => {
      // A sign-out or a customer switch dropped the native per-card refusal registrations;
      // cards JS still listens to are armed again (app-wide events are re-armed natively).
      rearmPaymentRefusalListeners();
    });
  },

  /**
   * The customer has logged out: both SDKs stop everything they run for them. Their cards,
   * merchant and history stay on the device for when they sign in again. Every other call
   * rejects with `NOT_SIGNED_IN` until the next `initialize`.
   */
  signOut(): Promise<void> {
    return nativeCall(() => VeyraNative.signOut());
  },

  /**
   * The app's exclusive NFC mode. Read-only — the SDK owns all transitions; the
   * mode follows your screens via the pay / get-paid sessions.
   */
  currentMode(): Promise<VeyraMode> {
    return nativeCall(() => VeyraNative.currentMode());
  },

  wallet,
  merchant,
  sessions,
};

export default Veyra;
