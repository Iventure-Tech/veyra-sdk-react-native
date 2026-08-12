/**
 * Typed error codes. Both native modules normalise their platform's failures into
 * these codes (Android's message prefixes, iOS's error enums), so JS never
 * string-matches an error message.
 */
export type VeyraErrorCode =
  /** SDK not initialised — call Veyra.initialize first. */
  | 'NOT_CONFIGURED'
  /** Method not available on this platform (e.g. wallet tap-to-pay on iOS). */
  | 'UNSUPPORTED_ON_PLATFORM'
  /**
   * A payment API was called without an open focus session. Mount usePaySession /
   * useGetPaidSession on the payment screen — the SDK arms only while it is focused.
   */
  | 'SESSION_REQUIRED'
  /** The mode claim was refused (the other mode's payment is mid-flight). */
  | 'MODE_REFUSED'
  /** Card temporarily can't pay; device must come online. SDK self-heals. */
  | 'ONLINE_REQUIRED'
  /**
   * The amount is larger than this card can carry in one payment. Unlike `ONLINE_REQUIRED`
   * this does NOT resolve by going online — offer a smaller amount or another card.
   */
  | 'AMOUNT_EXCEEDS_CARD_LIMIT'
  | 'TOKEN_NOT_ACTIVE'
  /**
   * The customer dismissed the device authentication sheet the SDK raised. Nothing was sent —
   * offer the payment again.
   */
  | 'AUTH_CANCELLED'
  /** The customer attempted authentication and the device rejected it. Nothing was sent. */
  | 'AUTH_FAILED'
  /**
   * This device can perform no authentication at all: no enrolled biometric AND no screen lock.
   * Unlike `AUTH_FAILED`, a retry cannot help — send the user to system settings to set a
   * screen lock.
   */
  | 'AUTH_UNAVAILABLE'
  | 'NO_ACTIVE_CARD'
  | 'CARD_CANNOT_SHOW_QR'
  | 'MISSING_MANDATORY_CONFIG'
  /** Request-level validation failed; `field` names the offending parameter. */
  | 'VALIDATION'
  /**
   * The device has no working internet connection, so the call never left it — tell the user to
   * connect and try again. Nothing was sent, so nothing needs undoing.
   *
   * Not to be confused with `ONLINE_REQUIRED`, which is about the *card* (its payment keys are
   * used up and the wallet must refresh them) rather than the *device*. Both end with "get
   * online", and they need different copy: `ONLINE_REQUIRED` on a connected phone resolves by
   * itself in seconds; this one does not resolve until the user restores their connection.
   */
  | 'NO_NETWORK_CONNECTION'
  /** Network/backend failure. */
  | 'REQUEST_FAILED'
  /** Anything not otherwise classified; see message + nativeErrorCode. */
  | 'UNKNOWN';

export class VeyraError extends Error {
  readonly code: VeyraErrorCode;
  /** Platform error identifier when one exists (e.g. an Android SdkErrorCode name). */
  readonly nativeErrorCode: string | null;
  /** Offending field for VALIDATION errors. */
  readonly field: string | null;

  constructor(
    code: VeyraErrorCode,
    message: string,
    nativeErrorCode: string | null = null,
    field: string | null = null
  ) {
    super(message);
    this.name = 'VeyraError';
    this.code = code;
    this.nativeErrorCode = nativeErrorCode;
    this.field = field;
  }
}

const KNOWN_CODES: ReadonlySet<string> = new Set<VeyraErrorCode>([
  'NOT_CONFIGURED',
  'UNSUPPORTED_ON_PLATFORM',
  'SESSION_REQUIRED',
  'MODE_REFUSED',
  'ONLINE_REQUIRED',
  'AMOUNT_EXCEEDS_CARD_LIMIT',
  'TOKEN_NOT_ACTIVE',
  'AUTH_CANCELLED',
  'AUTH_FAILED',
  'AUTH_UNAVAILABLE',
  'NO_ACTIVE_CARD',
  'CARD_CANNOT_SHOW_QR',
  'MISSING_MANDATORY_CONFIG',
  'VALIDATION',
  'NO_NETWORK_CONNECTION',
  'REQUEST_FAILED',
  'UNKNOWN',
]);

/**
 * Wraps a native-module rejection into a VeyraError. Native rejections carry the
 * VeyraErrorCode as the RN rejection `code` and optional `userInfo` extras.
 */
export function toVeyraError(e: unknown): VeyraError {
  if (e instanceof VeyraError) return e;
  const any = e as {
    code?: string;
    message?: string;
    userInfo?: { nativeErrorCode?: string; field?: string };
  };
  const code: VeyraErrorCode = KNOWN_CODES.has(any?.code ?? '')
    ? (any.code as VeyraErrorCode)
    : 'UNKNOWN';
  return new VeyraError(
    code,
    any?.message ?? 'Unknown error',
    any?.userInfo?.nativeErrorCode ?? null,
    any?.userInfo?.field ?? null
  );
}

/** Runs a native call and rethrows rejections as typed VeyraErrors. */
export async function nativeCall<T>(call: () => Promise<T>): Promise<T> {
  try {
    return await call();
  } catch (e) {
    throw toVeyraError(e);
  }
}
