import { useEffect } from 'react';
import { nativeCall } from './errors';
import { VeyraNative } from './native';
import type { SessionKind } from './types';

/**
 * Focus-bridged mode sessions — how a React Native app declares "this screen is the
 * payment experience".
 *
 * A React Native app runs its whole UI in one native screen, so the SDK cannot see
 * JS navigation. Mounting a session on your payment screen supplies the missing
 * signal: while the screen is focused the device is armed for that experience
 * (paying / getting paid), and the moment it blurs or unmounts the device is
 * disarmed. Backgrounding the app or locking the screen disarms too; returning
 * re-arms only if the screen is still focused. The SDK still owns every mode
 * decision — a payment mid-flight is never interrupted, and a screen that opens no
 * session leaves the device inert.
 *
 * Tap APIs (`wallet.tap`, `merchant.tap`) require their session to be open and
 * reject with `SESSION_REQUIRED` otherwise. QR flows work without a session (they
 * never arm NFC).
 *
 * Pass your navigator's focus state, e.g. with React Navigation:
 * ```tsx
 * function PayScreen() {
 *   usePaySession(useIsFocused());
 *   …
 * }
 * ```
 */
export function usePaySession(focused: boolean): void {
  useSession('pay', focused);
}

/** See {@link usePaySession}. */
export function useGetPaidSession(focused: boolean): void {
  useSession('getPaid', focused);
}

function useSession(kind: SessionKind, focused: boolean): void {
  useEffect(() => {
    if (!focused) return;
    // Fire-and-forget: a deferred claim (other mode's payment mid-flight) self-heals
    // natively when the payment finishes / the screen re-focuses.
    void nativeCall(() => VeyraNative.sessionOpen(kind)).catch(() => {});
    return () => {
      void nativeCall(() => VeyraNative.sessionClose(kind)).catch(() => {});
    };
  }, [kind, focused]);
}

/**
 * Imperative session control for non-hook call sites (headless flows, class
 * components). Prefer the hooks — they cannot leak an open session.
 */
export const sessions = {
  open(kind: SessionKind): Promise<void> {
    return nativeCall(() => VeyraNative.sessionOpen(kind));
  },
  close(kind: SessionKind): Promise<void> {
    return nativeCall(() => VeyraNative.sessionClose(kind));
  },
};
