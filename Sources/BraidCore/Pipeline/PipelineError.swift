import Foundation

/// Journey step 8 failure taxonomy: transient failures (network unreachable,
/// request timeout, provider HTTP 5xx or 429) retry automatically with
/// backoff; all others (auth, invalid request, Vault write, malformed
/// response) wait for user-initiated Retry.
public enum PipelineError: Error, CustomStringConvertible, Sendable {
    case transient(String)
    case permanent(String)
    /// The user cancelled the Job. Not a failure: it must not retry, must not
    /// park as `.failed`, and must not be reported as something going wrong.
    case cancelled

    public var isTransient: Bool {
        if case .transient = self { return true }
        return false
    }

    public var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    public var description: String {
        switch self {
        case .transient(let m): "transient: \(m)"
        case .permanent(let m): "\(m)"
        case .cancelled: "cancelled"
        }
    }

    /// Classify an HTTP response per the taxonomy.
    static func classify(status: Int, body: String, context: String) -> PipelineError {
        if status >= 500 || status == 429 {
            return .transient("\(context): HTTP \(status)")
        }
        return .permanent("\(context): HTTP \(status) — \(body.prefix(300))")
    }

    /// Classify a URLSession transport error (no HTTP response at all).
    static func classify(transport error: Error, context: String) -> PipelineError {
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            // An in-flight request torn down because the user cancelled the Job.
            if ns.code == NSURLErrorCancelled { return .cancelled }
            switch ns.code {
            case NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet, NSURLErrorSecureConnectionFailed:
                return .transient("\(context): \(ns.localizedDescription)")
            default: break
            }
        }
        return .permanent("\(context): \(ns.localizedDescription)")
    }
}
