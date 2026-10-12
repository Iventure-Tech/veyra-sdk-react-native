import type {
  VeyraConfig,
  VeyraProvider,
  VeyraRelayFailureKind,
  VeyraRelayFunction,
} from './types';

/**
 * Throw (reject with) this from a relay function to say how a forward failed.
 *
 * `neverSent` is the part that matters for payments: set it to `true` only when the request
 * provably never left the device — the call then ends `NOT_SENT` and may be retried with the same
 * reference. When in doubt leave it `false`, which keeps a payment pending until it is reconciled. Set `httpStatus` when
 * your backend got a non-200 answer from Veyra; the SDK then handles that status exactly as on a
 * direct connection.
 */
export class VeyraRelayError extends Error {
  readonly kind: VeyraRelayFailureKind;
  readonly neverSent: boolean;
  readonly httpStatus: number | null;

  constructor(
    kind: VeyraRelayFailureKind,
    neverSent: boolean,
    httpStatus: number | null = null,
    message?: string
  ) {
    super(message ?? `Relay failed (${kind}, neverSent=${neverSent})`);
    this.name = 'VeyraRelayError';
    this.kind = kind;
    this.neverSent = neverSent;
    this.httpStatus = httpStatus;
  }
}

/** The two SDKs; both are served by the app's one provider. */
export type ConnectionSdk = 'softpos' | 'wallet';

/** What crosses the bridge: functions cannot, so native gets the kind and the presence flags. */
export interface NativeProvider {
  kind: 'auth' | 'request' | 'clientSecret';
  clientId?: string;
  clientSecret?: string;
  hasAssertion?: boolean;
}

/**
 * The problem with `provider`, naming it, or null when it is usable. Mirrors the native SDKs'
 * init-time validation; done here too because only JS can see which functions exist. The kind
 * comes from `providerType`, and the functions present must agree with it — an object with both
 * `assertion` and `send` is refused, never guessed.
 */
export function providerProblem(provider: unknown): string | null {
  if (provider == null || typeof provider !== 'object') {
    return "provider is required: pass a VeyraAssertionProvider ({ providerType: 'AUTHENTICATION', … }) or a VeyraProxyProvider ({ providerType: 'PROXY', … })";
  }
  const p = provider as Record<string, unknown>;
  const blank = (v: unknown) => typeof v !== 'string' || v.trim() === '';
  const hasAssertion = typeof p.assertion === 'function';
  const hasSend = typeof p.send === 'function';
  if (hasAssertion && hasSend) {
    return 'provider has both assertion() and send(): pass one kind';
  }
  switch (p.providerType) {
    case 'AUTHENTICATION':
      if (hasSend) {
        return "provider.providerType is 'AUTHENTICATION', so the provider must be a VeyraAssertionProvider (assertion), not send()";
      }
      if (hasAssertion) {
        return blank(p.clientId) ? 'provider.clientId must not be blank (VeyraAssertionProvider)' : null;
      }
      if (p.clientSecret !== undefined) {
        if (blank(p.clientId)) return 'provider.clientId must not be blank (VeyraClientSecretProvider)';
        if (blank(p.clientSecret)) return 'provider.clientSecret must not be blank (VeyraClientSecretProvider)';
        return null;
      }
      return 'provider.assertion is required (VeyraAssertionProvider)';
    case 'PROXY':
      if (hasAssertion) {
        return "provider.providerType is 'PROXY', so the provider must be a VeyraProxyProvider (send), not assertion()";
      }
      return hasSend ? null : 'provider.send is required (VeyraProxyProvider)';
    default:
      return "provider.providerType must be 'AUTHENTICATION' or 'PROXY'";
  }
}

/** The bridge-safe description of a validated provider. */
export function toNative(provider: VeyraProvider): NativeProvider {
  if (provider.providerType === 'PROXY') {
    return { kind: 'request' };
  }
  if ('assertion' in provider && typeof provider.assertion === 'function') {
    return { kind: 'auth', clientId: provider.clientId, hasAssertion: true };
  }
  const secret = provider as { clientId: string; clientSecret: string };
  return { kind: 'clientSecret', clientId: secret.clientId, clientSecret: secret.clientSecret };
}

/** A failure as the native side receives it. `httpStatus` -1 = none. */
export interface RelayRejection {
  kind: VeyraRelayFailureKind;
  neverSent: boolean;
  httpStatus: number;
  message: string;
}

const KINDS: ReadonlySet<string> = new Set(['NO_NETWORK', 'TIMEOUT', 'CONNECTION_REFUSED', 'OTHER']);

/**
 * Map whatever a relay function rejected with onto the native failure. Only an object that says
 * `neverSent: true` explicitly may claim the request never left; anything else — a plain Error, a
 * string, a malformed object — is "may have been delivered", the safe direction for a payment.
 */
export function toRelayRejection(e: unknown): RelayRejection {
  const o = (e != null && typeof e === 'object' ? e : {}) as Record<string, unknown>;
  const kind = typeof o.kind === 'string' && KINDS.has(o.kind) ? (o.kind as VeyraRelayFailureKind) : 'OTHER';
  const status = typeof o.httpStatus === 'number' && Number.isInteger(o.httpStatus) ? o.httpStatus : -1;
  const message =
    typeof o.message === 'string' ? o.message : typeof e === 'string' ? e : 'Relay failed';
  return { kind, neverSent: o.neverSent === true, httpStatus: status, message };
}

/** A request native raised on the connection event channel. */
export interface ConnectionRequestEvent {
  id: string;
  sdk: ConnectionSdk;
  kind: 'assertion' | 'relay';
  /** Assertion: the jkt. Relay: the envelope (which names the HTTP method). */
  payload: string;
  /** Assertion only: the base URL of the Veyra API the assertion is for. */
  audience?: string;
}

/** How the registry answers native. */
export interface ConnectionAnswerSink {
  resolve(id: string, value: string | null): void;
  reject(id: string, kind: VeyraRelayFailureKind, neverSent: boolean, httpStatus: number, message: string): void;
}

/**
 * The JS half of the connection bridge: the app's current provider, replaced on every initialise
 * (so a reloaded bundle's functions are the ones called), and the handler that runs a native
 * request and answers it. Both SDKs' requests go to the same provider.
 */
export class ConnectionRegistry {
  private current: VeyraProvider | undefined;

  register(provider: VeyraProvider): void {
    this.current = provider;
  }

  get(): VeyraProvider | undefined {
    return this.current;
  }

  snapshot(): VeyraProvider | undefined {
    return this.current;
  }

  restore(snapshot: VeyraProvider | undefined): void {
    this.current = snapshot;
  }

  async handle(event: ConnectionRequestEvent, sink: ConnectionAnswerSink): Promise<void> {
    const provider = this.current as Record<string, unknown> | undefined;
    try {
      if (event.kind === 'assertion') {
        const assertion = provider?.assertion;
        if (typeof assertion !== 'function') {
          throw new Error(`No assertion provider is registered (${event.sdk})`);
        }
        if (!event.audience) {
          throw new Error(`The ${event.sdk} assertion request carried no audience`);
        }
        const answer = await (assertion as (a: string, j: string) => Promise<string | null>).call(
          provider,
          event.audience,
          event.payload
        );
        sink.resolve(event.id, answer ?? null);
        return;
      }
      const fn = provider?.send as VeyraRelayFunction | undefined;
      if (typeof fn !== 'function') {
        // Nothing to hand the request to: it provably never left the device.
        sink.reject(event.id, 'OTHER', true, -1, `No proxy provider send() is registered (${event.sdk})`);
        return;
      }
      const body = await fn.call(provider, event.payload);
      if (typeof body !== 'string') {
        // The request was forwarded; the answer is unusable. May have been delivered.
        sink.reject(event.id, 'OTHER', false, -1, 'The request provider resolved with a non-string body');
        return;
      }
      sink.resolve(event.id, body);
    } catch (e) {
      const r = toRelayRejection(e);
      if (event.kind === 'assertion') {
        // Any assertion failure is NOT_AUTHENTICATED natively; the kind is irrelevant there.
        sink.reject(event.id, 'OTHER', true, -1, r.message);
      } else {
        sink.reject(event.id, r.kind, r.neverSent, r.httpStatus, r.message);
      }
    }
  }
}

/**
 * Validate the provider, register it, and return the config with the provider replaced by its
 * bridge-safe description. Throws (naming the problem) before anything reaches native.
 */
export function prepareConfig(
  config: VeyraConfig,
  registry: ConnectionRegistry
): Record<string, unknown> {
  const problem = providerProblem(config?.provider);
  if (problem) throw new Error(problem);
  registry.register(config.provider);
  return { ...config, provider: toNative(config.provider) };
}
