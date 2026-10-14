import { nativeCall, VeyraError } from './errors';
import { Events, VeyraNative, veyraEmitter } from './native';
import { customerTracker } from './observers';
import {
  ConnectionRegistry,
  prepareConfig,
  type ConnectionAnswerSink,
  type ConnectionRequestEvent,
} from './connection';
import { softpos } from './softpos';
import { sessions, useGetPaidSession, usePaySession } from './sessions';
import { rearmPaymentRefusalListeners, releaseActivationObservers, wallet } from './wallet';
import type { VeyraMode, VeyraProvider, VeyraSdkConfig } from './types';

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
/** The customer the SDKs were last initialised for — tells a customer switch from a re-run. */
const customers = customerTracker();
function listenForConnectionRequests(): void {
  if (connectionListener) return;
  connectionListener = veyraEmitter.addListener(Events.connectionRequest, (e: ConnectionRequestEvent) => {
    void connections.handle(e, nativeAnswers);
  });
}
export { usePaySession, useGetPaidSession, sessions };
export { wallet, softpos };
export type { VeyraSubscription } from './softpos';

export const Veyra = {
  /**
   * Initialises both SDKs for `customerId` — the customer your app has signed in. Call at every
   * app start (idempotent for the same customer; safe to call again after the native Activity is
   * recreated). A different customer stops the previous customer's work and opens the new
   * customer's data. Same order as Android `VeyraSdk.initialize` and iOS `VeyraSDK.configure`.
   *
   * @param customerId The customer your app has authenticated. Required on every launch: the SDKs
   *   keep cards, merchant and history per customer and never remember who is signed in. The
   *   wallet sends it to Veyra on its card requests (add card, eligibility, activation) so support
   *   can find them; SoftPOS never sends it. Device logs only ever show it masked.
   * @param config Both SDKs' settings: `{ softpos, wallet }`.
   * @param provider How both SDKs reach Veyra — one provider, required. See {@link VeyraProvider}.
   */
  initialize(customerId: string, config: VeyraSdkConfig, provider: VeyraProvider): Promise<void> {
    let nativeConfig: Record<string, unknown>;
    const previous = connections.snapshot();
    try {
      // An unusable provider fails here, naming the problem — never at the first payment.
      nativeConfig = prepareConfig({ ...config, customerId, provider }, connections);
    } catch (e) {
      return Promise.reject(new VeyraError('INVALID_CONFIGURATION', (e as Error).message));
    }
    // Listening before native initialises: the SDK may need a token or a relay during init.
    listenForConnectionRequests();
    return nativeCall(() => VeyraNative.initialize(nativeConfig)).then(() => {
      // A sign-out or a customer switch dropped the native per-card refusal registrations;
      // cards JS still listens to are armed again (app-wide events are re-armed natively).
      rearmPaymentRefusalListeners();
      // Activation callbacks are per observer, not re-armable: a customer switch stopped every
      // native activation observer, so their callbacks go too. A same-customer initialise (the
      // Activity recreated) changed nothing natively, so a mounted screen keeps its callbacks.
      if (customers.initialized(customerId)) releaseActivationObservers();
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
    // Sign-out stops every native activation observer; their callbacks go with them.
    releaseActivationObservers();
    customers.signedOut();
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
  softpos,
  sessions,
};

export default Veyra;
