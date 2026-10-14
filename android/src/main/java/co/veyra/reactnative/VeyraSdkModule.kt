package co.veyra.reactnative

import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.FragmentActivity
import co.veyra.common.VeyraEnvironment
import co.veyra.common.VeyraErrorCode
import co.veyra.common.VeyraError
import co.veyra.core.NfcMode
import co.veyra.reactnative.Mappers.opt
import co.veyra.reactnative.Mappers.optRequestTimeoutSeconds
import co.veyra.reactnative.Mappers.optStringList
import co.veyra.reactnative.Mappers.req
import co.veyra.sdk.VeyraSdk
import co.veyra.sdk.VeyraSdkConfig
import co.veyra.sdk.internal.SingleActivityModeSession
import co.veyra.softpos.payment.sdk.VeyraSoftPOSSdk
import co.veyra.softpos.payment.sdk.VeyraSoftPosSdkConfig
import co.veyra.softpos.payment.sdk.cpm.ScannedCustomerQr
import co.veyra.wallet.sdk.ActivationMedium
import co.veyra.wallet.sdk.ActivationReason
import co.veyra.wallet.sdk.VeyraWalletSdk
import co.veyra.wallet.sdk.WalletTapEvent
import co.veyra.wallet.sdk.VeyraWalletSdkConfig
import co.veyra.wallet.sdk.api.mpm.ScanInspection
import co.veyra.wallet.sdk.api.mpm.VerifiedPayment
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
 * Activity-lifecycle observers (`VeyraSdk.initializeHosted`: wallet with `activity = null`,
 * SoftPOS hosted) and the exclusive NFC mode is driven solely by the
 * focus-bridged [SingleActivityModeSession] — JS screen focus opens/closes it. The calls
 * that arm NFC (`softposTapStart`, `walletSetActiveCard`) are gated on the session
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
    private val mpmContexts = HandleRegistry<VerifiedPayment>()
    private val cpmQrs = HandleRegistry<ScannedCustomerQr>()
    private val connections = ConnectionBridge(reactContext)

    @Volatile private var initialized = false
    /** False after [signOut] until the next [initialize]: every data call is refused. */
    @Volatile private var signedIn = false
    @Volatile private var customerId: String? = null
    @Volatile private var softposConfig: VeyraSoftPosSdkConfig? = null
    @Volatile private var softposProvider: co.veyra.common.providers.VeyraProvider? = null

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
        val softpos = softpos()
        // registered per signed-in customer rather than per payment — the case
        // that most needs it is a tap that resolves after the app was backgrounded. The SDK fires on its
        // poller's thread; hop to the JS thread the way every other event here does.
        softpos.observeTransactionResolved { r ->
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                emit(EventNames.TRANSACTION_RESOLVED, Mappers.transactionResolved(r))
            }
        }
        // same app-scoped shape for the credit-receipt confirmation — funds can be
        // confirmed days after the sale, long after any per-payment JS callback is gone. A later change
        // gave RN iOS the same channel off the Swift facade's forwarder, so this event now fires
        // identically on both platforms with the same name and the same payload.
        softpos.observeCreditConfirmation { c ->
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
        VeyraWalletSdk.getInstance()?.let { wallet ->
            wallet.observeTokenStatusChanged { c ->
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    emit(EventNames.TOKEN_STATUS_CHANGED, Mappers.tokenStatusChanged(c))
                }
            }
            wallet.observeTransactionResolved { r ->
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    emit(EventNames.WALLET_TRANSACTION_RESOLVED, Mappers.walletTransactionResolved(r))
                }
            }
            wallet.observeTokenKeyStateChanged { s ->
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    emit(EventNames.TOKEN_KEY_STATE, Mappers.tokenKeyState(s))
                }
            }
            // Tap-to-pay, for whichever card is active — the same `walletTap` payloads as before.
            wallet.observeTapEvents { e ->
                when (e) {
                    is WalletTapEvent.TransactionStarted ->
                        emit(EventNames.WALLET_TAP, Arguments.createMap().apply {
                            putString("type", "transactionStarted")
                            putString("tokenUniqueReference", e.tokenUniqueReference)
                        })
                    is WalletTapEvent.TransactionCompleted -> {
                        val r = e.response
                        emit(EventNames.WALLET_TAP, Arguments.createMap().apply {
                            putString("type", "transactionCompleted")
                            putString("status", r.status)
                            putString("message", r.message)
                            r.amountMinorUnits?.let { putDouble("amountMinorUnits", it.toDouble()) }
                                ?: putNull("amountMinorUnits")
                            putString("tokenUniqueReference", r.tokenUniqueReference)
                            putString("cardScheme", r.cardScheme?.name)
                            putString("reference", r.reference)
                        })
                    }
                }
            }
        }
        softpos.observeMerchantStatusChanged { c ->
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
            VeyraPromises.reject(promise, VeyraErrorCode.NOT_CONFIGURED, "Call Veyra.initialize first")
            return
        }
        if (!signedIn) {
            VeyraPromises.reject(
                promise, VeyraErrorCode.NOT_SIGNED_IN,
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
                    promise, VeyraErrorCode.NOT_CONFIGURED, "No Activity attached yet — call after the app is on screen"
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
                environment = VeyraEnvironment.fromString(softposMap.req("environment"))
                    ?: throw IllegalArgumentException("environment must be TEST or LIVE"),
                paymentAppProviderId = softposMap.req("paymentAppProviderId"),
            ).apply {
                if (softposMap.hasKey("enableNfc")) enableNfc(softposMap.getBoolean("enableNfc"))
                requestTimeoutSeconds(softposMap.optRequestTimeoutSeconds("softpos"))
            }.build()

            val wallet = VeyraWalletSdkConfig.builder(
                environment = VeyraEnvironment.fromString(walletMap.req("environment"))
                    ?: throw IllegalArgumentException("environment must be TEST or LIVE"),
                paymentAppProviderId = walletMap.req("paymentAppProviderId"),
                tokenRequestorId = walletMap.req("tokenRequestorId"),
            ).apply {
                if (walletMap.hasKey("enableNfc")) enableNfc(walletMap.getBoolean("enableNfc"))
                walletMap.opt("appVersion")?.let { appVersion(it) }
                walletMap.opt("recommendationStandardVersion")
                    ?.let { recommendationStandardVersion(it) }
                walletMap.optStringList("allowedAcquirerIds")?.let { allowedAcquirerIds(it) }
                walletMap.optStringList("allowedMerchantIds")?.let { allowedMerchantIds(it) }
                if (walletMap.hasKey("cdcvmAllowDeviceCredential")) {
                    cdcvmAllowDeviceCredential(walletMap.getBoolean("cdcvmAllowDeviceCredential"))
                }
                cdcvmPayPrompt(walletMap.opt("cdcvmPayTitle"), walletMap.opt("cdcvmPaySubtitle"))
                cdcvmShowQrPrompt(walletMap.opt("cdcvmShowQrTitle"), walletMap.opt("cdcvmShowQrSubtitle"))
                requestTimeoutSeconds(walletMap.optRequestTimeoutSeconds("wallet"))
            }.build()

            // The umbrella installs the exclusive arbiter + InertBackstop (reset to inert), then
            // sets up both member SDKs WITHOUT lifecycle binding (single-Activity host: the focus
            // session drives the mode, never the Activity observers).
            VeyraSdk.initializeHosted(activity, customer, VeyraSdkConfig(softpos, wallet), walletProvider, softposProvider)
            registerObservers()

            softposConfig = softpos
            this.softposProvider = softposProvider
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
            ?: return@withInit VeyraPromises.reject(promise, VeyraErrorCode.NOT_CONFIGURED, "No Activity attached")
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

    // ── Pay session: the same three calls as native Android and iOS ─────────────

    private fun PaySessionAnswer.toMap(): WritableMap = Arguments.createMap().apply {
        putString("responseStatus", status)
        putString("responseStatusReason", reason)
        putString("message", message)
    }

    /**
     * `wallet.openPaySession()` — arms tap-to-pay on the pay screen, answering like
     * `VeyraWalletSdk.openPaySession`. On a refusal nothing changes: a session that was not open
     * before stays closed. The `usePaySession` hook still declares the screen; this re-arms within it
     * (for example after `closePaySession` on a timeout).
     */
    @ReactMethod
    fun walletOpenPaySession(promise: Promise) = withInit(promise) {
        val activity = hostActivity()
        val adapter = android.nfc.NfcAdapter.getDefaultAdapter(reactContext)
        PaySessionAnswer.preflight(
            screenInFront = activity != null,
            nfcPresent = adapter != null,
            nfcEnabled = adapter?.isEnabled == true,
        )?.let { return@withInit promise.resolve(it.toMap()) }
        activity!!.runOnUiThread {
            try {
                val wasOpen = session.sessionMode == NfcMode.WALLET
                if (session.open(NfcMode.WALLET, activity)) {
                    promise.resolve(PaySessionAnswer.OPENED.toMap())
                } else {
                    // A SoftPOS payment holds the radio. FAILED means nothing changed.
                    if (!wasOpen) session.close()
                    promise.resolve(PaySessionAnswer.MODE_REFUSED.toMap())
                }
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    /** `wallet.closePaySession()` — disarms tap-to-pay at once; safe with no session open. */
    @ReactMethod
    fun walletClosePaySession(promise: Promise) = sessionClose("pay", promise)

    /** `wallet.isPaySessionOpen()`. */
    @ReactMethod
    fun walletIsPaySessionOpen(promise: Promise) = withInit(promise) {
        promise.resolve(session.sessionMode == NfcMode.WALLET)
    }

    private fun requireSession(mode: NfcMode, promise: Promise): Boolean {
        if (session.sessionMode != mode) {
            val hook = if (mode == NfcMode.WALLET) "usePaySession" else "useGetPaidSession"
            VeyraPromises.reject(
                promise, VeyraErrorCode.SESSION_REQUIRED,
                "This payment API arms NFC and needs its screen session open — mount $hook on the payment screen"
            )
            return false
        }
        return true
    }

    // ── Wallet: add card / digitise ─────────────────────────────────────────────

    @ReactMethod
    fun walletGetBanks(accountNumber: String?, promise: Promise) = withInit(promise) {
        wallet().getBanks(accountNumber) { promise.resolve(Mappers.bankList(it)) }
    }

    @ReactMethod
    fun walletVerifyAccount(params: ReadableMap, promise: Promise) = withInit(promise) {
        val request = try {
            Mappers.verifyAccountParams(params)
        } catch (e: IllegalArgumentException) {
            return@withInit promise.resolve(Mappers.verifyAccountRefused(Mappers.INVALID_REQUEST, e.message ?: "Invalid request"))
        }
        wallet().verifyAccount(request) { promise.resolve(Mappers.verifyAccount(it)) }
    }

    @ReactMethod
    fun walletDigitise(params: ReadableMap, promise: Promise) = withInit(promise) {
        val request = try {
            Mappers.digitiseParams(params)
        } catch (e: IllegalArgumentException) {
            return@withInit promise.resolve(Mappers.digitiseNotSent(Mappers.INVALID_REQUEST, e.message ?: "Invalid request"))
        }
        wallet().digitise(request) { promise.resolve(Mappers.digitiseResult(it)) }
    }

    /**
     * Cancels the digitise started with [clientRequestId] (set from `params.clientRequestId` by
     * [Mappers.digitiseParams]); resolves with the CancelResult name.
     */
    @ReactMethod
    fun walletCancelDigitise(clientRequestId: String, promise: Promise) = withInit(promise) {
        promise.resolve(Mappers.cancelResult(wallet().cancelDigitise(clientRequestId)))
    }

    // ── Wallet: activation ──────────────────────────────────────────────────────

    @ReactMethod
    fun walletRequestActivationCode(
        ref: String, medium: String, reason: String, promise: Promise
    ) = withInit(promise) {
        // The channel the code goes to is the method itself, on every platform — there is no
        // separate contact to send.
        val activationMedium = ActivationMedium.entries.firstOrNull { it.value == medium }
            ?: return@withInit promise.resolve(
                Mappers.activationCodeRefused(Mappers.INVALID_REQUEST, "Unknown activation medium: $medium"),
            )
        val activationReason = ActivationReason.entries.firstOrNull { it.value == reason } ?: ActivationReason.OTHER
        wallet().requestActivationCode(ref, activationMedium, activationReason) {
            promise.resolve(Mappers.activationCode(it))
        }
    }

    @ReactMethod
    fun walletActivate(ref: String, code: String, promise: Promise) = withInit(promise) {
        wallet().activate(ref, code) { promise.resolve(Mappers.activate(it)) }
    }

    @ReactMethod
    fun walletTokenStatus(ref: String, promise: Promise) = withInit(promise) {
        wallet().tokenStatus(ref) { promise.resolve(Mappers.tokenStatusResult(it)) }
    }

    @ReactMethod
    fun walletObserveActivation(ref: String, promise: Promise) = withInit(promise) {
        wallet().observeActivation(
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
        wallet().pauseActivationObserver(ref); promise.resolve(null)
    }

    @ReactMethod
    fun walletResumeActivationObserver(ref: String, promise: Promise) = withInit(promise) {
        wallet().resumeActivationObserver(ref); promise.resolve(null)
    }

    @ReactMethod
    fun walletStopActivationObserver(ref: String, promise: Promise) = withInit(promise) {
        wallet().stopActivationObserver(ref); promise.resolve(null)
    }

    @ReactMethod
    fun walletHasActivationObserver(ref: String, promise: Promise) = withInit(promise) {
        promise.resolve(wallet().hasActivationObserver(ref))
    }

    // ── Wallet: tokens ──────────────────────────────────────────────────────────

    @ReactMethod
    fun walletGetTokens(promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                val tokens = wallet().getTokens()
                val array = Arguments.createArray()
                tokens.forEach { array.pushMap(Mappers.token(it)) }
                promise.resolve(array)
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun walletGetActiveToken(promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                promise.resolve(wallet().getActiveToken()?.let { Mappers.token(it) })
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun walletGetToken(tokenUniqueReference: String, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                promise.resolve(wallet().getToken(tokenUniqueReference)?.let { Mappers.token(it) })
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun walletGetPaymentApplicationInstanceId(promise: Promise) = withInit(promise) {
        promise.resolve(wallet().getPaymentApplicationInstanceId())
    }

    @ReactMethod
    fun walletSetActiveToken(tokenUniqueReference: String, promise: Promise) = withInit(promise) {
        // Arms tap-to-pay for this card — pay session required (the iOS bridge gates it the same).
        // Tap events reach JS through the wallet's tap observer (registerObservers), refusals
        // per card through `wallet.observePaymentRefusals`.
        if (!requireSession(NfcMode.WALLET, promise)) return@withInit
        // A card whose payment data is missing answers FAILED / CARD_DATA_MISSING here, as on
        // native Android; no separate tap event (parity — native has none).
        val selection = wallet().setActiveToken(tokenUniqueReference)
        promise.resolve(Mappers.cardSelection(selection))
    }

    /**
     * Arm refusal delivery for one card. JS keeps the listener map; this decides
     * whether a refusal for that card crosses the bridge at all.
     */
    @ReactMethod
    fun walletObservePaymentRefusals(tokenUniqueReference: String, promise: Promise) = withInit(promise) {
        wallet().observePaymentRefusals(
            tokenUniqueReference = tokenUniqueReference,
            onRequireOnline = { emit(EventNames.PAYMENT_REFUSAL, Mappers.paymentRefusal(it)) },
            onAmountExceedCardLimit = { emit(EventNames.PAYMENT_REFUSAL, Mappers.paymentRefusal(it)) },
            onDeviceNotBound = { emit(EventNames.PAYMENT_REFUSAL, Mappers.paymentRefusal(it)) },
        )
        promise.resolve(null)
    }

    /** Release one card's refusal registration; other cards are unaffected. */
    @ReactMethod
    fun walletStopObservingPaymentRefusals(tokenUniqueReference: String, promise: Promise) = withInit(promise) {
        wallet().stopObservingPaymentRefusals(tokenUniqueReference)
        promise.resolve(null)
    }

    @ReactMethod
    fun walletDeactivateToken(ref: String, promise: Promise) = withInit(promise) {
        wallet().deactivateToken(ref) { promise.resolve(Mappers.tokenStatusUpdate(it)) }
    }

    @ReactMethod
    fun walletDeactivateDigitise(clientRequestId: String, promise: Promise) = withInit(promise) {
        wallet().deactivateDigitise(clientRequestId) { promise.resolve(Mappers.tokenStatusUpdate(it)) }
    }

    // ── Wallet: scan-to-pay (MPM) ───────────────────────────────────────────────

    @ReactMethod
    fun walletInspectScannedQr(payload: String, promise: Promise) = withInit(promise) {
        val result = wallet().inspectScannedQr(payload)
        val handle = (result as? ScanInspection.Verified)?.let { mpmContexts.put(it.context) }
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
        wallet().payScannedContext(context) { result ->
            result.fold(
                { promise.resolve(Mappers.paymentOutcome(it)) },
                { VeyraPromises.reject(promise, it) },
            )
        }
    }

    /** Cancels the scan-to-pay of the QR carrying [merchantOrderId]; resolves with the CancelResult name. */
    @ReactMethod
    fun walletCancelPayment(merchantOrderId: String, promise: Promise) = withInit(promise) {
        promise.resolve(Mappers.cancelResult(wallet().cancelPayment(merchantOrderId)))
    }

    // ── Wallet: show-QR-to-pay (CPM) ────────────────────────────────────────────

    @ReactMethod
    fun walletShowQrToPay(amountMinorUnits: Double, promise: Promise) = withInit(promise) {
        wallet().showQrToPay(
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
        wallet().cancelQrExpiry(); promise.resolve(null)
    }

    // ── Wallet: history & receipts ──────────────────────────────────────────────

    @ReactMethod
    fun walletGetTransactions(ref: String, limit: Int, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                val rows = wallet().getTransactions(ref, limit)
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
        wallet().reconcilePendingTransactions { result ->
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
                promise.resolve(Mappers.transactionLookup(wallet().refreshTransactionStatus(transactionHash)))
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
                promise.resolve(Mappers.transactionLookup(wallet().refreshCreditConfirmation(transactionHash)))
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun walletProcessReceipt(payload: String, expectedHash: String?, promise: Promise) =
        withInit(promise) {
            wallet().processReceipt(payload, expectedHash) { result ->
                promise.resolve(Mappers.receiptScan(result))
            }
        }

    @ReactMethod
    fun walletGetReceipts(limit: Int, promise: Promise) = withInit(promise) {
        scope.launch(Dispatchers.IO) {
            try {
                val rows = wallet().getReceipts(limit)
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
                val receipt = wallet().getReceiptForTransaction(hash)
                promise.resolve(receipt?.let { Mappers.receipt(it) })
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    // ── SoftPOS: registration & profile ─────────────────────────────────────────
    //
    // Every call below goes through the public `VeyraSoftPOSSdk` API — the same calls a native
    // Android app makes. A call that needs the stored merchant and finds none is answered by the SDK
    // itself (`MISSING_MANDATORY_CONFIG`: `NOT_SENT` for a payment, `FAILED` otherwise).

    @ReactMethod
    fun softposRegister(registration: ReadableMap, promise: Promise) = withInit(promise) {
        val data = try {
            Mappers.merchantRegistration(registration)
        } catch (e: IllegalArgumentException) {
            return@withInit promise.resolve(
                Mappers.merchantRegistrationRefused(Mappers.INVALID_REQUEST, e.message ?: "Invalid request"),
            )
        }
        softpos().register(data) { promise.resolve(Mappers.merchantRegistrationResult(it)) }
    }

    @ReactMethod
    fun softposGetBanks(promise: Promise) = withInit(promise) {
        softpos().getBanks { promise.resolve(Mappers.settlementBankList(it)) }
    }

    @ReactMethod
    fun softposIsRegistered(promise: Promise) = withInit(promise) {
        promise.resolve(softpos().isRegistered())
    }

    @ReactMethod
    fun softposGetStoredMerchantData(promise: Promise) = withInit(promise) {
        promise.resolve(softpos().getStoredMerchantData()?.let { Mappers.storedMerchant(it) })
    }

    @ReactMethod
    fun softposGetStoredMerchantId(promise: Promise) = withInit(promise) {
        promise.resolve(softpos().getStoredMerchantId())
    }

    @ReactMethod
    fun softposHasStoredMerchant(promise: Promise) = withInit(promise) {
        promise.resolve(softpos().hasStoredMerchant())
    }

    @ReactMethod
    fun softposIsMerchantActive(promise: Promise) = withInit(promise) {
        promise.resolve(softpos().isMerchantActive())
    }

    /**
     * Init-free: [customerId]'s stored merchant, read before `Veyra.initialize` — no init or
     * sign-in gate, nothing started (the Home-screen "Get paid" decision).
     */
    @ReactMethod
    fun softposGetStoredMerchantDataFor(customerId: String, promise: Promise) {
        try {
            promise.resolve(
                VeyraSoftPOSSdk.getStoredMerchantData(reactContext.applicationContext, customerId)?.let { Mappers.storedMerchant(it) },
            )
        } catch (t: Throwable) {
            VeyraPromises.reject(promise, t)
        }
    }

    /** Init-free: whether [customerId] has a merchant registered on this device — see [softposGetStoredMerchantDataFor]. */
    @ReactMethod
    fun softposIsMerchantRegistered(customerId: String, promise: Promise) {
        try {
            promise.resolve(VeyraSoftPOSSdk.isMerchantRegistered(reactContext.applicationContext, customerId))
        } catch (t: Throwable) {
            VeyraPromises.reject(promise, t)
        }
    }

    @ReactMethod
    fun softposRefreshStatus(promise: Promise) = withInit(promise) {
        softpos().refreshStatus { promise.resolve(Mappers.merchantStatus(it)) }
    }

    @ReactMethod
    fun softposActivate(promise: Promise) = withInit(promise) {
        softpos().activate { promise.resolve(Mappers.merchantStatus(it)) }
    }

    @ReactMethod
    fun softposDeactivate(promise: Promise) = withInit(promise) {
        softpos().deactivate { promise.resolve(Mappers.merchantStatus(it)) }
    }

    @ReactMethod
    fun softposUpdateMerchant(update: ReadableMap, promise: Promise) = withInit(promise) {
        val data = try {
            Mappers.merchantUpdate(update)
        } catch (e: IllegalArgumentException) {
            // Raised by the argument reads, before anything reaches the SDK.
            return@withInit promise.resolve(Mappers.merchantStatusRefused(Mappers.INVALID_REQUEST, e.message ?: "Invalid request"))
        }
        softpos().updateMerchant(data) { promise.resolve(Mappers.merchantStatus(it)) }
    }

    // ── SoftPOS: tap acceptance ─────────────────────────────────────────────────

    @ReactMethod
    fun softposTapStart(request: ReadableMap, promise: Promise) = withInit(promise) {
        if (!requireSession(NfcMode.SOFTPOS, promise)) return@withInit
        // JS mints the session id and listens for it before calling, so no event — an immediate
        // NOT_SENT result included — can arrive before JS knows which tap it belongs to.
        val sessionId = request.opt("sessionId")?.takeIf { it.isNotBlank() } ?: UUID.randomUUID().toString()

        // the app's own order id, NOT a transaction reference — the SDK mints that and returns it
        // on the result. Required: untyped JS that omits it is passed through blank so
        // the SDK's rule refuses it with a NOT_SENT / INVALID_REQUEST result.
        val merchantOrderId = request.opt("merchantOrderId").orEmpty()
        val tapRequest = try {
            Mappers.tapRequest(request)
        } catch (e: IllegalArgumentException) {
            // A bad argument ends the tap the way the SDK ends a blank order id: a NOT_SENT result
            // on the event stream, with nothing armed.
            promise.resolve(Arguments.createMap().apply { putString("sessionId", sessionId) })
            // The bridge ended this tap itself, so the SDK never saw it: log the failure here.
            @OptIn(co.veyra.common.VeyraInternalApi::class)
            co.veyra.common.logging.failure.OperationFailureLog.report(
                operation = co.veyra.common.logging.failure.SdkOperation.MERCHANT_TAP,
                status = co.veyra.common.outcome.ResponseStatus.NOT_SENT,
                reason = Mappers.INVALID_REQUEST,
                stage = co.veyra.common.logging.failure.FailureStage.VALIDATE,
                ids = mapOf("merchant_order_id" to merchantOrderId),
            )
            emit(EventNames.SOFTPOS_TAP, Mappers.tapEventResult(sessionId,
                Mappers.tapResultNotSent(Mappers.INVALID_REQUEST, e.message ?: "Invalid request")))
            return@withInit
        }

        softpos().tap.start(tapRequest) { event ->
            emit(EventNames.SOFTPOS_TAP, Mappers.tapEvent(sessionId, event))
        }
        promise.resolve(Arguments.createMap().apply { putString("sessionId", sessionId) })
    }

    @ReactMethod
    fun softposIsTransactionInProgress(promise: Promise) = withInit(promise) {
        promise.resolve(softpos().isTransactionInProgress())
    }

    @ReactMethod
    fun softposIsAwaitingCardTap(promise: Promise) = withInit(promise) {
        promise.resolve(softpos().isAwaitingCardTap())
    }

    /**
     * Cancels the SoftPOS payment started with [merchantOrderId] — tap, customer-QR charge or
     * payment-QR create alike. Resolves with the [co.veyra.common.cancel.CancelResult] name; the
     * payment itself still ends with its own outcome (a tap's on its `result` event). Leaving the
     * get-paid screen needs no call here: the focus session's close tears down an armed tap itself.
     */
    @ReactMethod
    fun softposCancelPayment(merchantOrderId: String, promise: Promise) = withInit(promise) {
        promise.resolve(Mappers.cancelResult(softpos().cancelPayment(merchantOrderId)))
    }

    // ── SoftPOS: get-paid QR (MPM) ──────────────────────────────────────────────

    @ReactMethod
    fun softposCreatePaymentContext(
        amountMinorUnits: Double,
        currency: String,
        // the merchant's own order id, so the MPM rail carries it like tap and CPM do. Required
        // for every merchant payment; null from untyped JS reaches the SDK blank and is refused there.
        merchantOrderId: String?,
        promise: Promise,
    ) = withInit(promise) {
        val sdk = softpos()
        scope.launch {
            try {
                val created = sdk.createPaymentContext(
                    amountMinorUnits = amountMinorUnits.toLong(),
                    currency = currency,
                    merchantOrderId = merchantOrderId.orEmpty(),
                ) {
                    emit(EventNames.QR_EXPIRED, Arguments.createMap().apply {
                        putString("scope", "softpos")
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
    fun softposCancelQrExpiry(promise: Promise) = withInit(promise) {
        softpos().cancelQrExpiry(); promise.resolve(null)
    }

    /**
     * A context poll, as a lookup: the state, or why the poll could not be made — a poll's own
     * failure is never the payment's status.
     */
    @ReactMethod
    fun softposContextStatus(txRef: String, promise: Promise) = withInit(promise) {
        val sdk = softpos()
        scope.launch {
            try {
                val result = sdk.contextStatus(txRef)
                promise.resolve(
                    Mappers.lookup(result.value?.let { Mappers.paymentContextStatus(it) }, result.failureReason, result.message),
                )
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    // ── SoftPOS: charge a customer QR (CPM) ─────────────────────────────────────

    @ReactMethod
    fun softposInspectCustomerQr(payload: String, promise: Promise) = withInit(promise) {
        val inspection = softpos().inspectCustomerQr(payload)
        // A handle is issued only for a QR that can be charged; the card data stays native.
        val handle = inspection.qr?.let { cpmQrs.put(it) }
        promise.resolve(Mappers.customerQrInspection(inspection, handle))
    }

    @ReactMethod
    fun softposChargeCustomerQr(handle: String, merchantOrderId: String?, promise: Promise) =
        withInit(promise) {
            val scanned = cpmQrs.take(handle)
                ?: return@withInit promise.resolve(
                    Mappers.customerQrChargeNotSent(Mappers.INVALID_REQUEST, "Unknown or already-used QR handle — re-scan"),
                )
            val sdk = softpos()
            scope.launch {
                try {
                    promise.resolve(Mappers.customerQrCharge(sdk.chargeCustomerQr(scanned, merchantOrderId.orEmpty())))
                } catch (t: Throwable) {
                    VeyraPromises.reject(promise, t)
                }
            }
        }

    // ── SoftPOS: transactions & receipts ────────────────────────────────────────

    /** Runs [body] off the main thread; its answer resolves the promise, a throw rejects it. */
    private fun resolveOnIo(promise: Promise, body: suspend (VeyraSoftPOSSdk) -> Any?) {
        val sdk = softpos()
        scope.launch(Dispatchers.IO) {
            try {
                promise.resolve(body(sdk))
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    @ReactMethod
    fun softposGetTransactions(limit: Int, promise: Promise) = withInit(promise) {
        resolveOnIo(promise) { sdk ->
            Arguments.createArray().apply { sdk.getTransactions(limit).forEach { pushMap(Mappers.merchantTransaction(it)) } }
        }
    }

    @ReactMethod
    fun softposGetTransaction(reference: String, promise: Promise) = withInit(promise) {
        resolveOnIo(promise) { sdk -> sdk.getTransaction(reference)?.let { Mappers.merchantTransaction(it) } }
    }

    /** Lookup by the app's own order id — a read: resolves a `VeyraLookup<OrderPaymentStatus>`. */
    @ReactMethod
    fun softposPaymentStatus(merchantOrderId: String, promise: Promise) = withInit(promise) {
        resolveOnIo(promise) { sdk -> Mappers.orderPaymentLookup(sdk.paymentStatus(merchantOrderId)) }
    }

    /**
     * The on-demand "check status now" for one transaction. Unlike [softposGetTransaction] this goes
     * to the gateway; a check that could not be made resolves with its `failureReason`
     * (`NO_NETWORK_CONNECTION` included) and the row untouched.
     */
    @ReactMethod
    fun softposRefreshTransactionStatus(reference: String, promise: Promise) = withInit(promise) {
        resolveOnIo(promise) { sdk -> Mappers.merchantTransactionLookup(sdk.refreshTransactionStatus(reference)) }
    }

    /**
     * "Check merchant credit now" for one sale. Unlike [softposGetTransaction] this goes
     * to the gateway; a check that could not be made resolves with its `failureReason`
     * (`NO_NETWORK_CONNECTION` included). An ineligible row makes no call and resolves unchanged.
     */
    @ReactMethod
    fun softposRefreshCreditConfirmation(reference: String, promise: Promise) = withInit(promise) {
        resolveOnIo(promise) { sdk -> Mappers.merchantTransactionLookup(sdk.refreshCreditConfirmation(reference)) }
    }

    @ReactMethod
    fun softposGetReceipt(reference: String, promise: Promise) = withInit(promise) {
        resolveOnIo(promise) { sdk -> sdk.getReceipt(reference)?.let { Mappers.merchantReceipt(it) } }
    }

    /** The gateway's raw record of one transaction — a read: `VeyraLookup<TransactionStatus[]>`. */
    @ReactMethod
    fun softposGetTransactionStatus(reference: String, transactionDate: String, promise: Promise) = withInit(promise) {
        resolveOnIo(promise) { sdk -> Mappers.transactionStatusLookup(sdk.getTransactionStatus(reference, transactionDate)) }
    }

    /** The merchant bank's raw credit confirmation for one sale — a read: `VeyraLookup<CreditConfirmationEvent>`. */
    @ReactMethod
    fun softposGetCreditConfirmation(creditTransactionId: String, amountMinorUnits: Double, promise: Promise) =
        withInit(promise) {
            resolveOnIo(promise) { sdk ->
                Mappers.creditConfirmationLookup(sdk.getCreditConfirmation(creditTransactionId, amountMinorUnits.toLong()))
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

    private fun notInitialised() = VeyraError(VeyraErrorCode.NOT_CONFIGURED, "Call Veyra.initialize first")

    private fun wallet(): VeyraWalletSdk = VeyraWalletSdk.getInstance() ?: throw notInitialised()

    private fun softpos(): VeyraSoftPOSSdk = VeyraSoftPOSSdk.getInstance() ?: throw notInitialised()

    private object EventNames {
        const val ACTIVATION = "VeyraActivationEvent"
        const val WALLET_TAP = "VeyraWalletTapEvent"
        const val SOFTPOS_TAP = "VeyraSoftposTapEvent"
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
        const val TOKEN_KEY_STATE = "VeyraTokenKeyStateEvent"

        /**
         * The merchant was deactivated, suspended or activated. Lets an app
         * stop accepting payments at once rather than at the next screen load.
         */
        const val MERCHANT_STATUS = "VeyraMerchantStatusEvent"
    }
}

/** `wallet.openPaySession`'s answer, before it becomes a bridge map (which only exists on a device). */
internal data class PaySessionAnswer(val status: String, val reason: String? = null, val message: String? = null) {
    companion object {
        val OPENED = PaySessionAnswer("APPROVED")
        val MODE_REFUSED = PaySessionAnswer("FAILED", "MODE_REFUSED", "A SoftPOS payment is in progress; try again when it ends")

        /** The refusals known before touching the session, in the order native Android checks them; null = go ahead. */
        fun preflight(screenInFront: Boolean, nfcPresent: Boolean, nfcEnabled: Boolean): PaySessionAnswer? = when {
            !screenInFront -> PaySessionAnswer("FAILED", "SCREEN_NOT_ACTIVE", "No activity is in front; open the pay session from the live pay screen")
            !nfcPresent -> PaySessionAnswer("FAILED", "NFC_UNAVAILABLE", "This device has no NFC, so it cannot pay by tap")
            !nfcEnabled -> PaySessionAnswer("FAILED", "NFC_DISABLED", "NFC is switched off; turn it on to pay by tap")
            else -> null
        }
    }
}
