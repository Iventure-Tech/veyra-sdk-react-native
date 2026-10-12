package co.veyra.reactnative

import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.FragmentActivity
import co.veyra.common.Environment
import co.veyra.common.VeyraSetupCode
import co.veyra.common.VeyraSetupException
import co.veyra.core.NfcMode
import co.veyra.reactnative.Mappers.opt
import co.veyra.reactnative.Mappers.optStringList
import co.veyra.reactnative.Mappers.req
import co.veyra.sdk.VeyraSdk
import co.veyra.sdk.VeyraSdkConfig
import co.veyra.sdk.internal.SingleActivityModeSession
import co.veyra.softpos.payment.sdk.TransactionRequest
import co.veyra.softpos.payment.sdk.VeyraSoftPOSSdk
import co.veyra.softpos.payment.sdk.VeyraSoftPosSdkConfig
import co.veyra.softpos.payment.sdk.context.ContextPaymentClient
import co.veyra.softpos.payment.sdk.merchant.MerchantStatusClient
import co.veyra.softpos.payment.sdk.cpm.ScannedCpmQr
import co.veyra.wallet.sdk.VeyraWalletSdk
import co.veyra.wallet.sdk.VeyraWalletSdkConfig
import co.veyra.wallet.sdk.api.mpm.MpmScanResult
import co.veyra.wallet.sdk.api.mpm.VerifiedPaymentContext
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * The Veyra native module. Classic bridge module (new-architecture apps consume it via
 * RN's interop layer).
 *
 * Mode handling (the single-Activity contract): the SDKs are initialised WITHOUT their
 * Activity-lifecycle observers (`VeyraWalletSdk.initialize(activity = null)`,
 * `VeyraSoftPOSSdk.initializeHosted`) and the exclusive NFC mode is driven solely by the
 * focus-bridged [SingleActivityModeSession] — JS screen focus opens/closes it. The calls
 * that arm NFC (`merchantTapStart`, `walletSetActiveCard`) are gated on the session
 * (SESSION_REQUIRED, the same two on iOS), so a screen that forgot to mount its session fails
 * loud at development time instead of leaving the device armed.
 *
 * Outcomes: every operation resolves with the SDK's outcome map (see [Mappers]); a promise
 * rejects only with a setup error ([VeyraPromises]). A bad call argument — an unknown handle or
 * enum value, a missing field — is not a setup error: it resolves `NOT_SENT` / `INVALID_REQUEST`.
 */
class VeyraSdkModule(private val reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext), LifecycleEventListener {

    companion object {
        const val NAME = "VeyraSdkReactNative"
    }

    override fun getName(): String = NAME

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val session = SingleActivityModeSession()
    private val mpmContexts = HandleRegistry<VerifiedPaymentContext>()
    private val cpmQrs = HandleRegistry<ScannedCpmQr>()
    private val connections = ConnectionBridge(reactContext)

    @Volatile private var initialized = false
    /** False after [signOut] until the next [initialize]: every data call is refused. */
    @Volatile private var signedIn = false
    @Volatile private var customerId: String? = null
    @Volatile private var softposConfig: VeyraSoftPosSdkConfig? = null
    @Volatile private var softposProvider: co.veyra.common.providers.VeyraProvider? = null
    @Volatile private var contextClient: ContextPaymentClient? = null

    init {
        // Failure lines from this process say they came through React Native, so support can tell
        // an RN integration from a native one on the same device.
        @OptIn(co.veyra.common.VeyraInternalApi::class)
        co.veyra.common.logging.failure.OperationFailureLog.surface =
            co.veyra.common.logging.failure.OperationFailureLog.SURFACE_RN
        reactContext.addLifecycleEventListener(this)
        // The SDK observers are registered after every initialise — see registerObservers.
    }

    /**
     * Bridge every SDK observer to its JS event. Called after **every** successful initialise:
     * signing a customer out, or initialising a different one, drops all observer registrations
     * so nothing of the previous customer's is announced — the bridge registers
     * again for whoever is signed in now. Each observer holds one listener, so re-registering
     * replaces rather than duplicates.
     */
    private fun registerObservers() {
        // registered per signed-in customer rather than per payment — the case
        // that most needs it is a tap that resolves after the app was backgrounded. The SDK fires on its
        // poller's thread; hop to the JS thread the way every other event here does.
        co.veyra.softpos.payment.sdk.merchant.TransactionResolvedObserver.onTransactionResolved { r ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                emit(EventNames.TRANSACTION_RESOLVED, Mappers.transactionResolved(r))
            }
        }
        // same app-scoped shape for the credit-receipt confirmation — funds can be
        // confirmed days after the sale, long after any per-payment JS callback is gone. A later change
        // gave RN iOS the same channel off the Swift facade's forwarder, so this event now fires
        // identically on both platforms with the same name and the same payload.
        co.veyra.softpos.payment.sdk.merchant.CreditConfirmationObserver.onCreditConfirmation { c ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                emit(EventNames.CREDIT_CONFIRMATION, Mappers.creditConfirmation(c))
            }
        }
        // The four "stored truth changed" channels. Registered here, not per screen, for the same
        // reason as the two above — the changes that matter most (a card suspended, a merchant
        // deactivated, a payment settling) happen while no screen is watching, so a per-screen
        // subscription would miss exactly the cases these exist for.
        //
        // The SDKs now hop to the main thread themselves, so the Handler.post here is strictly
        // belt-and-braces; it is kept so this file reads the same for every channel and so nothing
        // depends on that install having happened before the first event.
        co.veyra.wallet.sdk.api.TokenLifecycleObserver.onTokenStatusChanged { c ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                emit(EventNames.TOKEN_STATUS_CHANGED, Mappers.tokenStatusChanged(c))
            }
        }
        co.veyra.wallet.sdk.api.WalletTransactionResolvedObserver.onTransactionResolved { r ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                emit(EventNames.WALLET_TRANSACTION_RESOLVED, Mappers.walletTransactionResolved(r))
            }
        }
        co.veyra.wallet.sdk.api.WalletKeyStateObserver.onKeyStateChanged { s ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                emit(EventNames.CARD_KEY_STATE, Mappers.cardKeyState(s))
            }
        }
        co.veyra.softpos.payment.sdk.merchant.MerchantStatusObserver.onMerchantStatusChanged { c ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                emit(EventNames.MERCHANT_STATUS, Mappers.merchantStatusChanged(c))
            }
        }
    }

    private fun emit(event: String, payload: WritableMap) {
        reactContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(event, payload)
    }

    private fun hostActivity(): AppCompatActivity? = currentActivity as? AppCompatActivity

    private inline fun withInit(promise: Promise, body: () -> Unit) {
        if (!initialized) {
            VeyraPromises.reject(promise, VeyraSetupCode.NOT_CONFIGURED, "Call Veyra.initialize first")
            return
        }
        if (!signedIn) {
            VeyraPromises.reject(
                promise, VeyraSetupCode.NOT_SIGNED_IN,
                "No customer is signed in — call Veyra.initialize with the customerId first",
            )
            return
        }
        try {
            body()
        } catch (t: Throwable) {
            VeyraPromises.reject(promise, t)
        }
    }

    // ── Init & mode ─────────────────────────────────────────────────────────────

    @ReactMethod
    fun initialize(config: ReadableMap, promise: Promise) {
        try {
            val activity = hostActivity()
                ?: return VeyraPromises.reject(
                    promise, VeyraSetupCode.NOT_CONFIGURED, "No Activity attached yet — call after the app is on screen"
                )
            val customer = config.opt("customerId")?.takeIf { it.isNotBlank() }
                ?: throw IllegalArgumentException("customerId is required")
            val softposMap = config.getMap("softpos")
                ?: throw IllegalArgumentException("softpos config is required")
            val walletMap = config.getMap("wallet")
                ?: throw IllegalArgumentException("wallet config is required")
            // One provider for both SDKs: each gets its own native object routed by SDK key, all
            // answered by the same JS provider.
            val providerMap = config.getMap("provider")
            val walletProvider = connections.providerFor("wallet", providerMap)
            val softposProvider = connections.providerFor("softpos", providerMap)

            val softpos = VeyraSoftPosSdkConfig.builder(
                environment = Environment.fromString(softposMap.req("environment"))
                    ?: throw IllegalArgumentException("environment must be TEST or LIVE"),
                paymentAppProviderId = softposMap.req("paymentAppProviderId"),
            ).apply {
                if (softposMap.hasKey("enableNfc")) enableNfc(softposMap.getBoolean("enableNfc"))
            }.build()

            val wallet = VeyraWalletSdkConfig.builder(
                environment = Environment.fromString(walletMap.req("environment"))
                    ?: throw IllegalArgumentException("environment must be TEST or LIVE"),
                paymentAppProviderId = walletMap.req("paymentAppProviderId"),
                tokenRequestorId = walletMap.req("tokenRequestorId"),
            ).apply {
                if (walletMap.hasKey("enableNfc")) enableNfc(walletMap.getBoolean("enableNfc"))
                walletMap.opt("appVersion")?.let { appVersion(it) }
                walletMap.opt("recommendationStandardVersion")
                    ?.let { walletProviderTokenizationRecommendationStandardVersion(it) }
                walletMap.optStringList("allowedAcquirerIds")?.let { allowedAcquirerIds(it) }
                walletMap.optStringList("allowedMerchantIds")?.let { allowedMerchantIds(it) }
            }.build()

            // Umbrella first: installs the exclusive arbiter + InertBackstop and resets
            // to inert. Then the member SDKs — WITHOUT lifecycle binding (single-Activity
            // host: the focus session drives the mode, never the Activity observers).
            VeyraSdk.initialize(activity, customer, VeyraSdkConfig(softpos, wallet), walletProvider)
            VeyraWalletSdk.initialize(reactContext.applicationContext, customer, wallet, walletProvider, activity = null)
            VeyraSoftPOSSdk.initializeHosted(activity, customer, softpos, softposProvider)
            registerObservers()

            softposConfig = softpos
            this.softposProvider = softposProvider
            contextClient = ContextPaymentClient(
                reactContext.applicationContext,
                softpos.environment!!,
            )
            customerId = customer
            initialized = true
            signedIn = true
            promise.resolve(null)
        } catch (t: Throwable) {
            // A bad config value is INVALID_CONFIGURATION here, not a call argument.
            VeyraPromises.rejectInitialize(promise, t)
        }
    }

    // ── Connection callbacks (answers from JS) ──────────────────────────────────

    /** JS answered a connection request; `value` null is a valid "no assertion" answer. */
    @ReactMethod
    fun resolveConnectionRequest(id: String, value: String?) = connections.resolve(id, value)

    /** JS rejected a connection request. `httpStatus` -1 means none. */
    @ReactMethod
    fun rejectConnectionRequest(id: String, kind: String, neverSent: Boolean, httpStatus: Double, message: String?) =
        connections.reject(id, kind, neverSent, httpStatus.toInt(), message)

    /** The JS runtime is torn down (reload, destroy): fail whatever it was still answering. */
    override fun invalidate() {
        connections.failAllPending()
        super.invalidate()
    }

    @ReactMethod
    fun currentMode(promise: Promise) = withInit(promise) {
        promise.resolve(VeyraSdk.getInstance()?.currentMode()?.name ?: NfcMode.NONE.name)
    }

    // ── Focus-bridged sessions ──────────────────────────────────────────────────

    private fun kindToMode(kind: String): NfcMode = when (kind) {
        "pay" -> NfcMode.WALLET
        "getPaid" -> NfcMode.SOFTPOS
        else -> throw IllegalArgumentException("Unknown session kind: $kind")
    }

    @ReactMethod
    fun sessionOpen(kind: String, promise: Promise) = withInit(promise) {
        val activity = hostActivity()
            ?: return@withInit VeyraPromises.reject(promise, VeyraSetupCode.NOT_CONFIGURED, "No Activity attached")
        activity.runOnUiThread {
            try {
                session.open(kindToMode(kind), activity)
                promise.resolve(null)
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun sessionClose(kind: String, promise: Promise) = withInit(promise) {
        val mode = kindToMode(kind)
        val activity = hostActivity()
        val run = Runnable {
            try {
                if (session.sessionMode == mode) session.close()
                promise.resolve(null)
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
        if (activity != null) activity.runOnUiThread(run) else run.run()
    }

    private fun requireSession(mode: NfcMode, promise: Promise): Boolean {
        if (session.sessionMode != mode) {
            val hook = if (mode == NfcMode.WALLET) "usePaySession" else "useGetPaidSession"
            VeyraPromises.reject(
                promise, VeyraSetupCode.SESSION_REQUIRED,
                "This payment API arms NFC and needs its screen session open — mount $hook on the payment screen"
            )
            return false
        }
        return true
    }

    // ── Wallet: add card / digitise ─────────────────────────────────────────────

    @ReactMethod
    fun walletGetBanks(accountNumber: String?, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.getBanks(accountNumber) { promise.resolve(Mappers.bankList(it)) }
    }

    @ReactMethod
    fun walletVerifyAccount(params: ReadableMap, promise: Promise) = withInit(promise) {
        val request = try {
            Mappers.verifyAccountParams(params)
        } catch (e: IllegalArgumentException) {
            return@withInit promise.resolve(Mappers.verifyAccountRefused(Mappers.INVALID_REQUEST, e.message ?: "Invalid request"))
        }
        wallet().tokenisationService.checkAccountEligibility(request) { promise.resolve(Mappers.verifyAccount(it)) }
    }

    @ReactMethod
    fun walletDigitise(params: ReadableMap, promise: Promise) = withInit(promise) {
        val request = try {
            Mappers.digitiseParams(params)
        } catch (e: IllegalArgumentException) {
            return@withInit promise.resolve(Mappers.digitiseNotSent(Mappers.INVALID_REQUEST, e.message ?: "Invalid request"))
        }
        wallet().tokenisationService.digitizeAccount(request) { promise.resolve(Mappers.digitiseResult(it)) }
    }

    /**
     * Cancels the digitise started with [clientRequestId] (set from `params.clientRequestId` by
     * [Mappers.digitiseParams]); resolves with the CancelResult name.
     */
    @ReactMethod
    fun walletCancelDigitise(clientRequestId: String, promise: Promise) = withInit(promise) {
        promise.resolve(Mappers.cancelResult(wallet().tokenisationService.cancelDigitise(clientRequestId)))
    }

    // ── Wallet: activation ──────────────────────────────────────────────────────

    @ReactMethod
    fun walletRequestActivationCode(
        ref: String, medium: String, contact: String?, reason: String, promise: Promise
    ) = withInit(promise) {
        val reasonCode = when (reason) {
            "ADD_CARD" -> "ADD_CARD"
            "VERIFY_ACCOUNT" -> "VERIFY_ACCOUNT"
            else -> "OTHER"
        }
        wallet().tokenisationService.requestActivationCode(ref, medium, contact ?: "", reasonCode) {
            promise.resolve(Mappers.activationCode(it))
        }
    }

    @ReactMethod
    fun walletActivate(ref: String, code: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.activate(ref, code) { promise.resolve(Mappers.activate(it)) }
    }

    @ReactMethod
    fun walletTokenStatus(ref: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.tokenStatus(ref) { promise.resolve(Mappers.tokenStatusResult(it)) }
    }

    @ReactMethod
    fun walletObserveActivation(ref: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.observeActivation(
            ref,
            onActivated = {
                emit(EventNames.ACTIVATION, Arguments.createMap().apply {
                    putString("tokenUniqueReference", ref)
                    putString("event", "activated")
                })
            },
            onTimeout = {
                emit(EventNames.ACTIVATION, Arguments.createMap().apply {
                    putString("tokenUniqueReference", ref)
                    putString("event", "timeout")
                })
            },
            onError = { t ->
                emit(EventNames.ACTIVATION, Arguments.createMap().apply {
                    putString("tokenUniqueReference", ref)
                    putString("event", "error")
                    putString("message", t.message ?: "error")
                })
            },
        )
        promise.resolve(null)
    }

    @ReactMethod
    fun walletPauseActivationObserver(ref: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.pauseActivationObserver(ref); promise.resolve(null)
    }

    @ReactMethod
    fun walletResumeActivationObserver(ref: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.resumeActivationObserver(ref); promise.resolve(null)
    }

    @ReactMethod
    fun walletStopActivationObserver(ref: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.stopActivationObserver(ref); promise.resolve(null)
    }

    // ── Wallet: cards ───────────────────────────────────────────────────────────

    @ReactMethod
    fun walletGetCards(promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                val tokens = wallet().tokenisationService.getTokens()
                val array = Arguments.createArray()
                tokens.forEach { array.pushMap(Mappers.card(it)) }
                promise.resolve(array)
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun walletGetActiveCard(promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                val token = wallet().tokenisationService.getActiveToken()
                promise.resolve(token?.let { Mappers.card(it) })
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun walletSetActiveCard(cardId: String, promise: Promise) = withInit(promise) {
        // Arms tap-to-pay for this card — pay session required (the iOS bridge gates it the same).
        if (!requireSession(NfcMode.WALLET, promise)) return@withInit
        val activity = hostActivity()
        val selection = wallet().tokenisationService.setActiveToken(
            cardId,
            activity,
            onTransactionStarted = { tokenId ->
                emit(EventNames.WALLET_TAP, Arguments.createMap().apply {
                    putString("type", "transactionStarted")
                    putString("tokenId", tokenId)
                })
            },
            onTransactionCompleted = { r ->
                emit(EventNames.WALLET_TAP, Arguments.createMap().apply {
                    putString("type", "transactionCompleted")
                    putString("status", r.status)
                    putString("message", r.message)
                    r.amount?.let { putDouble("amountMinorUnits", it.toDouble()) }
                        ?: putNull("amountMinorUnits")
                    putString("tokenId", r.tokenId)
                    putString("cardScheme", r.cardScheme?.name)
                    putString("reference", r.reference)
                })
            },
            onActivationFailed = { message ->
                emit(EventNames.WALLET_TAP, Arguments.createMap().apply {
                    putString("type", "activationFailed")
                    putString("message", message)
                })
            },
            // Refusals are NOT registered here any more. They are per card and
            // reach JS through `wallet.onPaymentRefusal`, which arms them for whichever card the
            // app is listening to — not only the active one.
        )
        promise.resolve(Mappers.cardSelection(selection))
    }

    /**
     * Arm refusal delivery for one card. JS keeps the listener map; this decides
     * whether a refusal for that card crosses the bridge at all.
     */
    @ReactMethod
    fun walletObservePaymentRefusals(tokenUniqueReference: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.observePaymentRefusals(
            tokenUniqueReference = tokenUniqueReference,
            onRequireOnline = { event ->
                emit(EventNames.PAYMENT_REFUSAL, Arguments.createMap().apply {
                    putString("type", "requireOnline")
                    putString("tokenId", event.tokenId)
                    putString("tokenUniqueReference", event.tokenUniqueReference)
                    putDouble("amountMinorUnits", event.amountMinorUnits.toDouble())
                    putString("rail", event.rail)
                    putString("message", event.message)
                })
            },
            onAmountExceedCardLimit = { event ->
                emit(EventNames.PAYMENT_REFUSAL, Arguments.createMap().apply {
                    putString("type", "amountExceedCardLimit")
                    putString("tokenId", event.tokenId)
                    putString("tokenUniqueReference", event.tokenUniqueReference)
                    putDouble("amountMinorUnits", event.amountMinorUnits.toDouble())
                    event.cardLimitMinorUnits?.let { putDouble("cardLimitMinorUnits", it.toDouble()) }
                        ?: putNull("cardLimitMinorUnits")
                    putString("rail", event.rail)
                    putString("message", event.message)
                })
            },
            onDeviceNotBound = { event ->
                emit(EventNames.PAYMENT_REFUSAL, Arguments.createMap().apply {
                    putString("type", "deviceNotBound")
                    putString("tokenId", event.tokenId)
                    putString("tokenUniqueReference", event.tokenUniqueReference)
                    putDouble("amountMinorUnits", event.amountMinorUnits.toDouble())
                    putString("rail", event.rail)
                    putString("message", event.message)
                })
            },
        )
        promise.resolve(null)
    }

    /** Release one card's refusal registration; other cards are unaffected. */
    @ReactMethod
    fun walletStopObservingPaymentRefusals(tokenUniqueReference: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.stopObservingPaymentRefusals(tokenUniqueReference)
        promise.resolve(null)
    }

    @ReactMethod
    fun walletDeactivateToken(ref: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.deactivateToken(ref) { promise.resolve(Mappers.tokenStatusUpdate(it)) }
    }

    // ── Wallet: scan-to-pay (MPM) ───────────────────────────────────────────────

    @ReactMethod
    fun walletInspectScannedQr(payload: String, promise: Promise) = withInit(promise) {
        val result = wallet().tokenisationService.inspectScannedQr(payload)
        val handle = (result as? MpmScanResult.Verified)?.let { mpmContexts.put(it.context) }
        promise.resolve(Mappers.scanInspection(result, handle))
    }

    // `walletAuthenticateForPayment` was removed. The SDK raises the device
    // authentication sheet itself inside `walletPayScannedContext` / `walletShowQrToPay`,
    // including the main-looper hop this method used to do with `runOnUiThread`. Note that this
    // bridge always sourced the Activity itself via `hostActivity()` — an RN developer never
    // passed one — which is part of why the SDK asking was always the right shape.

    @ReactMethod
    fun walletPayScannedContext(handle: String, promise: Promise) = withInit(promise) {
        val context = mpmContexts.take(handle)
            ?: return@withInit promise.resolve(
                Mappers.paymentOutcomeNotSent(
                    Mappers.INVALID_REQUEST, "Unknown or already-used payment handle — re-inspect the QR",
                ),
            )
        // Every refusal and no-answer is the outcome; only a setup error is a failure here.
        wallet().tokenisationService.payScannedContext(context) { result ->
            result.fold(
                { promise.resolve(Mappers.paymentOutcome(it)) },
                { VeyraPromises.reject(promise, it) },
            )
        }
    }

    /** Cancels the scan-to-pay of the QR carrying [merchantOrderId]; resolves with the CancelResult name. */
    @ReactMethod
    fun walletCancelPayment(merchantOrderId: String, promise: Promise) = withInit(promise) {
        promise.resolve(Mappers.cancelResult(wallet().tokenisationService.cancelPayment(merchantOrderId)))
    }

    // ── Wallet: show-QR-to-pay (CPM) ────────────────────────────────────────────

    @ReactMethod
    fun walletShowQrToPay(amountMinorUnits: Double, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.showQrToPay(
            amountMinorUnits.toLong(),
            onExpired = {
                emit(EventNames.QR_EXPIRED, Arguments.createMap().apply {
                    putString("scope", "wallet")
                    putNull("handle")
                })
            },
        ) { result ->
            result.fold(
                { promise.resolve(Mappers.paymentQr(it)) },
                { VeyraPromises.reject(promise, it) },
            )
        }
    }

    @ReactMethod
    fun walletCancelQrExpiry(promise: Promise) = withInit(promise) {
        wallet().tokenisationService.cancelQrExpiry(); promise.resolve(null)
    }

    // ── Wallet: history & receipts ──────────────────────────────────────────────

    @ReactMethod
    fun walletGetTransactions(ref: String, limit: Int, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                val rows = wallet().tokenisationService.getTransactions(ref, limit)
                val array = Arguments.createArray()
                rows.forEach { array.pushMap(Mappers.transactionSummary(it)) }
                promise.resolve(array)
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun walletReconcilePendingTransactions(promise: Promise) = withInit(promise) {
        wallet().tokenisationService.reconcilePendingTransactions { result ->
            promise.resolve(Mappers.reconcileResult(result))
        }
    }

    /**
     * The per-transaction counterpart to the reconcile above — one row, keyed by hash,
     * resolving with the updated stored row rather than nothing. A check that could not be made
     * resolves with its `failureReason` (`NO_NETWORK_CONNECTION` when offline) and the row untouched.
     */
    @ReactMethod
    fun walletRefreshTransactionStatus(transactionHash: String, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                promise.resolve(Mappers.transactionLookup(wallet().tokenisationService.refreshTransactionStatus(transactionHash)))
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    /**
     * "Check merchant credit now" for one wallet payment. Settlement only — it can never
     * change the row's outcome triple. A check that could not be made resolves with its
     * `failureReason` (`NO_NETWORK_CONNECTION` when offline) and the row untouched; an ineligible row
     * makes no call at all and resolves unchanged.
     */
    @ReactMethod
    fun walletRefreshCreditConfirmation(transactionHash: String, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                promise.resolve(Mappers.transactionLookup(wallet().tokenisationService.refreshCreditConfirmation(transactionHash)))
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun walletProcessReceipt(payload: String, expectedHash: String?, promise: Promise) =
        withInit(promise) {
            wallet().tokenisationService.processReceipt(payload, expectedHash) { result ->
                promise.resolve(Mappers.receiptScan(result))
            }
        }

    @ReactMethod
    fun walletGetReceipts(limit: Int, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                val rows = wallet().tokenisationService.getLastReceipts(limit)
                val array = Arguments.createArray()
                rows.forEach { array.pushMap(Mappers.receipt(it)) }
                promise.resolve(array)
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun walletGetReceiptForTransaction(hash: String, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                val receipt = wallet().tokenisationService.getReceiptForTransaction(hash)
                promise.resolve(receipt?.let { Mappers.receipt(it) })
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    // ── Merchant: registration & profile ────────────────────────────────────────

    @ReactMethod
    fun merchantRegister(registration: ReadableMap, promise: Promise) = withInit(promise) {
        val (type, data) = try {
            Mappers.merchantRegistration(registration)
        } catch (e: IllegalArgumentException) {
            return@withInit promise.resolve(
                Mappers.merchantRegistrationRefused(Mappers.INVALID_REQUEST, e.message ?: "Invalid request"),
            )
        }
        val callback = { r: co.veyra.softpos.payment.sdk.merchant.MerchantRegistrationResponse ->
            promise.resolve(Mappers.merchantRegistrationResult(r))
        }
        when (type) {
            "PERSONAL" -> softpos().merchantService.registerPersonalMerchant(data, callback)
            "BUSINESS" -> softpos().merchantService.registerBusinessMerchant(data, callback)
            else -> promise.resolve(
                Mappers.merchantRegistrationRefused(Mappers.INVALID_REQUEST, "merchantType must be PERSONAL or BUSINESS"),
            )
        }
    }

    @ReactMethod
    fun merchantGetSettlementBanks(promise: Promise) = withInit(promise) {
        softpos().merchantService.getBanks { promise.resolve(Mappers.settlementBankList(it)) }
    }

    @ReactMethod
    fun merchantIsRegistered(promise: Promise) = withInit(promise) {
        promise.resolve(softpos().merchantService.isRegistered())
    }

    @ReactMethod
    fun merchantGetStored(promise: Promise) = withInit(promise) {
        promise.resolve(softpos().merchantService.getStoredMerchantData()?.let { Mappers.storedMerchant(it) })
    }

    /** No merchant on this device: refused on the phone, nothing sent (the iOS bridge says the same). */
    private fun noMerchant(): WritableMap =
        Mappers.merchantStatusRefused("MISSING_MANDATORY_CONFIG", "No merchant is registered on this device")

    /**
     * A status read for the stored merchant — the same answer iOS's `merchant.status` gives. The
     * SDK's own refresh also runs, so the stored profile and the merchant-status observer follow.
     */
    @ReactMethod
    fun merchantRefreshStatus(promise: Promise) = withInit(promise) {
        val service = softpos().merchantService
        val merchantId = service.getStoredMerchantId()?.takeIf { it.isNotBlank() }
            ?: return@withInit promise.resolve(noMerchant())
        val environment = softposConfig?.environment
            ?: throw VeyraSetupException(VeyraSetupCode.INVALID_CONFIGURATION, "softpos.environment is not configured")
        service.refreshStatus()
        scope.launch {
            try {
                promise.resolve(
                    Mappers.merchantStatus(MerchantStatusClient(reactContext.applicationContext, environment).fetchStatus(merchantId)),
                )
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun merchantActivate(promise: Promise) = withInit(promise) {
        softpos().merchantService.activate { promise.resolve(Mappers.merchantStatus(it)) }
    }

    @ReactMethod
    fun merchantDeactivate(promise: Promise) = withInit(promise) {
        softpos().merchantService.deactivate { promise.resolve(Mappers.merchantStatus(it)) }
    }

    @ReactMethod
    fun merchantUpdate(update: ReadableMap, promise: Promise) = withInit(promise) {
        val service = softpos().merchantService
        try {
            service.updateMerchant(
                merchantName = update.req("merchantName"),
                emailAddress = update.req("emailAddress"),
                phoneNumber = update.req("phoneNumber"),
                addressLine1 = update.req("addressLine1"),
                addressLine2 = update.opt("addressLine2") ?: "",
                city = update.req("city"),
                state = update.req("state"),
                countryCode = update.req("countryCode"),
                accountNumber = update.req("accountNumber"),
                institutionCode = update.req("institutionCode"),
                walletAccountId = update.opt("walletAccountId"),
                bvn = update.opt("bvn"),
            ) { promise.resolve(Mappers.merchantStatus(it)) }
        } catch (e: IllegalArgumentException) {
            // Raised by the argument reads above, before anything reaches the SDK.
            promise.resolve(Mappers.merchantStatusRefused(Mappers.INVALID_REQUEST, e.message ?: "Invalid request"))
        }
    }

    // ── Merchant: tap acceptance ────────────────────────────────────────────────

    @ReactMethod
    fun merchantTapStart(request: ReadableMap, promise: Promise) = withInit(promise) {
        if (!requireSession(NfcMode.SOFTPOS, promise)) return@withInit
        val sessionId = UUID.randomUUID().toString()

        fun tapEvent(type: String): WritableMap = Arguments.createMap().apply {
            putString("type", type)
            putString("sessionId", sessionId)
        }

        // the app's own order id, NOT a transaction reference — the SDK mints that and returns it
        // on the result. Required: untyped JS that omits it is passed through blank so
        // the SDK's rule refuses it with a NOT_SENT / INVALID_REQUEST result.
        val merchantOrderId = request.opt("merchantOrderId").orEmpty()
        val parsed = try {
            Triple(
                if (request.hasKey("amountMinorUnits") && !request.isNull("amountMinorUnits")) {
                    request.getDouble("amountMinorUnits").toLong()
                } else throw IllegalArgumentException("amountMinorUnits is required"),
                request.opt("currency") ?: "0566",
                TransactionRequest.TxType.valueOf(request.opt("txType") ?: "PURCHASE"),
            )
        } catch (e: IllegalArgumentException) {
            // A bad argument ends the tap the way the SDK ends a blank order id: a NOT_SENT result
            // on the event stream, with nothing armed.
            promise.resolve(Arguments.createMap().apply { putString("sessionId", sessionId) })
            // The bridge ended this tap itself, so the SDK never saw it: log the failure here.
            @OptIn(co.veyra.common.VeyraInternalApi::class)
            co.veyra.common.logging.failure.OperationFailureLog.report(
                operation = co.veyra.common.logging.failure.SdkOperation.MERCHANT_TAP,
                status = co.veyra.common.outcome.OutcomeStatus.NOT_SENT,
                reason = Mappers.INVALID_REQUEST,
                stage = co.veyra.common.logging.failure.FailureStage.VALIDATE,
                ids = mapOf("merchant_order_id" to merchantOrderId),
            )
            emit(EventNames.MERCHANT_TAP, tapEvent("result").apply {
                putMap("result", Mappers.tapResultNotSent(Mappers.INVALID_REQUEST, e.message ?: "Invalid request"))
            })
            return@withInit
        }
        val (amount, currency, txType) = parsed

        softpos().cardPaymentService.makeCardPayment(
            TransactionRequest.Builder(amount, currency, merchantOrderId, txType).build(),
            callback = { response ->
                emit(EventNames.MERCHANT_TAP, tapEvent("result").apply {
                    putMap("result", Mappers.tapResult(response))
                })
            },
            onCardDetected = { emit(EventNames.MERCHANT_TAP, tapEvent("cardDetected")) },
            onCardContactLost = { emit(EventNames.MERCHANT_TAP, tapEvent("cardContactLost")) },
            onUnsupportedCard = { emit(EventNames.MERCHANT_TAP, tapEvent("unsupportedCard")) },
            onCardReadingComplete = { emit(EventNames.MERCHANT_TAP, tapEvent("readingComplete")) },
            onSendingRequestOnline = { emit(EventNames.MERCHANT_TAP, tapEvent("sendingOnline")) },
            onReceivingOnlineResponse = { emit(EventNames.MERCHANT_TAP, tapEvent("receivingOnline")) },
        )
        promise.resolve(Arguments.createMap().apply { putString("sessionId", sessionId) })
    }

    /**
     * Cancels the SoftPOS payment started with [merchantOrderId] — tap, customer-QR charge or
     * payment-QR create alike. Resolves with the [co.veyra.common.cancel.CancelResult] name; the
     * payment itself still ends with its own outcome (a tap's on its `result` event). Leaving the
     * get-paid screen needs no call here: the focus session's close tears down an armed tap itself.
     */
    @ReactMethod
    fun merchantCancelPayment(merchantOrderId: String, promise: Promise) = withInit(promise) {
        promise.resolve(Mappers.cancelResult(softpos().cancelPayment(merchantOrderId)))
    }

    // ── Merchant: get-paid QR (MPM) ─────────────────────────────────────────────

    @ReactMethod
    fun merchantCreatePaymentContext(
        amountMinorUnits: Double,
        currency: String,
        // the merchant's own order id, so the MPM rail carries it like tap and CPM do. Required
        // for every merchant payment; null from untyped JS reaches the SDK blank and is refused there.
        merchantOrderId: String?,
        promise: Promise,
    ) =
        withInit(promise) {
            val merchantId = softpos().merchantService.getStoredMerchantId()?.takeIf { it.isNotBlank() }
                ?: return@withInit promise.resolve(
                    Mappers.paymentContextQrNotSent("MISSING_MANDATORY_CONFIG", "No merchant is registered on this device"),
                )
            scope.launch {
                try {
                    val created = client().createContextPayment(
                        merchantId,
                        amountMinorUnits.toLong(),
                        currency,
                        merchantOrderId = merchantOrderId.orEmpty(),
                    ) {
                        emit(EventNames.QR_EXPIRED, Arguments.createMap().apply {
                            putString("scope", "merchant")
                            putNull("handle")
                        })
                    }
                    promise.resolve(Mappers.paymentContextQr(created))
                } catch (t: Throwable) {
                    VeyraPromises.reject(promise, t)
                }
            }
        }

    @ReactMethod
    fun merchantCancelQrExpiry(promise: Promise) = withInit(promise) {
        client().cancelQrExpiry(); promise.resolve(null)
    }

    /**
     * A context poll, as a lookup: the state, or why the poll could not be made — a poll's own
     * failure is never the payment's status. Carried as the Android client answers it.
     */
    @ReactMethod
    fun merchantContextStatus(txRef: String, promise: Promise) = withInit(promise) {
        scope.launch {
            try {
                val result = client().contextStatus(txRef)
                promise.resolve(
                    Mappers.lookup(result.status?.let { Mappers.paymentContextStatus(it) }, result.failureReason, result.message),
                )
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    // ── Merchant: charge a customer QR (CPM) ────────────────────────────────────

    @ReactMethod
    fun merchantInspectCustomerQr(payload: String, promise: Promise) = withInit(promise) {
        val inspection = softpos().cpmCustomerQrService.inspect(payload)
        // A handle is issued only for a QR that can be charged; the card data stays native.
        val handle = inspection.qr?.let { cpmQrs.put(it) }
        promise.resolve(Mappers.customerQrInspection(inspection, handle))
    }

    @ReactMethod
    fun merchantChargeCustomerQr(handle: String, merchantOrderId: String?, promise: Promise) =
        withInit(promise) {
            val scanned = cpmQrs.take(handle)
                ?: return@withInit promise.resolve(
                    Mappers.customerQrChargeNotSent(Mappers.INVALID_REQUEST, "Unknown or already-used QR handle — re-scan"),
                )
            scope.launch {
                try {
                    val response = softpos().cpmCustomerQrService
                        .charge(scanned, merchantOrderId = merchantOrderId.orEmpty())
                    promise.resolve(Mappers.customerQrCharge(response))
                } catch (t: Throwable) {
                    VeyraPromises.reject(promise, t)
                }
            }
        }

    // ── Merchant: transactions & receipts ───────────────────────────────────────

    @ReactMethod
    fun merchantGetTransactions(limit: Int, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                val rows = softpos().transactionService.getLastTransactions(limit)
                val array = Arguments.createArray()
                rows.forEach { array.pushMap(Mappers.merchantTransaction(it)) }
                promise.resolve(array)
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun merchantGetTransaction(reference: String, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                val row = softpos().transactionService.getTransaction(reference)
                promise.resolve(row?.let { Mappers.merchantTransaction(it) })
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    /**
     * The on-demand "check status now" for one merchant transaction. Unlike
     * [merchantGetTransaction] above this goes to the gateway; a check that could not be made
     * resolves with its `failureReason` (`NO_NETWORK_CONNECTION` included) and the row untouched.
     */
    /** Lookup by the app's own order id — a read: resolves a `VeyraLookup<OrderPaymentStatus>`. */
    @ReactMethod
    fun merchantPaymentStatus(merchantOrderId: String, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                promise.resolve(Mappers.orderPaymentLookup(softpos().transactionService.paymentStatus(merchantOrderId)))
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun merchantRefreshTransactionStatus(reference: String, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                promise.resolve(Mappers.merchantTransactionLookup(softpos().transactionService.refreshTransactionStatus(reference)))
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    /**
     * "Check merchant credit now" for one sale. Unlike [merchantGetTransaction] this goes
     * to the gateway; a check that could not be made resolves with its `failureReason`
     * (`NO_NETWORK_CONNECTION` included). An ineligible row makes no call and resolves unchanged.
     */
    @ReactMethod
    fun merchantRefreshCreditConfirmation(reference: String, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                promise.resolve(Mappers.merchantTransactionLookup(softpos().transactionService.refreshCreditConfirmation(reference)))
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun merchantGetReceipt(reference: String, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                val receipt = softpos().transactionService.generateTransactionReceipt(reference)
                promise.resolve(receipt?.let { Mappers.merchantReceipt(it) })
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    // ── Event-emitter plumbing (required by NativeEventEmitter) ─────────────────

    /**
     * The customer has logged out: both SDKs stop everything they run for them and drop every
     * observer; their data stays on the device. Every data call is refused until the next
     * [initialize].
     */
    @ReactMethod
    fun signOut(promise: Promise) {
        try {
            VeyraSdk.signOut()
            signedIn = false
            customerId = null
            promise.resolve(null)
        } catch (t: Throwable) {
            VeyraPromises.reject(promise, t)
        }
    }

    @ReactMethod
    fun addListener(@Suppress("UNUSED_PARAMETER") eventName: String) = Unit

    @ReactMethod
    fun removeListeners(@Suppress("UNUSED_PARAMETER") count: Int) = Unit

    // ── Host lifecycle: re-attach after Activity recreation ─────────────────────

    override fun onHostResume() {
        if (!initialized) return
        val activity = hostActivity() ?: return
        // Process singletons must re-bind to the recreated Activity (reader service);
        // lifecycle observers stay unbound — the focus session drives the mode.
        val customer = customerId ?: return // signed out: nothing to re-attach for
        val provider = softposProvider ?: return
        softposConfig?.let { VeyraSoftPOSSdk.initializeHosted(activity, customer, it, provider) }
    }

    override fun onHostPause() = Unit
    override fun onHostDestroy() = Unit

    // ── Helpers ─────────────────────────────────────────────────────────────────

    private fun notInitialised() = VeyraSetupException(VeyraSetupCode.NOT_CONFIGURED, "Call Veyra.initialize first")

    private fun wallet(): VeyraWalletSdk = VeyraWalletSdk.getInstance() ?: throw notInitialised()

    private fun softpos(): VeyraSoftPOSSdk = VeyraSoftPOSSdk.getInstance() ?: throw notInitialised()

    private fun client(): ContextPaymentClient = contextClient ?: throw notInitialised()

    private object EventNames {
        const val ACTIVATION = "VeyraActivationEvent"
        const val WALLET_TAP = "VeyraWalletTapEvent"
        const val MERCHANT_TAP = "VeyraMerchantTapEvent"
        const val QR_EXPIRED = "VeyraQrExpiredEvent"

        /**
         * a payment was refused before any proof was built. Its own channel rather than a
         * `walletTap` phase: refusals are per card and fire on the QR rails too,
         * neither of which is a tap.
         */
        const val PAYMENT_REFUSAL = "VeyraPaymentRefusalEvent"

        /**
         * a payment the app was left waiting on has resolved. Emitted for any transaction that
         * stops being pending — including one started in an earlier app session and settled by a later
         * poll — so a JS confirmation screen showing "processing" can finish without polling the store.
         */
        const val TRANSACTION_RESOLVED = "VeyraTransactionResolvedEvent"

        /**
         * the funds of an approved sale were confirmed in the merchant's bank account
         * (`RECEIVED`), or the 30-day window closed unconfirmed (`UNABLE_TO_CONFIRM`). Settlement
         * confirmation only — never a change to the payment outcome. Fires on both platforms
         * (The iOS bridge is wired to the same shared observer.)
         */
        const val CREDIT_CONFIRMATION = "VeyraCreditConfirmationEvent"

        /**
         * The issuer changed a card's status — suspended, reactivated,
         * expired, deactivated. The sharp case is a card suspended server-side while the customer
         * is looking at a card screen: without this the app finds out only if it reads again, and
         * a screen already on-screen never does.
         */
        const val TOKEN_STATUS_CHANGED = "VeyraTokenStatusChangedEvent"

        /**
         * A **wallet** payment left `PENDING` reached a final outcome. The
         * payer-side twin of [TRANSACTION_RESOLVED], which is the merchant's side of the same
         * payment — the two carry different identifiers and are not interchangeable.
         */
        const val WALLET_TRANSACTION_RESOLVED = "VeyraWalletTransactionResolvedEvent"

        /**
         * A card's payment keys ran out, or a refresh replenished them —
         * `requiresOnline` flipping. Covers key consumption and refresh, **not** keys expiring by
         * clock (nothing runs then); such a card reads as requires-online on the next card read.
         */
        const val CARD_KEY_STATE = "VeyraCardKeyStateEvent"

        /**
         * The merchant was deactivated, suspended or activated. Lets an app
         * stop accepting payments at once rather than at the next screen load.
         */
        const val MERCHANT_STATUS = "VeyraMerchantStatusEvent"
    }
}
