import Foundation

/// A single turn in a Gemini conversation, as sent to the
/// `generateContent`/`streamGenerateContent` APIs.
public struct GeminiMessage: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Errors surfaced by `GeminiClient`. `errorDescription` strings are written
/// to read directly in the chat UI.
public enum GeminiClientError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case httpError(status: Int, message: String)
    case network(Error)
    case decoding

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Google AI Studio API key set. Add one in Preferences."
        case .invalidAPIKey:
            return "Your Google AI Studio API key was rejected. Check it in Preferences."
        case .rateLimited:
            return "Rate limited by Google AI Studio. Please wait and try again."
        case .httpError(let status, let message):
            return "Gemini API error (\(status)): \(message)"
        case .network(let error):
            return "Network error talking to Google AI Studio: \(error.localizedDescription)"
        case .decoding:
            return "Couldn't parse the Gemini response."
        }
    }
}

/// A raw-HTTPS streaming client for the Google AI Studio Gemini API. Swift
/// has no official Gemini SDK, so this speaks the wire protocol directly via
/// `URLSession`, mirroring the shape of the app's previous Anthropic client.
public final class GeminiClient: @unchecked Sendable {
    /// Google retires pinned Gemini model names on a roughly quarterly cadence
    /// (this app has been bitten twice), so we track the `-latest` alias, which
    /// Google repoints to the current flagship flash model. To pin a specific
    /// version instead, set an explicit name here (e.g. "gemini-3.5-flash").
    private static let model = "gemini-flash-latest"
    private static let endpoint = URL(
        string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse"
    )!
    private static let maxOutputTokens = 4096

    private let keychain: KeychainService

    public init(keychain: KeychainService) {
        self.keychain = keychain
    }

    /// Streams the assistant's reply to `messages` (with `system` as the
    /// system prompt) as an `AsyncThrowingStream` of text deltas, so the UI
    /// can render token-by-token.
    public func streamMessage(system: String, messages: [GeminiMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let apiKey = keychain.apiKey() else {
                    continuation.finish(throwing: GeminiClientError.missingAPIKey)
                    return
                }

                var request = URLRequest(url: Self.endpoint)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let body: [String: Any] = [
                    "systemInstruction": ["parts": [["text": system]]],
                    "contents": messages.map {
                        ["role": $0.role == "assistant" ? "model" : "user", "parts": [["text": $0.content]]]
                    },
                    "generationConfig": ["maxOutputTokens": Self.maxOutputTokens]
                ]

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    continuation.finish(throwing: GeminiClientError.network(error))
                    return
                }

                let bytesResult: (URLSession.AsyncBytes, URLResponse)
                do {
                    bytesResult = try await URLSession.shared.bytes(for: request)
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.finish(throwing: GeminiClientError.network(error))
                    return
                }

                let (bytes, response) = bytesResult

                if let httpResponse = response as? HTTPURLResponse {
                    switch httpResponse.statusCode {
                    case 200..<300:
                        break
                    case 400, 403:
                        var raw = ""
                        do {
                            for try await line in bytes.lines {
                                raw += line
                            }
                        } catch {
                            // Best effort — fall through with whatever we read.
                        }
                        let message = Self.extractErrorMessage(from: raw) ?? "Unknown error"
                        if Self.looksLikeInvalidAPIKey(message) {
                            continuation.finish(throwing: GeminiClientError.invalidAPIKey)
                        } else {
                            continuation.finish(
                                throwing: GeminiClientError.httpError(status: httpResponse.statusCode, message: message)
                            )
                        }
                        return
                    case 429:
                        continuation.finish(throwing: GeminiClientError.rateLimited)
                        return
                    default:
                        var raw = ""
                        do {
                            for try await line in bytes.lines {
                                raw += line
                            }
                        } catch {
                            // Best effort — fall through with whatever we read.
                        }
                        let message = Self.extractErrorMessage(from: raw) ?? raw
                        continuation.finish(
                            throwing: GeminiClientError.httpError(status: httpResponse.statusCode, message: message)
                        )
                        return
                    }
                }

                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))
                        if payload.isEmpty { continue }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            // Malformed line — skip rather than crash.
                            continue
                        }

                        guard let candidates = json["candidates"] as? [[String: Any]] else { continue }
                        for candidate in candidates {
                            guard let content = candidate["content"] as? [String: Any],
                                  let parts = content["parts"] as? [[String: Any]] else { continue }
                            for part in parts {
                                if let text = part["text"] as? String {
                                    continuation.yield(text)
                                }
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: GeminiClientError.network(error))
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Best-effort extraction of `error.message` from a Gemini JSON error
    /// body. Returns `nil` if the body isn't parseable JSON in that shape.
    /// The body may be a bare `{"error": {...}}` object or a single-element
    /// array wrapping one, depending on the failure path.
    private static func extractErrorMessage(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let dict = json as? [String: Any], let errorObj = dict["error"] as? [String: Any] {
            return errorObj["message"] as? String
        }
        if let array = json as? [[String: Any]],
           let first = array.first,
           let errorObj = first["error"] as? [String: Any] {
            return errorObj["message"] as? String
        }
        return nil
    }

    /// Whether an error message indicates a rejected/invalid API key
    /// (as opposed to some other 400/403), per spec.
    private static func looksLikeInvalidAPIKey(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("api key")
            || lowered.contains("permission")
            || lowered.contains("permission_denied")
            || lowered.contains("api_key_invalid")
    }
}
