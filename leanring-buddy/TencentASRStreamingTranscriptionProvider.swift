//
//  TencentASRStreamingTranscriptionProvider.swift
//  leanring-buddy
//
//  Streaming transcription provider backed by Tencent Cloud realtime ASR.
//

import AVFoundation
import Foundation

struct TencentASRStreamingTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class TencentASRStreamingTranscriptionProvider: BuddyTranscriptionProvider {
    private static let signedURLProxyPath = "/transcribe-url"

    let displayName = "Tencent Cloud ASR"
    let requiresSpeechRecognitionPermission = false

    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    private let sharedWebSocketURLSession = URLSession(configuration: .default)

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        let signedWebsocketURL = try await fetchSignedWebsocketURL(keyterms: keyterms)
        print("🎙️ Tencent ASR: fetched signed websocket URL")

        let session = TencentASRStreamingTranscriptionSession(
            websocketURL: signedWebsocketURL,
            urlSession: sharedWebSocketURLSession,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        try await session.open()
        return session
    }

    private func fetchSignedWebsocketURL(keyterms: [String]) async throws -> URL {
        let proxyURLString = AppBundleConfiguration.workerBaseURL + Self.signedURLProxyPath
        guard let proxyURL = URL(string: proxyURLString) else {
            throw TencentASRStreamingTranscriptionProviderError(
                message: "Tencent ASR proxy URL is invalid."
            )
        }

        var request = URLRequest(url: proxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["keyterms": keyterms])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw TencentASRStreamingTranscriptionProviderError(
                message: "Failed to fetch Tencent ASR websocket URL (HTTP \(statusCode)): \(body)"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let websocketURLString = json["websocket_url"] as? String,
              let websocketURL = URL(string: websocketURLString) else {
            throw TencentASRStreamingTranscriptionProviderError(
                message: "Invalid Tencent ASR signed URL response from proxy."
            )
        }

        return websocketURL
    }
}

private final class TencentASRStreamingTranscriptionSession: BuddyStreamingTranscriptionSession {
    private struct ResponseEnvelope: Decodable {
        let code: Int
        let message: String?
        let result: RecognitionResult?
        let final: Int?
    }

    private struct RecognitionResult: Decodable {
        let slice_type: Int
        let index: Int
        let voice_text_str: String
    }

    private struct StoredSentence {
        var transcriptText: String
        var isFinal: Bool
    }

    private static let targetSampleRate = 16_000.0
    private static let explicitFinalTranscriptGracePeriodSeconds = 2.0

    let finalTranscriptFallbackDelaySeconds: TimeInterval = 3.5

    private let websocketURL: URL
    private let urlSession: URLSession
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.tencentasr.state")
    private let sendQueue = DispatchQueue(label: "com.learningbuddy.tencentasr.send")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: targetSampleRate)

    private var webSocketTask: URLSessionWebSocketTask?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var hasResolvedReadyContinuation = false
    private var hasDeliveredFinalTranscript = false
    private var isAwaitingExplicitFinalTranscript = false
    private var latestTranscriptText = ""
    private var storedSentencesByIndex: [Int: StoredSentence] = [:]
    private var explicitFinalTranscriptDeadlineWorkItem: DispatchWorkItem?

    init(
        websocketURL: URL,
        urlSession: URLSession,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.websocketURL = websocketURL
        self.urlSession = urlSession
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func open() async throws {
        let webSocketTask = urlSession.webSocketTask(with: websocketURL)
        self.webSocketTask = webSocketTask
        webSocketTask.resume()

        receiveNextMessage()

        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                self.readyContinuation = continuation
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.data(audioPCM16Data)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasDeliveredFinalTranscript else { return }
            self.isAwaitingExplicitFinalTranscript = true
            self.scheduleExplicitFinalTranscriptDeadline()
        }

        sendJSONMessage(["type": "end"])
    }

    func cancel() {
        stateQueue.async {
            self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
            self.explicitFinalTranscriptDeadlineWorkItem = nil
        }

        sendJSONMessage(["type": "end"])
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func receiveNextMessage() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingTextMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingTextMessage(text)
                    }
                @unknown default:
                    break
                }

                self.receiveNextMessage()
            case .failure(let error):
                self.failSession(with: error)
            }
        }
    }

    private func handleIncomingTextMessage(_ text: String) {
        guard let messageData = text.data(using: .utf8) else { return }

        do {
            let envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: messageData)

            guard envelope.code == 0 else {
                failSession(with: TencentASRStreamingTranscriptionProviderError(
                    message: envelope.message ?? "Tencent ASR returned an error."
                ))
                return
            }

            resolveReadyContinuationIfNeeded(with: .success(()))

            if let recognitionResult = envelope.result {
                handleRecognitionResult(recognitionResult)
            }

            if envelope.final == 1 {
                stateQueue.async {
                    self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
                }
            }
        } catch {
            failSession(with: error)
        }
    }

    private func handleRecognitionResult(_ result: RecognitionResult) {
        let transcriptText = result.voice_text_str
            .trimmingCharacters(in: .whitespacesAndNewlines)

        stateQueue.async {
            if !transcriptText.isEmpty {
                let isFinalSentence = result.slice_type == 2
                self.storedSentencesByIndex[result.index] = StoredSentence(
                    transcriptText: transcriptText,
                    isFinal: isFinalSentence
                )
            }

            let fullTranscriptText = self.composeFullTranscript()
            self.latestTranscriptText = fullTranscriptText

            if !fullTranscriptText.isEmpty {
                self.onTranscriptUpdate(fullTranscriptText)
            }

            if self.isAwaitingExplicitFinalTranscript && result.slice_type == 2 {
                self.explicitFinalTranscriptDeadlineWorkItem?.cancel()
                self.explicitFinalTranscriptDeadlineWorkItem = nil
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }
    }

    private func composeFullTranscript() -> String {
        storedSentencesByIndex
            .sorted(by: { $0.key < $1.key })
            .map(\.value.transcriptText)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func scheduleExplicitFinalTranscriptDeadline() {
        explicitFinalTranscriptDeadlineWorkItem?.cancel()

        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            self?.stateQueue.async {
                guard let self else { return }
                self.deliverFinalTranscriptIfNeeded(self.bestAvailableTranscriptText())
            }
        }

        explicitFinalTranscriptDeadlineWorkItem = deadlineWorkItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.explicitFinalTranscriptGracePeriodSeconds,
            execute: deadlineWorkItem
        )
    }

    private func deliverFinalTranscriptIfNeeded(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        explicitFinalTranscriptDeadlineWorkItem?.cancel()
        explicitFinalTranscriptDeadlineWorkItem = nil
        onFinalTranscriptReady(transcriptText)
    }

    private func sendJSONMessage(_ payload: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        sendQueue.async { [weak self] in
            guard let self, let webSocketTask = self.webSocketTask else { return }
            webSocketTask.send(.string(jsonString)) { [weak self] error in
                if let error {
                    self?.failSession(with: error)
                }
            }
        }
    }

    private func failSession(with error: Error) {
        resolveReadyContinuationIfNeeded(with: .failure(error))
        stateQueue.async {
            if self.hasDeliveredFinalTranscript {
                return
            }

            let latestTranscriptText = self.bestAvailableTranscriptText()

            if self.isAwaitingExplicitFinalTranscript
                && !self.hasDeliveredFinalTranscript
                && !latestTranscriptText.isEmpty {
                print("[Tencent ASR] WebSocket error during finalization, delivering partial transcript: \(error.localizedDescription)")
                self.deliverFinalTranscriptIfNeeded(latestTranscriptText)
                return
            }

            print("[Tencent ASR] Session failed with error: \(error.localizedDescription)")
            self.onError(error)
        }
    }

    private func bestAvailableTranscriptText() -> String {
        let composedTranscriptText = composeFullTranscript()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !composedTranscriptText.isEmpty {
            return composedTranscriptText
        }

        return latestTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveReadyContinuationIfNeeded(with result: Result<Void, Error>) {
        stateQueue.async {
            guard !self.hasResolvedReadyContinuation else { return }
            self.hasResolvedReadyContinuation = true

            switch result {
            case .success:
                self.readyContinuation?.resume()
            case .failure(let error):
                self.readyContinuation?.resume(throwing: error)
            }

            self.readyContinuation = nil
        }
    }
}
