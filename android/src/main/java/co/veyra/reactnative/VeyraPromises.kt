package co.veyra.reactnative

import co.veyra.common.VeyraErrorCode
import co.veyra.common.VeyraError
import com.facebook.react.bridge.Promise

/**
 * The bridge's one rejection path. Only a setup error rejects — a mistake in the app's
 * integration — and it is mapped by its [VeyraErrorCode], never by matching a message (the iOS
 * module maps its error enums to the same five codes). Everything that happens **to** a call is an
 * outcome the SDK returns, which the module resolves; anything else reaching here is an SDK defect
 * and rejects `UNKNOWN`.
 */
internal object VeyraPromises {

    fun reject(promise: Promise, t: Throwable) {
        val code = classify(t)
        promise.reject(code, t.message ?: code, t)
    }

    fun reject(promise: Promise, code: VeyraErrorCode, message: String) {
        promise.reject(code.name, message)
    }

    /** The JS code for [t]: its setup code (no-customer included, by type), else `UNKNOWN`. */
    fun classify(t: Throwable): String = when (t) {
        is VeyraError -> t.code.name
        else -> "UNKNOWN"
    }

    /**
     * `initialize`'s rejection. There, an [IllegalArgumentException] comes from reading the config map
     * or validating the provider (a missing customerId, environment or required id, an unusable
     * provider) — the app's configuration, so `INVALID_CONFIGURATION`, naming the problem.
     */
    fun rejectInitialize(promise: Promise, t: Throwable) {
        val code = classifyInitialize(t)
        promise.reject(code, t.message ?: code, t)
    }

    fun classifyInitialize(t: Throwable): String =
        if (t is IllegalArgumentException) VeyraErrorCode.INVALID_CONFIGURATION.name else classify(t)
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
