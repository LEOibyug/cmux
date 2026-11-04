import Foundation

/// Stateless callbacks reject redirects, credential negotiation and body replay.
final class CodexpressSessionDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    nonisolated func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        didReceive _: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    nonisolated func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void
    ) {
        completionHandler(nil)
    }

    nonisolated func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willBeginDelayedRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLSession.DelayedRequestDisposition, URLRequest?) -> Void
    ) {
        completionHandler(.cancel, nil)
    }
}
