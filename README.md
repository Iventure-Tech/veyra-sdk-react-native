# Veyra SDK for React Native

Official React Native bindings for the **Veyra SDK** — contactless payments for
Nigerian NUBAN accounts. One package covers both sides of a payment:

- **Get paid (SoftPOS merchant):** registration & profile, NFC tap acceptance,
  get-paid QR (merchant-presented), charging a customer's payment QR
  (consumer-presented), transaction history and receipts.
- **Pay (wallet customer):** add card (account tokenisation), activation,
  Android NFC tap-to-pay, scan-to-pay, show-QR-to-pay, card states, history and
  receipts.

> Tap-to-**pay** (card emulation) is not available on iOS — Apple restricts card
> emulation — so the iOS wallet pays by QR. Tap **acceptance** works on
> NFC-capable iPhones. Every method's platform availability is stated in its
> TypeScript documentation.

The complete working integration is the
[Veyra React Native sample app](https://github.com/Iventure-Tech/veyra-react-native-sample-app),
which is also the home of the full developer guide.

## Requirements

- React Native **0.80+** (0.79 with a Kotlin override — the SDK's Kotlin 2.2 metadata
  needs your app's Kotlin to be 2.1+, which earlier React Native Gradle plugins cannot
  run). Classic architecture and new architecture (via interop) both work.
- **Android:** minSdk 28, a physical NFC-capable device.
- **iOS:** iOS 15+, a physical iPhone, and your Apple Developer **Team ID**.
- **Veyra onboarding credentials:** artifact-repository username/password, payment
  app provider id, token requestor id, and what your [provider](#connect-to-veyra) needs (an
  OAuth client id for a `VeyraAssertionProvider`; nothing for a `VeyraProxyProvider`).

## Install

```sh
npm install veyra-sdk-react-native
```

### Android

The native SDK resolves from the Veyra Maven repository (authenticated). Two steps:

1. Add your repository credentials to `~/.gradle/gradle.properties` (or your CI's
   environment as `VEYRA_REPO_USERNAME` / `VEYRA_REPO_PASSWORD`):

   ```properties
   veyraRepoUsername=your-repo-username
   veyraRepoPassword=your-repo-password
   ```

2. Declare the repository in your app's `android/build.gradle` — your app's own
   classpath pulls the `co.veyra:*` artifacts transitively, so the repository must be
   visible to it, not just to this package:

   ```groovy
   allprojects {
       repositories {
           maven {
               name = "veyra"
               url = "https://repo.veyra.co/releases"
               credentials {
                   username = findProperty("veyraRepoUsername") ?: System.getenv("VEYRA_REPO_USERNAME") ?: ""
                   password = findProperty("veyraRepoPassword") ?: System.getenv("VEYRA_REPO_PASSWORD") ?: ""
               }
           }
       }
   }
   ```

Your app also needs the NFC permission and (for tap-to-pay) the SDK's HCE service
registration in its manifest — copy the manifest block from the sample app's
`android/app/src/main/AndroidManifest.xml` verbatim.

### iOS

The native SDK downloads as a prebuilt framework from the Veyra artifact server at
`pod install`. Add your repository credentials to `~/.netrc`:

```
machine repo.veyra.co
  login your-repo-username
  password your-repo-password
```

```sh
chmod 600 ~/.netrc
cd ios && pod install
```

Copy the `Info.plist` NFC entries (including the Veyra AID) from the sample app.

## Initialise

```ts
import Veyra from 'veyra-sdk-react-native';

await Veyra.initialize({
  customerId: signedInCustomerId,
  provider,                                  // required, one for both SDKs — see "Connect to Veyra"
  softpos: {
    environment: 'TEST',
    paymentAppProviderId: VEYRA_PAYMENT_APP_PROVIDER_ID,
  },
  wallet: {
    environment: 'TEST',
    paymentAppProviderId: VEYRA_PAYMENT_APP_PROVIDER_ID,
    tokenRequestorId: VEYRA_TOKEN_REQUESTOR_ID,
    recommendationStandardVersion: '1.0',    // Android
    appleTeamId: 'YOURTEAMID',               // iOS
  },
});
```

## Connect to Veyra

You pass **one** `provider` to `Veyra.initialize`, and it says how both SDKs reach the Veyra
backend. There is no default and the SDK never guesses one: which kind you implement is your
payment app provider's decision. The kind is fixed for the life of the app process — there is never
a fallback from one to the other.

| Provider | `providerType` | The SDK… | Choose it when |
|---|---|---|---|
| `VeyraAssertionProvider` | `'AUTHENTICATION'` | calls Veyra itself, with a short-lived assertion your backend signs for the signed-in user | your backend can sign a JWT for the user (recommended) |
| `VeyraProxyProvider` | `'PROXY'` | calls nothing itself — every backend call goes through your provider to your backend | you want all traffic through your own backend |

A JavaScript object can't inherit a default, so you write `providerType` out; the SDK checks it
against the functions your object has. An unusable provider rejects `Veyra.initialize` with
`INVALID_CONFIGURATION`, naming the problem: no provider; an object with both `assertion` and `send`; a
`providerType` that contradicts the functions present; a blank `clientId`; a missing function
(e.g. `provider.send is required (VeyraProxyProvider)`). Every backend call the SDK makes
carries an `X-Veyra-Provider-Type` header (your provider's `providerType`: `AUTHENTICATION` or `PROXY`) and an `X-Veyra-Sdk-Version` header.

### `VeyraAssertionProvider` (recommended)

```ts
import type { VeyraAssertionProvider } from 'veyra-sdk-react-native';

const provider: VeyraAssertionProvider = {
  providerType: 'AUTHENTICATION',
  clientId: VEYRA_CLIENT_ID,                     // public, issued at onboarding
  assertion: async (audience, jkt) => {
    // Ask your backend for an assertion for the signed-in user. Resolve null when nobody
    // is signed in — the SDK then fails the call with NOT_AUTHENTICATED and sends nothing.
    const res = await fetch('https://your-backend.example/veyra/assertion', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${yourSession}` },
      body: JSON.stringify({ audience, jkt }),
    });
    return res.ok ? (await res.json()).assertion : null;
  },
};
```

The SDK calls `assertion()` only when it holds no valid access token, and never more
than once at a time per SDK. The access token it obtains is bound to a key generated on this
device that cannot be exported, so a token copied off the device is useless elsewhere.

`audience` is the base URL of the Veyra API the SDK will redeem the assertion at
(`https://api.uat.veyra.co` on `TEST`, `https://api.veyra.co` on `LIVE`). **Check it before you
sign:** copy it into `aud` only when it is a Veyra base URL you expect for that environment, and
refuse anything else, so an assertion your backend signs can never be redeemed anywhere but Veyra.

**What your backend returns:** a compact JWT, signed with a key whose public half you have
registered with Veyra, carrying:

**Required by Veyra — the minimum.** How you produce the assertion is up to you: your own
endpoint, your authorization server's token exchange (RFC 8693), or any identity provider. Veyra
checks only the following. An assertion that is missing any of them, or fails a check, is refused,
and the SDK reports `NOT_AUTHENTICATED`.

| Part | What to put in it | Why Veyra needs it |
|---|---|---|
| Signature (`alg`) | `ES256`, `ES384`, `PS256` or `RS256` (the ones agreed for your issuer), signed with a private key held in an HSM or KMS. Never `none` or an HMAC (`HS…`) algorithm | Veyra verifies it with your **public** key (your JWKS URI, or keys you registered). That proves the assertion came from you, and Veyra can never create one itself |
| `kid` (header) | The id of the signing key in your JWKS. It can be left out only if you publish exactly one key | Picks the key to verify with, so you can rotate: publish the new key, then start signing with it |
| `iss` | Exactly the issuer identifier registered with Veyra, character for character | Tells Veyra whose keys and rules apply. An unknown or disabled issuer is refused |
| `sub` | A stable, pairwise identifier for the signed-in user: the same value every time for that user. Never an account number, customer id, phone number or email | Veyra derives its own user id from `iss` + `sub`, so the same person is recognised across sessions and devices without you sharing who they are |
| `aud` | The `audience` the SDK passed to `assertion()` (the Veyra API base URL: `https://api.uat.veyra.co` on `TEST`, `https://api.veyra.co` on `LIVE`), or the alias agreed at onboarding | Addresses the assertion to Veyra only, so no other service that trusts your key can accept it |
| `iat` | When you issued it, in seconds since the epoch | Must not be in the future (Veyra allows 60 seconds of clock difference). Together with `exp`, it bounds the assertion's life |
| `exp` | The expiry: at most your agreed maximum after `iat`, which is **5 minutes** unless agreed otherwise | Limits how long a leaked assertion could be used. An expired one is refused |
| `jti` | A new unique id for every assertion, e.g. a UUID | Veyra accepts each `iss` + `jti` only once, so a captured assertion can't be replayed |

**Optional:**

| Claim | What to put in it | Why |
|---|---|---|
| `cnf.jkt` *(recommended)* | Exactly the `jkt` the SDK passed to `assertion()` | Binds the assertion to this device's key. If it's present, Veyra refuses the assertion unless it matches the key the SDK proves it holds, so a leaked assertion is useless on any other device. Veyra can make it mandatory for your issuer if you agree to that |
| `acr` | The authentication level of the user's session, from the values agreed at onboarding | Needed only if Veyra sets a minimum level for your issuer, e.g. to require multi-factor sign-in. Below the minimum, the assertion is refused |
| `nbf` | A not-before time | Honoured if present |

**Only the required claims above are mandatory.** `cnf.jkt`, `acr` and `nbf` are optional: include
`acr` only if Veyra has agreed a minimum sign-in level for your issuer. Any other claim is ignored.

**Device binding between your app and your backend is optional.** You don't have to bind the
assertion to the device, either with `cnf.jkt` or by using DPoP on your own `/sdk-assertion`
endpoint. Veyra accepts an unbound assertion that meets the minimum above. Either way, the SDK
always uses DPoP with Veyra: the access token it gets is bound to a key generated on this device
that cannot be exported. **What binding adds:** without it, an assertion that leaks in its few
minutes of life could be redeemed once by another device. With it, it can't be redeemed anywhere
else.

Issue it only for an authenticated session of the user it names, and rate-limit the endpoint.

### `VeyraProxyProvider`

```ts
import { VeyraRelayError, type VeyraProxyProvider } from 'veyra-sdk-react-native';

const forward = async (request: string): Promise<string> => {
  let res: Response;
  try {
    res = await fetch('https://your-api-gateway.example/issuertokengateway/v1/proxy', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${yourSession}` },
      body: request,                       // forward the envelope unmodified
    });
  } catch {
    // We cannot tell whether your backend received it: leave neverSent false.
    throw new VeyraRelayError('OTHER', false);
  }
  if (res.status === 200) return await res.text();   // Veyra's body, unmodified
  throw new VeyraRelayError('OTHER', false, res.status);
};

const provider: VeyraProxyProvider = { providerType: 'PROXY', send: forward };
```

`send` receives the complete envelope — it names the method and the Veyra API — so every call
posts to one endpoint. Your proxy backend (your issuer token gateway, ITG) authenticates
itself to Veyra with its own OAuth client credentials, held server-side (an API key is not
accepted).

**The request envelope (version 1)** — a JSON string:

```json
{ "version": 1,
  "service": "SOFTPOS",
  "method": "POST",
  "path": "/payment",
  "query": { "merchant_id": "…" },
  "headers": { "Content-Type": "application/json",
               "X-Veyra-Sdk-Version": "3.0.0",
               "X-Veyra-Provider-Type": "PROXY" },
  "body": "<the request JSON, as a string>" }
```

- `service` is the Veyra API the call is for: `WALLET` or `SOFTPOS`. It names the API, not your
  SDK — a wallet call to the payment API is `SOFTPOS`. Your proxy backend routes on it.
- `method` is the HTTP method to use towards Veyra. Because the envelope names it, the provider has a
  single `send` and every call goes to one endpoint.
- `path` is relative to that service — never a full URL, and without any API prefix.
- `query` is omitted when there is none (values are decoded). `body` is absent on `GET` and `DELETE`.
- New fields may be added under the same `version`; a breaking change bumps `version`.
- Your proxy backend forwards `query`, every header and `body` to Veyra unmodified; resolve with
  Veyra's response body exactly as received. If the proxy backend itself cannot complete the call
  it answers `200` with `{"response_status": "PROXY_FAILED", …, "never_sent": true|false}` —
  resolve with that body too; the SDK recognises it.

**Failures — say whether the request was sent.** Reject with a `VeyraRelayError(kind,
neverSent, httpStatus?)` (or any object with those fields):

- `neverSent: true` only when the request **provably never left the device** (for example
  the phone is offline and your call to your backend never started). A payment or digitise then
  ends `NOT_SENT`, and may be retried with the same order id; any other call ends `FAILED` with
  the same reason. Use kind `'NO_NETWORK'` for "offline" — the SDK then reports
  `NO_NETWORK_CONNECTION`.
- `neverSent: false` whenever it may have been delivered — a timeout, a dropped connection, an
  answer you could not read. A payment then stays pending and the SDK reconciles it. **When in
  doubt, `false`**: it is the safe direction.
- `httpStatus` when your backend got a non-200 answer from Veyra; the SDK handles that status
  exactly as on a direct connection.
- Any other rejection counts as `neverSent: false`, and so does a call that outlives the
  SDK's own timeout for that request.

**Your proxy provider is called from background work too** — status polling for pending payments, key
refresh, credit confirmations — not only from calls your app makes. Keep it usable without a
screen up. If the SDK cannot reach your JavaScript (no running JS runtime) a background cycle
simply skips and tries again later; it never fails a payment because of that.

**What your backend can see.** Request and response bodies pass through your app and backend. Card
key material is encrypted end to end to the device and payment proofs are cryptographically
protected, so your backend can neither read nor forge those. It **can** read account and identity
fields and could alter plain answers such as a transaction status — which is why only the
issuing bank or payment app provider itself, the party already trusted with those fields, may
operate a proxy provider, and why it must forward bytes unmodified.

## Payment screens declare themselves with a session

The SDK arms and disarms the device automatically. In a React Native app you tell
it which screen is the payment experience by mounting a **session hook** on that
screen — and only that screen:

```tsx
import { useIsFocused } from '@react-navigation/native';
import { usePaySession, useGetPaidSession } from 'veyra-sdk-react-native';

function PayScreen() {
  usePaySession(useIsFocused());       // armed while this screen is focused
  // …
}

function GetPaidScreen() {
  useGetPaidSession(useIsFocused());   // reader active while focused
  // …
}
```

While the session screen is focused the device stays armed (queueing at a
terminal, re-tapping after a decline — all fine). The moment the user navigates
away, backgrounds the app, or the screen locks, the device disarms. Tap APIs
called without their session open reject with `SESSION_REQUIRED`.

## Outcomes, not rejections

Every call **resolves with its outcome** — it never rejects for one. Branch on
`responseStatus` first, then on `responseStatusReason`; use `responseCode` (payments only) for
receipts and support, never to branch on.

| `responseStatus` | Meaning | Merchant order id | What to do |
|---|---|---|---|
| `APPROVED` | done | used — paid | complete |
| `DECLINED` | done; someone with authority refused; no money moved | free | show the reason; another card or method may be tried under the **same** order id |
| `FAILED` | it was not performed, and retrying with the same reference won't help — on a call other than a payment or digitise, also when it never reached Veyra (no network, not authenticated, …) | free, except after `94` (the order is already paid or possibly paid) | fix the reason and try again |
| `PENDING` | may have been done; not known yet | used | **never retry**; the SDK resolves it in the background |
| `RETRY` | reached Veyra, but was never sent to the bank; nothing was done | **unused** | fix the reason; retry with the **same** order id |
| `NOT_SENT` | payments and digitise only: never reached Veyra; nothing was done | **unused** | fix the reason; retry with the **same** order id (or digitise request) |

**`NOT_SENT` is only for payments and digitise** — `merchant.tap`, `chargeCustomerQr`,
`createPaymentContext`, `wallet.payScannedContext`, `wallet.showQrToPay` and `wallet.digitise`,
where it tells you the reference is still unused. Every other call (merchant registration,
activation, status and bank lists, wallet banks, account verification, activation codes,
`tokenStatus`, `deactivateToken`, `inspectCustomerQr`, `processReceipt`, `setActiveCard`) answers
**`FAILED`** with the same reason — fix it and call again.

`NOT_SENT` never carries a `responseCode`. Its `responseStatusReason` says what to fix (a
non-payment call carries the same reasons under `FAILED`) —
`INVALID_REQUEST`, `NO_NETWORK_CONNECTION`, `SDK_UNABLE_TO_CONNECT`, `NOT_AUTHENTICATED`,
`AUTH_CANCELLED` / `AUTH_FAILED` / `AUTH_UNAVAILABLE`, `CANCELLED`, `MODE_REFUSED`,
`ONLINE_REQUIRED`, `TOKEN_NOT_ACTIVE`, `AMOUNT_EXCEEDS_CARD_LIMIT`, `DEVICE_NOT_BOUND`,
`MISSING_MANDATORY_CONFIG`, `CARD_READ_FAILED`, `SDK_INTERNAL_ERROR`… Reasons are plain strings
and the vocabulary grows without an SDK release, so always keep a default branch.

`RETRY` is Veyra's answer: it carries Veyra's `responseCode` and reason (for example `91`, or
`21` / `NAME_ENQUIRY_FAILED`) and the payment is recorded in history. Handle it exactly like
`NOT_SENT` — nothing was debited; the reason says where it stopped.

- **The retry rule.** An order id can be used again until the order is `APPROVED` or `PENDING`.
  After `NOT_SENT`, `RETRY`, `DECLINED` or `FAILED` no money moved: keep the order id and pay again
  under the same one (fix the reason first; after a decline, another card). Once the order is paid
  or possibly paid — or the status is one your app doesn't know, which you treat as pending — a new
  attempt answers `94` (below); don't take another payment.
- **A duplicate order id** is `94` / `FAILED` / `DUPLICATE_MERCHANT_ORDER_ID`, and carries
  `originalPayment: OriginalPayment | null` (on `MerchantTapResult`, `CustomerQrChargeOutcome` and
  `PaymentContextQr`) — the payment already holding the order. If its `responseStatus` is
  `PENDING`, tell the merchant "A payment for this order is still being confirmed - do not take
  another payment"; otherwise "This order is already paid - do not take another payment". Never
  offer a retry.
- **Reads** — `merchant.contextStatus`, `merchant.refreshTransactionStatus` /
  `refreshCreditConfirmation`, `merchant.paymentStatus`, `wallet.refreshTransactionStatus` / `refreshCreditConfirmation` —
  resolve a `VeyraLookup<T>`: `{ value, failureReason, message }`. A read is never `PENDING`; when
  the check could not be made, `failureReason` says why and the payment is unchanged. Other
  lookups (`getBanks`, `getSettlementBanks`, `tokenStatus`, `inspectCustomerQr`,
  `merchant.refreshStatus`) carry `responseStatus` and are never `PENDING` either.

**A promise rejects only with a setup error** — a `VeyraError` whose `code` is one of:

| `code` | Meaning |
|---|---|
| `NOT_CONFIGURED` | `Veyra.initialize` has not run (on Android: also no Activity attached yet) |
| `NOT_SIGNED_IN` | no customer is signed in — after `Veyra.signOut` |
| `INVALID_CONFIGURATION` | `Veyra.initialize` was given a configuration it can't use; the message names the problem |
| `SESSION_REQUIRED` | a payment API without its screen session (`merchant.tap.*`, `wallet.setActiveCard`) |
| `UNSUPPORTED_ON_PLATFORM` | a method this platform can't perform — `wallet.onTapEvent` throws it on iOS |
| `UNKNOWN` | anything not otherwise classified — an SDK defect; see `message` |

These are integration bugs, found in development — don't build user-facing screens for them.

The wallet's on-phone calls answer too:

- `wallet.processReceipt` resolves a `ReceiptScan` — `{ receipt, responseStatus,
  responseStatusReason, message }`: `APPROVED` with the stored `receipt`, or `FAILED` with
  `INVALID_RECEIPT`, `RECEIPT_NOT_FROM_THIS_WALLET`, `RECEIPT_MISMATCH` (amount, currency, date,
  merchant or reference disagree), `PAYMENT_NOT_CONFIRMED` (scan again shortly) or
  `RECEIPT_FOR_ANOTHER_TRANSACTION`. Nothing is sent.
- `wallet.setActiveCard` resolves a `CardSelection` — `{ responseStatus, responseStatusReason,
  message }`: `APPROVED`, or `FAILED` with `CARD_NOT_FOUND` (not in this wallet) or, on Android,
  `CARD_DATA_MISSING` (remove the card and add it again).
- `wallet.reconcilePendingTransactions` is a read and resolves a `ReconcileResult` —
  `{ checked, failureReason, message }`; `failureReason` is set only when the reconcile itself
  could not run.

**Upgrading from 2.x:** the per-cause rejection codes (`VALIDATION`, `INVALID_REQUEST`,
`NO_NETWORK_CONNECTION`, `NOT_AUTHENTICATED`, `AUTH_CANCELLED`, `AUTH_FAILED`, `AUTH_UNAVAILABLE`,
`ONLINE_REQUIRED`, `AMOUNT_EXCEEDS_CARD_LIMIT`, `TOKEN_NOT_ACTIVE`, `DEVICE_NOT_BOUND`,
`NO_ACTIVE_CARD`, `CARD_CANNOT_SHOW_QR`, `MODE_REFUSED`, `MISSING_MANDATORY_CONFIG`,
`DUPLICATE_MERCHANT_ORDER_ID`, `REQUEST_FAILED`) are retired as rejections — the same names now
arrive as `responseStatusReason` on a resolved outcome. `getBanks` / `getSettlementBanks` resolve
`BankList` / `SettlementBankList`; `tokenStatus` resolves `TokenStatusResult`; `checkTokenActive`
is removed; `deactivateToken` resolves `TokenStatusUpdateResponse` (only `APPROVED` removed the
card); merchant `refreshStatus` / `activate` / `deactivate` / `update` resolve
`MerchantStatusResult`; `inspectCustomerQr` resolves `CustomerQrInspection`; `processReceipt`
resolves `ReceiptScan`, `setActiveCard` resolves `CardSelection` (it resolved `void`) and
`reconcilePendingTransactions` resolves `ReconcileResult`; `showQrToPay`
(`PaymentQr`) and `createPaymentContext` (`PaymentContextQr`) carry a status, with their QR set
only on `APPROVED`; the tap `result` branches on `responseStatus` (`status` is a deprecated
alias). The sample app's developer guide has the full migration table.

## Looking up a payment by your order ID

`merchant.paymentStatus(merchantOrderId)` answers "what happened to this order?" for every merchant
rail — `merchant.tap`, `createPaymentContext` and `chargeCustomerQr` — without saying which. Use it
for a payment that ended `PENDING`, or when your app restarted before the result arrived. It
resolves `VeyraLookup<OrderPaymentStatus>`: `responseStatus` is the **order's** status, by
precedence over all its attempts — any `APPROVED`, else any `PENDING`, else the latest attempt
(`DECLINED`, `FAILED` or `RETRY`); an order with no attempts (including a merchant QR not paid yet)
is `RETRY` / `25` / `UNABLE_TO_LOCATE_RECORD`. It also carries the deciding attempt's code, reason,
`merchantTransactionReference`, `transactionId` and `amountMinorUnits`, every attempt newest first,
and `answeredBy` (`'DEVICE'` when this device's own record is final, otherwise `'GATEWAY'`). A payment still on its way counts: it is on the history as `PENDING` before its request leaves, so mid-flight the lookup answers `PENDING`, even before the gateway has a record of it. It is a
read: it rejects only on a setup error — when the gateway could not be asked, `failureReason` says
why and `value` is what this device holds, if anything. A blank order id resolves
`failureReason: 'INVALID_REQUEST'`, a device with no registered merchant
`'MISSING_MANDATORY_CONFIG'`. The wallet has no lookup by order id. The retry rule is above: after
`NOT_SENT`, `RETRY`, `DECLINED` or `FAILED`, pay again under the **same** order id; after
`APPROVED` or `PENDING`, don't take another payment.

## Use it

```ts
import { Platform } from 'react-native';
import Veyra, { wallet, merchant, VeyraError } from 'veyra-sdk-react-native';

// Wallet: add a card
const banks = await wallet.getBanks();
if (banks.responseStatus !== 'APPROVED') showProblem(banks.message ?? banks.responseStatusReason);
const result = await wallet.digitise({ /* … */ recommendation: 'APPROVE' });

// Wallet: tap to pay (Android only — onTapEvent throws UNSUPPORTED_ON_PLATFORM on iOS)
const selection = await wallet.setActiveCard(cardId);
if (selection.responseStatus !== 'APPROVED') showProblem(selection.message ?? selection.responseStatusReason);
if (Platform.OS === 'android') {
  const tapSub = wallet.onTapEvent((e) => {
    if (e.type === 'transactionCompleted') console.log(e.status);  // the card-reading leg
  });
}

// Merchant: accept a tap. The order id stays usable until the order is APPROVED or PENDING.
const { sessionId } = await merchant.tap.start({ amountMinorUnits: 105000, merchantOrderId: 'ORDER-1042' });
const sub = merchant.tap.onEvent((e) => {
  if (e.type === 'unsupportedCard') showHint('Card not supported — try another');
  if (e.type !== 'result') return;
  const r = e.result;
  switch (r.responseStatus) {
    case 'APPROVED': return showApproved(r);
    case 'DECLINED': return showDeclined(r.responseStatusReason);
    case 'FAILED':
      if (r.responseStatusReason === 'DUPLICATE_MERCHANT_ORDER_ID') {
        return showNoRetry(r.originalPayment?.responseStatus === 'PENDING'
          ? 'A payment for this order is still being confirmed - do not take another payment'
          : 'This order is already paid - do not take another payment');
      }
      return showFailed(r.responseStatusReason);
    case 'NOT_SENT':
      if (r.responseStatusReason === 'CANCELLED') return;   // your own cancelPayment — not a result
      return showNotSent(r.responseStatusReason);            // retry with the same order id
    case 'RETRY':
      return showNotSent(r.responseStatusReason);            // not sent to the bank: same order id
    default:
      return showPending(r.merchantTransactionReference);   // PENDING: never charge again
  }
});

// Wallet: scan to pay. payScannedContext raises the device authentication sheet itself and
// resolves with the outcome — a dismissed sheet is an outcome, not an exception.
const outcome = await wallet.payScannedContext(handle);
if (outcome.responseStatus === 'NOT_SENT') {
  if (outcome.responseStatusReason === 'AUTH_CANCELLED') {
    // The customer dismissed the sheet — nothing was sent; let them try again.
  } else if (outcome.responseStatusReason === 'AUTH_UNAVAILABLE') {
    // No biometric and no screen lock on this device — send them to system settings.
  }
}

// Only setup mistakes reject — never string-match messages.
try {
  await Veyra.initialize(config);
} catch (e) {
  if (e instanceof VeyraError && e.code === 'INVALID_CONFIGURATION') console.error(e.message);
}
```

Cards that temporarily cannot pay report `requiresOnline: true` — grey them out;
the SDK restores them by itself when the device is online. Tap events
`cardContactLost` / `unsupportedCard` are transient: the reader stays armed for a
re-tap, so keep your waiting screen up and only treat `result` as terminal.

## Cancelling a payment or adding a card

A payment or an add-card can be cancelled **only while its request is still on the device**. Once it
has been sent, the bank may act on it whatever the phone does next, so the cancel is refused and the
call delivers its normal result. Every cancel names the call by a reference you already hold:

| Call | Cancel with | Reference |
|---|---|---|
| `merchant.tap.start`, `merchant.chargeCustomerQr`, `merchant.createPaymentContext` | `merchant.cancelPayment(merchantOrderId)` | the order ID you started the payment with |
| `wallet.payScannedContext` | `wallet.cancelPayment(merchantOrderId)` | `merchantOrderId` from `wallet.inspectScannedQr` (`null` on a QR that carries none — it cannot be cancelled) |
| `wallet.digitise` | `wallet.cancelDigitise(clientRequestId)` | the `clientRequestId` you passed in its params (without one, an add-card cannot be cancelled) |

Wallet show-QR-to-pay has no wallet-side cancel: the merchant's charge is the payment request.

The cancel resolves at once with a `CancelResult`. It is the answer to the **cancel**; the cancelled
call still resolves (for a tap, ends its event stream) with its own outcome.

| `CancelResult` | What happened | What to show |
|---|---|---|
| `CANCELLED` | Nothing was sent. The call ends `NOT_SENT` / `CANCELLED`. | Go back to the previous screen. Retry with the **same** order ID / `clientRequestId`. |
| `TOO_LATE_TO_CANCEL_REQUEST_ALREADY_SENT` | The request has already left the device; the call carries on. | "This can no longer be cancelled", and keep waiting for the call's result. |
| `TOO_LATE_TO_CANCEL_TASK_ALREADY_PROCESSED` | The call had already finished. | The result it already delivered. |
| `NO_PAYMENT_IN_PROGRESS_FOR_ORDER_ID` / `NO_DIGITISATION_IN_PROGRESS_FOR_CLIENT_REQUEST_ID` | Nothing with that reference is in progress (wrong reference, never started, or already finished). | Nothing is in progress. |

```ts
import { merchant, type CancelResult } from 'veyra-sdk-react-native';

async function onCancelPressed(orderId: string) {
  const answer: CancelResult = await merchant.cancelPayment(orderId);
  switch (answer) {
    case 'CANCELLED':
      return navigation.goBack();                         // the tap's result is NOT_SENT / CANCELLED
    case 'TOO_LATE_TO_CANCEL_REQUEST_ALREADY_SENT':
      return showHint('This can no longer be cancelled'); // keep waiting for the result event
    default:
      return;                                             // nothing in progress
  }
}

// Add a card you can cancel: give it your own clientRequestId.
const requestId = `add-card-${Date.now()}`;
const added = wallet.digitise({ /* … */ clientRequestId: requestId, recommendation: 'APPROVE' });
// later, from a Cancel button:
await wallet.cancelDigitise(requestId);
```

Leaving the get-paid screen (its session closing) cancels a tap that has not been sent yet — waiting
for a card, reading it, or read and not yet sent — on Android and iOS alike; a tap already sent runs
to its result. To cancel at any other moment, call `merchant.cancelPayment`.

**Migrating:** `merchant.tap.cancel(sessionId)` is removed. Use
`merchant.cancelPayment(merchantOrderId)` with the order ID you passed to `merchant.tap.start`; it
resolves with a `CancelResult` instead of `void`, and it also cancels a customer-QR charge or a
payment-QR create. Unlike the old cancel, it never stops a payment that is already with the bank.

## The full API

Every method, DTO, event and response code is typed and documented in the
package's TypeScript definitions, and demonstrated end-to-end in the
[sample app](https://github.com/Iventure-Tech/veyra-react-native-sample-app),
whose `DEVELOPER-GUIDE.md` is the canonical React Native guide.

Building **native** Android or iOS instead? See
[veyra-android-sample-app](https://github.com/Iventure-Tech/veyra-android-sample-app)
and [veyra-ios-sample-app](https://github.com/Iventure-Tech/veyra-ios-sample-app).
Do **not** integrate the native SDK artifacts directly from React Native — the
SDK's automatic arming follows native screen lifecycle, which a React Native
app's JavaScript navigation does not exercise; this package's session hooks exist
precisely to bridge that gap.
