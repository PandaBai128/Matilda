import AppKit
import SwiftUI

@MainActor
final class ScreenOperationSettingsWindowManager {
    private var window: NSWindow?
    private let companionManager: CompanionManager

    init(companionManager: CompanionManager) { self.companionManager = companionManager }

    func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "壮壮 · Screen Control"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ScreenOperationSettingsView(companionManager: companionManager))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct ScreenOperationSettingsView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("屏幕操作 · 实验版", systemImage: "cursorarrow.click.2")
                .font(.title2.weight(.semibold))
            Toggle("允许壮壮操作屏幕", isOn: Binding(get: { companionManager.isScreenOperationsEnabled }, set: { companionManager.setScreenOperationsEnabled($0) }))
                .toggleStyle(.switch).pointerCursor()
            Text(companionManager.lastScreenOperationMessage)
                .foregroundStyle(.secondary).font(.callout).fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("你明确要求的一步操作会直接执行：点击、双击、右键、滚动、打开应用、关闭当前窗口。\n“指一下”仍只指示；目标不明确时才会问你。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("执行中按住 Control＋Option 即可打断。关闭开关会立即停止待执行动作；系统自己的密码或指纹验证照常由你完成。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("停止当前操作") { companionManager.stopScreenOperation() }
                .disabled(!companionManager.isPerformingScreenOperation)
                .pointerCursor(isEnabled: companionManager.isPerformingScreenOperation)
            Spacer(minLength: 0)
        }
        .padding(22).frame(width: 440, height: 360).preferredColorScheme(.dark)
    }
}
