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
    private let voicesProxyURL: URL
    private let session: URLSession

    /// The audio player for the current TTS playback. Kept alive so the
    /// audio finishes playing even if the caller doesn't hold a reference.
    private var audioPlayer: AVAudioPlayer?
    private var pendingStreamingSpeechRequests: [SpeechRequest] = []
    private var pendingStreamingAudio: [Data] = []
    private var streamingSynthesisTask: Task<Void, Never>?
    private var streamingGeneration = UUID()
    private var isAcceptingStreamingSpeech = false
    private var hasStartedStreamingPlayback = false
    private var onStreamingPlaybackStarted: (() -> Void)?
    private var onStreamingSpeechFailure: ((Error) -> Void)?

    init(proxyURL: String) {
        let ttsProxyURL = URL(string: proxyURL)!
        self.ttsProxyURL = ttsProxyURL
        self.voicesProxyURL = ttsProxyURL.deletingLastPathComponent().appendingPathComponent("voices")

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
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
        let audioData = try await synthesizeAudio(SpeechRequest(
            text: text,
            voiceID: voiceID,
            volume: volume,
            speed: speed,
            pitch: pitch,
            emotion: emotion
        ))
        try Task.checkCancellation()
        try playAudioData(audioData)
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
        startStreamingSynthesisIfNeeded()
    }

    func finishStreamingResponse() {
        isAcceptingStreamingSpeech = false
    }

    private func synthesizeAudio(_ speechRequest: SpeechRequest) async throws -> Data {
        var request = URLRequest(url: ttsProxyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

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

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

    private func startStreamingSynthesisIfNeeded() {
        guard streamingSynthesisTask == nil else { return }
        let synthesisGeneration = streamingGeneration

        streamingSynthesisTask = Task { [weak self] in
            guard let self else { return }

            while synthesisGeneration == self.streamingGeneration,
                  !self.pendingStreamingSpeechRequests.isEmpty {
                let speechRequest = self.pendingStreamingSpeechRequests.removeFirst()
                do {
                    let audioData = try await self.synthesizeAudio(speechRequest)
                    try Task.checkCancellation()
                    self.pendingStreamingAudio.append(audioData)
                    try self.playNextStreamingAudioIfNeeded()
                } catch is CancellationError {
                    break
                } catch {
                    self.onStreamingSpeechFailure?(error)
                }
            }

            guard synthesisGeneration == self.streamingGeneration else { return }
            self.streamingSynthesisTask = nil
            if !self.pendingStreamingSpeechRequests.isEmpty {
                self.startStreamingSynthesisIfNeeded()
            }
        }
    }

    private func playNextStreamingAudioIfNeeded() throws {
        guard audioPlayer == nil, !pendingStreamingAudio.isEmpty else { return }
        let audioData = pendingStreamingAudio.removeFirst()
        try playAudioData(audioData)

        if !hasStartedStreamingPlayback {
            hasStartedStreamingPlayback = true
            onStreamingPlaybackStarted?()
        }
    }

    private func playAudioData(_ audioData: Data) throws {
        let player = try AVAudioPlayer(data: audioData)
        audioPlayer = player
        player.delegate = self
        player.volume = 1
        player.prepareToPlay()
        player.play()
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
            || streamingSynthesisTask != nil
            || !pendingStreamingSpeechRequests.isEmpty
            || !pendingStreamingAudio.isEmpty
            || isAcceptingStreamingSpeech
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        streamingGeneration = UUID()
        streamingSynthesisTask?.cancel()
        streamingSynthesisTask = nil
        pendingStreamingSpeechRequests.removeAll()
        pendingStreamingAudio.removeAll()
        isAcceptingStreamingSpeech = false
        hasStartedStreamingPlayback = false
        onStreamingPlaybackStarted = nil
        onStreamingSpeechFailure = nil
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.audioPlayer === player else { return }
            self.audioPlayer = nil
            do {
                try self.playNextStreamingAudioIfNeeded()
            } catch {
                self.onStreamingSpeechFailure?(error)
            }
        }
    }
}
