/** The emitter surface the observers need — `NativeEventEmitter` in the app, a fake in tests. */
export interface ListenerSource {
  addListener(event: string, listener: (e: any) => void): { remove(): void };
}

/** What an `observeX` call returns; `remove()` stops that one listener. */
export interface ObserverSubscription {
  remove(): void;
}

/**
 * One event kind's JS listeners, so `stopObservingX()` can remove all of them without touching
 * other kinds that share a native channel (the qr-expired channel also carries SoftPOS expiries).
 * Module-internal (not exported from the package).
 */
export function observerKind<E>(
  source: ListenerSource,
  event: string,
  accept: (e: E) => boolean = () => true
) {
  const subs = new Set<{ remove(): void }>();
  return {
    observe(listener: (e: E) => void): ObserverSubscription {
      const sub = source.addListener(event, (e: E) => {
        if (accept(e)) listener(e);
      });
      subs.add(sub);
      return {
        remove() {
          if (subs.delete(sub)) sub.remove();
        },
      };
    },
    stopAll(): void {
      for (const sub of Array.from(subs)) sub.remove();
      subs.clear();
    },
  };
}

/**
 * A single pending one-shot callback on a shared channel — the QR-expiry `onExpired` of the QR most
 * recently rendered. Arming supersedes whatever was pending; the callback fires at most once and
 * its listener is removed before it runs, so nothing is left registered. Module-internal.
 */
export function oneShotSlot<E>(
  source: ListenerSource,
  event: string,
  accept: (e: E) => boolean = () => true
) {
  let current: { remove(): void } | null = null;
  let generation = 0;
  const clear = (): void => {
    generation++;
    if (current) {
      current.remove();
      current = null;
    }
  };
  return {
    /** Supersede anything pending and, when given, wait for one event. Returns this arm's token. */
    arm(callback?: () => void): number {
      clear();
      const armed = generation;
      if (callback) {
        current = source.addListener(event, (e: E) => {
          if (!accept(e) || armed !== generation) return;
          clear();
          callback();
        });
      }
      return armed;
    },
    /** Clear only if nothing has been armed since `token` (a later render keeps its callback). */
    clearIf(token: number): void {
      if (token === generation) clear();
    },
    clear,
    /** Whether a callback is waiting (for tests). */
    get pending(): boolean {
      return current !== null;
    },
  };
}

/** The callbacks one `observeActivation` call registers. */
export interface ActivationCallbacks {
  onActivated: () => void;
  onTimeout: () => void;
  onError?: (message: string) => void;
}

type ActivationPayload =
  | { tokenUniqueReference: string; event: 'activated' }
  | { tokenUniqueReference: string; event: 'timeout' }
  | { tokenUniqueReference: string; event: 'error'; message: string };

/**
 * Per-token activation callbacks over the one activation event channel. One emitter listener, open
 * while any token is observed; an event goes only to its own token's callbacks. Re-registering a
 * token replaces its callbacks; a terminal event (activated / timeout / error) releases them before
 * they run, as do `release` and `clearAll`. Module-internal.
 */
export function activationRegistry(source: ListenerSource, event: string) {
  const byToken = new Map<string, ActivationCallbacks>();
  let channel: { remove(): void } | null = null;

  const closeIfIdle = (): void => {
    if (byToken.size === 0 && channel) {
      channel.remove();
      channel = null;
    }
  };

  const dispatch = (e: ActivationPayload): void => {
    const callbacks = byToken.get(e.tokenUniqueReference);
    if (!callbacks) return;
    // Every activation event is terminal: release before calling, so a callback that observes the
    // same token again registers afresh rather than being removed by this one.
    byToken.delete(e.tokenUniqueReference);
    closeIfIdle();
    if (e.event === 'activated') callbacks.onActivated();
    else if (e.event === 'timeout') callbacks.onTimeout();
    else callbacks.onError?.(e.message);
  };

  return {
    /** Register (or replace) the callbacks for a token. Returns them, as the registration's identity. */
    set(tokenUniqueReference: string, callbacks: ActivationCallbacks): ActivationCallbacks {
      if (!channel) channel = source.addListener(event, dispatch);
      const registered = { ...callbacks };
      byToken.set(tokenUniqueReference, registered);
      return registered;
    },
    /** Release a token's callbacks — only `registration`'s, when given (a later one is kept). */
    release(tokenUniqueReference: string, registration?: ActivationCallbacks): void {
      if (registration && byToken.get(tokenUniqueReference) !== registration) return;
      byToken.delete(tokenUniqueReference);
      closeIfIdle();
    },
    /** Release every token's callbacks (sign-out, re-initialise). Returns the tokens released. */
    clearAll(): string[] {
      const released = Array.from(byToken.keys());
      byToken.clear();
      closeIfIdle();
      return released;
    },
    has(tokenUniqueReference: string): boolean {
      return byToken.has(tokenUniqueReference);
    },
  };
}

/**
 * Which customer the SDKs were last initialised for, so per-customer JS state can tell a customer
 * switch (the native SDKs drop that customer's observers) from a same-customer initialise (an
 * Activity recreated — nothing native changed, so nothing JS holds may be dropped). Module-internal.
 */
export function customerTracker() {
  let current: string | null = null;
  return {
    /** Record a successful initialise. True when it switched from a different signed-in customer. */
    initialized(customerId: string): boolean {
      const switched = current !== null && current !== customerId;
      current = customerId;
      return switched;
    },
    /** Record a sign-out: the next initialise starts from nobody. */
    signedOut(): void {
      current = null;
    },
  };
}
