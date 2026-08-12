#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

@interface RCT_EXTERN_MODULE (VeyraSdkReactNative, RCTEventEmitter)

// ── Init & mode ──────────────────────────────────────────────────────────────
RCT_EXTERN_METHOD(initialize : (NSDictionary *)config
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(currentMode : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)

// ── Sessions ─────────────────────────────────────────────────────────────────
RCT_EXTERN_METHOD(sessionOpen : (NSString *)kind
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(sessionClose : (NSString *)kind
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)

// ── Wallet ───────────────────────────────────────────────────────────────────
RCT_EXTERN_METHOD(walletGetBanks : (NSString *)accountNumber
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletVerifyAccount : (NSDictionary *)params
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletDigitise : (NSDictionary *)params
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletRequestActivationCode : (NSString *)ref
                  medium : (NSString *)medium
                  contact : (NSString *)contact
                  reason : (NSString *)reason
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletActivate : (NSString *)ref
                  code : (NSString *)code
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletCheckTokenActive : (NSString *)ref
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletTokenStatus : (NSString *)ref
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletObserveActivation : (NSString *)ref
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletPauseActivationObserver : (NSString *)ref
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletResumeActivationObserver : (NSString *)ref
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletStopActivationObserver : (NSString *)ref
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletGetCards : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletGetActiveCard : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletSetActiveCard : (NSString *)cardId
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletDeactivateCard : (NSString *)ref
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletInspectScannedQr : (NSString *)payload
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletPayScannedContext : (NSString *)handle
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletShowQrToPay : (double)amountMinorUnits
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletCancelQrExpiry : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletGetTransactions : (NSString *)ref
                  limit : (double)limit
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletReconcilePendingTransactions : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletRefreshTransactionStatus : (NSString *)transactionHash
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletRefreshCreditConfirmation : (NSString *)transactionHash
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletProcessReceipt : (NSString *)payload
                  expectedHash : (NSString *)expectedHash
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletGetReceipts : (double)limit
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(walletGetReceiptForTransaction : (NSString *)hash
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)

// ── Merchant ─────────────────────────────────────────────────────────────────
RCT_EXTERN_METHOD(merchantRegister : (NSDictionary *)registration
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantGetSettlementBanks : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantIsRegistered : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantGetStored : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantClearStored : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantRefreshStatus : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantActivate : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantDeactivate : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantUpdate : (NSDictionary *)update
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantTapStart : (NSDictionary *)request
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantTapCancel : (NSString *)sessionId
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantCreatePaymentContext : (double)amountMinorUnits
                  currency : (NSString *)currency
                  merchantOrderId : (NSString *_Nullable)merchantOrderId
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantCancelQrExpiry : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantContextStatus : (NSString *)txRef
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantInspectCustomerQr : (NSString *)payload
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantChargeCustomerQr : (NSString *)handle
                  merchantOrderId : (NSString *)merchantOrderId
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantGetTransactions : (double)limit
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantGetTransaction : (NSString *)reference
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantRefreshTransactionStatus : (NSString *)reference
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantRefreshCreditConfirmation : (NSString *)reference
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(merchantGetReceipt : (NSString *)reference
                  resolver : (RCTPromiseResolveBlock)resolve
                  rejecter : (RCTPromiseRejectBlock)reject)

@end
