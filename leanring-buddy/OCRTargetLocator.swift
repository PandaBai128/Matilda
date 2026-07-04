//
//  OCRTargetLocator.swift
//  leanring-buddy
//
//  Generic local text grounding for screenshots. This is intentionally not
//  app-specific: it uses Apple's Vision OCR to find visible text boxes and maps
//  them back to macOS screen coordinates.
//

import AppKit
import Foundation
import ImageIO
import Vision

enum OCRTargetLocator {
    private struct OCRMatch {
        let target: NativePointingTarget
        let score: Double
        let recognizedText: String
        let matchedTerm: String
    }

    static func locate(
        in screenCaptures: [CompanionScreenCapture],
        transcript: String,
        assistantResponse: String,
        currentLabel: String?
    ) -> NativePointingTarget? {
        let terms = searchTerms(
            transcript: transcript,
            assistantResponse: assistantResponse,
            currentLabel: currentLabel
        )
        guard !terms.isEmpty else {
            clickyDebugLog("ocr locator skipped no-terms")
            return nil
        }

        var bestMatch: OCRMatch?
        for capture in screenCaptures {
            guard let cgImage = makeCGImage(from: capture.imageData) else {
                continue
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.008
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                clickyDebugLog("ocr locator vision-error \(error.localizedDescription)")
                continue
            }

            let observations = request.results ?? []
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else {
                    continue
                }

                let recognizedText = candidate.string
                guard let termScore = score(recognizedText: recognizedText, terms: terms) else {
                    continue
                }

                let target = targetFromObservation(
                    observation,
                    capture: capture,
                    label: recognizedText
                )
                let score = termScore.score + Double(candidate.confidence) * 20
                let match = OCRMatch(
                    target: target,
                    score: score,
                    recognizedText: recognizedText,
                    matchedTerm: termScore.term
                )

                if bestMatch == nil || match.score > bestMatch!.score {
                    bestMatch = match
                }
            }
        }

        guard let bestMatch, bestMatch.score >= 55 else {
            clickyDebugLog("ocr locator no-match terms=\(terms.prefix(8).joined(separator: ","))")
            return nil
        }

        clickyDebugLog("ocr locator target text=\(bestMatch.recognizedText) term=\(bestMatch.matchedTerm) score=\(String(format: "%.1f", bestMatch.score)) screenLocation=\(bestMatch.target.screenLocation)")
        return bestMatch.target
    }

    private static func targetFromObservation(
        _ observation: VNRecognizedTextObservation,
        capture: CompanionScreenCapture,
        label: String
    ) -> NativePointingTarget {
        let boundingBox = observation.boundingBox
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        // Vision uses normalized lower-left coordinates. NSScreen/AppKit also
        // uses lower-left screen coordinates, so only scaling and display offset
        // are needed here.
        let screenLocation = CGPoint(
            x: displayFrame.origin.x + boundingBox.midX * displayWidth,
            y: displayFrame.origin.y + boundingBox.midY * displayHeight
        )

        return NativePointingTarget(
            screenLocation: screenLocation,
            displayFrame: displayFrame,
            label: label,
            source: "ocr"
        )
    }

    private static func score(
        recognizedText: String,
        terms: [String]
    ) -> (score: Double, term: String)? {
        let normalizedOCRText = normalize(recognizedText)
        guard !normalizedOCRText.isEmpty else { return nil }

        var bestScore: Double = 0
        var bestTerm: String?
        for term in terms {
            guard !term.isEmpty else { continue }

            let score: Double
            if normalizedOCRText == term {
                score = 100 + Double(term.count)
            } else if normalizedOCRText.contains(term) {
                score = 78 + Double(term.count)
            } else if term.contains(normalizedOCRText), normalizedOCRText.count >= 3 {
                score = 62 + Double(normalizedOCRText.count)
            } else {
                continue
            }

            if score > bestScore {
                bestScore = score
                bestTerm = term
            }
        }

        guard let bestTerm else { return nil }
        return (bestScore, bestTerm)
    }

    private static func searchTerms(
        transcript: String,
        assistantResponse: String,
        currentLabel: String?
    ) -> [String] {
        let sourceText = [transcript, assistantResponse, currentLabel ?? ""].joined(separator: " ")
        var terms: [String] = []

        if let currentLabel, !currentLabel.isEmpty {
            terms.append(contentsOf: labelTerms(from: currentLabel))
        }

        terms.append(contentsOf: labelTerms(from: transcript))
        terms.append(contentsOf: labelTerms(from: assistantResponse))

        var seenTerms = Set<String>()
        return terms.filter { term in
            guard !seenTerms.contains(term) else { return false }
            seenTerms.insert(term)
            return true
        }
    }

    private static func labelTerms(from text: String) -> [String] {
        let normalizedText = normalize(text)
        var terms: [String] = []

        let latinPattern = #"[a-z0-9][a-z0-9._-]{1,}"#
        terms.append(contentsOf: regexMatches(pattern: latinPattern, in: normalizedText))

        let cjkPattern = #"[\p{Han}]{2,}"#
        let cjkRuns = regexMatches(pattern: cjkPattern, in: normalizedText)
        for run in cjkRuns {
            let trimmedRun = stripGenericWords(from: run)
            if trimmedRun.count >= 2 {
                terms.append(trimmedRun)
            }
        }

        return terms
            .map(stripGenericWords)
            .filter { term in
                term.count >= 2 && !genericTerms.contains(term)
            }
    }

    private static func stripGenericWords(from text: String) -> String {
        var result = text
        for genericTerm in genericTerms.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: genericTerm, with: "")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regexMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "「", with: " ")
            .replacingOccurrences(of: "」", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "'", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static let genericTerms: Set<String> = [
        "帮我", "定位", "指", "指一下", "指给我看", "给我", "看", "哪里", "在哪", "在哪里",
        "打开", "点击", "点", "文件", "文件夹", "图标", "按钮", "菜单", "栏", "这个", "那个",
        "的", "了", "一下", "我", "你", "软件",
        "where", "find", "show", "point", "click", "open", "file", "folder", "icon", "button", "menu", "the", "a", "an"
    ]
}
