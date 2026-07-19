//
//  SystemSpeechFallbackController.swift
//  leanring-buddy
//
//  Retained macOS speech fallback for user-facing response failures.
//

import AppKit
import Foundation

enum CompanionResponseFailureMessage {
    static func spokenMessage(for error: Error) -> String {
        let errorCode = (error as NSError).code
        let errorDomain = (error as NSError).domain
        if errorDomain == NSURLErrorDomain
            || error is URLError
            || errorCode == NSURLErrorTimedOut
            || errorCode == NSURLErrorNotConnectedToInternet {
            return "网络连接出了问题，请检查本地服务或网络后再试。"
        }
        return "这次没有成功完成，请稍后再试。"
    }
}

@MainActor
final class SystemSpeechFallbackController: NSObject, NSSpeechSynthesizerDelegate {
    private var speechSynthesizer: NSSpeechSynthesizer?
    private var completionContinuation: CheckedContinuation<Void, Never>?

    func speak(_ text: String) async {
        stop()

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                let speechSynthesizer = NSSpeechSynthesizer()
                speechSynthesizer.delegate = self
                self.speechSynthesizer = speechSynthesizer
                self.completionContinuation = continuation

                if !speechSynthesizer.startSpeaking(text) {
                    finishSpeaking()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.stop()
            }
        }
    }

    func stop() {
        speechSynthesizer?.stopSpeaking()
        finishSpeaking()
    }

    func speechSynthesizer(
        _ sender: NSSpeechSynthesizer,
        didFinishSpeaking finishedSpeaking: Bool
    ) {
        finishSpeaking()
    }

    private func finishSpeaking() {
        speechSynthesizer?.delegate = nil
        speechSynthesizer = nil
        completionContinuation?.resume()
        completionContinuation = nil
    }
}
