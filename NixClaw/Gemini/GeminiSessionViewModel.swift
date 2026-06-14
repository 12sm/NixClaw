import Foundation
import SwiftUI

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var isInBackground: Bool = false
  @Published var sessionDuration: TimeInterval = 0
  @Published var isAudioOnlyMode: Bool = false
  /// Audio-first: when false, video frames are NOT streamed to Gemini (vision
  /// uses on-demand single-frame capture instead). Turned on by the set_video
  /// tool or the explicit glasses-streaming start path.
  @Published var videoEnabled: Bool = false
  private let geminiService = GeminiLiveService()
  // openClawBridge is now exposed via computed property (see below)
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private var lastVideoFrameTime: Date = .distantPast
  private var lastVideoFrame: UIImage?  // Store for tool calls that need the current view

  /// Debug property to check if we have a video frame available
  var hasVideoFrame: Bool { lastVideoFrame != nil }

  /// Debug: was image included in last tool call?
  @Published var lastToolCallIncludedImage: Bool = false

  /// Capture feedback: triggers flash animation when image is sent to AI
  @Published var showCaptureFlash: Bool = false
  @Published var capturedImageForFlash: UIImage?

  /// Debug: expose bridge for UI debug indicators
  var openClawBridge: OpenClawBridge { _openClawBridge }
  private let _openClawBridge = OpenClawBridge()
  private var stateObservation: Task<Void, Never>?
  private var sessionStartTime: Date?
  private var sessionTimer: Task<Void, Never>?
  private var shouldAutoReconnect = false
  private var reconnectAttempts = 0
  private let maxReconnectAttempts = 3

  // Auto-close: end an idle session so it doesn't stream (and bill) forever.
  private var autoCloseTask: Task<Void, Never>?
  private var lastActivityTime: Date = .distantPast
  private let autoCloseInterval: TimeInterval = 45
  private let stopPhrases = [
    "that's all", "thats all", "that's it", "thats it", "that's everything",
    "i'm done", "im done", "stop listening", "stop session", "goodbye scout",
  ]

  var streamingMode: StreamingMode = .glasses
  var onPauseVideoCapture: (() -> Void)?
  var onResumeVideoCapture: (() -> Void)?
  /// Ask the stream layer to capture ONE frame on demand (audio-first vision).
  var onRequestVisionFrame: (() -> Void)?
  /// Ask the stream layer to start/stop continuous camera streaming (set_video).
  var onSetVideoStreaming: ((Bool) -> Void)?

  // Vision intent → on-demand single-frame capture (only when not already streaming).
  private let visionKeywords = [
    "look", "looking at", "see this", "what is this", "what's this", "whats this",
    "what am i", "what color", "how many", "read this", "read the", "identify",
    "describe", "in front of me", "what do you see", "check this out",
  ]
  private var requestedVisionThisTurn = false

  init() {
    setupBackgroundObservers()
  }

  private func setupBackgroundObservers() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleEnterBackground),
      name: .appDidEnterBackground,
      object: nil
    )

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleEnterForeground),
      name: .appWillEnterForeground,
      object: nil
    )
  }

  @objc private func handleEnterBackground() {
    NSLog("[GeminiSession] Entering background mode - stopping video, keeping audio")
    isInBackground = true
    onPauseVideoCapture?()
  }

  @objc private func handleEnterForeground() {
    NSLog("[GeminiSession] Returning to foreground - resuming video")
    isInBackground = false
    if isGeminiActive {
      onResumeVideoCapture?()
    }
  }

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured. Open Settings (gear icon) and enter your API key from https://aistudio.google.com/apikey"
      return
    }

    isGeminiActive = true

    // Wire audio callbacks
    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        // iPhone mode: mute mic while model speaks to prevent echo feedback
        // (loudspeaker + co-located mic overwhelms iOS echo cancellation)
        if self.streamingMode == .iPhone && self.geminiService.isModelSpeaking { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      self?.audioManager.playAudio(data: data)
    }

    geminiService.onInterrupted = { [weak self] in
      self?.audioManager.stopPlayback()
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        // Clear user transcript when AI finishes responding
        self.userTranscript = ""
        self.requestedVisionThisTurn = false
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.aiTranscript = ""
        // User is talking — keep the session alive.
        self.bumpActivity()
        let lower = self.userTranscript.lowercased()
        // Explicit "I'm done" phrases end the session immediately.
        if self.stopPhrases.contains(where: { lower.contains($0) }) {
          NSLog("[GeminiSession] Stop phrase detected — ending session")
          self.stopSession()
          return
        }
        // Audio-first: if the user asks something visual and we're not already
        // streaming video, grab one frame and inject it so Gemini can answer.
        if !self.videoEnabled, !self.requestedVisionThisTurn,
           self.visionKeywords.contains(where: { lower.contains($0) }) {
          self.requestedVisionThisTurn = true
          NSLog("[GeminiSession] Vision intent detected — requesting one frame")
          self.onRequestVisionFrame?()
        }
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
      }
    }

    // Handle unexpected disconnection with auto-reconnect
    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive else { return }

        let isServerTimeout = reason?.contains("Server closing") == true ||
                              reason?.contains("goAway") == true

        if isServerTimeout && self.shouldAutoReconnect && self.reconnectAttempts < self.maxReconnectAttempts {
          NSLog("[GeminiSession] Server timeout, attempting reconnect (\(self.reconnectAttempts + 1)/\(self.maxReconnectAttempts))")
          self.reconnectAttempts += 1
          self.connectionState = .connecting

          // Brief pause before reconnecting
          try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

          // Reconnect
          let success = await self.geminiService.connect()
          if success {
            NSLog("[GeminiSession] Reconnected successfully")
            self.reconnectAttempts = 0
            self.connectionState = .ready
          } else {
            self.stopSession()
            self.errorMessage = "Reconnection failed after server timeout"
          }
        } else {
          self.stopSession()
          if isServerTimeout {
            self.errorMessage = "Session ended (Gemini has a ~15 min limit). Tap to start a new session."
          } else {
            self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
          }
        }
      }
    }

    // New OpenClaw session per Gemini session (fresh context, no stale memory)
    _openClawBridge.resetSession()

    // Wire tool call handling
    toolCallRouter = ToolCallRouter(bridge: _openClawBridge)

    // Capture feedback: show flash animation when image is sent to AI
    toolCallRouter?.onImageCaptured = { [weak self] image in
      guard let self else { return }
      self.capturedImageForFlash = image
      self.showCaptureFlash = true
      NSLog("[GeminiSession] Image captured - triggering flash feedback")
    }

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          // set_video is handled locally (toggle continuous streaming), not sent to Scout.
          if call.name == "set_video" {
            let on = (call.args["on"] as? Bool) ?? false
            NSLog("[GeminiSession] set_video(%@)", on ? "on" : "off")
            self.setVideo(on)
            let response: [String: Any] = [
              "toolResponse": ["functionResponses": [[
                "id": call.id,
                "name": call.name,
                "response": ["result": on ? "Continuous video is now on." : "Continuous video is now off."],
              ]]],
            ]
            self.geminiService.sendToolResponse(response)
            continue
          }

          // DEBUG: Log frame availability at tool call time
          let frameAvailable = self.lastVideoFrame != nil
          NSLog("[GeminiSession] Tool call received. lastVideoFrame available: %@", frameAvailable ? "YES" : "NO")

          // Update debug indicator
          self.lastToolCallIncludedImage = frameAvailable

          // Pass the current video frame so tool calls can include images
          self.toolCallRouter?.handleToolCall(call, currentFrame: self.lastVideoFrame) { [weak self] response in
            self?.geminiService.sendToolResponse(response)
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }

    // Observe service state and update Live Activity
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
        self.toolCallStatus = self.openClawBridge.lastToolCallStatus

        // Update Live Activity
        GeminiLiveActivityManager.shared.updateActivity(
          isConnected: self.connectionState == .ready,
          isModelSpeaking: self.isModelSpeaking,
          duration: self.sessionDuration
        )
      }
    }

    // Setup audio
    // In audio-only mode, prefer Bluetooth (AirPods) if available for both input and output
    // This prevents audio from being routed to Ray-Ban glasses speaker
    do {
      let preferBluetooth = isAudioOnlyMode && audioManager.isBluetoothConnected
      try audioManager.setupAudioSession(
        useIPhoneMode: streamingMode == .iPhone,
        preferBluetooth: preferBluetooth
      )
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isGeminiActive = false
      return
    }

    // Connect to Gemini and wait for setupComplete
    let setupOk = await geminiService.connect()

    if !setupOk {
      let msg: String
      if case .error(let err) = geminiService.connectionState {
        msg = err
      } else {
        msg = "Failed to connect to Gemini"
      }
      errorMessage = msg
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Start mic capture
    do {
      try audioManager.startCapture()
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    // Enable auto-reconnect and start session timer
    shouldAutoReconnect = true
    reconnectAttempts = 0
    sessionStartTime = Date()
    startSessionTimer()
    startAutoCloseTimer()

    // Start Dynamic Island Live Activity
    GeminiLiveActivityManager.shared.startActivity()
  }

  private func startSessionTimer() {
    sessionTimer?.cancel()
    sessionTimer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        guard !Task.isCancelled, let self, let start = self.sessionStartTime else { break }
        self.sessionDuration = Date().timeIntervalSince(start)
      }
    }
  }

  /// Mark the session as active right now (resets the auto-close countdown).
  private func bumpActivity() {
    lastActivityTime = Date()
  }

  /// End the session after `autoCloseInterval` seconds of no user speech.
  /// Stays alive while the model is speaking or a tool call is in flight.
  private func startAutoCloseTimer() {
    autoCloseTask?.cancel()
    lastActivityTime = Date()
    autoCloseTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000) // check every 2s
        guard !Task.isCancelled, let self else { break }
        guard self.isGeminiActive else { break }
        // Don't time out while we're mid-turn.
        if self.isModelSpeaking { self.bumpActivity(); continue }
        if case .executing = self.toolCallStatus { self.bumpActivity(); continue }
        if Date().timeIntervalSince(self.lastActivityTime) >= self.autoCloseInterval {
          NSLog("[GeminiSession] Auto-closing after %.0fs of inactivity", self.autoCloseInterval)
          self.stopSession()
          break
        }
      }
    }
  }

  func stopSession() {
    shouldAutoReconnect = false
    sessionTimer?.cancel()
    sessionTimer = nil
    autoCloseTask?.cancel()
    autoCloseTask = nil
    sessionStartTime = nil
    sessionDuration = 0
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle

    // End Dynamic Island Live Activity
    GeminiLiveActivityManager.shared.endActivity()
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    // ALWAYS store the latest frame for tool calls (even if we don't send it to Gemini)
    // This ensures lastVideoFrame is never nil when a tool call needs an image
    lastVideoFrame = image

    // Audio-first: only stream frames to Gemini when continuous video is enabled.
    guard videoEnabled else { return }
    guard !isInBackground else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  /// Turn continuous video streaming on/off (set_video tool, or explicit start).
  func setVideo(_ on: Bool) {
    videoEnabled = on
    onSetVideoStreaming?(on)
  }

  /// Inject a single on-demand frame so Gemini can answer a vision question
  /// without continuous streaming. Also makes it available to any execute call.
  func injectVisionFrame(_ image: UIImage) {
    lastVideoFrame = image
    geminiService.sendVideoFrame(image: image)
    NSLog("[GeminiSession] Injected one on-demand frame to Gemini for vision")
  }

  /// Get the most recent video frame (for tool calls that need to include an image)
  func getLastVideoFrame() -> UIImage? {
    return lastVideoFrame
  }

  // MARK: - Audio Only Mode (Background-friendly, no video)

  /// Start an audio-only session for voice commands and tool calling.
  /// This mode works in background with Dynamic Island and doesn't require camera access.
  func startAudioOnlySession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured"
      return
    }

    isAudioOnlyMode = true
    streamingMode = .iPhone  // Use iPhone audio settings for best echo cancellation

    // Start the regular session - video frames will be skipped due to isAudioOnlyMode
    await startSession()

    if isGeminiActive {
      NSLog("[GeminiSession] Audio-only mode started (background-friendly)")
    }
  }

  func stopAudioOnlySession() {
    stopSession()
    isAudioOnlyMode = false
    NSLog("[GeminiSession] Audio-only mode stopped")
  }

}
