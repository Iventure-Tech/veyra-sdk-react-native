import type { CancelResult } from './types';

/**
 * The setup errors — the **only** thing a Veyra call rejects with. Each is a mistake in the app's
 * integration, found in development, and the same type, with the same five codes, exists on Android
 * and iOS (`VeyraError`). Both native modules map their platform's setup error to the code by its
 * type, so JS never string-matches a message.
 *
 * Everything that happens **to** a call — refused on the phone, offline, authentication dismissed,
 * declined, no answer — is not an error: the promise resolves with the outcome, and its
 * `responseStatus` / `responseStatusReason` say what happened (see {@link ResponseStatus}).
 */
export type VeyraErrorCode =
  /** The SDK is not initialised — call `Veyra.initialize` first (also: no Activity attached yet on Android). */
  | 'NOT_CONFIGURED'
  /** No customer is signed in (after `Veyra.signOut`) — call `Veyra.initialize` with the customerId. */
  | 'NOT_SIGNED_IN'
  /**
   * The configuration cannot be used; the message names the problem — an unusable provider, a
   * provider of a different kind from an earlier `initialize`, a blank customerId, or a missing
   * required setting (environment, payment app provider ID, token requestor ID, `appleTeamId` on iOS…).
   */
  | 'INVALID_CONFIGURATION'
  /**
   * A payment API was called without its screen session open. Mount `usePaySession` /
   * `useGetPaidSession` on the payment screen — the SDK arms only while it is focused. Raised for
   * `softpos.tap.*` and `wallet.setActiveToken`, on both platforms.
   */
  | 'SESSION_REQUIRED'
  /** A method this platform cannot perform — e.g. wallet tap-to-pay (`wallet.observeTapEvents`) on iOS. */
  | 'UNSUPPORTED_ON_PLATFORM'
  /** Anything not otherwise classified — an SDK defect, not an outcome; see `message`. */
  | 'UNKNOWN';

export class VeyraError extends Error {
  readonly code: VeyraErrorCode;
  /** Platform error identifier when one exists. */
  readonly nativeErrorCode: string | null;
  /** The offending field, when an error names one. No setup error sets it today. */
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
  'NOT_SIGNED_IN',
  'INVALID_CONFIGURATION',
  'SESSION_REQUIRED',
  'UNSUPPORTED_ON_PLATFORM',
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

/** Every answer a cancel can give — the five values of {@link CancelResult}. */
const CANCEL_RESULTS: ReadonlySet<string> = new Set<CancelResult>([
  'CANCELLED',
  'TOO_LATE_TO_CANCEL_REQUEST_ALREADY_SENT',
  'TOO_LATE_TO_CANCEL_TASK_ALREADY_PROCESSED',
  'NO_PAYMENT_IN_PROGRESS_FOR_ORDER_ID',
  'NO_DIGITISATION_IN_PROGRESS_FOR_CLIENT_REQUEST_ID',
]);

/**
 * Reads a native cancel answer. Both native modules resolve with the answer's name; anything else
 * means the JS and native halves of the package are from different builds — an SDK defect, so it
 * rejects `UNKNOWN` rather than handing the app an answer its `switch` cannot know.
 */
export function toCancelResult(raw: unknown): CancelResult {
  if (typeof raw === 'string' && CANCEL_RESULTS.has(raw)) return raw as CancelResult;
  throw new VeyraError('UNKNOWN', `Unrecognised cancel answer from the native module: ${String(raw)}`);
}

/** Runs a native cancel: setup rejections become typed VeyraErrors, the answer a {@link CancelResult}. */
export function cancelCall(call: () => Promise<unknown>): Promise<CancelResult> {
  return nativeCall(call).then(toCancelResult);
}
