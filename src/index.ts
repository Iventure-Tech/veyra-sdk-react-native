import { nativeCall, VeyraError } from './errors';
import { Events, VeyraNative, veyraEmitter } from './native';
import {
  ConnectionRegistry,
  prepareConfig,
  type ConnectionAnswerSink,
  type ConnectionRequestEvent,
} from './connection';
import { merchant } from './merchant';
import { sessions, useGetPaidSession, usePaySession } from './sessions';
import { rearmPaymentRefusalListeners, wallet } from './wallet';
import type { VeyraConfig, VeyraMode } from './types';

export * from './types';
export { VeyraError, type VeyraErrorCode } from './errors';
export { VeyraRelayError } from './connection';

/**
 * The app's provider, shared by both SDKs and replaced on every initialise. One listener for the
 * process: native routes each request to whatever provider is current, so a reloaded bundle never
 * leaves the native side calling a dead function.
 */
const connections = new ConnectionRegistry();
const nativeAnswers: ConnectionAnswerSink = {
  resolve: (id, value) => VeyraNative.resolveConnectionRequest(id, value),
  reject: (id, kind, neverSent, httpStatus, message) =>
    VeyraNative.rejectConnectionRequest(id, kind, neverSent, httpStatus, message),
};
let connectionListener: { remove(): void } | null = null;
function listenForConnectionRequests(): void {
  if (connectionListener) return;
  connectionListener = veyraEmitter.addListener(Events.connectionRequest, (e: ConnectionRequestEvent) => {
    void connections.handle(e, nativeAnswers);
  });
}
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
    let nativeConfig: Record<string, unknown>;
    const previous = connections.snapshot();
    try {
      // An unusable provider fails here, naming the problem — never at the first payment.
      nativeConfig = prepareConfig(config, connections);
    } catch (e) {
      return Promise.reject(new VeyraError('INVALID_CONFIGURATION', (e as Error).message));
    }
    // Listening before native initialises: the SDK may need a token or a relay during init.
    listenForConnectionRequests();
    return nativeCall(() => VeyraNative.initialize(nativeConfig)).then(() => {
      // A sign-out or a customer switch dropped the native per-card refusal registrations;
      // cards JS still listens to are armed again (app-wide events are re-armed natively).
      rearmPaymentRefusalListeners();
    }, (e) => {
      // Native refused (e.g. a different kind of provider than this process already uses):
      // the provider native is still bound to stays the one answered.
      connections.restore(previous);
      throw e;
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
