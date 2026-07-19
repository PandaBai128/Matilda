//
//  AppearanceSettingsView.swift
//  leanring-buddy
//
//  Live preview and persisted controls for the cursor companion's appearance.
//

import SwiftUI

private enum CompanionPreviewMode: String, CaseIterable, Identifiable {
    case idle = "Idle"
    case listening = "Listen"
    case thinking = "Think"
    case pointing = "Point"
    case blinking = "Blink"

    var id: String { rawValue }

    var voiceState: CompanionVoiceState {
        switch self {
        case .idle, .blinking: return .idle
        case .listening: return .listening
        case .thinking: return .processing
        case .pointing: return .responding
        }
    }

    var navigationMode: BuddyNavigationMode {
        self == .pointing ? .pointingAtTarget : .followingCursor
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var previewMode: CompanionPreviewMode = .idle

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(DS.Colors.borderSubtle)

            ScrollView {
                VStack(spacing: 0) {
                    livePreview
                    Divider().background(DS.Colors.borderSubtle)
                    placementControls
                    Divider().background(DS.Colors.borderSubtle)
                    visibilityControls
                    Divider().background(DS.Colors.borderSubtle)
                    pointingControls
                    Divider().background(DS.Colors.borderSubtle)
                    glowControls
                }
            }
        }
        .background(DS.Colors.background)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Appearance")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Tune how 壮壮 looks and follows your cursor.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 16)
    }

    private var livePreview: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.28))

                GeometryReader { geometryProxy in
                    let cursorPosition = CGPoint(
                        x: geometryProxy.size.width * 0.42,
                        y: geometryProxy.size.height * 0.55
                    )
                    let cursorOffset = companionManager.companionCursorDistance.cursorOffset(
                        for: companionManager.companionAvatarSize
                    )

                    if previewMode == .pointing {
                        ZhuangzhuangTargetMarkerView(
                            diameter: CGFloat(companionManager.companionPointingMarkerDiameter),
                            markerColor: companionManager.companionPointingMarkerColor,
                            showsCenterDot: companionManager.isCompanionPointingCenterDotEnabled
                        )
                        .position(cursorPosition)

                        Text("汪，汪汪")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(companionManager.companionPointingLabelForegroundColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(companionManager.companionPointingLabelBackgroundColor)
                                    .shadow(
                                        color: companionManager.companionPointingLabelBackgroundColor.opacity(0.5),
                                        radius: 6
                                    )
                            )
                            .position(
                                x: cursorPosition.x + cursorOffset.x + 42,
                                y: cursorPosition.y + cursorOffset.y
                                    + (companionManager.companionAvatarSize.diameter / 2) + 12
                            )
                    } else {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .position(cursorPosition)
                    }

                    ZhuangzhuangAvatarView(
                        diameter: companionManager.companionAvatarSize.diameter,
                        voiceState: previewMode.voiceState,
                        navigationMode: previewMode.navigationMode,
                        audioPowerLevel: previewMode == .listening ? 0.55 : 0,
                        travelTiltDegrees: 0,
                        glowColor: companionManager.companionGlowColor,
                        glowIntensity: companionManager.companionGlowIntensity,
                        isGlowEnabled: companionManager.isCompanionGlowEnabled,
                        blinkCycleDurationSeconds: previewMode == .blinking ? 1.4 : 5.8
                    )
                    .position(
                        x: cursorPosition.x + cursorOffset.x,
                        y: cursorPosition.y + cursorOffset.y
                    )
                }
            }
            .frame(height: 170)

            Picker("Preview state", selection: $previewMode) {
                ForEach(CompanionPreviewMode.allCases) { previewMode in
                    Text(previewMode.rawValue).tag(previewMode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 360)
            .pointerCursor()
        }
        .padding(24)
    }

    private var placementControls: some View {
        settingsSection(title: "Placement") {
            settingsPickerRow(title: "Size") {
                Picker("Size", selection: Binding(
                    get: { companionManager.companionAvatarSize },
                    set: { companionManager.setCompanionAvatarSize($0) }
                )) {
                    ForEach(CompanionAvatarSize.allCases, id: \.self) { companionAvatarSize in
                        Text(companionAvatarSize.displayName).tag(companionAvatarSize)
                    }
                }
            }

            settingsPickerRow(title: "Distance") {
                Picker("Distance", selection: Binding(
                    get: { companionManager.companionCursorDistance },
                    set: { companionManager.setCompanionCursorDistance($0) }
                )) {
                    ForEach(CompanionCursorDistance.allCases, id: \.self) { companionCursorDistance in
                        Text(companionCursorDistance.displayName).tag(companionCursorDistance)
                    }
                }
            }

            settingsPickerRow(title: "Follow") {
                Picker("Follow", selection: Binding(
                    get: { companionManager.companionFollowResponse },
                    set: { companionManager.setCompanionFollowResponse($0) }
                )) {
                    ForEach(CompanionFollowResponse.allCases, id: \.self) { companionFollowResponse in
                        Text(companionFollowResponse.displayName).tag(companionFollowResponse)
                    }
                }
            }
        }
    }

    private var visibilityControls: some View {
        settingsSection(title: "Visibility") {
            settingsToggleRow(
                title: "Auto-hide",
                isOn: Binding(
                    get: { companionManager.isCompanionAutoHideEnabled },
                    set: { companionManager.setCompanionAutoHideEnabled($0) }
                )
            )

            VStack(spacing: 8) {
                HStack {
                    Text("Hide after")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text("\(Int(companionManager.companionAutoHideDelaySeconds)) sec")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Slider(
                    value: Binding(
                        get: { companionManager.companionAutoHideDelaySeconds },
                        set: { companionManager.setCompanionAutoHideDelaySeconds($0) }
                    ),
                    in: 2...30,
                    step: 1
                )
                .disabled(!companionManager.isCompanionAutoHideEnabled)
                .opacity(companionManager.isCompanionAutoHideEnabled ? 1 : 0.42)
                .pointerCursor(isEnabled: companionManager.isCompanionAutoHideEnabled)
            }
        }
    }

    private var pointingControls: some View {
        settingsSection(title: "Pointing") {
            VStack(spacing: 8) {
                HStack {
                    Text("Marker size")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text("\(Int(companionManager.companionPointingMarkerDiameter)) px")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Slider(
                    value: Binding(
                        get: { companionManager.companionPointingMarkerDiameter },
                        set: { companionManager.setCompanionPointingMarkerDiameter($0) }
                    ),
                    in: 20...64,
                    step: 2
                )
                .pointerCursor()
            }

            settingsToggleRow(
                title: "Center dot",
                isOn: Binding(
                    get: { companionManager.isCompanionPointingCenterDotEnabled },
                    set: { companionManager.setCompanionPointingCenterDotEnabled($0) }
                )
            )

            settingsColorRow(
                title: "Marker color",
                selection: Binding(
                    get: { companionManager.companionPointingMarkerColor },
                    set: { companionManager.setCompanionPointingMarkerColor($0) }
                )
            )

            settingsColorRow(
                title: "Label color",
                selection: Binding(
                    get: { companionManager.companionPointingLabelBackgroundColor },
                    set: { companionManager.setCompanionPointingLabelBackgroundColor($0) }
                )
            )
        }
    }

    private var glowControls: some View {
        settingsSection(title: "Glow") {
            settingsToggleRow(
                title: "Glow",
                isOn: Binding(
                    get: { companionManager.isCompanionGlowEnabled },
                    set: { companionManager.setCompanionGlowEnabled($0) }
                )
            )

            HStack {
                Text("Color")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                ColorPicker(
                    "Glow color",
                    selection: Binding(
                        get: { companionManager.companionGlowColor },
                        set: { companionManager.setCompanionGlowColor($0) }
                    ),
                    supportsOpacity: false
                )
                .labelsHidden()
                .disabled(!companionManager.isCompanionGlowEnabled)
                .opacity(companionManager.isCompanionGlowEnabled ? 1 : 0.42)
                .pointerCursor(isEnabled: companionManager.isCompanionGlowEnabled)
            }

            VStack(spacing: 8) {
                HStack {
                    Text("Intensity")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Text("\(Int(companionManager.companionGlowIntensity * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Slider(
                    value: Binding(
                        get: { companionManager.companionGlowIntensity },
                        set: { companionManager.setCompanionGlowIntensity($0) }
                    ),
                    in: 0.1...1,
                    step: 0.05
                )
                .disabled(!companionManager.isCompanionGlowEnabled)
                .opacity(companionManager.isCompanionGlowEnabled ? 1 : 0.42)
                .pointerCursor(isEnabled: companionManager.isCompanionGlowEnabled)
            }
        }
        .padding(.bottom, 24)
    }

    private func settingsSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
            content()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private func settingsPickerRow<Content: View>(
        title: String,
        @ViewBuilder picker: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            picker()
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 270)
                .pointerCursor()
        }
    }

    private func settingsToggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DS.Colors.accent)
                .scaleEffect(0.85)
                .pointerCursor()
        }
    }

    private func settingsColorRow(title: String, selection: Binding<Color>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Spacer()
            ColorPicker(title, selection: selection, supportsOpacity: false)
                .labelsHidden()
                .pointerCursor()
        }
    }
}
