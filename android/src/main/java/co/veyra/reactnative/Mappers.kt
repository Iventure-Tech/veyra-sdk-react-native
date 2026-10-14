@file:OptIn(co.veyra.common.VeyraInternalApi::class)

package co.veyra.reactnative

import co.veyra.softpos.payment.sdk.MerchantTransaction
import co.veyra.softpos.payment.sdk.TapEvent
import co.veyra.softpos.payment.sdk.TapRequest
import co.veyra.softpos.payment.sdk.TapResult
import co.veyra.common.cancel.CancelResult
import co.veyra.common.outcome.OutcomeReason
import co.veyra.common.outcome.ResponseStatus
import co.veyra.softpos.payment.sdk.context.PaymentContextQr
import co.veyra.softpos.payment.sdk.payment.OriginalPayment
import co.veyra.softpos.payment.sdk.context.PaymentContextStatus
import co.veyra.softpos.payment.sdk.cpm.CustomerQrInspection
import co.veyra.softpos.payment.sdk.merchant.MerchantRegistration
import co.veyra.softpos.payment.sdk.merchant.MerchantType
import co.veyra.softpos.payment.sdk.merchant.MerchantUpdate
import co.veyra.softpos.payment.sdk.merchant.MerchantRegistrationResult
import co.veyra.softpos.payment.sdk.merchant.SettlementBankList
import co.veyra.softpos.payment.sdk.merchant.StoredMerchant
import co.veyra.softpos.payment.sdk.merchant.MerchantReceipt
import co.veyra.wallet.sdk.AccountNumberSource
import co.veyra.wallet.sdk.ActivateResponse
import co.veyra.wallet.sdk.ActivationCodeResponse
import co.veyra.wallet.sdk.BankList
import co.veyra.wallet.sdk.PaymentQr
import co.veyra.wallet.sdk.TokenStatusResult
import co.veyra.wallet.sdk.TokenStatusUpdateResponse
import co.veyra.wallet.sdk.Token
import co.veyra.wallet.sdk.DigitiseParams
import co.veyra.wallet.sdk.DigitiseResult
import co.veyra.wallet.sdk.TokenizationRecommendation
import co.veyra.wallet.sdk.TokenizationRecommendationReason
import co.veyra.wallet.sdk.TransactionReceipt
import co.veyra.common.outcome.VeyraLookup
import co.veyra.wallet.sdk.TransactionSummary
import co.veyra.wallet.sdk.TrustScore
import co.veyra.wallet.sdk.VerifyAccountParams
import co.veyra.wallet.sdk.VerifyAccountResponse
import co.veyra.wallet.sdk.api.mpm.PaymentOutcome
import co.veyra.wallet.sdk.api.mpm.ScanInspection
import co.veyra.wallet.sdk.api.mpm.VerifiedPayment
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap

/**
 * JS-map ↔ SDK-DTO mapping. Field names match the TypeScript types verbatim.
 *
 * Every operation's map carries `responseStatus` / `responseStatusReason` (and `responseCode` on
 * payments), copied from the SDK's outcome — never derived here. The `…NotSent` shapes are the
 * bridge's own refusals of a bad call argument (an unknown handle, an unknown enum value, a missing
 * field): `NOT_SENT` / `INVALID_REQUEST`, every other key of the type present and empty, so JS reads
 * the same shape whichever way the call ended. The iOS module builds the same keys.
 *
 * `into` parameters exist for tests: `Arguments.createMap()` needs the native bridge, `JavaOnlyMap`
 * doesn't.
 */
private typealias Ops = co.veyra.common.logging.failure.SdkOperation

internal object Mappers {

    /** The reason the bridge gives a call it refuses for a bad argument. */
    const val INVALID_REQUEST = OutcomeReason.INVALID_REQUEST

    private fun WritableMap.putOutcome(status: String?, reason: String?, message: String?) {
        putString("responseStatus", status)
        putString("responseStatusReason", reason)
        putString("message", message)
    }

    /**
     * A `NOT_SENT` outcome the bridge itself gives — nothing reached the SDK, so nothing was sent.
     * [falseKeys] / [nullKeys] are the type's other keys, present and empty.
     */
    fun notSent(
        reason: String,
        message: String,
        falseKeys: List<String> = emptyList(),
        nullKeys: List<String> = emptyList(),
        into: WritableMap = Arguments.createMap(),
        status: String = ResponseStatus.NOT_SENT,
        /** The SDK never sees a call the bridge refuses itself, so the bridge logs its failure line. */
        operation: String? = null,
    ): WritableMap = into.apply {
        if (operation != null) {
            @OptIn(co.veyra.common.VeyraInternalApi::class)
            co.veyra.common.logging.failure.OperationFailureLog.reportBridgeRefusal(operation, status, reason)
        }
        putOutcome(status, reason, message)
        falseKeys.forEach { putBoolean(it, false) }
        nullKeys.forEach { putNull(it) }
    }

    /**
     * The same refusal on a call that is not a payment or digitisation: `FAILED` with the reason
     * (`devices/CLAUDE.md` §15.2 — only payment processing and digitisation answer `NOT_SENT`).
     */
    fun refused(
        reason: String,
        message: String,
        falseKeys: List<String> = emptyList(),
        nullKeys: List<String> = emptyList(),
        into: WritableMap = Arguments.createMap(),
        operation: String? = null,
    ): WritableMap = notSent(reason, message, falseKeys, nullKeys, into, ResponseStatus.FAILED, operation)

    /** `PaymentOutcome` (wallet scan-to-pay) refused before anything was sent. */
    fun paymentOutcomeNotSent(reason: String, message: String, into: WritableMap = Arguments.createMap()) =
        notSent(reason, message, listOf("approved"), listOf("responseCode", "merchantName", "merchantLocation"), into,
            operation = Ops.SCAN_TO_PAY)

    /** `CustomerQrChargeOutcome` refused before anything was sent. */
    fun customerQrChargeNotSent(reason: String, message: String, into: WritableMap = Arguments.createMap()) =
        notSent(
            reason, message, listOf("approved"),
            listOf(
                "responseCode", "transactionId", "merchantTransactionReference", "merchantOrderId",
                "creditTransactionId", "isCreditConfirmationSupported", "originalPayment",
            ),
            into,
            operation = Ops.CPM_CHARGE,
        )

    /** `MerchantRegistrationResult` refused before anything was sent: `FAILED`. */
    fun merchantRegistrationRefused(reason: String, message: String, into: WritableMap = Arguments.createMap()) =
        refused(reason, message, listOf("success"), listOf("merchantId", "terminalId", "merchantStatus"), into,
            operation = Ops.MERCHANT_REGISTER)

    /** `MerchantStatusResult` refused before anything was sent: `FAILED`. */
    fun merchantStatusRefused(reason: String, message: String, into: WritableMap = Arguments.createMap()) =
        refused(reason, message, nullKeys = listOf("merchantId", "merchantStatus"), into = into,
            operation = Ops.MERCHANT_STATUS)

    /** `ActivationCodeResponse` refused before anything was sent: `FAILED`. */
    fun activationCodeRefused(reason: String, message: String, into: WritableMap = Arguments.createMap()) =
        refused(
            reason, message,
            nullKeys = listOf("tokenUniqueReference", "expirationDateTime", "status", "failureCode"),
            into = into, operation = Ops.ACTIVATION,
        )

    /** `VerifyAccountResponse` refused before anything was sent: `FAILED`. */
    fun verifyAccountRefused(reason: String, message: String, into: WritableMap = Arguments.createMap()) =
        refused(reason, message, listOf("isApproved"), listOf("responseCode"), into, operation = Ops.VERIFY_ACCOUNT)

    /** `DigitiseResult` refused before anything was sent. */
    fun digitiseNotSent(
        reason: String,
        message: String,
        into: WritableMap = Arguments.createMap(),
        methodsInto: WritableArray = Arguments.createArray(),
    ) = notSent(
        reason, message, listOf("isApproved", "requiresActivation"),
        listOf("responseCode", "tokenUniqueReference", "tokenStored", "clientRequestId"), into, operation = Ops.DIGITISE,
    ).apply { putArray("activationMethods", methodsInto) }

    // ── Readers ─────────────────────────────────────────────────────────────────

    fun ReadableMap.req(key: String): String =
        if (hasKey(key) && !isNull(key)) getString(key)!!.also { require(it.isNotBlank()) { "$key must not be blank" } }
        else throw IllegalArgumentException("$key is required")

    fun ReadableMap.opt(key: String): String? =
        if (hasKey(key) && !isNull(key)) getString(key) else null

    fun ReadableMap.optStringList(key: String): List<String>? =
        if (hasKey(key) && !isNull(key)) getArray(key)?.toStringList() else null

    /**
     * `requestTimeoutSeconds` from an SDK's config map: null when absent. JS numbers are doubles, so
     * a fractional value is refused here, naming the SDK; the 5–60 range is the SDK's own rule and
     * is checked at initialise like on every other platform.
     */
    fun ReadableMap.optRequestTimeoutSeconds(sdk: String): Int? {
        if (!hasKey("requestTimeoutSeconds") || isNull("requestTimeoutSeconds")) return null
        val value = getDouble("requestTimeoutSeconds")
        require(value % 1.0 == 0.0 && value >= Int.MIN_VALUE && value <= Int.MAX_VALUE) {
            "$sdk.requestTimeoutSeconds must be a whole number of seconds (was $value)"
        }
        return value.toInt()
    }

    private fun ReadableArray.toStringList(): List<String> =
        (0 until size()).mapNotNull { getString(it) }

    fun verifyAccountParams(map: ReadableMap): VerifyAccountParams =
        VerifyAccountParams.Builder(
            accountNumber = map.req("accountNumber"),
            institutionCode = map.req("institutionCode"),
            walletAccountId = map.req("walletAccountId"),
        ).apply {
            map.opt("accountHolderName")?.let { accountHolderName(it) }
            map.opt("accountNumberSource")?.let { accountNumberSource(AccountNumberSource.valueOf(it)) }
        }.build()

    /**
     * JS `DigitiseParams` → [DigitiseParams]: the same fields and the same required set on every
     * platform. A required field missing or blank answers `NOT_SENT` / `INVALID_REQUEST` before
     * anything is sent.
     */
    fun digitiseParams(map: ReadableMap): DigitiseParams = DigitiseParams(
        accountNumber = map.req("accountNumber"),
        institutionCode = map.req("institutionCode"),
        accountHolderName = map.req("accountHolderName"),
        walletAccountId = map.req("walletAccountId"),
        emailAddress = map.req("emailAddress"),
        recommendation = TokenizationRecommendation.valueOf(map.req("recommendation")),
        consumerIdentifier = map.opt("consumerIdentifier"),
        bvn = map.opt("bvn"),
        accountHolderAddress = map.opt("accountHolderAddress"),
        mobileNumber = map.opt("mobileNumber"),
        clientRequestId = map.opt("clientRequestId")?.takeIf { it.isNotBlank() },
        accountNumberSource = map.opt("accountNumberSource")?.let { AccountNumberSource.valueOf(it) },
        deviceScore = map.opt("deviceScore")?.let { TrustScore.valueOf(it) },
        accountScore = map.opt("accountScore")?.let { TrustScore.valueOf(it) },
        recommendationReasons = map.optStringList("recommendationReasons")
            ?.map { TokenizationRecommendationReason.valueOf(it) },
        bankName = map.opt("bankName"),
    )

    /** `MerchantRegistration`; a missing field or an unknown `merchantType` throws [IllegalArgumentException]. */
    fun merchantRegistration(map: ReadableMap): MerchantRegistration {
        val type = map.req("merchantType").let { raw ->
            MerchantType.entries.firstOrNull { it.name == raw }
                ?: throw IllegalArgumentException("merchantType must be PERSONAL or BUSINESS")
        }
        return MerchantRegistration(
            merchantType = type,
            merchantName = map.req("merchantName"),
            emailAddress = map.req("emailAddress"),
            phoneNumber = map.req("phoneNumber"),
            addressLine1 = map.req("addressLine1"),
            city = map.req("city"),
            state = map.req("state"),
            countryCode = map.req("countryCode"),
            accountNumber = map.req("accountNumber"),
            institutionCode = map.req("institutionCode"),
            addressLine2 = map.opt("addressLine2") ?: "",
            bvn = map.opt("bvn"),
            cacNumber = map.opt("cacNumber"),
            walletAccountId = map.opt("walletAccountId"),
        )
    }

    /** `MerchantUpdate`; a missing required field throws [IllegalArgumentException]. */
    fun merchantUpdate(map: ReadableMap): MerchantUpdate = MerchantUpdate(
        merchantName = map.req("merchantName"),
        emailAddress = map.req("emailAddress"),
        phoneNumber = map.req("phoneNumber"),
        addressLine1 = map.req("addressLine1"),
        city = map.req("city"),
        state = map.req("state"),
        countryCode = map.req("countryCode"),
        accountNumber = map.req("accountNumber"),
        institutionCode = map.req("institutionCode"),
        addressLine2 = map.opt("addressLine2") ?: "",
        walletAccountId = map.opt("walletAccountId"),
        bvn = map.opt("bvn"),
    )

    /**
     * `TapRequest` from JS — a purchase. A missing amount throws [IllegalArgumentException]; a blank
     * order id or a bad currency is passed through so the SDK refuses it with its own `NOT_SENT` /
     * `INVALID_REQUEST` result.
     */
    fun tapRequest(map: ReadableMap): TapRequest {
        if (!map.hasKey("amountMinorUnits") || map.isNull("amountMinorUnits")) {
            throw IllegalArgumentException("amountMinorUnits is required")
        }
        return TapRequest(
            amountMinorUnits = map.getDouble("amountMinorUnits").toLong(),
            currency = map.opt("currency") ?: "566",
            merchantOrderId = map.opt("merchantOrderId").orEmpty(),
        )
    }

    /** The JS name of each [TapEvent] — the native spellings, the same on Android and iOS. */
    fun tapEventType(event: TapEvent): String = when (event) {
        TapEvent.CardDetected -> "cardDetected"
        TapEvent.CardContactLost -> "cardContactLost"
        TapEvent.UnsupportedCard -> "unsupportedCard"
        TapEvent.CardReadingComplete -> "cardReadingComplete"
        TapEvent.SendingRequestOnline -> "sendingRequestOnline"
        TapEvent.ReceivingOnlineResponse -> "receivingOnlineResponse"
        is TapEvent.Result -> "result"
    }

    /** A `softpos.tap.onEvent` payload. [into]/[resultInto] exist for tests. */
    fun tapEvent(
        sessionId: String,
        event: TapEvent,
        into: WritableMap = Arguments.createMap(),
        resultInto: WritableMap? = null,
    ): WritableMap = into.apply {
        putString("type", tapEventType(event))
        putString("sessionId", sessionId)
        if (event is TapEvent.Result) putMap("result", tapResult(event.result, resultInto ?: Arguments.createMap()))
    }

    /** A `result` tap event carrying a result map the bridge built itself. */
    fun tapEventResult(sessionId: String, result: WritableMap, into: WritableMap = Arguments.createMap()): WritableMap =
        into.apply {
            putString("type", "result")
            putString("sessionId", sessionId)
            putMap("result", result)
        }

    // ── Writers ─────────────────────────────────────────────────────────────────

    private fun bankArray(banks: List<Triple<String?, String?, String?>>): WritableArray =
        Arguments.createArray().apply {
            banks.forEach { (slug, name, institutionCode) ->
                pushMap(Arguments.createMap().apply {
                    putString("slug", slug)
                    putString("name", name)
                    putString("institutionCode", institutionCode)
                })
            }
        }

    /** `BankList` — the wallet's bank lookup, a read: `banks` on `APPROVED`, else the reason. */
    fun bankList(r: BankList): WritableMap = Arguments.createMap().apply {
        putArray("banks", bankArray(r.banks.map { Triple(it.slug, it.name, it.institutionCode) }))
        putOutcome(r.responseStatus, r.responseStatusReason, r.message)
    }

    /** `SettlementBankList` — the merchant's settlement banks, same rules as [bankList]. */
    fun settlementBankList(r: SettlementBankList): WritableMap = Arguments.createMap().apply {
        putArray("banks", bankArray(r.banks.map { Triple(it.slug, it.name, it.institutionCode) }))
        putOutcome(r.responseStatus, r.responseStatusReason, r.message)
    }

    fun verifyAccount(r: VerifyAccountResponse, into: WritableMap = Arguments.createMap()): WritableMap = into.apply {
        putString("responseCode", r.responseCode)
        // What the call did, and why it decided that — carried verbatim.
        putOutcome(r.responseStatus, r.responseStatusReason, r.message)
        putBoolean("isApproved", r.isApproved)
    }

    fun activationCode(r: ActivationCodeResponse, into: WritableMap = Arguments.createMap()): WritableMap = into.apply {
        putString("tokenUniqueReference", r.tokenUniqueReference)
        putString("expirationDateTime", r.expirationDateTime)
        putString("status", r.status)
        // Raw wire value: JS carries codes verbatim (unknown codes included).
        putString("failureCode", r.failureCodeRaw)
        putString("failureCodeRaw", r.failureCodeRaw)
        putOutcome(r.responseStatus, r.responseStatusReason, r.message)
    }

    fun activate(r: ActivateResponse, into: WritableMap = Arguments.createMap()): WritableMap = into.apply {
        putString("tokenUniqueReference", r.tokenUniqueReference)
        putString("status", r.status)
        // Raw wire values: JS carries codes verbatim (unknown codes included).
        putString("failureCode", r.failureCodeRaw)
        putString("failureCodeRaw", r.failureCodeRaw)
        r.attemptsRemaining?.let { putInt("attemptsRemaining", it) } ?: putNull("attemptsRemaining")
        putString("recommendDelete", r.recommendDeleteRaw)
        putString("recommendDeleteRaw", r.recommendDeleteRaw)
        putOutcome(r.responseStatus, r.responseStatusReason, r.message)
    }

    /**
     * `TokenStatusResult` — the server's status for a card, verbatim (a value this build does not know
     * still reaches JS), or the reason the check could not be made.
     */
    fun tokenStatusResult(r: TokenStatusResult, into: WritableMap = Arguments.createMap()): WritableMap = into.apply {
        putString("tokenStatus", r.tokenStatus)
        putOutcome(r.responseStatus, r.responseStatusReason, r.message)
    }

    fun digitiseResult(r: DigitiseResult): WritableMap = Arguments.createMap().apply {
        putString("responseCode", r.responseCode)
        // The cause is a field, not prose: `responseCode` is the issuer's decision,
        // `responseStatus` what the call did, and `responseStatusReason` why — carried verbatim so
        // a cause added after this build still reaches JS.
        putOutcome(r.responseStatus, r.responseStatusReason, r.message)
        putString("tokenUniqueReference", r.tokenUniqueReference)
        putArray("activationMethods", activationMethods(r.activationMethods.map { it.medium to it.contact }))
        putBoolean("isApproved", r.isApproved)
        putBoolean("requiresActivation", r.requiresActivation)
        putBoolean("tokenStored", r.tokenStored)
        putString("clientRequestId", r.clientRequestId)
    }

    private fun activationMethods(
        methods: List<Pair<String?, String?>>?,
        into: WritableArray = Arguments.createArray(),
    ): WritableArray =
        into.apply {
            methods?.forEach { (medium, contact) ->
                pushMap(Arguments.createMap().apply {
                    putString("medium", medium)
                    putString("contact", contact)
                })
            }
        }

    /** JS `Token`. Every token read from the SDK carries its `tokenUniqueReference`. */
    fun token(
        t: Token,
        into: WritableMap = Arguments.createMap(),
        methodsInto: WritableArray = Arguments.createArray(),
    ): WritableMap = into.apply {
        putString("tokenUniqueReference", t.tokenUniqueReference)
        putString("maskedPan", t.maskedPan)
        putString("panLastFour", t.panLastFour)
        putString("cardHolderName", t.cardHolderName)
        putString("expiry", t.expiry)
        putString("bankName", t.bankName)
        putString("cardScheme", t.cardScheme?.name)
        // the stored lifecycle status, so a greyed card can say why.
        putString("status", t.status?.name)
        putBoolean("isActive", t.isActive)
        putBoolean("isSelected", t.isSelected)
        putBoolean("requiresActivation", t.requiresActivation)
        putArray(
            "activationMethods",
            activationMethods(t.activationMethods?.map { it.medium to it.contact }, methodsInto)
        )
        putBoolean("requiresOnline", t.requiresOnline)
        putBoolean("deviceNotBound", t.deviceNotBound)
    }

    /**
     * A cancel's answer, as JS's `CancelResult`: the enum's name, verbatim — the five names are the
     * contract on every platform, so nothing is translated here.
     */
    fun cancelResult(r: CancelResult): String = r.name

    fun scanInspection(result: ScanInspection, handle: String?, into: WritableMap = Arguments.createMap()): WritableMap =
        into.apply {
            when (result) {
                is ScanInspection.Verified -> {
                    val c: VerifiedPayment = result.context
                    putBoolean("verified", true)
                    putString("handle", handle)
                    putString("merchantName", c.merchantName)
                    putString("merchantCity", c.merchantCity)
                    putString("amountDisplay", c.amountDisplay)
                    putDouble("amountMinorUnits", c.amountMinorUnits.toDouble())
                    putString("currencyCode", c.currencyCode)
                    putDouble("expiresAtEpochSeconds", c.expiresAtEpochSeconds.toDouble())
                    // What wallet.cancelPayment takes; null on a QR that carries none.
                    putString("merchantOrderId", c.merchantOrderId)
                }
                is ScanInspection.Rejected -> {
                    putBoolean("verified", false)
                    putString("reason", result.reason.name)
                    putString("detail", result.detail)
                }
            }
        }

    fun paymentOutcome(o: PaymentOutcome, into: WritableMap = Arguments.createMap()): WritableMap = into.apply {
        // `approved` is the SDK's reading of the status, never of the code.
        putBoolean("approved", o.approved)
        putString("responseCode", o.responseCode)
        // the status is what the payment IS — `approved` alone cannot tell a decline
        // from a push the gateway answered PENDING, or one that never left (NOT_SENT).
        putOutcome(o.responseStatus, o.responseStatusReason, o.message)
        putString("merchantName", o.merchantName)
        putString("merchantLocation", o.merchantLocation)
    }

    /** `PaymentQr` — a QR to render on `APPROVED`, or the reason none was made (no payload). */
    fun paymentQr(qr: PaymentQr, into: WritableMap = Arguments.createMap()): WritableMap = into.apply {
        putString("tokenUniqueReference", qr.tokenUniqueReference)
        putString("payload", qr.payload)
        putDouble("amountMinorUnits", qr.amountMinorUnits.toDouble())
        putString("currencyCode", qr.currencyCode)
        putDouble("expiresAtEpochMillis", qr.expiresAtEpochMillis.toDouble())
        putString("transactionHash", qr.transactionHash)
        putOutcome(qr.responseStatus, qr.responseStatusReason, qr.message)
    }

    /** A `VeyraLookup`: the value, or why the read could not be made. */
    fun lookup(
        value: WritableMap?,
        failureReason: String?,
        message: String?,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        if (value != null) putMap("value", value) else putNull("value")
        putString("failureReason", failureReason)
        putString("message", message)
        putBoolean("checked", failureReason == null)
    }

    /** `VeyraLookup<OrderPaymentStatus>` — the lookup by merchant order id. [into]/[make] exist for tests. */
    fun orderPaymentLookup(
        r: VeyraLookup<co.veyra.softpos.payment.sdk.merchant.OrderPaymentStatus>,
        into: WritableMap = Arguments.createMap(),
        make: () -> WritableMap = { Arguments.createMap() },
        makeArray: () -> com.facebook.react.bridge.WritableArray = { Arguments.createArray() },
    ): WritableMap = lookup(r.value?.let { orderPaymentStatus(it, make(), make, makeArray) }, r.failureReason, r.message, into)

    fun orderPaymentStatus(
        o: co.veyra.softpos.payment.sdk.merchant.OrderPaymentStatus,
        into: WritableMap = Arguments.createMap(),
        make: () -> WritableMap = { Arguments.createMap() },
        makeArray: () -> com.facebook.react.bridge.WritableArray = { Arguments.createArray() },
    ): WritableMap = into.apply {
        putString("merchantOrderId", o.merchantOrderId)
        putString("responseStatus", o.responseStatus)
        putString("responseStatusReason", o.responseStatusReason)
        putString("responseCode", o.responseCode)
        putString("merchantTransactionReference", o.merchantTransactionReference)
        putString("transactionId", o.transactionId)
        o.amountMinorUnits?.let { putDouble("amountMinorUnits", it.toDouble()) } ?: putNull("amountMinorUnits")
        putString("answeredBy", o.answeredBy)
        putArray("attempts", makeArray().apply {
            o.attempts.forEach { a ->
                pushMap(make().apply {
                    putString("merchantTransactionReference", a.merchantTransactionReference)
                    putString("transactionId", a.transactionId)
                    a.amountMinorUnits?.let { putDouble("amountMinorUnits", it.toDouble()) } ?: putNull("amountMinorUnits")
                    putString("responseCode", a.responseCode)
                    putString("responseStatus", a.responseStatus)
                    putString("responseStatusReason", a.responseStatusReason)
                })
            }
        })
    }

    /** `VeyraLookup<TransactionSummary>` — a wallet status or credit check. */
    fun transactionLookup(r: VeyraLookup<TransactionSummary>): WritableMap =
        lookup(r.value?.let { transactionSummary(it) }, r.failureReason, r.message)

    /** `VeyraLookup<TransactionStatus[]>` — the gateway's raw record of one transaction. [into]/[make] exist for tests. */
    fun transactionStatusLookup(
        r: VeyraLookup<List<co.veyra.softpos.payment.sdk.merchant.TransactionStatus>>,
        into: WritableMap = Arguments.createMap(),
        make: () -> WritableMap = { Arguments.createMap() },
        makeArray: () -> WritableArray = { Arguments.createArray() },
    ): WritableMap = into.apply {
        val items = r.value
        if (items == null) putNull("value") else putArray("value", makeArray().apply {
            items.forEach { i ->
                pushMap(make().apply {
                    putString("merchantTransactionReference", i.merchantTransactionReference)
                    putString("merchantId", i.merchantId)
                    i.amountMinorUnits?.let { putDouble("amountMinorUnits", it.toDouble()) } ?: putNull("amountMinorUnits")
                    putString("responseCode", i.responseCode)
                    putString("responseStatus", i.responseStatus)
                    putString("responseStatusReason", i.responseStatusReason)
                    putString("merchantStatus", i.merchantStatus)
                    putString("transactionId", i.transactionId)
                    putString("creditTransactionId", i.creditTransactionId)
                    i.isCreditConfirmationSupported?.let { putBoolean("isCreditConfirmationSupported", it) }
                        ?: putNull("isCreditConfirmationSupported")
                })
            }
        })
        putString("failureReason", r.failureReason)
        putString("message", r.message)
        putBoolean("checked", r.checked)
    }

    /** `VeyraLookup<CreditConfirmationEvent>` — the merchant bank's raw answer for one sale. [into]/[valueInto] exist for tests. */
    fun creditConfirmationLookup(
        r: VeyraLookup<co.veyra.common.credit.CreditConfirmation>,
        into: WritableMap = Arguments.createMap(),
        valueInto: WritableMap? = null,
    ): WritableMap = lookup(
        r.value?.let { c ->
            (valueInto ?: Arguments.createMap()).apply {
                putString("creditTransactionId", c.creditTransactionId)
                putString("status", c.status)
                c.amountMinorUnits?.let { putDouble("amountMinorUnits", it.toDouble()) } ?: putNull("amountMinorUnits")
                putString("creditedAt", c.creditedAt)
                putString("bankReference", c.bankReference)
                putString("message", c.message)
            }
        },
        r.failureReason, r.message, into,
    )

    /** `VeyraLookup<MerchantTransaction>` — a merchant status or credit check. */
    fun merchantTransactionLookup(r: VeyraLookup<MerchantTransaction>): WritableMap =
        lookup(r.value?.let { merchantTransaction(it) }, r.failureReason, r.message)

    fun transactionSummary(s: TransactionSummary): WritableMap = Arguments.createMap().apply {
        putString("merchantName", s.merchantName)
        // `putDouble`, like every other minor-unit field on this bridge — the summary's amount is a
        // Long and `putInt` cannot carry one. A JS number holds it exactly up to 2^53, far above
        // any amount this rail can see.
        putDouble("amountMinorUnits", s.amountMinorUnits.toDouble())
        putString("currencyCode", s.currencyCode)
        putString("tokenUniqueReference", s.tokenUniqueReference)
        putString("transactionHash", s.transactionHash)
        putString("authorizationStatus", s.authorizationStatus)
        // the outcome's code and stated cause, verbatim, for the detail view.
        putString("responseCode", s.responseCode)
        putString("responseStatusReason", s.responseStatusReason)
        putString("localTransactionDateTime", s.localTransactionDateTime)
        s.atEpochMillis?.let { putDouble("atEpochMillis", it.toDouble()) } ?: putNull("atEpochMillis")
        putString("entryMethod", s.entryMethod)
        putString("merchantLocation", s.merchantLocation)
        putString("merchantTransactionReference", s.merchantTransactionReference)
        putString("merchantId", s.merchantId)
        // Beneficiary credit confirmation. `isCreditConfirmationSupported` is the gate the screen
        // reads — true means the SDK is polling and the credit line should render; false/null
        // means show nothing. `creditConfirmationStatus` is null until terminal.
        putString("creditTransactionId", s.creditTransactionId)
        s.isCreditConfirmationSupported?.let { putBoolean("isCreditConfirmationSupported", it) }
            ?: putNull("isCreditConfirmationSupported")
        putString("creditConfirmationStatus", s.creditConfirmationStatus)
        putString("creditedAt", s.creditedAt)
        putString("bankReference", s.bankReference)
        // The merchant's order id — from the verified QR at payment time (MPM) or the status
        // poll (tap/CPM). Display only; null until the row learns it.
        putString("merchantOrderId", s.merchantOrderId)
    }

    /** `TokenSelection` — `APPROVED`, or `FAILED` / `CARD_NOT_FOUND` · `CARD_DATA_MISSING`. */
    fun cardSelection(r: co.veyra.wallet.sdk.TokenSelection, into: WritableMap = Arguments.createMap()): WritableMap =
        into.apply { putOutcome(r.responseStatus, r.responseStatusReason, r.message) }

    /** `ReconcileResult` — `failureReason` only when the reconcile itself could not run. */
    fun reconcileResult(r: co.veyra.wallet.sdk.ReconcileResult, into: WritableMap = Arguments.createMap()): WritableMap =
        into.apply {
            putBoolean("checked", r.checked)
            putString("failureReason", r.failureReason)
            putString("message", r.message)
        }

    /** `ReceiptScan` — `APPROVED` with `receipt`, or `FAILED` with the reason and no receipt. */
    fun receiptScan(
        r: co.veyra.wallet.sdk.ReceiptScan,
        into: WritableMap = Arguments.createMap(),
        receiptInto: (TransactionReceipt) -> WritableMap = ::receipt,
    ): WritableMap = into.apply {
        val stored = r.receipt
        if (stored != null) putMap("receipt", receiptInto(stored)) else putNull("receipt")
        putOutcome(r.responseStatus, r.responseStatusReason, r.message)
    }

    fun receipt(r: TransactionReceipt): WritableMap = Arguments.createMap().apply {
        putString("merchantName", r.merchantName)
        putString("merchantId", r.merchantId)
        putString("merchantAddress", r.merchantAddress)
        putString("transactionType", r.transactionType)
        putString("transactionStatus", r.transactionStatus)
        putString("transactionTime", r.transactionTime)
        putDouble("totalAmountMinorUnits", r.totalAmountMinorUnits.toDouble())
        putString("totalAmountFormatted", r.totalAmountFormatted)
        putString("currencyCode", r.currencyCode)
        putString("maskedToken", r.maskedToken)
        putString("merchantTransactionReference", r.merchantTransactionReference)
        r.cdcvmApprovedByWallet?.let { putBoolean("cdcvmApprovedByWallet", it) }
            ?: putNull("cdcvmApprovedByWallet")
        putString("transactionId", r.transactionId)
        putString("transactionHash", r.transactionHash)
    }

    fun merchantRegistrationResult(r: MerchantRegistrationResult, into: WritableMap = Arguments.createMap()): WritableMap =
        into.apply {
            putBoolean("success", r.success)
            putString("merchantId", r.merchantId)
            putString("terminalId", r.terminalId)
            putString("merchantStatus", r.merchantStatus)
            putOutcome(r.responseStatus, r.responseStatusReason, r.message)
        }

    /** `MerchantStatusResult` — a status read, activate, deactivate or update, as the SDK answered it. */
    fun merchantStatus(
        merchantId: String?,
        merchantStatus: String?,
        responseStatus: String?,
        responseStatusReason: String?,
        message: String?,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("merchantId", merchantId)
        putString("merchantStatus", merchantStatus)
        putOutcome(responseStatus, responseStatusReason, message)
    }

    fun merchantStatus(r: co.veyra.softpos.payment.sdk.merchant.MerchantStatusResult): WritableMap =
        merchantStatus(r.merchantId, r.merchantStatus, r.responseStatus, r.responseStatusReason, r.message)

    fun storedMerchant(m: StoredMerchant): WritableMap = Arguments.createMap().apply {
        putString("merchantId", m.merchantId)
        putString("merchantType", m.merchantType)
        putString("merchantName", m.merchantName)
        putString("emailAddress", m.emailAddress)
        putString("phoneNumber", m.phoneNumber)
        putString("addressLine1", m.addressLine1)
        putString("addressLine2", m.addressLine2)
        putString("city", m.city)
        putString("state", m.state)
        putString("countryCode", m.countryCode)
        putString("accountNumber", m.accountNumber)
        putString("institutionCode", m.institutionCode)
        putString("acquirerId", m.acquirerId)
        putString("merchantCategoryCode", m.merchantCategoryCode)
        putString("terminalId", m.terminalId)
        putString("merchantStatus", m.merchantStatus)
        putString("walletAccountId", m.walletAccountId)
        putString("bvn", m.bvn)
        putString("cacNumber", m.cacNumber)
    }

    /**
     * `OriginalPayment` — on a `DUPLICATE_MERCHANT_ORDER_ID` refusal, the payment already holding the
     * order ID. Its `responseStatus` says whether the order is already paid or still being confirmed.
     */
    fun originalPayment(o: OriginalPayment, into: WritableMap = Arguments.createMap()): WritableMap = into.apply {
        putString("responseCode", o.responseCode)
        putString("responseStatus", o.responseStatus)
        putString("responseStatusReason", o.responseStatusReason)
        o.amountMinorUnits?.let { putDouble("amountMinorUnits", it.toDouble()) } ?: putNull("amountMinorUnits")
        putString("merchantTransactionReference", o.merchantTransactionReference)
        putString("transactionId", o.transactionId)
    }

    /** `originalPayment` on an outcome map: the nested map, or null. [into] exists for tests. */
    private fun WritableMap.putOriginalPayment(o: OriginalPayment?, into: WritableMap?) {
        if (o == null) putNull("originalPayment")
        else putMap("originalPayment", originalPayment(o, into ?: Arguments.createMap()))
    }

    // [into] exists for tests: Arguments.createMap() needs the native bridge, JavaOnlyMap doesn't.
    fun tapResult(
        r: TapResult,
        into: WritableMap = Arguments.createMap(),
        originalInto: WritableMap? = null,
    ): WritableMap = into.apply {
        // carry the outcome the backend stated; never re-derive it from the code. This block
        // was a code->status mapping of its own — the seventh — and it read every code it did not
        // recognise as FAILED, so `09`/`68`/`96` (still settling) and `25` (no record) all surfaced to
        // React Native as failures. `"99"` is retired: pending is said by `status` now.
        // A NOT_SENT tap never went on the wire, so it has no code.
        putString("responseCode", r.responseCode?.takeIf { it.isNotEmpty() })
        putOutcome(r.responseStatus, r.responseStatusReason, r.message)
        r.amountMinorUnits?.let { putDouble("amountMinorUnits", it.toDouble()) } ?: putNull("amountMinorUnits")
        putString("cardScheme", r.cardScheme)
        putString("maskedTokenLast4", r.maskedTokenLast4)
        putString("merchantTransactionReference", r.merchantTransactionReference)
        putString("transactionId", r.transactionId)
        putString("merchantStatus", r.merchantStatus)
        // an approved sale carries the merchant-bank credit id, and whether the
        // merchant's bank can confirm the credit at all. `isCreditConfirmationSupported == true`
        // is the app's cue to show a "confirming credit…" state on the result screen and flip it
        // from the onCreditConfirmation event; null/false means there is nothing to wait for.
        putString("creditTransactionId", r.creditTransactionId)
        r.isCreditConfirmationSupported?.let { putBoolean("isCreditConfirmationSupported", it) }
            ?: putNull("isCreditConfirmationSupported")
        putOriginalPayment(r.originalPayment, originalInto)
    }

    /** A tap `result` the bridge ends itself for a bad argument: `NOT_SENT`, nothing armed or sent. */
    fun tapResultNotSent(reason: String, message: String, into: WritableMap = Arguments.createMap()): WritableMap =
        notSent(
            reason, message,
            nullKeys = listOf(
                "responseCode", "amountMinorUnits", "cardScheme", "maskedTokenLast4", "merchantTransactionReference",
                "transactionId", "merchantStatus", "creditTransactionId", "isCreditConfirmationSupported",
                "originalPayment",
            ),
            into = into,
        )

    /**
     * The `VeyraTransactionResolvedEvent` payload. Extracted from the module's
     * observer registration so the shape both platforms must agree on is asserted by
     * a test rather than by two hand-written map literals — the iOS bridge builds the same keys.
     *
     * [into] exists for tests: `Arguments.createMap()` needs the native bridge, `JavaOnlyMap` doesn't.
     */
    /**
     * The answer to a token status change — today `walletDeactivateToken`. JS gets the same three
     * fields the Android and iOS surfaces return, so a caller can tell a stated status from the
     * server having said nothing.
     */
    fun tokenStatusUpdate(
        r: TokenStatusUpdateResponse,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("tokenUniqueReference", r.tokenUniqueReference)
        putString("status", r.status)
        putOutcome(r.responseStatus, r.responseStatusReason, r.message)
    }

    fun transactionResolved(
        r: co.veyra.softpos.payment.sdk.merchant.TransactionResolvedEvent,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("merchantTransactionReference", r.merchantTransactionReference)
        putString("responseCode", r.responseCode)
        putString("status", r.status)
        putString("reason", r.reason)
    }

    /**
     * The `VeyraCreditConfirmationEvent` payload; same extraction rationale as
     * [transactionResolved]. `amountMinorUnits` crosses as a JS number — RN has no 64-bit integer,
     * and a minor-unit amount is far inside the double's exact-integer range.
     */
    fun creditConfirmation(
        c: co.veyra.softpos.payment.sdk.merchant.CreditConfirmationEvent,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("merchantTransactionReference", c.merchantTransactionReference)
        putString("creditTransactionId", c.creditTransactionId)
        putString("status", c.status)
        c.amountMinorUnits?.let { putDouble("amountMinorUnits", it.toDouble()) }
            ?: putNull("amountMinorUnits")
        putString("bankReference", c.bankReference)
        putString("creditedAt", c.creditedAt)
    }

    /**
     * The `VeyraTokenStatusChangedEvent` payload — the issuer changed a
     * card's status.
     *
     * `canPay` crosses deliberately rather than being left for JS to derive from `status`: JS
     * deriving it would be a second reading of the payability rule, and the first status added to
     * the backend after this SDK shipped would be classified by a `switch` that has never heard of
     * it. `rawStatus` is what to log — for an unrecognised status it is the only identifying value.
     */
    fun tokenStatusChanged(
        c: co.veyra.wallet.sdk.api.TokenStatusChangedEvent,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("tokenUniqueReference", c.tokenUniqueReference)
        putString("status", c.status.value)
        putString("rawStatus", c.rawStatus)
        putBoolean("canPay", c.canPay)
        putString("previousStatus", c.previousStatus)
    }

    /**
     * The `VeyraWalletTransactionResolvedEvent` payload — a wallet payment
     * that was left `PENDING` reached a final outcome.
     *
     * Distinct from [transactionResolved], which is the **merchant** side of a payment: that one
     * keys on the merchant's own `merchantTransactionReference`, which a wallet never sees. This
     * keys on `transactionHash`. Same event shape, different question — do not merge them.
     * `amountMinorUnits` crosses as a JS number (see [creditConfirmation]).
     */
    fun walletTransactionResolved(
        r: co.veyra.wallet.sdk.api.WalletTransactionResolvedEvent,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("transactionHash", r.transactionHash)
        putString("tokenUniqueReference", r.tokenUniqueReference)
        putString("status", r.status)
        putString("responseCode", r.responseCode)
        putString("reason", r.reason)
        putDouble("amountMinorUnits", r.amountMinorUnits.toDouble())
        putString("merchantName", r.merchantName)
    }

    /**
     * The `VeyraTokenKeyStateEvent` payload — a card ran out of payment keys,
     * or got them back. `requiresOnline` is the same value `StoredCard.requiresOnline` carries.
     */
    fun tokenKeyState(
        s: co.veyra.wallet.sdk.api.TokenKeyStateEvent,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("tokenUniqueReference", s.tokenUniqueReference)
        putBoolean("requiresOnline", s.requiresOnline)
        putBoolean("deviceNotBound", s.deviceNotBound)
    }

    /**
     * The `VeyraMerchantStatusEvent` payload — the merchant was deactivated,
     * suspended or activated. `canAcceptPayments` crosses for the same reason `canPay` does above:
     * so JS never has to re-derive a gate the SDK already owns.
     */
    fun merchantStatusChanged(
        c: co.veyra.softpos.payment.sdk.merchant.MerchantStatusEvent,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("merchantId", c.merchantId)
        putString("status", c.status)
        putBoolean("canAcceptPayments", c.canAcceptPayments)
        putString("previousStatus", c.previousStatus)
    }

    /** `PaymentContextQr` — `txRef` / `mpmPayload` only on `APPROVED`; otherwise the reason. */
    fun paymentContextQr(
        c: PaymentContextQr,
        into: WritableMap = Arguments.createMap(),
        originalInto: WritableMap? = null,
    ): WritableMap = into.apply {
        putString("txRef", c.txRef)
        putString("mpmPayload", c.mpmPayload)
        putString("expiry", c.expiry)
        putOutcome(c.responseStatus, c.responseStatusReason, c.message)
        putOriginalPayment(c.originalPayment, originalInto)
    }

    /**
     * `CustomerQrInspection` — `qr` (display fields + the opaque [handle]) on `APPROVED`, else
     * `NOT_SENT` / `INVALID_REQUEST` and no `qr`. The card data stays native behind the handle.
     */
    fun customerQrInspection(
        i: CustomerQrInspection,
        handle: String?,
        into: WritableMap = Arguments.createMap(),
        qrInto: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        val scanned = i.qr
        if (scanned != null && handle != null) {
            putMap("qr", qrInto.apply {
                putString("handle", handle)
                putString("maskedCard", scanned.maskedCard)
                putDouble("amountMinorUnits", scanned.amountMinorUnits.toDouble())
                putString("currencyCode", scanned.currencyCode)
                putString("cardholderName", scanned.cardholderName)
            })
        } else putNull("qr")
        putOutcome(i.responseStatus, i.responseStatusReason, i.message)
    }

    /**
     * `CustomerQrChargeOutcome` — the triple verbatim. `approved` is read from the status, never
     * worked out from the code: a `00` with any other status is not an approval.
     */
    fun customerQrCharge(
        r: co.veyra.softpos.payment.sdk.cpm.CustomerQrChargeOutcome,
        into: WritableMap = Arguments.createMap(),
        originalInto: WritableMap? = null,
    ): WritableMap = into.apply {
        putBoolean("approved", r.approved)
        putString("responseCode", r.responseCode)
        putOutcome(r.responseStatus, r.responseStatusReason, r.message)
        putString("transactionId", r.transactionId)
        // the MINTED reference, from the gateway's echo — not a value the caller supplied, so every
        // receipt lookup and status poll built on it finds the stored payment.
        putString("merchantTransactionReference", r.merchantTransactionReference)
        putString("merchantOrderId", r.merchantOrderId)
        // an approved answer carries the merchant-bank credit id + supported flag — the result
        // screen's cue to wait for confirmation.
        putString("creditTransactionId", r.creditTransactionId)
        r.isCreditConfirmationSupported?.let { putBoolean("isCreditConfirmationSupported", it) }
            ?: putNull("isCreditConfirmationSupported")
        putOriginalPayment(r.originalPayment, originalInto)
    }

    fun paymentContextStatus(s: PaymentContextStatus): WritableMap = Arguments.createMap().apply {
        putString("txRef", s.txRef)
        putString("state", s.state)
        putString("responseCode", s.responseCode)
        putString("transactionHash", s.transactionHash)
        putBoolean("isSettled", s.isSettled)
        putBoolean("isApproved", s.isApproved)
    }

    // [into] exists for tests: Arguments.createMap() needs the native bridge, JavaOnlyMap doesn't.
    fun merchantTransaction(t: MerchantTransaction, into: WritableMap = Arguments.createMap()): WritableMap = into.apply {
        putString("merchantTransactionReference", t.merchantTransactionReference)
        // the app's own order id, from the stored row — so a transaction detail or history
        // screen can show it, not just the screen that took the payment.
        putString("merchantOrderId", t.merchantOrderId)
        putDouble("amountMinorUnits", t.amountMinorUnits.toDouble())
        putString("status", t.status)
        putString("responseCode", t.responseCode)
        // the outcome's stated cause, verbatim, for the detail view.
        putString("responseStatusReason", t.responseStatusReason)
        putString("transactionTime", t.transactionTime)
        putString("currencyCode", t.currencyCode)
        putString("transactionId", t.transactionId)
        putString("rail", t.rail)
        putString("railLabel", t.railLabel)
        // Android's MerchantTransaction carries neither — the iOS record does (see the Swift bridge).
        putNull("maskedTokenLast4")
        putNull("transactionHash")
        putString("cardholderName", t.cardholderName)
        // the credit id, the supported flag (the result screen's cue to wait) and the
        // terminal confirmation state — null while unconfirmed ("not confirmed yet", never
        // "not received").
        putString("creditTransactionId", t.creditTransactionId)
        t.isCreditConfirmationSupported?.let { putBoolean("isCreditConfirmationSupported", it) }
            ?: putNull("isCreditConfirmationSupported")
        putString("creditConfirmationStatus", t.creditConfirmationStatus)
    }

    fun merchantReceipt(r: MerchantReceipt): WritableMap = Arguments.createMap().apply {
        putString("merchantName", r.merchantName)
        putString("merchantAddress", r.merchantAddress)
        putString("transactionType", r.transactionType)
        putDouble("totalAmountMinorUnits", r.totalAmountMinorUnits.toDouble())
        putString("totalAmountFormatted", r.totalAmountFormatted)
        putString("maskedToken", r.maskedToken)
        putString("merchantTransactionReference", r.merchantTransactionReference)
        putString("transactionHash", r.transactionHash)
        putString("qrCodeBase64", r.qrCodeBase64)
        putNull("qrPayload")
        putString("cardholderName", r.cardholderName)
    }

    /** `WalletPaymentRefusal` — one payload for the three refusals; [into] exists for tests. */
    fun paymentRefusal(r: co.veyra.wallet.sdk.WalletPaymentRefusal, into: WritableMap = Arguments.createMap()): WritableMap =
        into.apply {
            putString("type", r.type)
            putString("tokenUniqueReference", r.tokenUniqueReference)
            putDouble("amountMinorUnits", r.amountMinorUnits.toDouble())
            if (r.type == co.veyra.wallet.sdk.WalletPaymentRefusal.AMOUNT_EXCEED_CARD_LIMIT) {
                r.cardLimitMinorUnits?.let { putDouble("cardLimitMinorUnits", it.toDouble()) } ?: putNull("cardLimitMinorUnits")
            }
            putString("rail", r.rail)
            putString("message", r.message)
        }
}
