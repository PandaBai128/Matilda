//
//  PointingRequestPolicy.swift
//  leanring-buddy
//

import Foundation

enum PointingRequestPolicy {
    /// Pointing follows natural questions about the visible screen while keeping
    /// knowledge, writing, and abstract troubleshooting questions cursor-free.
    nonisolated static func shouldRequestPointing(
        for transcript: String,
        previousUserTranscript: String? = nil
    ) -> Bool {
        let normalizedTranscript = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedTranscript.isEmpty else { return false }

        let explicitPointingPhrases = [
            "指给我看", "给我指", "帮我指", "指一下",
            "点一下", "点击一下",
            "点哪里", "点击哪里", "点哪个", "点击哪个",
            "应该点", "该点",
            "point to", "show me where", "where should i click",
            "which button", "which icon"
        ]

        if explicitPointingPhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return true
        }

        let currentScreenReferencePhrases = [
            "这个页面", "当前页面", "这个界面", "当前界面",
            "这是什么页面", "这是什么界面", "这是什么窗口",
            "这是哪个页面", "这是哪个应用", "这是什么应用", "这是什么软件",
            "这个按钮", "这个图标", "这个菜单", "这个窗口",
            "屏幕上", "桌面上", "页面上", "这里",
            "this page", "current page", "this screen", "this button",
            "this icon", "this menu", "this window", "on screen", "on the desktop"
        ]
        if currentScreenReferencePhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return true
        }

        let closeActionPhrases = [
            "怎么关掉", "如何关掉", "怎样关掉",
            "怎么关闭", "如何关闭", "怎样关闭",
            "where do i close", "how do i close"
        ]
        let visibleCloseTargetWords = [
            "页面", "界面", "窗口", "面板", "弹窗", "标签页", "应用", "软件",
            "page", "screen", "window", "panel", "dialog", "tab", "app", "application"
        ]
        let asksHowToClose = closeActionPhrases.contains {
            normalizedTranscript.contains($0)
        }
        let namesVisibleCloseTarget = visibleCloseTargetWords.contains {
            normalizedTranscript.contains($0)
        }
        if asksHowToClose && namesVisibleCloseTarget {
            return true
        }

        if asksHowToClose,
           let previousUserTranscript {
            let normalizedPreviousTranscript = previousUserTranscript
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let previousMessageEstablishedVisibleTarget = currentScreenReferencePhrases.contains {
                normalizedPreviousTranscript.contains($0)
            } || visibleCloseTargetWords.contains {
                normalizedPreviousTranscript.contains($0)
            }
            if previousMessageEstablishedVisibleTarget {
                return true
            }
        }

        let visibleTargetWords = [
            "按钮", "图标", "菜单", "文件", "文件夹", "桌面", "窗口",
            "应用", "软件", "浏览器", "输入框", "选项", "设置",
            "狗", "猫", "宠物", "人物", "头像", "图片", "照片", "标志"
        ]
        let englishVisibleTargetWords: Set<String> = [
            "button", "icon", "menu", "file", "folder", "desktop", "window",
            "app", "application", "browser", "field", "tab", "toolbar", "settings",
            "dog", "cat", "pet", "person", "avatar", "image", "photo", "logo"
        ]
        let englishWordsInTranscript = Set(normalizedTranscript.split {
            !$0.isLetter && !$0.isNumber
        }.map(String.init))
        let describesVisibleTarget = visibleTargetWords.contains {
            normalizedTranscript.contains($0)
        } || !englishWordsInTranscript.isDisjoint(with: englishVisibleTargetWords)
        let directLocationPhrases = [
            "在哪儿", "在哪里", "在哪", "什么位置", "哪个位置",
            "where is", "where's", "where are", "what position"
        ]
        if describesVisibleTarget,
           directLocationPhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return true
        }

        let visibleSearchOrLocationPhrases = [
            "帮我定位", "给我定位", "定位一下",
            "帮我找", "给我找", "找一下", "找出", "找找",
            "locate", "help me find", "find the"
        ]

        return visibleSearchOrLocationPhrases.contains {
            normalizedTranscript.contains($0)
        } && describesVisibleTarget
    }

    /// A newly named target should be located from the current screenshot alone.
    /// Only short follow-ups that depend on an earlier target retain visual history.
    nonisolated static func requiresPreviousVisualContext(for transcript: String) -> Bool {
        let normalizedTranscript = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty, normalizedTranscript.count <= 30 else {
            return false
        }

        let previousTargetReferences = [
            "它", "刚才那个", "刚刚那个", "前面那个", "上一个",
            "that one", "the previous one"
        ]
        if previousTargetReferences.contains(where: { normalizedTranscript.contains($0) }) {
            return true
        }

        let contextDependentClosePhrases = [
            "告诉我如何关掉", "告诉我怎么关掉", "怎么关掉", "如何关掉",
            "where do i close it", "how do i close it"
        ]
        return contextDependentClosePhrases.contains {
            normalizedTranscript == $0
                || normalizedTranscript == "\($0)？"
                || normalizedTranscript == "\($0)?"
        }
    }
}

enum ScreenTextExtractionPolicy {
    nonisolated static func isTextExtractionRequest(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { return false }

        let extractionPhrases = [
            "提取文字", "提取画面", "提取视频", "提取字幕",
            "识别文字", "识别画面", "识别字幕",
            "复制文字", "复制画面", "复制字幕",
            "画面里的文字", "画面中的文字", "视频里的文字", "视频中的文字",
            "extract text", "transcribe text", "copy the text", "copy text",
            "text in this frame", "text on screen", "ocr"
        ]

        return extractionPhrases.contains { normalizedTranscript.contains($0) }
    }
}
