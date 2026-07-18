import Foundation
import Testing
@testable import Matilda

@MainActor
@Suite(.serialized)
struct TTSCancellationTests {
    @Test func olderCompleteAudioRequestCannotPlayAfterNewPreviewStarts() async throws {
        TTSTestURLProtocol.reset()
        var playedPayloads: [String] = []
        let client = makeClient { audioData in
            playedPayloads.append(String(decoding: audioData, as: UTF8.self))
        }

        let olderPreviewTask = Task {
            try? await client.speakText(
                "old-preview",
                voiceID: "test-voice",
                volume: 1,
                speed: 1,
                pitch: 0,
                emotion: "automatic"
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        let newerPreviewTask = Task {
            try? await client.speakText(
                "new-preview",
                voiceID: "test-voice",
                volume: 1,
                speed: 1,
                pitch: 0,
                emotion: "automatic"
            )
        }

        await olderPreviewTask.value
        await newerPreviewTask.value

        #expect(playedPayloads == ["new-preview"])
    }

    @Test func stopPlaybackPreventsPendingCompleteAudioFromReviving() async throws {
        TTSTestURLProtocol.reset()
        var playbackCount = 0
        let client = makeClient { _ in playbackCount += 1 }

        let previewTask = Task {
            try? await client.speakText(
                "old-preview",
                voiceID: "test-voice",
                volume: 1,
                speed: 1,
                pitch: 0,
                emotion: "automatic"
            )
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        client.stopPlayback()
        await previewTask.value

        #expect(playbackCount == 0)
    }

    @Test func cancelledStreamingGenerationDoesNotFallbackOrCallNewFailureHandler() async throws {
        TTSTestURLProtocol.reset()
        let client = makeClient { _ in }
        var firstSessionFailureCount = 0
        var secondSessionFailureCount = 0

        client.beginStreamingResponse(
            onPlaybackStarted: {},
            onFailure: { _ in firstSessionFailureCount += 1 }
        )
        client.enqueueStreamingSpeech(
            "old-stream",
            voiceID: "test-voice",
            volume: 1,
            speed: 1,
            pitch: 0,
            emotion: "automatic"
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        client.beginStreamingResponse(
            onPlaybackStarted: {},
            onFailure: { _ in secondSessionFailureCount += 1 }
        )
        client.finishStreamingResponse()
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(firstSessionFailureCount == 0)
        #expect(secondSessionFailureCount == 0)
        #expect(TTSTestURLProtocol.requestCount(forPath: "/tts") == 0)
    }

    @Test func cancellingVoicePreviewDoesNotEndAnActiveStreamingSession() {
        TTSTestURLProtocol.reset()
        let client = makeClient { _ in }
        client.beginStreamingResponse(onPlaybackStarted: {}, onFailure: { _ in })

        client.stopCompleteSpeechPlayback()

        #expect(client.isPlaying)
        client.stopPlayback()
    }

    @Test func streamingPlayerCancellationReturnsBeforeSlowAudioCleanupFinishes() {
        let cleanupFinished = DispatchSemaphore(value: 0)
        let player = StreamingMP3AudioPlayer(
            onPlaybackStarted: {},
            onPlaybackFinished: {},
            onFailure: { _ in },
            cancellationCleanupHandler: {
                Thread.sleep(forTimeInterval: 0.3)
                cleanupFinished.signal()
            }
        )

        let cancellationStartedAt = Date()
        player.cancel()
        let cancellationDuration = Date().timeIntervalSince(cancellationStartedAt)

        #expect(cancellationDuration < 0.05)
        #expect(cleanupFinished.wait(timeout: .now() + 1) == .success)
    }

    private func makeClient(
        audioPlaybackHandler: @escaping (Data) throws -> Void
    ) -> ElevenLabsTTSClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TTSTestURLProtocol.self]
        return ElevenLabsTTSClient(
            proxyURL: "https://clicky.test/tts",
            session: URLSession(configuration: configuration),
            audioPlaybackHandler: audioPlaybackHandler
        )
    }
}

private final class TTSTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let stateLock = NSLock()
    private static var pathRequestCounts: [String: Int] = [:]
    private var responseWorkItem: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "clicky.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.stateLock.lock()
        Self.pathRequestCounts[path, default: 0] += 1
        Self.stateLock.unlock()

        let requestBody = Self.requestBodyData(from: request)
        let requestPayload = (try? JSONSerialization.jsonObject(with: requestBody)) as? [String: Any]
        let requestText = requestPayload?["text"] as? String ?? ""
        let delay = requestText.hasPrefix("old") ? 0.2 : 0.02
        let responseWorkItem = DispatchWorkItem { [weak self] in
            guard let self, let url = self.request.url else { return }
            let response = HTTPURLResponse(
                url: url,
                statusCode: path == "/tts-stream" ? 503 : 200,
                httpVersion: nil,
                headerFields: ["Content-Type": path == "/tts-stream" ? "application/json" : "audio/mpeg"]
            )!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(requestText.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.responseWorkItem = responseWorkItem
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: responseWorkItem)
    }

    override func stopLoading() {
        responseWorkItem?.cancel()
        responseWorkItem = nil
    }

    static func reset() {
        stateLock.lock()
        pathRequestCounts.removeAll()
        stateLock.unlock()
    }

    static func requestCount(forPath path: String) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pathRequestCounts[path, default: 0]
    }

    private static func requestBodyData(from request: URLRequest) -> Data {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let bodyStream = request.httpBodyStream else { return Data() }

        bodyStream.open()
        defer { bodyStream.close() }
        var requestBody = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let bytesRead = bodyStream.read(&buffer, maxLength: buffer.count)
            guard bytesRead > 0 else { break }
            requestBody.append(contentsOf: buffer.prefix(bytesRead))
        }
        return requestBody
    }
}
