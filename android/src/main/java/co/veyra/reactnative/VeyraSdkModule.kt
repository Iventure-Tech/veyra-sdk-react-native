package co.veyra.reactnative

import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.FragmentActivity
import co.veyra.common.Environment
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
 * focus-bridged [SingleActivityModeSession] — JS screen focus opens/closes it. Tap APIs
 * are gated on the session (SESSION_REQUIRED), so a screen that forgot to mount its
 * session fails loud at development time instead of leaving the device armed.
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

    @Volatile private var initialized = false
    @Volatile private var softposConfig: VeyraSoftPosSdkConfig? = null
    @Volatile private var contextClient: ContextPaymentClient? = null
    @Volatile private var currentTapSessionId: String? = null

    init {
        reactContext.addLifecycleEventListener(this)
    }

    private fun emit(event: String, payload: WritableMap) {
        reactContext
            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
            .emit(event, payload)
    }

    private fun hostActivity(): AppCompatActivity? = currentActivity as? AppCompatActivity

    private inline fun withInit(promise: Promise, body: () -> Unit) {
        if (!initialized) {
            VeyraPromises.reject(promise, "NOT_CONFIGURED", "Call Veyra.initialize first")
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
                    promise, "NOT_CONFIGURED", "No Activity attached yet — call after the app is on screen"
                )
            val softposMap = config.getMap("softpos")
                ?: throw IllegalArgumentException("softpos config is required")
            val walletMap = config.getMap("wallet")
                ?: throw IllegalArgumentException("wallet config is required")

            val softpos = VeyraSoftPosSdkConfig.builder(
                environment = Environment.fromString(softposMap.req("environment"))
                    ?: throw IllegalArgumentException("environment must be TEST or LIVE"),
                clientId = softposMap.req("clientId"),
                clientSecret = softposMap.req("clientSecret"),
            ).apply {
                if (softposMap.hasKey("enableNfc")) enableNfc(softposMap.getBoolean("enableNfc"))
            }.build()

            val wallet = VeyraWalletSdkConfig.builder(
                environment = Environment.fromString(walletMap.req("environment"))
                    ?: throw IllegalArgumentException("environment must be TEST or LIVE"),
                paymentAppProviderId = walletMap.req("paymentAppProviderId"),
                tokenRequestorId = walletMap.req("tokenRequestorId"),
                allowedCountryCodes = walletMap.optStringList("allowedCountryCodes") ?: emptyList(),
                clientId = walletMap.req("clientId"),
                clientSecret = walletMap.req("clientSecret"),
            ).apply {
                if (walletMap.hasKey("enableNfc")) enableNfc(walletMap.getBoolean("enableNfc"))
                walletMap.opt("appVersion")?.let { appVersion(it) }
                walletMap.opt("recommendationStandardVersion")
                    ?.let { walletProviderTokenizationRecommendationStandardVersion(it) }
                walletMap.optStringList("allowedAcquirerIds")?.let { allowedAcquirerIds(it) }
                walletMap.optStringList("allowedMerchantIds")?.let { allowedMerchantIds(it) }
                walletMap.optStringList("allowedMccs")?.let { allowedMccs(it) }
            }.build()

            // Umbrella first: installs the exclusive arbiter + InertBackstop and resets
            // to inert. Then the member SDKs — WITHOUT lifecycle binding (single-Activity
            // host: the focus session drives the mode, never the Activity observers).
            VeyraSdk.initialize(activity, VeyraSdkConfig(softpos, wallet))
            VeyraWalletSdk.initialize(reactContext.applicationContext, wallet, activity = null)
            VeyraSoftPOSSdk.initializeHosted(activity, softpos)

            softposConfig = softpos
            contextClient = ContextPaymentClient(
                reactContext.applicationContext,
                softpos.environment!!,
                softpos.clientId,
                softpos.clientSecret,
            )
            initialized = true
            promise.resolve(null)
        } catch (t: Throwable) {
            VeyraPromises.reject(promise, t)
        }
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
            ?: return@withInit VeyraPromises.reject(promise, "NOT_CONFIGURED", "No Activity attached")
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
                promise, "SESSION_REQUIRED",
                "This payment API arms NFC and needs its screen session open — mount $hook on the payment screen"
            )
            return false
        }
        return true
    }

    // ── Wallet: add card / digitise ─────────────────────────────────────────────

    @ReactMethod
    fun walletGetBanks(accountNumber: String?, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.getBanks(accountNumber) { result ->
            result.fold(
                { promise.resolve(Mappers.banks(it)) },
                { VeyraPromises.reject(promise, it) },
            )
        }
    }

    @ReactMethod
    fun walletVerifyAccount(params: ReadableMap, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.checkAccountEligibility(Mappers.verifyAccountParams(params)) { result ->
            result.fold(
                { r ->
                    promise.resolve(Arguments.createMap().apply {
                        putString("responseCode", r.responseCode)
                        putString("message", r.message)
                        putBoolean("isApproved", r.responseCode == "APPROVED" || r.responseCode == "APPROVE_REQUIRE_AUTH")
                    })
                },
                { VeyraPromises.reject(promise, it) },
            )
        }
    }

    @ReactMethod
    fun walletDigitise(params: ReadableMap, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.digitizeAccount(Mappers.digitiseParams(params)) { response ->
            promise.resolve(Mappers.digitiseResult(response))
        }
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
        wallet().tokenisationService.requestActivationCode(ref, medium, contact ?: "", reasonCode) { result ->
            result.fold(
                { r ->
                    promise.resolve(Arguments.createMap().apply {
                        putString("tokenUniqueReference", r.tokenUniqueReference)
                        putString("expirationDateTime", r.expirationDateTime)
                        putString("status", r.status)
                        putString("message", r.message)
                    })
                },
                { VeyraPromises.reject(promise, it) },
            )
        }
    }

    @ReactMethod
    fun walletActivate(ref: String, code: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.activate(ref, code) { result ->
            result.fold(
                { r ->
                    promise.resolve(Arguments.createMap().apply {
                        putString("tokenUniqueReference", r.tokenUniqueReference)
                        putString("status", r.status)
                        putString("message", r.message)
                    })
                },
                { VeyraPromises.reject(promise, it) },
            )
        }
    }

    @ReactMethod
    fun walletCheckTokenActive(ref: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.checkTokenStatus(ref) { result ->
            result.fold({ promise.resolve(it) }, { VeyraPromises.reject(promise, it) })
        }
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
        // Arms tap-to-pay for this card — pay session required (ISSUE-free single-Activity contract).
        if (!requireSession(NfcMode.WALLET, promise)) return@withInit
        val activity = hostActivity()
        wallet().tokenisationService.setActiveToken(
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
        )
        promise.resolve(null)
    }

    @ReactMethod
    fun walletDeactivateCard(ref: String, promise: Promise) = withInit(promise) {
        wallet().tokenisationService.deactivateToken(ref) { result ->
            result.fold({ promise.resolve(null) }, { VeyraPromises.reject(promise, it) })
        }
    }

    // ── Wallet: scan-to-pay (MPM) ───────────────────────────────────────────────

    @ReactMethod
    fun walletInspectScannedQr(payload: String, promise: Promise) = withInit(promise) {
        val result = wallet().tokenisationService.inspectScannedQr(payload)
        val handle = (result as? MpmScanResult.Verified)?.let { mpmContexts.put(it.context) }
        promise.resolve(Mappers.scanInspection(result, handle))
    }

    @ReactMethod
    fun walletAuthenticateForPayment(
        title: String, subtitle: String?, allowDeviceCredential: Boolean, promise: Promise
    ) = withInit(promise) {
        val activity = hostActivity() as? FragmentActivity
            ?: return@withInit VeyraPromises.reject(promise, "NOT_CONFIGURED", "No Activity attached")
        activity.runOnUiThread {
            wallet().tokenisationService.authenticateForScannedPayment(
                activity, title, subtitle, allowDeviceCredential
            ) { result ->
                result.fold({ promise.resolve(null) }, { VeyraPromises.reject(promise, it) })
            }
        }
    }

    @ReactMethod
    fun walletPayScannedContext(handle: String, promise: Promise) = withInit(promise) {
        val context = mpmContexts.take(handle)
            ?: return@withInit VeyraPromises.reject(
                promise, "VALIDATION", "Unknown or already-used payment handle — re-inspect the QR"
            )
        wallet().tokenisationService.payScannedContext(context) { result ->
            result.fold(
                { promise.resolve(Mappers.paymentOutcome(it)) },
                { VeyraPromises.reject(promise, it) },
            )
        }
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
            result.fold({ promise.resolve(null) }, { VeyraPromises.reject(promise, it) })
        }
    }

    @ReactMethod
    fun walletProcessReceipt(payload: String, expectedHash: String?, promise: Promise) =
        withInit(promise) {
            wallet().tokenisationService.processReceipt(payload, expectedHash) { result ->
                result.fold(
                    { promise.resolve(Mappers.receipt(it)) },
                    { VeyraPromises.reject(promise, it) },
                )
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
        val (type, data) = Mappers.merchantRegistration(registration)
        val callback = { r: co.veyra.softpos.payment.sdk.merchant.MerchantRegistrationResponse ->
            promise.resolve(Mappers.merchantRegistrationResult(r))
        }
        when (type) {
            "PERSONAL" -> softpos().merchantService.registerPersonalMerchant(data, callback)
            "BUSINESS" -> softpos().merchantService.registerBusinessMerchant(data, callback)
            else -> throw IllegalArgumentException("merchantType must be PERSONAL or BUSINESS")
        }
    }

    @ReactMethod
    fun merchantGetSettlementBanks(promise: Promise) = withInit(promise) {
        softpos().merchantService.getBanks { banks ->
            if (banks == null) {
                VeyraPromises.reject(promise, "REQUEST_FAILED", "Could not load settlement banks")
            } else {
                promise.resolve(Mappers.nubanBanks(banks))
            }
        }
    }

    @ReactMethod
    fun merchantIsRegistered(promise: Promise) = withInit(promise) {
        promise.resolve(softpos().merchantService.isRegistered())
    }

    @ReactMethod
    fun merchantGetStored(promise: Promise) = withInit(promise) {
        promise.resolve(softpos().merchantService.getStoredMerchantData()?.let { Mappers.storedMerchant(it) })
    }

    @ReactMethod
    fun merchantClearStored(promise: Promise) = withInit(promise) {
        softpos().merchantService.clearStoredMerchant(); promise.resolve(null)
    }

    @ReactMethod
    fun merchantRefreshStatus(promise: Promise) = withInit(promise) {
        // Android's refresh is fire-and-forget; resolve the last-known stored status
        // (the refresh continues in the background and updates the stored profile).
        softpos().merchantService.refreshStatus()
        promise.resolve(softpos().merchantService.getStoredMerchantData()?.merchantStatus)
    }

    @ReactMethod
    fun merchantActivate(promise: Promise) = withInit(promise) {
        softpos().merchantService.activate { r -> promise.resolve(r?.merchantStatus) }
    }

    @ReactMethod
    fun merchantDeactivate(promise: Promise) = withInit(promise) {
        softpos().merchantService.deactivate { r -> promise.resolve(r?.merchantStatus) }
    }

    @ReactMethod
    fun merchantUpdate(update: ReadableMap, promise: Promise) = withInit(promise) {
        softpos().merchantService.updateMerchant(
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
        ) { r -> promise.resolve(r?.merchantStatus) }
    }

    // ── Merchant: tap acceptance ────────────────────────────────────────────────

    @ReactMethod
    fun merchantTapStart(request: ReadableMap, promise: Promise) = withInit(promise) {
        if (!requireSession(NfcMode.SOFTPOS, promise)) return@withInit
        val sessionId = UUID.randomUUID().toString()
        val amount = request.getDouble("amountMinorUnits").toLong()
        val currency = request.opt("currency") ?: "0566"
        val reference = request.opt("merchantTransactionReference")
            ?: "${System.currentTimeMillis()}_${(1000..9999).random()}"
        val txType = TransactionRequest.TxType.valueOf(request.opt("txType") ?: "PURCHASE")

        fun tapEvent(type: String): WritableMap = Arguments.createMap().apply {
            putString("type", type)
            putString("sessionId", sessionId)
        }

        currentTapSessionId = sessionId
        softpos().cardPaymentService.makeCardPayment(
            TransactionRequest.Builder(amount, reference, currency, txType).build(),
            callback = { response ->
                if (currentTapSessionId == sessionId) currentTapSessionId = null
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

    @ReactMethod
    fun merchantTapCancel(sessionId: String, promise: Promise) = withInit(promise) {
        if (currentTapSessionId == sessionId) {
            softpos().cardPaymentService.cancelPendingPayment()
            currentTapSessionId = null
        }
        promise.resolve(null)
    }

    // ── Merchant: get-paid QR (MPM) ─────────────────────────────────────────────

    @ReactMethod
    fun merchantCreatePaymentContext(amountMinorUnits: Double, currency: String, promise: Promise) =
        withInit(promise) {
            val merchantId = softpos().merchantService.getStoredMerchantId()
                ?: return@withInit VeyraPromises.reject(
                    promise, "VALIDATION", "No registered merchant — register first"
                )
            scope.launch {
                try {
                    val created = client().createContextPayment(merchantId, amountMinorUnits.toLong(), currency) {
                        emit(EventNames.QR_EXPIRED, Arguments.createMap().apply {
                            putString("scope", "merchant")
                            putNull("handle")
                        })
                    } ?: return@launch VeyraPromises.reject(
                        promise, "REQUEST_FAILED", "Could not create the payment QR"
                    )
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

    @ReactMethod
    fun merchantContextStatus(txRef: String, promise: Promise) = withInit(promise) {
        scope.launch {
            try {
                val status = client().contextStatus(txRef)
                    ?: return@launch VeyraPromises.reject(
                        promise, "REQUEST_FAILED", "Could not fetch the payment status"
                    )
                promise.resolve(Mappers.paymentContextStatus(status))
            } catch (t: Throwable) {
                VeyraPromises.reject(promise, t)
            }
        }
    }

    // ── Merchant: charge a customer QR (CPM) ────────────────────────────────────

    @ReactMethod
    fun merchantInspectCustomerQr(payload: String, promise: Promise) = withInit(promise) {
        val scanned = softpos().cpmCustomerQrService.inspect(payload)
        promise.resolve(Arguments.createMap().apply {
            putString("handle", cpmQrs.put(scanned))
            putString("maskedCard", "•••• " + scanned.dpan.takeLast(4))
            putDouble("amountMinorUnits", scanned.amountMinorUnits.toDouble())
            putString("currencyNumeric", scanned.currencyNumeric4)
        })
    }

    @ReactMethod
    fun merchantChargeCustomerQr(handle: String, reference: String?, promise: Promise) =
        withInit(promise) {
            val scanned = cpmQrs.take(handle)
                ?: return@withInit VeyraPromises.reject(
                    promise, "VALIDATION", "Unknown or already-used QR handle — re-scan"
                )
            scope.launch {
                try {
                    val response = softpos().cpmCustomerQrService.charge(scanned, reference)
                    promise.resolve(Arguments.createMap().apply {
                        putBoolean("approved", response.responseCode == "00")
                        putString("responseCode", response.responseCode)
                        putString("transactionId", response.transactionId)
                        putString("merchantTransactionReference", reference)
                    })
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
        softposConfig?.let { VeyraSoftPOSSdk.initializeHosted(activity, it) }
    }

    override fun onHostPause() = Unit
    override fun onHostDestroy() = Unit

    // ── Helpers ─────────────────────────────────────────────────────────────────

    private fun wallet(): VeyraWalletSdk =
        VeyraWalletSdk.getInstance() ?: throw IllegalStateException("VeyraSdk not initialised")

    private fun softpos(): VeyraSoftPOSSdk =
        VeyraSoftPOSSdk.getInstance() ?: throw IllegalStateException("VeyraSdk not initialised")

    private fun client(): ContextPaymentClient =
        contextClient ?: throw IllegalStateException("VeyraSdk not initialised")

    private object EventNames {
        const val ACTIVATION = "VeyraActivationEvent"
        const val WALLET_TAP = "VeyraWalletTapEvent"
        const val MERCHANT_TAP = "VeyraMerchantTapEvent"
        const val QR_EXPIRED = "VeyraQrExpiredEvent"
    }
}
