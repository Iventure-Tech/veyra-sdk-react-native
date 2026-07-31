import { nativeCall } from './errors';
import { VeyraNative } from './native';
import { merchant } from './merchant';
import { sessions, useGetPaidSession, usePaySession } from './sessions';
import { wallet } from './wallet';
import type { VeyraConfig, VeyraMode } from './types';

export * from './types';
export { VeyraError, type VeyraErrorCode } from './errors';
export { usePaySession, useGetPaidSession, sessions };
export { wallet, merchant };

export const Veyra = {
  /**
   * Initialises both SDKs. Call once at app start (idempotent; safe to call again
   * after the native Activity is recreated — the SDK re-attaches itself).
   */
  initialize(config: VeyraConfig): Promise<void> {
    return nativeCall(() => VeyraNative.initialize(config));
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
