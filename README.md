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
- **Veyra onboarding credentials:** artifact-repository username/password, OAuth
  client id/secret, payment app provider id, and token requestor id.

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
  softpos: {
    environment: 'TEST',
    clientId: VEYRA_CLIENT_ID,
    clientSecret: VEYRA_CLIENT_SECRET,
  },
  wallet: {
    environment: 'TEST',
    clientId: VEYRA_CLIENT_ID,
    clientSecret: VEYRA_CLIENT_SECRET,
    paymentAppProviderId: VEYRA_PAYMENT_APP_PROVIDER_ID,
    tokenRequestorId: VEYRA_TOKEN_REQUESTOR_ID,
    allowedCountryCodes: ['0566'],
    recommendationStandardVersion: '1.0',    // Android
    appleTeamId: 'YOURTEAMID',               // iOS
  },
});
```

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

## Use it

```ts
import Veyra, { wallet, merchant, VeyraError } from 'veyra-sdk-react-native';

// Wallet: add a card
const banks = await wallet.getBanks();
const result = await wallet.digitise({ /* … */ recommendation: 'APPROVE' });

// Wallet: tap to pay (Android) — select the card while the pay screen is focused
await wallet.setActiveCard(cardId);
const tapSub = wallet.onTapEvent((e) => {
  if (e.type === 'transactionCompleted') console.log(e.status);
});

// Merchant: accept a tap
const { sessionId } = await merchant.tap.start({ amountMinorUnits: 105000 });
const sub = merchant.tap.onEvent((e) => {
  if (e.type === 'unsupportedCard') showHint('Card not supported — try another');
  if (e.type === 'result') showOutcome(e.result);   // '00' approved, '05' declined…
});

// Typed errors — never string-match messages.
// payScannedContext raises the device authentication sheet itself; you make no auth call.
try {
  await wallet.payScannedContext(handle);
} catch (e) {
  if (e instanceof VeyraError && e.code === 'AUTH_CANCELLED') {
    // The customer dismissed the sheet — nothing was sent; let them try again.
  }
  if (e instanceof VeyraError && e.code === 'AUTH_UNAVAILABLE') {
    // No biometric and no screen lock on this device — send them to system settings.
  }
}
```

Cards that temporarily cannot pay report `requiresOnline: true` — grey them out;
the SDK restores them by itself when the device is online. Tap events
`cardContactLost` / `unsupportedCard` are transient: the reader stays armed for a
re-tap, so keep your waiting screen up and only treat `result` as terminal.

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
