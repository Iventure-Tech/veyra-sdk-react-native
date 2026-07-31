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
            acquirerId = map.req("acquirerId"),
            addressLine2 = map.opt("addressLine2") ?: "",
            bvn = map.opt("bvn"),
            cacNumber = map.opt("cacNumber"),
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
        putNull("status")
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
        putInt("amountMinorUnits", s.amountInMinorUnit)
        putString("transactionCurrencyCode", s.transactionCurrencyCode)
        putString("transactionHash", s.transactionHash)
        putString("authorizationStatus", s.authorizationStatus)
        putString("localTransactionDateTime", s.localTransactionDateTime)
        s.atEpochMillis?.let { putDouble("atEpochMillis", it.toDouble()) } ?: putNull("atEpochMillis")
        putString("entryMethod", s.entryMethod)
        putString("merchantLocation", s.merchantLocation)
        putString("merchantTransactionReference", s.merchantTransactionReference)
        putString("merchantId", s.merchantId)
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
    }

    fun tapResult(r: SoftposTransactionResponse): WritableMap = Arguments.createMap().apply {
        putString("responseCode", r.transactionCode)
        putString(
            "status",
            when (r.transactionCode) {
                "00" -> "APPROVED"
                "05", "12", "14", "51", "54" -> "DECLINED"
                "99" -> "PENDING"
                else -> "FAILED"
            }
        )
        putString("message", r.message)
        putString("amountDisplay", r.amount)
        putString("cardScheme", r.cardScheme)
        putString("maskedTokenLast4", r.maskedTokenLast4)
        putString("merchantTransactionReference", r.merchantTransactionReference)
        putString("transactionId", r.transactionId)
        putString("merchantStatus", r.merchantStatus)
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

    fun merchantTransaction(t: TransactionInfo): WritableMap = Arguments.createMap().apply {
        putString("merchantTransactionReference", t.merchantTransactionReference)
        putDouble("amountMinorUnits", t.amount.toDouble())
        putString("status", t.transactionStatus.name)
        putString("responseCode", t.responseCode)
        putString("transactionTime", t.transactionTime)
        putString("currencyCode", t.currencyCode)
        putString("transactionId", t.transactionId)
        putNull("rail")
        putNull("maskedTokenLast4")
        putNull("transactionHash")
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
    }
}
