// VeyraCommon — the deployment environment both Veyra SDKs are configured with.

import Foundation

/// The deployment environment — which Veyra backend the SDK talks to. The same type, with the same
/// name, as Android and React Native `VeyraEnvironment`.
public enum VeyraEnvironment: String, Sendable {
    case local = "LOCAL"
    case test = "TEST"
    case live = "LIVE"
}
