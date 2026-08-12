package co.veyra.reactnative

import co.veyra.softpos.payment.sdk.TransactionInfo
import co.veyra.softpos.payment.sdk.TransactionResponse as SoftposTransactionResponse
import co.veyra.softpos.payment.sdk.context.CreatedPaymentContext
import co.veyra.softpos.payment.sdk.context.PaymentContextStatus
import co.veyra.softpos.payment.sdk.merchant.MerchantRegistrationData
import co.veyra.softpos.payment.sdk.merchant.MerchantRegistrationResponse
import co.veyra.softpos.payment.sdk.merchant.NubanBank
import co.veyra.softpos.payment.sdk.merchant.StoredMerchantData
import co.veyra.softpos.payment.sdk.merchant.TransactionReceiptResult
import co.veyra.wallet.sdk.AccountNumberSource
import co.veyra.wallet.sdk.Bank
import co.veyra.wallet.sdk.CpmPaymentQr
import co.veyra.wallet.sdk.Token
import co.veyra.wallet.sdk.TokenisationResponse
import co.veyra.wallet.sdk.TokenizationRecommendation
import co.veyra.wallet.sdk.TokenizationRecommendationReason
import co.veyra.wallet.sdk.TokenizationRequestParams
import co.veyra.wallet.sdk.TransactionReceipt
import co.veyra.wallet.sdk.TransactionSummary
import co.veyra.wallet.sdk.TrustScore
import co.veyra.wallet.sdk.VerifyAccountParams
import co.veyra.wallet.sdk.api.mpm.MpmPushOutcome
import co.veyra.wallet.sdk.api.mpm.MpmScanResult
import co.veyra.wallet.sdk.api.mpm.VerifiedPaymentContext
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap

/** JS-map ↔ SDK-DTO mapping. Field names match the TypeScript types verbatim. */
internal object Mappers {

    // ── Readers ─────────────────────────────────────────────────────────────────

    fun ReadableMap.req(key: String): String =
        if (hasKey(key) && !isNull(key)) getString(key)!!.also { require(it.isNotBlank()) { "$key must not be blank" } }
        else throw IllegalArgumentException("$key is required")

    fun ReadableMap.opt(key: String): String? =
        if (hasKey(key) && !isNull(key)) getString(key) else null

    fun ReadableMap.optStringList(key: String): List<String>? =
        if (hasKey(key) && !isNull(key)) getArray(key)?.toStringList() else null

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

    fun digitiseParams(map: ReadableMap): TokenizationRequestParams {
        val builder = TokenizationRequestParams.Builder(
            accountNumber = map.req("accountNumber"),
            institutionCode = map.req("institutionCode"),
            accountHolderName = map.req("accountHolderName"),
            walletProviderTokenizationRecommendation =
                TokenizationRecommendation.valueOf(map.req("recommendation")),
            consumerIdentifier = map.req("consumerIdentifier"),
            bvn = map.req("bvn"),
            accountHolderAddress = map.req("accountHolderAddress"),
            mobileNumber = map.req("mobileNumber"),
            walletAccountId = map.req("walletAccountId"),
            emailAddress = map.req("emailAddress"),
        )
        map.opt("clientRequestId")?.let { builder.clientRequestId(it) }
        map.opt("accountNumberSource")?.let { builder.accountNumberSource(AccountNumberSource.valueOf(it)) }
        map.opt("deviceScore")?.let { builder.walletProviderDeviceScore(TrustScore.valueOf(it)) }
        map.opt("accountScore")?.let { builder.walletProviderAccountScore(TrustScore.valueOf(it)) }
        map.optStringList("recommendationReasons")?.let { reasons ->
            builder.walletProviderTokenizationRecommendationReasons(
                reasons.map { TokenizationRecommendationReason.valueOf(it) }
            )
        }
        return builder.build()
    }

    fun merchantRegistration(map: ReadableMap): Pair<String, MerchantRegistrationData> {
        val type = map.req("merchantType")
        return type to MerchantRegistrationData(
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

    // ── Writers ─────────────────────────────────────────────────────────────────

    fun banks(banks: List<Bank>): WritableArray = Arguments.createArray().apply {
        banks.forEach { b ->
            pushMap(Arguments.createMap().apply {
                putString("slug", b.slug)
                putString("name", b.name)
                putString("institutionCode", b.institutionCode)
            })
        }
    }

    fun nubanBanks(banks: List<NubanBank>): WritableArray = Arguments.createArray().apply {
        banks.forEach { b ->
            pushMap(Arguments.createMap().apply {
                putString("slug", b.slug)
                putString("name", b.name)
                putString("institutionCode", b.institutionCode)
            })
        }
    }

    fun digitiseResult(r: TokenisationResponse): WritableMap = Arguments.createMap().apply {
        putString("responseCode", r.responseCode)
        putString("tokenUniqueReference", r.tokenUniqueReference)
        putArray("activationMethods", activationMethods(r.activationMethods?.map { it.medium to it.contact }))
        putString("message", r.message)
        putBoolean("isApproved", r.isSuccess)
        putBoolean("requiresActivation", !r.activationMethods.isNullOrEmpty())
        putNull("tokenStored")
        val err = r.error
        if (err != null) {
            putMap("error", Arguments.createMap().apply {
                putString("code", err.code)
                putString("message", err.message)
                putString("details", err.details)
            })
        } else putNull("error")
    }

    private fun activationMethods(methods: List<Pair<String?, String?>>?): WritableArray =
        Arguments.createArray().apply {
            methods?.forEach { (medium, contact) ->
                pushMap(Arguments.createMap().apply {
                    putString("medium", medium)
                    putString("contact", contact)
                })
            }
        }

    fun card(t: Token): WritableMap = Arguments.createMap().apply {
        putString("id", t.tokenId)
        putString("tokenUniqueReference", t.tokenUniqueReference)
        putString("tokenId", t.tokenId)
        putString("maskedPan", t.getMaskedPAN())
        putString("panLastFour", t.getLastFourDigits())
        putString("cardHolderName", t.cardHolderName)
        putString("expiry", t.expiryDate)
        putNull("bankName")
        putString("cardScheme", t.cardScheme?.name)
        // the stored lifecycle status (verbatim), so a greyed card can say why.
        putString("status", t.statusRaw)
        putBoolean("isActive", t.isActive)
        putBoolean("requiresActivation", !t.activationMethods.isNullOrEmpty())
        putArray(
            "activationMethods",
            activationMethods(t.activationMethods?.map { it.medium to it.contact })
        )
        putBoolean("requiresOnline", t.requiresOnline)
    }

    fun scanInspection(result: MpmScanResult, handle: String?): WritableMap =
        Arguments.createMap().apply {
            when (result) {
                is MpmScanResult.Verified -> {
                    val c: VerifiedPaymentContext = result.context
                    putBoolean("verified", true)
                    putString("handle", handle)
                    putString("merchantName", c.merchantName)
                    putString("merchantCity", c.merchantCity)
                    putString("amountDisplay", c.amount)
                    putDouble("amountMinorUnits", c.amountMinorUnits.toDouble())
                    putString("currencyNumeric", c.currencyNumeric)
                    putDouble("expiresAtEpochSeconds", c.expiryEpochSeconds.toDouble())
                }
                is MpmScanResult.Rejected -> {
                    putBoolean("verified", false)
                    putString("reason", result.reason.name)
                    putString("detail", result.detail)
                }
            }
        }

    fun paymentOutcome(o: MpmPushOutcome): WritableMap = Arguments.createMap().apply {
        putBoolean("approved", o.approved)
        putString("responseCode", o.responseCode)
        // the status is what the payment IS — `approved` alone cannot tell a decline
        // from a push the gateway answered PENDING.
        putString("responseStatus", o.responseStatus)
        putString("responseStatusReason", o.responseStatusReason)
        putString("message", o.message)
        putString("merchantName", o.merchantName)
        putString("merchantLocation", o.merchantLocation)
    }

    fun paymentQr(qr: CpmPaymentQr): WritableMap = Arguments.createMap().apply {
        putString("tokenUniqueReference", qr.tokenUniqueReference)
        putString("payload", qr.payload)
        putDouble("amountMinorUnits", qr.amountMinorUnits.toDouble())
        putString("currencyNumeric", qr.currencyNumeric)
        putDouble("expiresAtEpochMillis", qr.expiresAtEpochMillis.toDouble())
        putString("transactionHash", qr.transactionHash)
    }

    fun transactionSummary(s: TransactionSummary): WritableMap = Arguments.createMap().apply {
        putString("merchantName", s.merchantName)
        // `putDouble`, like every other minor-unit field on this bridge — the summary's amount is a
        // Long and `putInt` cannot carry one. A JS number holds it exactly up to 2^53, far above
        // any amount this rail can see.
        putDouble("amountMinorUnits", s.amountInMinorUnit.toDouble())
        putString("transactionCurrencyCode", s.transactionCurrencyCode)
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

    fun receipt(r: TransactionReceipt): WritableMap = Arguments.createMap().apply {
        putString("merchantName", r.merchantName)
        putString("merchantId", r.merchantId)
        putString("merchantAddress", r.merchantAddress)
        putString("transactionType", r.transactionType)
        putString("transactionStatus", r.transactionStatus)
        putString("transactionTime", r.transactionTime)
        putString("totalAmountMinorUnits", r.totalAmount)
        putString("totalAmountFormatted", r.totalAmountFormatted)
        putString("currency", r.currency)
        putString("maskedToken", r.maskedToken)
        putString("merchantTransactionReference", r.merchantTransactionReference)
        r.cdcvmApprovedByWallet?.let { putBoolean("cdcvmApprovedByWallet", it) }
            ?: putNull("cdcvmApprovedByWallet")
        putString("transactionId", r.transactionId)
        putString("transactionHash", r.transactionHash)
    }

    fun merchantRegistrationResult(r: MerchantRegistrationResponse): WritableMap =
        Arguments.createMap().apply {
            putBoolean("success", r.success)
            putString("merchantId", r.merchantId)
            putString("terminalId", r.terminalId)
            putString("merchantStatus", r.merchantStatus)
            putString("message", r.message)
        }

    fun storedMerchant(m: StoredMerchantData): WritableMap = Arguments.createMap().apply {
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
    }

    // [into] exists for tests: Arguments.createMap() needs the native bridge, JavaOnlyMap doesn't.
    fun tapResult(r: SoftposTransactionResponse, into: WritableMap = Arguments.createMap()): WritableMap = into.apply {
        // carry the outcome the backend stated; never re-derive it from the code. This block
        // was a code->status mapping of its own — the seventh — and it read every code it did not
        // recognise as FAILED, so `09`/`68`/`96` (still settling) and `25` (no record) all surfaced to
        // React Native as failures. `"99"` is retired: pending is said by `status` now.
        putString("responseCode", r.transactionCode.takeIf { it.isNotEmpty() })
        putString("status", r.responseStatus?.name)
        putString("reason", r.responseStatusReason)
        // Set only when the SDK could not attempt a payment (validation, arming refusal, card read) or
        // failed inside itself: not a payment outcome, so there is no code and no status beside it.
        putString("sdkErrorCode", r.sdkErrorCode?.name)
        putString("message", r.message)
        putString("amountDisplay", r.amount)
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
    }

    /**
     * The `VeyraTransactionResolvedEvent` payload. Extracted from the module's
     * observer registration so the shape both platforms must agree on is asserted by
     * a test rather than by two hand-written map literals — the iOS bridge builds the same keys.
     *
     * [into] exists for tests: `Arguments.createMap()` needs the native bridge, `JavaOnlyMap` doesn't.
     */
    fun transactionResolved(
        r: co.veyra.softpos.payment.sdk.merchant.TransactionResolution,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("merchantTransactionReference", r.reference)
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
        c: co.veyra.softpos.payment.sdk.merchant.CreditConfirmation,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("merchantTransactionReference", c.reference)
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
        c: co.veyra.wallet.sdk.api.TokenStatusChange,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("tokenUniqueReference", c.tokenUniqueReference)
        putString("status", c.status.value)
        putString("rawStatus", c.rawStatus)
        putBoolean("canPay", c.canPay)
        putString("previousStatus", c.previousRawStatus)
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
        r: co.veyra.wallet.sdk.api.WalletTransactionResolution,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("transactionHash", r.transactionHash)
        putString("tokenUniqueReference", r.tokenUniqueReference)
        putString("status", r.status)
        putString("responseCode", r.responseCode)
        putString("reason", r.reason)
        putDouble("amountMinorUnits", r.amountInMinorUnit.toDouble())
        putString("merchantName", r.merchantName)
    }

    /**
     * The `VeyraCardKeyStateEvent` payload — a card ran out of payment keys,
     * or got them back. `requiresOnline` is the same value `StoredCard.requiresOnline` carries.
     */
    fun cardKeyState(
        s: co.veyra.wallet.sdk.api.CardKeyState,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("tokenUniqueReference", s.tokenUniqueReference)
        putBoolean("requiresOnline", s.requiresOnline)
    }

    /**
     * The `VeyraMerchantStatusEvent` payload — the merchant was deactivated,
     * suspended or activated. `canAcceptPayments` crosses for the same reason `canPay` does above:
     * so JS never has to re-derive a gate the SDK already owns.
     */
    fun merchantStatusChanged(
        c: co.veyra.softpos.payment.sdk.merchant.MerchantStatusChange,
        into: WritableMap = Arguments.createMap(),
    ): WritableMap = into.apply {
        putString("merchantId", c.merchantId)
        putString("status", c.status)
        putBoolean("canAcceptPayments", c.canAcceptPayments)
        putString("previousStatus", c.previousStatus)
    }

    fun paymentContextQr(c: CreatedPaymentContext): WritableMap = Arguments.createMap().apply {
        putString("txRef", c.txRef)
        putString("mpmPayload", c.mpmPayload)
        putString("expiry", c.expiry)
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
    fun merchantTransaction(t: TransactionInfo, into: WritableMap = Arguments.createMap()): WritableMap = into.apply {
        putString("merchantTransactionReference", t.merchantTransactionReference)
        // the app's own order id, from the stored row — so a transaction detail or history
        // screen can show it, not just the screen that took the payment.
        putString("merchantOrderId", t.merchantOrderId)
        putDouble("amountMinorUnits", t.amount.toDouble())
        putString("status", t.transactionStatus.name)
        putString("responseCode", t.responseCode)
        // the outcome's stated cause, verbatim, for the detail view.
        putString("responseStatusReason", t.responseStatusReason)
        putString("transactionTime", t.transactionTime)
        putString("currencyCode", t.currencyCode)
        putString("transactionId", t.transactionId)
        putString("rail", t.rail)
        putString("railLabel", t.railLabel)
        // Android's TransactionInfo carries neither — the iOS record does (see the Swift bridge).
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

    fun merchantReceipt(r: TransactionReceiptResult): WritableMap = Arguments.createMap().apply {
        putString("merchantName", r.merchantName)
        putString("merchantAddress", r.merchantAddress)
        putString("transactionType", r.transactionType)
        putDouble("totalAmountMinorUnits", r.totalAmount.toDouble())
        putString("totalAmountFormatted", r.totalAmountFormatted)
        putString("maskedToken", r.maskedToken)
        putString("merchantTransactionReference", r.merchantTransactionReference)
        putString("transactionHash", r.transactionHash)
        putString("qrCodeBase64", r.qrCodeBase64)
        putNull("qrPayload")
        putString("cardholderName", r.cardholderName)
    }
}
