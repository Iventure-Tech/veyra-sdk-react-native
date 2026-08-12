package co.veyra.reactnative

import co.veyra.core.SdkModeException
import co.veyra.softpos.payment.sdk.SdkErrorCode
import co.veyra.softpos.payment.sdk.VeyraSdkException
import co.veyra.wallet.sdk.exception.TokenizationRequestValidationException
import co.veyra.wallet.sdk.exception.WalletRefusalException
import com.facebook.react.bridge.Promise

/**
 * Normalises Android SDK failures into the wrapper's typed error codes so JS never
 * string-matches a message (the iOS module maps its typed enums to the same codes).
 */
internal object VeyraPromises {

    fun reject(promise: Promise, t: Throwable) {
        val (code, native) = classify(t)
        promise.reject(code, t.message ?: code, t)
        if (native != null) {
            // nativeErrorCode rides in the message when present; the reject signature
            // carries (code, message, throwable) portably across RN versions.
        }
    }

    fun reject(promise: Promise, code: String, message: String) {
        promise.reject(code, message)
    }

    private fun classify(t: Throwable): Pair<String, String?> {
        val message = t.message ?: ""
        return when {
            t is TokenizationRequestValidationException -> "VALIDATION" to t.fieldName
            t is SdkModeException -> "MODE_REFUSED" to null
            // the device has no working connection. Checked before the SdkErrorCode
            // branches below so it is never flattened into REQUEST_FAILED, and matched two ways
            // because the two SDKs report it in their own idioms — SoftPOS as an SdkErrorCode, the
            // wallet as a message prefix on Result.failure — for the one same condition.
            t is VeyraSdkException && t.errorCode == SdkErrorCode.NO_NETWORK_CONNECTION ->
                "NO_NETWORK_CONNECTION" to t.errorCodeString
            t is co.veyra.common.net.VeyraNetworkException && message.contains("NO_NETWORK_CONNECTION") ->
                "NO_NETWORK_CONNECTION" to null
            t is VeyraSdkException ->
                if (t.errorCode == SdkErrorCode.MISSING_MANDATORY_CONFIG) {
                    "MISSING_MANDATORY_CONFIG" to t.errorCodeString
                } else {
                    "REQUEST_FAILED" to t.errorCodeString
                }
            // the SDK now throws typed refusals — the prefix table this bridge used to
            // keep lives in WalletRefusalException.fromMessage, beside the codes it matches.
            t is WalletRefusalException.AmountExceedsCardLimit -> "AMOUNT_EXCEEDS_CARD_LIMIT" to null
            t is WalletRefusalException.OnlineRequired -> "ONLINE_REQUIRED" to null
            t is WalletRefusalException.TokenNotActive -> "TOKEN_NOT_ACTIVE" to null
            // The CDCVM sheet the SDK raises itself. `CDCVM_REQUIRED` used to sit
            // here, meaning "the app forgot to authenticate" — it no longer exists, because the
            // SDK asks rather than refusing. These three are what a customer's answer produces,
            // and they carry the code in the message like every other refusal.
            message.contains("AUTH_CANCELLED") -> "AUTH_CANCELLED" to null
            message.contains("AUTH_UNAVAILABLE") -> "AUTH_UNAVAILABLE" to null
            message.contains("AUTH_FAILED") -> "AUTH_FAILED" to null
            message.startsWith("No active card") -> "NO_ACTIVE_CARD" to null
            message.contains("can't show a payment QR") -> "CARD_CANNOT_SHOW_QR" to null
            t is IllegalArgumentException -> "VALIDATION" to null
            t is IllegalStateException && message.contains("not initialised") -> "NOT_CONFIGURED" to null
            else -> "UNKNOWN" to null
        }
    }
}

/**
 * Opaque handles for natively-held payment objects (verified MPM contexts, scanned CPM
 * QRs): signed payloads and card data never round-trip through JS.
 */
internal class HandleRegistry<T : Any> {
    private val entries = java.util.concurrent.ConcurrentHashMap<String, T>()

    fun put(value: T): String {
        val handle = java.util.UUID.randomUUID().toString()
        entries[handle] = value
        return handle
    }

    fun take(handle: String): T? = entries.remove(handle)
    fun peek(handle: String): T? = entries[handle]
}
