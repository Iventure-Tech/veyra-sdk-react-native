package co.veyra.reactnative

import co.veyra.common.providers.VeyraAssertionProvider
import co.veyra.common.providers.VeyraClientSecretProvider
import co.veyra.common.providers.VeyraProvider
import co.veyra.common.providers.VeyraProxyProvider
import co.veyra.common.providers.VeyraRelayException
import co.veyra.common.net.NetworkFailureKind
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Bridges the app's provider — `assertion()` of an AUTHENTICATION provider, or `send()` of a PROXY
 * provider — to the JS functions the app passed to `Veyra.initialize`. Functions cannot cross the bridge, so JS keeps
 * them (per SDK) and native asks for each call over the [EVENT] channel; JS answers through
 * [resolve] / [reject].
 *
 * The native callback objects built here route by SDK key to whatever JS functions are currently
 * registered; a reloaded bundle builds a new bridge and re-initialises, which re-binds the SDKs to
 * it (the SDKs re-bind their connection on every initialise). They
 * are called from background work as well as from JS-initiated calls; that is fine while the JS
 * runtime is alive. With no live runtime a request cannot be delivered at all:
 *  - a relay request then fails `neverSent = true` (nothing left the device), and the SDK's
 *    background cycle treats it as a failed poll — it keeps the row and tries again later;
 *  - an assertion request fails, which the SDK reports as `NOT_AUTHENTICATED`.
 * Requests already handed to JS when the runtime goes away fail `neverSent = false`: JS may have
 * forwarded them.
 */
internal class ConnectionBridge(private val reactContext: ReactApplicationContext) {

    companion object {
        const val EVENT = "VeyraConnectionRequest"
    }

    private val pending = ConcurrentHashMap<String, CancellableContinuation<String?>>()

    /**
     * Build the native provider for [sdk] (`"softpos"` / `"wallet"`) from the bridge-safe map JS
     * sent for the app's one provider. Validates defensively — JS already did — naming the field.
     * Each SDK gets its own native object, routed by SDK key, all answered by the same JS provider.
     */
    @Suppress("DEPRECATION")
    fun providerFor(sdk: String, map: ReadableMap?): VeyraProvider {
        requireNotNull(map) { "provider is required: pass an AUTHENTICATION or a PROXY provider" }
        fun str(key: String): String? = if (map.hasKey(key) && !map.isNull(key)) map.getString(key) else null
        return when (val kind = str("kind")) {
            "clientSecret" -> {
                val id = str("clientId")?.takeIf { it.isNotBlank() }
                    ?: throw IllegalArgumentException("provider.clientId must not be blank (VeyraClientSecretProvider)")
                val secret = str("clientSecret")?.takeIf { it.isNotBlank() }
                    ?: throw IllegalArgumentException("provider.clientSecret must not be blank (VeyraClientSecretProvider)")
                ClientSecret(id, secret)
            }
            "auth" -> {
                val id = str("clientId")?.takeIf { it.isNotBlank() }
                    ?: throw IllegalArgumentException("provider.clientId must not be blank (VeyraAssertionProvider)")
                require(map.hasKey("hasAssertion") && map.getBoolean("hasAssertion")) {
                    "provider.assertion is required (VeyraAssertionProvider)"
                }
                assertionProvider(sdk, id)
            }
            // JS has already checked that `send` exists; it is the provider's only function.
            "request" -> relay(sdk)
            else -> throw IllegalArgumentException(
                "provider.providerType must be 'AUTHENTICATION' or 'PROXY' (got $kind)",
            )
        }
    }

    private fun assertionProvider(sdk: String, id: String) = object : VeyraAssertionProvider {
        override val clientId: String = id
        override suspend fun assertion(audience: String, jkt: String): String? = try {
            request(sdk, "assertion", jkt, audience)
        } catch (e: VeyraRelayException) {
            // The SDK's token client turns any assertion failure into NOT_AUTHENTICATED.
            throw IllegalStateException(e.message ?: "assertion provider failed", e)
        }
    }

    private fun relay(sdk: String) = object : VeyraProxyProvider {
        override suspend fun send(request: String) = forward(sdk, request)
    }

    private suspend fun forward(sdk: String, envelope: String): String =
        request(sdk, "relay", envelope, null)
            ?: throw VeyraRelayException(NetworkFailureKind.OTHER, neverSent = false, message = "The relay answered null")

    /** [audience] travels with an assertion request only (the API base URL the assertion is for). */
    private suspend fun request(sdk: String, kind: String, payload: String, audience: String?): String? {
        if (!reactContext.hasActiveReactInstance()) {
            throw VeyraRelayException(
                NetworkFailureKind.OTHER, neverSent = true,
                message = "No JavaScript runtime is running to answer the $sdk $kind request",
            )
        }
        val id = UUID.randomUUID().toString()
        return suspendCancellableCoroutine { cont ->
            pending[id] = cont
            // The SDK's own timeout cancels the wait; a late JS answer then finds nothing.
            cont.invokeOnCancellation { pending.remove(id) }
            try {
                reactContext
                    .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
                    .emit(EVENT, Arguments.createMap().apply {
                        putString("id", id)
                        putString("sdk", sdk)
                        putString("kind", kind)
                        putString("payload", payload)
                        if (audience != null) putString("audience", audience)
                    })
            } catch (t: Throwable) {
                // Could not hand it to JS: it never left the device.
                if (pending.remove(id) != null) {
                    cont.resumeWithException(
                        VeyraRelayException(NetworkFailureKind.OTHER, neverSent = true, message = t.message, cause = t),
                    )
                }
            }
        }
    }

    /** JS answered [id]; `null` is a valid assertion answer ("no user signed in"). */
    fun resolve(id: String, value: String?) {
        pending.remove(id)?.resume(value)
    }

    /** JS rejected [id]. [httpStatus] -1 means none. */
    fun reject(id: String, kind: String, neverSent: Boolean, httpStatus: Int, message: String?) {
        val cont = pending.remove(id) ?: return
        val failureKind = runCatching { NetworkFailureKind.valueOf(kind) }.getOrDefault(NetworkFailureKind.OTHER)
        cont.resumeWithException(
            VeyraRelayException(failureKind, neverSent, httpStatus.takeIf { it >= 0 }, message),
        )
    }

    /** The JS runtime is going away: everything already handed to it may have been forwarded. */
    fun failAllPending() {
        val ids = pending.keys.toList()
        for (id in ids) {
            pending.remove(id)?.resumeWithException(
                VeyraRelayException(
                    NetworkFailureKind.OTHER, neverSent = false,
                    message = "The JavaScript runtime went away before answering",
                ),
            )
        }
    }
}

@Suppress("DEPRECATION")
private class ClientSecret(override val clientId: String, override val clientSecret: String) : VeyraClientSecretProvider
