import Foundation
import Synchronization

/// Downloads a body that may not pass a size limit, for URLs that cannot be trusted. The body is taken
/// a chunk at a time, as the session delivers it, and the transfer is cancelled, closing the
/// connection, as soon as the declared length or the bytes received pass the limit. How long a
/// transfer may take is the session's to say (`timeoutIntervalForResource`). Nothing of the URL is
/// kept or reported.
public enum CappedDownload {
    /// The body of a 2xx response, if it is at most `limit` bytes. Nil for any other status, and for a
    /// body declared or found to be longer than `limit`. Throws the transfer's own error when it fails
    /// (a `URLError`: no connection, a timeout), and `CancellationError` when the calling task is
    /// cancelled, which cancels the transfer.
    public static func body(from url: URL, session: URLSession, limit: Int) async throws -> Data? {
        let receiver = Receiver(limit: limit)
        let task = session.dataTask(with: url)
        task.delegate = receiver  // held by the task until it ends
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if receiver.start(continuation) { task.resume() }
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// One transfer's delegate. It answers the caller once: the first outcome decided stands, and what
/// the session reports after it (the cancel that follows a refusal, say) changes nothing.
private final class Receiver: NSObject, URLSessionDataDelegate, Sendable {
    private enum Outcome {
        case body
        case refused
        case failed(any Error)
    }

    private struct State {
        var continuation: CheckedContinuation<Data?, any Error>?
        var body = Data()
    }

    private let limit: Int
    private let state = Mutex(State())

    init(limit: Int) {
        self.limit = limit
    }

    /// False, with the caller already answered, when it was cancelled before the transfer started.
    func start(_ continuation: CheckedContinuation<Data?, any Error>) -> Bool {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return false
        }
        state.withLock { $0.continuation = continuation }
        return true
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let expected = response.expectedContentLength  // -1 when unknown
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              expected <= Int64(limit)
        else {
            finish(.refused)
            completionHandler(.cancel)
            return
        }
        let capacity = expected > 0 ? Int(expected) : min(limit, 64 * 1024)
        state.withLock { $0.body.reserveCapacity(capacity) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = state.withLock { state -> Bool in
            guard state.continuation != nil else { return false }  // already answered
            if data.count > limit - state.body.count { return true }
            state.body.append(data)
            return false
        }
        guard over else { return }
        finish(.refused)
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error else {
            finish(.body)
            return
        }
        // Cancelled by the caller; a cancel of this receiver's own follows an answer already given.
        finish(.failed((error as? URLError)?.code == .cancelled ? CancellationError() : error))
    }

    private func finish(_ outcome: Outcome) {
        let (continuation, body) = state.withLock { state in
            let taken = (state.continuation, state.body)
            state.continuation = nil
            state.body = Data()
            return taken
        }
        guard let continuation else { return }
        switch outcome {
        case .body: continuation.resume(returning: body)
        case .refused: continuation.resume(returning: nil)
        case .failed(let error): continuation.resume(throwing: error)
        }
    }
}
