//
//  PointingRequestPolicy.swift
//  leanring-buddy
//

import Foundation

enum PointingRequestPolicy {
    /// Pointing follows natural questions about the visible screen while keeping
    /// knowledge, writing, and abstract troubleshooting questions cursor-free.
    nonisolated static func shouldRequestPointing(for transcript: String) -> Bool {
        let normalizedTranscript = transcript
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedTranscript.isEmpty else { return false }

        let explicitPointingPhrases = [
            "指给我看", "给我指", "帮我指", "指一下",
            "点哪里", "点击哪里", "点哪个", "点击哪个",
            "应该点", "该点",
            "point to", "show me where", "where should i click",
            "which button", "which icon"
        ]

        if explicitPointingPhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return true
        }

        let nonVisualSubjectWords = [
            "新闻", "知识", "代码", "脚本", "文案", "提示词",
            "bug 的原因", "bug原因", "问题的原因", "错误的原因",
            "news", "knowledge", "code", "script", "prompt",
            "cause of the bug", "reason for the error"
        ]
        let describesNonVisualSubject = nonVisualSubjectWords.contains {
            normalizedTranscript.contains($0)
        }

        let directLocationPhrases = [
            "在哪儿", "在哪里", "在哪", "什么位置", "哪个位置",
            "where is", "where's", "where are", "what position"
        ]
        if !describesNonVisualSubject,
           directLocationPhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return true
        }

        let currentScreenReferencePhrases = [
            "这个页面", "当前页面", "这个界面", "当前界面",
            "这个按钮", "这个图标", "这个菜单", "这个窗口",
            "屏幕上", "桌面上", "页面上", "这里",
            "this page", "current page", "this screen", "this button",
            "this icon", "this menu", "this window", "on screen", "on the desktop"
        ]
        if !describesNonVisualSubject,
           currentScreenReferencePhrases.contains(where: { normalizedTranscript.contains($0) }) {
            return true
        }

        let visibleTargetWords = [
            "按钮", "图标", "菜单", "文件", "文件夹", "桌面", "窗口",
            "应用", "软件", "浏览器", "输入框", "选项", "设置",
            "button", "icon", "menu", "file", "folder", "desktop", "window",
            "app", "application", "browser", "field", "tab", "toolbar", "settings"
        ]
        let visibleSearchOrLocationPhrases = [
            "帮我定位", "给我定位", "定位一下",
            "帮我找", "给我找", "找一下", "找出", "找找",
            "locate", "help me find", "find the"
        ]

        return visibleSearchOrLocationPhrases.contains {
            normalizedTranscript.contains($0)
        } && visibleTargetWords.contains {
            normalizedTranscript.contains($0)
        }
    }
}
