import SwiftUI

private enum AppearanceSection: String, CaseIterable, Identifiable {
    case character = "形象与动作"
    case following = "跟随与显示"
    case pointing = "指向提示"
    var id: String { rawValue }
}

private enum CompanionPreviewMode: String, CaseIterable, Identifiable {
    case natural = "日常"
    case front = "正面"
    case left = "左看"
    case right = "右看"
    case listening = "聆听"
    case blinking = "眨眼"
    case nodding = "点头"
    case thinking = "思考"
    case pointing = "指向"

    var id: String { rawValue }
    static let headPoses: [Self] = [.front, .left, .right, .listening, .blinking, .nodding]
    var headFrame: Int? { Self.headPoses.firstIndex(of: self) }
    var voiceState: CompanionVoiceState {
        switch self {
        case .listening: return .listening
        case .thinking: return .processing
        case .pointing: return .responding
        default: return .idle
        }
    }
    var navigationMode: BuddyNavigationMode {
        self == .pointing ? .pointingAtTarget : .followingCursor
    }
    var explanation: String {
        switch self {
        case .natural: return "按当前大小和形态显示；设置会立即保存。"
        case .front: return "安静陪着你时的正面头像。"
        case .left: return "鼠标向左移动时，先向左看一眼。"
        case .right: return "鼠标向右移动时，先向右看一眼。"
        case .listening: return "你说话时侧头聆听，旁边显示声音起伏。"
        case .blinking: return "闭眼姿态在这里保持显示；日常只会偶尔眨一下。"
        case .nodding: return "操作派发后的点头姿态，不代表任务已完成。"
        case .thinking: return "思考时轻轻倾头，用小圆点表示正在处理。"
        case .pointing: return "显示到达目标后的标记和气泡，不会实际操作屏幕。"
        }
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var section: AppearanceSection = .character
    @State private var previewMode: CompanionPreviewMode = .natural

    var body: some View {
        VStack(spacing: 0) {
            header
            livePreview
            Picker("外观分类", selection: $section) {
                ForEach(AppearanceSection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 24).padding(.bottom, 16).pointerCursor()
            sectionDivider
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch section {
                    case .character:
                        characterControls
                        sectionDivider
                        poseControls
                        sectionDivider
                        glowControls
                    case .following:
                        followControls
                        sectionDivider
                        visibilityControls
                    case .pointing:
                        bubbleControls
                        sectionDivider
                        markerControls
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.Colors.background)
        .onChange(of: section) { _, value in previewMode = value == .pointing ? .pointing : .natural }
        .onChange(of: companionManager.companionVisualStyle) { _, _ in previewMode = .natural }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("壮壮的外观").font(.system(size: 19, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Text("即时预览 · 自动保存").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 14)
    }

    private var livePreview: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.24))
                Text(previewMode == .natural ? companionManager.companionVisualStyle.displayName : previewMode.rawValue)
                    .font(.system(size: 11, weight: .medium)).foregroundColor(DS.Colors.textTertiary).padding(12)
                GeometryReader { geometry in
                    let isPose = previewMode.headFrame != nil
                    let offset = companionManager.companionCursorDistance.cursorOffset(for: companionManager.companionAvatarSize)
                    let cursor = CGPoint(x: geometry.size.width * 0.43, y: geometry.size.height * 0.47)
                    let avatar = isPose
                        ? CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        : CGPoint(x: cursor.x + offset.x, y: cursor.y + offset.y)
                    if previewMode == .pointing {
                        ZhuangzhuangTargetMarkerView(
                            diameter: CGFloat(companionManager.companionPointingMarkerDiameter),
                            markerColor: companionManager.companionPointingMarkerColor,
                            showsCenterDot: companionManager.isCompanionPointingCenterDotEnabled
                        ).position(cursor)
                    } else if !isPose {
                        Image(systemName: "cursorarrow").font(.system(size: 19, weight: .medium))
                            .foregroundColor(.white.opacity(0.9)).position(cursor)
                    }
                    ZhuangzhuangAvatarView(
                        diameter: isPose ? max(companionManager.companionAvatarSize.diameter, 48) : companionManager.companionAvatarSize.diameter,
                        voiceState: previewMode.voiceState,
                        navigationMode: previewMode.navigationMode,
                        audioPowerLevel: previewMode == .listening ? 0.55 : 0,
                        travelTiltDegrees: 0,
                        glowColor: companionManager.companionGlowColor,
                        glowIntensity: companionManager.companionGlowIntensity,
                        isGlowEnabled: companionManager.isCompanionGlowEnabled,
                        visualStyle: isPose ? .portrait : companionManager.companionVisualStyle,
                        previewHeadFrame: previewMode.headFrame
                    ).position(avatar)
                    if previewMode == .pointing {
                        let text = companionManager.companionPointingText(for: "保存按钮")
                        if !text.isEmpty {
                            Text(text).font(.system(size: 11, weight: .medium))
                                .foregroundColor(companionManager.companionPointingLabelForegroundColor).lineLimit(1)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(companionManager.companionPointingLabelBackgroundColor))
                                .position(CompanionAppearanceMotion.bubbleCenter(
                                    proposed: CGPoint(x: avatar.x + 48, y: avatar.y + companionManager.companionAvatarSize.diameter / 2 + 22),
                                    size: CGSize(width: CGFloat(text.count) * 11 + 18, height: 24), container: geometry.size
                                ))
                        }
                    }
                }
            }
            .frame(height: 140)
            Text(previewMode.explanation).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2).frame(height: 28, alignment: .topLeading)
        }
        .padding(.horizontal, 24).padding(.bottom, 12)
    }

    private var characterControls: some View {
        VStack(spacing: 16) {
            pickerRow("形态") {
                Picker("形态", selection: Binding(get: { companionManager.companionVisualStyle }, set: { companionManager.setCompanionVisualStyle($0) })) {
                    ForEach(CompanionVisualStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            pickerRow("大小") {
                Picker("大小", selection: Binding(get: { companionManager.companionAvatarSize }, set: { companionManager.setCompanionAvatarSize($0) })) {
                    Text("小").tag(CompanionAvatarSize.small)
                    Text("中").tag(CompanionAvatarSize.medium)
                    Text("大").tag(CompanionAvatarSize.large)
                }
            }
        }
    }

    private var poseControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("看看每一种表情", detail: "点选即可查看，不会改变桌面上的形态。")
            HStack(spacing: 8) {
                ForEach(CompanionPreviewMode.headPoses) { pose in
                    Button { previewMode = pose } label: {
                        VStack(spacing: 5) {
                            CompanionAtlasFrame(name: "ZhuangzhuangHeadAtlas", columns: 3, rows: 2, index: pose.headFrame ?? 0, size: 43)
                            Text(pose.rawValue).font(.system(size: 11, weight: previewMode == pose ? .semibold : .regular))
                                .foregroundColor(previewMode == pose ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(previewMode == pose ? DS.Colors.accent.opacity(0.16) : Color.white.opacity(0.035)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(previewMode == pose ? DS.Colors.accent : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("预览\(pose.rawValue)")
                    .accessibilityAddTraits(previewMode == pose ? .isSelected : []).pointerCursor()
                }
            }
            HStack(spacing: 10) {
                Text("动态预览").font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary)
                ForEach([CompanionPreviewMode.natural, .thinking, .pointing]) { mode in
                    Button(mode.rawValue) { previewMode = mode }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(previewMode == mode ? DS.Colors.accent : nil).pointerCursor()
                }
            }
        }
    }

    private var followControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("陪在鼠标旁边", detail: "调整跟随距离和节奏，聆听时会安静停靠。")
            pickerRow("距离") {
                Picker("距离", selection: Binding(get: { companionManager.companionCursorDistance }, set: { companionManager.setCompanionCursorDistance($0) })) {
                    Text("近").tag(CompanionCursorDistance.near)
                    Text("中").tag(CompanionCursorDistance.medium)
                    Text("远").tag(CompanionCursorDistance.far)
                }
            }
            pickerRow("跟随速度") {
                Picker("跟随速度", selection: Binding(get: { companionManager.companionFollowResponse }, set: { companionManager.setCompanionFollowResponse($0) })) {
                    Text("快").tag(CompanionFollowResponse.quick)
                    Text("中").tag(CompanionFollowResponse.natural)
                    Text("慢").tag(CompanionFollowResponse.relaxed)
                }
            }
        }
    }

    private var visibilityControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("空闲时收起", detail: "鼠标停下后自动淡出，再次互动时出现。")
            toggleRow("自动隐藏", isOn: Binding(get: { companionManager.isCompanionAutoHideEnabled }, set: { companionManager.setCompanionAutoHideEnabled($0) }))
            sliderRow("等待时间", valueText: "\(Int(companionManager.companionAutoHideDelaySeconds)) 秒", value: Binding(get: { companionManager.companionAutoHideDelaySeconds }, set: { companionManager.setCompanionAutoHideDelaySeconds($0) }), range: 2...30, step: 1)
                .disabled(!companionManager.isCompanionAutoHideEnabled).opacity(companionManager.isCompanionAutoHideEnabled ? 1 : 0.42)
        }
    }

    private var bubbleControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("到达时显示什么", detail: "只显示气泡文字，不会额外发声或调用 API。")
            Picker("气泡内容", selection: Binding(get: { companionManager.companionPointingLabelMode }, set: { companionManager.setCompanionPointingLabelMode($0) })) {
                ForEach(CompanionPointingLabelMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().pointerCursor()
            if companionManager.companionPointingLabelMode == .custom {
                TextField("写一句想让壮壮显示的话", text: Binding(get: { companionManager.companionCustomPointingText }, set: { companionManager.setCompanionCustomPointingText($0) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("自定义指向气泡")
            }
            if companionManager.companionPointingLabelMode != .hidden {
                colorRow("气泡颜色", selection: Binding(get: { companionManager.companionPointingLabelBackgroundColor }, set: { companionManager.setCompanionPointingLabelBackgroundColor($0) }))
            }
        }
    }

    private var markerControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("目标标记", detail: "圆圈的中心就是定位位置。")
            sliderRow("圆圈大小", valueText: "\(Int(companionManager.companionPointingMarkerDiameter)) px", value: Binding(get: { companionManager.companionPointingMarkerDiameter }, set: { companionManager.setCompanionPointingMarkerDiameter($0) }), range: 20...64, step: 2)
            toggleRow("显示中心点", isOn: Binding(get: { companionManager.isCompanionPointingCenterDotEnabled }, set: { companionManager.setCompanionPointingCenterDotEnabled($0) }))
            colorRow("圆圈颜色", selection: Binding(get: { companionManager.companionPointingMarkerColor }, set: { companionManager.setCompanionPointingMarkerColor($0) }))
        }
    }

    private var glowControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            toggleRow("柔和光晕", isOn: Binding(get: { companionManager.isCompanionGlowEnabled }, set: { companionManager.setCompanionGlowEnabled($0) }))
            if companionManager.isCompanionGlowEnabled {
                colorRow("光晕颜色", selection: Binding(get: { companionManager.companionGlowColor }, set: { companionManager.setCompanionGlowColor($0) }))
                sliderRow("光晕强度", valueText: "\(Int(companionManager.companionGlowIntensity * 100))%", value: Binding(get: { companionManager.companionGlowIntensity }, set: { companionManager.setCompanionGlowIntensity($0) }), range: 0.1...1, step: 0.05)
            }
        }
    }

    private var sectionDivider: some View { Divider().background(DS.Colors.borderSubtle) }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
            Text(detail).font(.system(size: 11)).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func rowTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(DS.Colors.textSecondary)
    }

    private func pickerRow<Content: View>(_ title: String, @ViewBuilder picker: () -> Content) -> some View {
        HStack {
            rowTitle(title)
            Spacer(minLength: 24)
            picker().labelsHidden().pickerStyle(.segmented).frame(width: 260).pointerCursor()
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            rowTitle(title)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).tint(DS.Colors.accent).controlSize(.small).pointerCursor()
        }
    }

    private func colorRow(_ title: String, selection: Binding<Color>) -> some View {
        HStack {
            rowTitle(title)
            Spacer()
            ColorPicker(title, selection: selection, supportsOpacity: false).labelsHidden().pointerCursor()
        }
    }

    private func sliderRow(_ title: String, valueText: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(spacing: 8) {
            HStack {
                rowTitle(title)
                Spacer()
                Text(valueText).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(DS.Colors.textTertiary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step).accessibilityLabel(title).pointerCursor()
        }
    }
}
