import { NativeEventEmitter, NativeModules, Platform } from 'react-native';

/**
 * Classic native module, consumed on the new architecture through RN's interop
 * layer — the standard backward-compatible vendor-SDK shape.
 */
const LINKING_ERROR =
  "The package 'veyra-sdk-react-native' doesn't seem to be linked. Make sure:\n" +
  (Platform.OS === 'ios' ? "- You have run 'pod install' in the ios/ directory\n" : '') +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go (a development build is required)\n';

export const VeyraNative = NativeModules.VeyraSdkReactNative
  ? NativeModules.VeyraSdkReactNative
  : new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    );

export const veyraEmitter = new NativeEventEmitter(
  NativeModules.VeyraSdkReactNative ?? undefined
);

/** Native event channel names (module-internal). */
export const Events = {
  activation: 'VeyraActivationEvent',
  walletTap: 'VeyraWalletTapEvent',
  merchantTap: 'VeyraMerchantTapEvent',
  qrExpired: 'VeyraQrExpiredEvent',
  transactionResolved: 'VeyraTransactionResolvedEvent',
  creditConfirmation: 'VeyraCreditConfirmationEvent',
} as const;
