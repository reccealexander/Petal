import Foundation

/// A single turn in a Claude conversation, as sent to the Messages API.
public struct ClaudeMessage: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Errors surfaced by `ClaudeClient`. `errorDescription` strings are written
/// to read directly in the chat UI.
public enum ClaudeClientError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case httpError(status: Int, message: String)
    case network(Error)
    case decoding

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Anthropic API key set. Add one in Settings."
        case .invalidAPIKey:
            return "Your Anthropic API key was rejected (401). Check it in Settings."
        case .rateLimited:
            return "Rate limited by Anthropic (429). Please wait and try again."
        case .httpError(let status, let message):
            return "Anthropic API error (\(status)): \(message)"
        case .network(let error):
            return "Network error talking to Anthropic: \(error.localizedDescription)"
        case .decoding:
            return "Couldn't parse Anthropic's response."
        }
    }
}

/// A raw-HTTPS streaming client for the Anthropic Messages API. Swift has no
/// official Anthropic SDK, so this speaks the wire protocol directly via
/// `URLSession`.
public final class ClaudeClient: @unchecked Sendable {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let anthropicVersion = "2023-06-01"
    /// Exact model string mandated by spec — do not change.
    private static let model = "claude-sonnet-4-6"
    private static let maxTokens = 4096

    private let keychain: KeychainService

    public init(keychain: KeychainService) {
        self.keychain = keychain
    }

    /// Streams the assistant's reply to `messages` (with `system` as the
    /// system prompt) as an `AsyncThrowingStream` of text deltas, so the UI
    /// can render token-by-token.
    public func streamMessage(system: String, messages: [ClaudeMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let apiKey = keychain.apiKey() else {
                    continuation.finish(throwing: ClaudeClientError.missingAPIKey)
                    return
                }

                var request = URLRequest(url: Self.endpoint)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
                request.setValue("application/json", forHTTPHeaderField: "content-type")

                let body: [String: Any] = [
                    "model": Self.model,
                    "max_tokens": Self.maxTokens,
                    "stream": true,
                    "system": system,
                    "messages": messages.map { ["role": $0.role, "content": $0.content] }
                ]

                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    continuation.finish(throwing: ClaudeClientError.network(error))
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
                    continuation.finish(throwing: ClaudeClientError.network(error))
                    return
                }

                let (bytes, response) = bytesResult

                if let httpResponse = response as? HTTPURLResponse {
                    switch httpResponse.statusCode {
                    case 200..<300:
                        break
                    case 401:
                        continuation.finish(throwing: ClaudeClientError.invalidAPIKey)
                        return
                    case 429:
                        continuation.finish(throwing: ClaudeClientError.rateLimited)
                        return
                    default:
                        var message = ""
                        do {
                            for try await line in bytes.lines {
                                message += line
                            }
                        } catch {
                            // Best effort — fall through with whatever we read.
                        }
                        continuation.finish(
                            throwing: ClaudeClientError.httpError(status: httpResponse.statusCode, message: message)
                        )
                        return
                    }
                }

                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst("data: ".count))
                        if payload.isEmpty || payload == "[DONE]" { continue }

                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = json["type"] as? String else {
                            // Malformed line — skip rather than crash.
                            continue
                        }

                        switch type {
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let deltaType = delta["type"] as? String,
                               deltaType == "text_delta",
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "error":
                            let errorObj = json["error"] as? [String: Any]
                            let message = (errorObj?["message"] as? String) ?? "Unknown error"
                            continuation.finish(throwing: ClaudeClientError.httpError(status: 0, message: message))
                            return
                        case "message_stop":
                            continuation.finish()
                            return
                        default:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: ClaudeClientError.network(error))
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
