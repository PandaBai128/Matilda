import Foundation

enum ScreenOperationKind: String, Equatable {
    case click, doubleClick, rightClick, scrollUp, scrollDown, openApplication, closeWindow, cancel
}

struct ScreenOperationRequest: Equatable {
    let kind: ScreenOperationKind
    let target: String

    var requiresVisualTarget: Bool {
        [.click, .doubleClick, .rightClick, .openApplication].contains(kind)
    }

    var localizationPrompt: String { "请指一下\(target)。只定位目标，不执行操作。" }

    var requiresConversationContext: Bool {
        PointingRequestPolicy.requiresPreviousVisualContext(for: target) || ["它", "这个", "那个", "这一个", "那一个"].contains(target)
    }
}

enum ScreenOperationPolicy {
    static let preferenceKey = "matildaScreenOperationsEnabled"
    static let disabledMessage = "屏幕操作现在是关闭的。可以在 Screen Control 里开启；这次没有操作。"

    static func containsMultipleOperations(_ transcript: String) -> Bool {
        transcript.range(of: "(?:然后|接着|并且|同时)\\s*(?:帮我|请|再|给我|你)?(?:点击|点|打开|关闭|关掉|双击|右键|向[上下]滚)", options: .regularExpression) != nil
    }

    static func request(for transcript: String) -> ScreenOperationRequest? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased().replacingOccurrences(of: "[。！？!?]+$", with: "", options: .regularExpression)
        if ["停止操作", "取消操作", "停下", "stop", "cancel"].contains(normalized) {
            return .init(kind: .cancel, target: "")
        }
        // Questions and pointing are guidance, never an implicit click grant.
        if ["怎么", "如何", "哪里", "哪个", "为什么", "什么意思", "指给", "指一下", "不要", "不用", "别点", "不必", "how ", "where ", "what ", "don't"].contains(where: normalized.contains) { return nil }
        var command = normalized.replacingOccurrences(of: "^(?:请你|麻烦你|帮我|给我|能不能|可以|我想|我要|我需要|能|请|你|直接)+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?:可以吗|好吗|行吗|吗|吧)$", with: "", options: .regularExpression)
        if let range = command.range(of: "^把(.+?)(?:关掉|关闭)$", options: .regularExpression) {
            let subject = String(command[range]).replacingOccurrences(of: "^把|(?:关掉|关闭)$", with: "", options: .regularExpression)
            command = "关闭" + subject
        }
        if command.range(of: "^(?:关闭|关掉)(?:这个|当前|现在的|最前面的|前台)?(?:窗口)$", options: .regularExpression) != nil {
            return .init(kind: .closeWindow, target: "当前窗口")
        }
        if command.range(of: "^(?:向|往)?(?:上|下)(?:滚动|滚|翻)(?:一点|一下|一页|半页)?$", options: .regularExpression) != nil
            || command.range(of: "^(?:滚动|翻)(?:上|下)(?:一页|半页|一点|一下)?$", options: .regularExpression) != nil {
            return .init(kind: command.contains("上") ? .scrollUp : .scrollDown, target: "")
        }
        for (prefix, kind) in [("双击打开", ScreenOperationKind.doubleClick), ("双击", .doubleClick), ("右键点击", .rightClick), ("右键", .rightClick), ("点击", .click), ("点一下", .click), ("点开", .doubleClick), ("打开", .doubleClick), ("关闭", .click), ("关掉", .click), ("点", .click)] {
            guard command.hasPrefix(prefix) else { continue }
            var target = String(command.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            target = target.replacingOccurrences(of: "(?:一下|吧|就好|好吗|。|！|？)+$", with: "", options: .regularExpression)
            guard !target.isEmpty else { return nil }
            if prefix == "关闭" || prefix == "关掉" { target += "的关闭按钮" }
            let explicitlyOpensFile = prefix == "打开" && ["文件", "文件夹", "图标", ".pdf", ".doc", ".png", ".jpg"].contains(where: target.contains)
            if prefix == "打开", !explicitlyOpensFile,
               !["这个", "那个", "刚才", "菜单", "按钮", "链接", "窗口", "网页", "页面"].contains(where: target.contains) {
                return .init(kind: .openApplication, target: target)
            }
            let resolvedKind: ScreenOperationKind = prefix == "点开" || (prefix == "打开" && !explicitlyOpensFile) ? .click : kind
            return .init(kind: resolvedKind, target: target)
        }
        return nil
    }

    static func applicationBundleIdentifier(named name: String) -> String? {
        let names = ["chrome": "com.google.Chrome", "chrome浏览器": "com.google.Chrome", "谷歌": "com.google.Chrome", "谷歌浏览器": "com.google.Chrome",
                     "safari": "com.apple.Safari", "safari浏览器": "com.apple.Safari", "finder": "com.apple.finder", "访达": "com.apple.finder",
                     "预览": "com.apple.Preview", "preview": "com.apple.Preview", "文本编辑": "com.apple.TextEdit",
                     "系统设置": "com.apple.systempreferences", "终端": "com.apple.Terminal", "codex": "com.openai.codex"]
        return names[name.lowercased()]
    }

    static func confirmationDecision(for transcript: String) -> Bool? {
        let answer = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "[。！？!?]+$", with: "", options: .regularExpression)
        if ["是", "是的", "对", "对的", "没错", "就这个", "确定", "继续", "yes", "ok"].contains(answer) { return true }
        if ["不是", "不", "取消", "算了", "不用了", "no", "cancel"].contains(answer) { return false }
        return nil
    }
}
