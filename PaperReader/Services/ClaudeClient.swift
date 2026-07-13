import Foundation

public struct ClaudeMessage: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum ClaudeClientError: LocalizedError {
    case missingAPIKey, invalidAPIKey, rateLimited, decoding
    case httpError(status: Int, message: String)
    case network(Error)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No Anthropic API key set. Add one in Settings."
        case .invalidAPIKey: "Your Anthropic API key was rejected (401). Check it in Settings."
        case .rateLimited: "Rate limited by Anthropic (429). Please wait and try again."
        case .httpError(let status, let message): "Anthropic API error (\(status)): \(message)"
        case .network(let error): "Network error talking to Anthropic: \(error.localizedDescription)"
        case .decoding: "Couldn't parse Anthropic's response."
        }
    }
}

public final class ClaudeClient: @unchecked Sendable {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let anthropicVersion = "2023-06-01"
    private static let model = "claude-sonnet-5"
    private static let maxTokens = 4096
    private let keychain: KeychainService

    public init(keychain: KeychainService) { self.keychain = keychain }

    public func streamMessage(system: String, messages: [ClaudeMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let apiKey = keychain.apiKey(for: .claude) else {
                    continuation.finish(throwing: ClaudeClientError.missingAPIKey)
                    return
                }
                var request = URLRequest(url: Self.endpoint)
                request.httpMethod = "POST"
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
                request.setValue("application/json", forHTTPHeaderField: "content-type")
                let body: [String: Any] = [
                    "model": Self.model, "max_tokens": Self.maxTokens, "stream": true,
                    "system": system,
                    "messages": messages.map { ["role": $0.role, "content": $0.content] }
                ]
                do { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
                catch { continuation.finish(throwing: ClaudeClientError.network(error)); return }

                let bytes: URLSession.AsyncBytes
                let response: URLResponse
                do { (bytes, response) = try await URLSession.shared.bytes(for: request) }
                catch {
                    if Task.isCancelled { continuation.finish() }
                    else { continuation.finish(throwing: ClaudeClientError.network(error)) }
                    return
                }
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 401 { continuation.finish(throwing: ClaudeClientError.invalidAPIKey); return }
                    if http.statusCode == 429 { continuation.finish(throwing: ClaudeClientError.rateLimited); return }
                    if !(200..<300).contains(http.statusCode) {
                        var message = ""
                        do { for try await line in bytes.lines { message += line } } catch {}
                        continuation.finish(throwing: ClaudeClientError.httpError(status: http.statusCode, message: message))
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
                              let type = json["type"] as? String else { continue }
                        switch type {
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String { continuation.yield(text) }
                        case "error":
                            let error = json["error"] as? [String: Any]
                            continuation.finish(throwing: ClaudeClientError.httpError(status: 0, message: error?["message"] as? String ?? "Unknown error"))
                            return
                        case "message_stop": continuation.finish(); return
                        default: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() }
                    else { continuation.finish(throwing: ClaudeClientError.network(error)) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
