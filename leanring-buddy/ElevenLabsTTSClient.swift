//
//  ElevenLabsTTSClient.swift
//  leanring-buddy
//
//  Fetches MiniMax text-to-speech audio from the configured Worker and plays
//  it through the system audio output. Also loads the account voice catalog.
//

import AVFoundation
import Foundation

struct MiniMaxVoiceOption: Identifiable, Equatable {
    let voiceID: String
    let displayName: String
    let category: String
    let description: String

    var id: String { voiceID }
}

@MainActor
final class ElevenLabsTTSClient: NSObject, AVAudioPlayerDelegate {
    private struct SpeechRequest {
        let text: String
        let voiceID: String
        let volume: Double
        let speed: Double
        let pitch: Int
        let emotion: String
    }

    private struct StreamingTTSFailure: LocalizedError {
        let underlyingError: Error
        let receivedAudioBytes: Bool

        var errorDescription: String? {
            underlyingError.localizedDescription
        }
    }

    private struct VoiceCatalogResponse: Decodable {
        let systemVoice: [VoiceRecord]?
        let voiceCloning: [VoiceRecord]?
        let voiceGeneration: [VoiceRecord]?

        enum CodingKeys: String, CodingKey {
            case systemVoice = "system_voice"
            case voiceCloning = "voice_cloning"
            case voiceGeneration = "voice_generation"
        }
    }

    private struct VoiceRecord: Decodable {
        let voiceID: String
        let voiceName: String?
        let description: [String]?

        enum CodingKeys: String, CodingKey {
            case voiceID = "voice_id"
            case voiceName = "voice_name"
            case description
        }
    }

    private let ttsProxyURL: URL
    private let streamingTTSProxyURL: URL
    private let voicesProxyURL: URL
    private let session: URLSession
    private let audioPlaybackHandler: ((Data) throws -> Void)?

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?
    private var completeSpeechGeneration = UUID()
    private var pendingStreamingSpeechRequests: [SpeechRequest] = []
    private var streamingSynthesisTask: Task<Void, Never>?
    private var streamingAudioPlayer: StreamingMP3AudioPlayer?
    private var streamingGeneration = UUID()
    private var isAcceptingStreamingSpeech = false
    private var hasStartedStreamingPlayback = false
    private var onStreamingPlaybackStarted: (() -> Void)?
    private var onStreamingSpeechFailure: ((Error) -> Void)?

    init(
        proxyURL: String,
        session: URLSession? = nil,
        audioPlaybackHandler: ((Data) throws -> Void)? = nil
    ) {
        let ttsProxyURL = URL(string: proxyURL)!
        self.ttsProxyURL = ttsProxyURL
        self.streamingTTSProxyURL = ttsProxyURL.deletingLastPathComponent().appendingPathComponent("tts-stream")
        self.voicesProxyURL = ttsProxyURL.deletingLastPathComponent().appendingPathComponent("voices")

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
        self.audioPlaybackHandler = audioPlaybackHandler
        super.init()
    }

    /// Sends `text` to the Worker TTS endpoint and plays the resulting audio.
    /// Throws on network or decoding errors. Cancellation-safe.
    func speakText(
        _ text: String,
        voiceID: String,
        volume: Double,
        speed: Double,
        pitch: Int,
        emotion: String
    ) async throws {
        stopPlayback()
        let speechGeneration = completeSpeechGeneration
        let audioData = try await synthesizeAudio(SpeechRequest(
            text: text,
            voiceID: voiceID,
            volume: volume,
            speed: speed,
            pitch: pitch,
            emotion: emotion
        ))
        try Task.checkCancellation()
        guard speechGeneration == completeSpeechGeneration else {
            throw CancellationError()
        }
        if let audioPlaybackHandler {
            try audioPlaybackHandler(audioData)
        } else {
            try playAudioData(audioData)
        }
    }

    func beginStreamingResponse(
        onPlaybackStarted: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        stopPlayback()
        isAcceptingStreamingSpeech = true
        hasStartedStreamingPlayback = false
        onStreamingPlaybackStarted = onPlaybackStarted
        onStreamingSpeechFailure = onFailure
        let responseGeneration = streamingGeneration
        streamingAudioPlayer = StreamingMP3AudioPlayer(
            onPlaybackStarted: { [weak self] in
                guard let self,
                      responseGeneration == self.streamingGeneration,
                      !self.hasStartedStreamingPlayback else { return }
                self.hasStartedStreamingPlayback = true
                self.onStreamingPlaybackStarted?()
            },
            onPlaybackFinished: { [weak self] in
                guard let self, responseGeneration == self.streamingGeneration else { return }
                self.streamingAudioPlayer = nil
            },
            onFailure: { [weak self] error in
                guard let self, responseGeneration == self.streamingGeneration else { return }
                self.streamingAudioPlayer = nil
                self.onStreamingSpeechFailure?(error)
            }
        )
    }

    func enqueueStreamingSpeech(
        _ text: String,
        voiceID: String,
        volume: Double,
        speed: Double,
        pitch: Int,
        emotion: String
    ) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAcceptingStreamingSpeech, !normalizedText.isEmpty else { return }

        pendingStreamingSpeechRequests.append(SpeechRequest(
            text: normalizedText,
            voiceID: voiceID,
            volume: volume,
            speed: speed,
            pitch: pitch,
            emotion: emotion
        ))
        matildaDebugLog("tts segment enqueued")
        startStreamingSynthesisIfNeeded()
    }

    func finishStreamingResponse() {
        isAcceptingStreamingSpeech = false
        finishStreamingPlaybackIfReady()
    }

    private func synthesizeAudio(_ speechRequest: SpeechRequest) async throws -> Data {
        var request = URLRequest(url: ttsProxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        request.httpBody = try speechRequestBody(speechRequest)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "MiniMaxTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "MiniMaxTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        return data
    }

    private func speechRequestBody(_ speechRequest: SpeechRequest) throws -> Data {
        var body: [String: Any] = [
            "text": speechRequest.text,
            "voice_id": speechRequest.voiceID,
            "volume": min(max(speechRequest.volume, 0.1), 10),
            "speed": min(max(speechRequest.speed, 0.5), 2),
            "pitch": min(max(speechRequest.pitch, -12), 12)
        ]
        if speechRequest.emotion != "automatic" {
            body["emotion"] = speechRequest.emotion
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func startStreamingSynthesisIfNeeded() {
        guard streamingSynthesisTask == nil, let streamingAudioPlayer else { return }
        let synthesisGeneration = streamingGeneration
        let streamingFailureHandler = onStreamingSpeechFailure

        streamingSynthesisTask = Task { [weak self] in
            guard let self else { return }

            while synthesisGeneration == self.streamingGeneration,
                  !self.pendingStreamingSpeechRequests.isEmpty {
                let speechRequest = self.pendingStreamingSpeechRequests.removeFirst()
                do {
                    try await self.streamAudio(speechRequest, into: streamingAudioPlayer)
                    try Task.checkCancellation()
                } catch is CancellationError {
                    break
                } catch let streamingFailure as StreamingTTSFailure
                    where !streamingFailure.receivedAudioBytes {
                    guard self.isCurrentStreamingGeneration(synthesisGeneration) else { break }
                    do {
                        let completeAudioData = try await self.synthesizeAudio(speechRequest)
                        guard self.isCurrentStreamingGeneration(synthesisGeneration) else { break }
                        try await streamingAudioPlayer.beginSegment()
                        try await streamingAudioPlayer.appendAudioBytes(completeAudioData)
                        await streamingAudioPlayer.endSegment()
                        matildaDebugLog("tts stream used complete-audio fallback")
                    } catch {
                        guard self.isCurrentStreamingGeneration(synthesisGeneration),
                              !Self.isCancellationError(error) else { break }
                        streamingFailureHandler?(error)
                    }
                } catch {
                    guard self.isCurrentStreamingGeneration(synthesisGeneration),
                          !Self.isCancellationError(error) else { break }
                    streamingFailureHandler?(error)
                }
            }

            guard synthesisGeneration == self.streamingGeneration else { return }
            self.streamingSynthesisTask = nil
            if !self.pendingStreamingSpeechRequests.isEmpty {
                self.startStreamingSynthesisIfNeeded()
            } else {
                self.finishStreamingPlaybackIfReady()
            }
        }
    }

    private func streamAudio(
        _ speechRequest: SpeechRequest,
        into streamingAudioPlayer: StreamingMP3AudioPlayer
    ) async throws {
        var receivedAudioBytes = false
        do {
            var request = URLRequest(url: streamingTTSProxyURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
            request.httpBody = try speechRequestBody(speechRequest)

            let (audioBytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "MiniMaxTTS", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid streaming response"])
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw NSError(domain: "MiniMaxTTS", code: httpResponse.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Streaming TTS API error (\(httpResponse.statusCode))"])
            }

            try await streamingAudioPlayer.beginSegment()
            var pendingAudioData = Data()
            pendingAudioData.reserveCapacity(8_192)
            var totalAudioByteCount = 0

            for try await audioByte in audioBytes {
                try Task.checkCancellation()
                pendingAudioData.append(audioByte)
                if pendingAudioData.count >= 8_192 {
                    receivedAudioBytes = true
                    totalAudioByteCount += pendingAudioData.count
                    try await streamingAudioPlayer.appendAudioBytes(pendingAudioData)
                    pendingAudioData.removeAll(keepingCapacity: true)
                }
            }

            if !pendingAudioData.isEmpty {
                receivedAudioBytes = true
                totalAudioByteCount += pendingAudioData.count
                try await streamingAudioPlayer.appendAudioBytes(pendingAudioData)
            }
            guard receivedAudioBytes else {
                throw NSError(domain: "MiniMaxTTS", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "MiniMax returned no streaming audio"])
            }
            await streamingAudioPlayer.endSegment()
            matildaDebugLog("tts stream finished")
        } catch let error where Self.isCancellationError(error) {
            await streamingAudioPlayer.endSegment()
            throw CancellationError()
        } catch {
            await streamingAudioPlayer.endSegment()
            throw StreamingTTSFailure(
                underlyingError: error,
                receivedAudioBytes: receivedAudioBytes
            )
        }
    }

    private func finishStreamingPlaybackIfReady() {
        guard !isAcceptingStreamingSpeech,
              streamingSynthesisTask == nil,
              pendingStreamingSpeechRequests.isEmpty else { return }
        streamingAudioPlayer?.finishPlayback()
    }

    private func isCurrentStreamingGeneration(_ generation: UUID) -> Bool {
        generation == streamingGeneration && !Task.isCancelled
    }

    private nonisolated static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }

    private func playAudioData(_ audioData: Data) throws {
        let player = try AVAudioPlayer(data: audioData)
        audioPlayer = player
        player.delegate = self
        player.volume = 1
        player.prepareToPlay()
        player.play()
        matildaDebugLog("tts playback started")
        print("🔊 MiniMax TTS: playing \(audioData.count / 1024)KB audio")
    }

    func fetchAvailableVoices() async throws -> [MiniMaxVoiceOption] {
        var request = URLRequest(url: voicesProxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "MiniMaxTTS", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid voice catalog response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "MiniMaxTTS", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Voice catalog error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        let catalog = try JSONDecoder().decode(VoiceCatalogResponse.self, from: data)
        return makeVoiceOptions(from: catalog.systemVoice, category: "System")
            + makeVoiceOptions(from: catalog.voiceCloning, category: "Cloned")
            + makeVoiceOptions(from: catalog.voiceGeneration, category: "Generated")
    }

    private func makeVoiceOptions(from records: [VoiceRecord]?, category: String) -> [MiniMaxVoiceOption] {
        (records ?? []).compactMap { record in
            let voiceID = record.voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !voiceID.isEmpty else { return nil }
            let voiceName = record.voiceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = voiceName.flatMap { $0.isEmpty ? nil : $0 } ?? voiceID
            return MiniMaxVoiceOption(
                voiceID: voiceID,
                displayName: displayName,
                category: category,
                description: (record.description ?? []).joined(separator: " ")
            )
        }
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        (audioPlayer?.isPlaying ?? false)
            || streamingAudioPlayer != nil
            || streamingSynthesisTask != nil
            || !pendingStreamingSpeechRequests.isEmpty
            || isAcceptingStreamingSpeech
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        stopCompleteSpeechPlayback()
        streamingGeneration = UUID()
        streamingSynthesisTask?.cancel()
        streamingSynthesisTask = nil
        pendingStreamingSpeechRequests.removeAll()
        streamingAudioPlayer?.cancel()
        streamingAudioPlayer = nil
        isAcceptingStreamingSpeech = false
        hasStartedStreamingPlayback = false
        onStreamingPlaybackStarted = nil
        onStreamingSpeechFailure = nil
    }

    /// Complete-file playback is used by voice previews. It can be cancelled
    /// without interrupting a separate streaming response already in progress.
    func stopCompleteSpeechPlayback() {
        completeSpeechGeneration = UUID()
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.audioPlayer = nil
        }
    }
}
