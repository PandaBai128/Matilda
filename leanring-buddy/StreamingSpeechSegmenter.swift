//
//  StreamingSpeechSegmenter.swift
//  leanring-buddy
//

import Foundation

/// Converts accumulated LLM text into complete, speakable sentences while
/// withholding code blocks and machine-readable pointing tags.
struct StreamingSpeechSegmenter {
    private var previousAccumulatedText = ""
    private var unprocessedText = ""
    private var pendingSpeechText = ""
    private var allSpeakableText = ""
    private var isInsideCodeBlock = false
    private var encounteredCodeBlock = false

    mutating func consume(accumulatedText: String) -> [String] {
        if !accumulatedText.hasPrefix(previousAccumulatedText) {
            reset()
        }

        let newText = String(accumulatedText.dropFirst(previousAccumulatedText.count))
        previousAccumulatedText = accumulatedText
        unprocessedText.append(newText)
        return processAvailableText(allowIncompleteFenceMarker: false)
    }

    mutating func finish(finalAccumulatedText: String) -> [String] {
        var completedSegments = consume(accumulatedText: finalAccumulatedText)
        completedSegments.append(contentsOf: processAvailableText(allowIncompleteFenceMarker: true))

        pendingSpeechText = Self.removingPointingTagSuffix(from: pendingSpeechText)
        if let finalSegment = takePendingSpeechSegment() {
            completedSegments.append(finalSegment)
        }

        if encounteredCodeBlock,
           !allSpeakableText.localizedCaseInsensitiveContains("复制"),
           !allSpeakableText.localizedCaseInsensitiveContains("copy") {
            let copyNotice = "内容已经写好，可以在面板里复制。"
            allSpeakableText.append(" \(copyNotice)")
            completedSegments.append(copyNotice)
        }

        return completedSegments
    }

    mutating func reset() {
        previousAccumulatedText = ""
        unprocessedText = ""
        pendingSpeechText = ""
        allSpeakableText = ""
        isInsideCodeBlock = false
        encounteredCodeBlock = false
    }

    private mutating func processAvailableText(allowIncompleteFenceMarker: Bool) -> [String] {
        var completedSegments: [String] = []

        while !unprocessedText.isEmpty {
            if unprocessedText.hasPrefix("```") {
                unprocessedText.removeFirst(3)
                isInsideCodeBlock.toggle()
                encounteredCodeBlock = true
                continue
            }

            if !allowIncompleteFenceMarker,
               unprocessedText.count < 3,
               unprocessedText.allSatisfy({ $0 == "`" }) {
                break
            }

            let nextCharacter = unprocessedText.removeFirst()
            guard !isInsideCodeBlock else { continue }

            if pendingSpeechText.last == ".", nextCharacter.isWhitespace {
                if let completedSegment = takePendingSpeechSegment() {
                    completedSegments.append(completedSegment)
                }
                continue
            }

            pendingSpeechText.append(nextCharacter)
            if Self.immediateSentenceTerminators.contains(nextCharacter),
               let completedSegment = takePendingSpeechSegment() {
                completedSegments.append(completedSegment)
            }
        }

        return completedSegments
    }

    private mutating func takePendingSpeechSegment() -> String? {
        let completedSegment = pendingSpeechText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingSpeechText = ""
        guard !completedSegment.isEmpty else { return nil }
        allSpeakableText.append(allSpeakableText.isEmpty ? completedSegment : " \(completedSegment)")
        return completedSegment
    }

    private static let immediateSentenceTerminators: Set<Character> = ["。", "！", "？", "!", "?"]

    private static func removingPointingTagSuffix(from text: String) -> String {
        let pointingTagPattern = #"\[POINT(?:_V2)?:[\s\S]*$"#
        guard let pointingTagRegex = try? NSRegularExpression(pattern: pointingTagPattern) else {
            return text
        }
        let textRange = NSRange(text.startIndex..., in: text)
        return pointingTagRegex.stringByReplacingMatches(
            in: text,
            range: textRange,
            withTemplate: ""
        )
    }
}

/// Owns sentence segmentation and ordered TTS enqueueing for one model response.
@MainActor
final class StreamingSpeechResponseSession {
    private let ttsClient: ElevenLabsTTSClient
    private let voiceID: String
    private let volume: Double
    private let speed: Double
    private let pitch: Int
    private let emotion: String
    private var segmenter = StreamingSpeechSegmenter()

    init(
        ttsClient: ElevenLabsTTSClient,
        voiceID: String,
        volume: Double,
        speed: Double,
        pitch: Int,
        emotion: String
    ) {
        self.ttsClient = ttsClient
        self.voiceID = voiceID
        self.volume = volume
        self.speed = speed
        self.pitch = pitch
        self.emotion = emotion
    }

    func begin(
        onPlaybackStarted: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        ttsClient.beginStreamingResponse(
            onPlaybackStarted: onPlaybackStarted,
            onFailure: onFailure
        )
    }

    func consume(accumulatedText: String) {
        enqueue(segmenter.consume(accumulatedText: accumulatedText))
    }

    func finish(finalAccumulatedText: String) {
        enqueue(segmenter.finish(finalAccumulatedText: finalAccumulatedText))
        ttsClient.finishStreamingResponse()
    }

    private func enqueue(_ speechSegments: [String]) {
        for speechSegment in speechSegments {
            ttsClient.enqueueStreamingSpeech(
                speechSegment,
                voiceID: voiceID,
                volume: volume,
                speed: speed,
                pitch: pitch,
                emotion: emotion
            )
        }
    }
}
