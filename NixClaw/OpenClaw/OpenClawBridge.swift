import Foundation
import UIKit

@MainActor
class OpenClawBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var debugImageReachedDelegateTask: Bool = false  // DEBUG: did image reach delegateTask?

  private let session: URLSession
  private var sessionKey: String

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    self.session = URLSession(configuration: config)
    self.sessionKey = OpenClawBridge.newSessionKey()
  }

  func resetSession() {
    sessionKey = OpenClawBridge.newSessionKey()
    NSLog("[OpenClaw] New session: %@", sessionKey)
  }

  private static func newSessionKey() -> String {
    let ts = ISO8601DateFormatter().string(from: Date())
    return "agent:main:glass:\(ts)"
  }

  // MARK: - Agent Chat (session continuity via x-openclaw-session-key header)

  func delegateTask(
    task: String,
    toolName: String = "execute",
    image: UIImage? = nil
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    guard let url = URL(string: "\(AppConfig.shared.openClawBaseURL)/v1/chat/completions") else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(AppConfig.shared.openClawToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")

    NSLog("[OpenClaw] delegateTask called. image param is: %@", image != nil ? "NOT NIL" : "NIL")
    await MainActor.run { self.debugImageReachedDelegateTask = (image != nil) }

    // Build messages. If a frame is present, send it INLINE as an OpenAI image_url
    // data URI — Burrow's /v1/chat/completions (Phase 1) normalizes this to the
    // internal image shape and routes it to Scout's vision-capable model.
    // (No separate upload server needed.)
    var messages: [[String: Any]] = []
    if let image = image, let jpeg = image.jpegData(compressionQuality: 0.7) {
      let dataURI = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
      messages = [[
        "role": "user",
        "content": [
          ["type": "text", "text": task],
          ["type": "image_url", "image_url": ["url": dataURI]],
        ],
      ]]
      NSLog("[OpenClaw] Sending inline image (%d bytes jpeg)", jpeg.count)
    } else {
      messages = [["role": "user", "content": task]]
    }

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": messages,
      "stream": false,
    ]

    do {
      let jsonData = try JSONSerialization.data(withJSONObject: body)
      request.httpBody = jsonData
      
      let (data, response) = try await session.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[OpenClaw] Chat failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))
        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        return .failure("Chat request failed (HTTP \(code))")
      }

      // Parse OpenAI-style response
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any],
            let content = message["content"] as? String else {
        lastToolCallStatus = .failed(toolName, "Invalid response")
        return .failure("Could not parse response")
      }

      lastToolCallStatus = .completed(toolName)
      return .success(content)

    } catch {
      NSLog("[OpenClaw] Request error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Request error: \(error.localizedDescription)")
    }
  }
}
