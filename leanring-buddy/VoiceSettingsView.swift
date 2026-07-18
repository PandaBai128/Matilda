//
//  VoiceSettingsView.swift
//  leanring-buddy
//
//  Searchable MiniMax voice browser with shared preview and speech controls.
//

import SwiftUI

private enum VoiceSourceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case system = "System"
    case cloned = "Cloned"
    case generated = "Generated"

    var id: String { rawValue }
}

struct VoiceSettingsView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var searchText = ""
    @State private var sourceFilter: VoiceSourceFilter = .all
    @State private var previewText = "你好，我是 Clicky。这是我的声音效果。"

    private let supportedEmotions: [(id: String, label: String)] = [
        ("automatic", "Automatic"),
        ("happy", "Happy"),
        ("sad", "Sad"),
        ("angry", "Angry"),
        ("fearful", "Fearful"),
        ("disgusted", "Disgusted"),
        ("surprised", "Surprised"),
        ("calm", "Calm")
    ]

    private var filteredVoices: [MiniMaxVoiceOption] {
        companionManager.availableTTSVoices
            .filter { voice in
                sourceFilter == .all || voice.category == sourceFilter.rawValue
            }
            .filter { voice in
                guard !searchText.isEmpty else { return true }
                return voice.displayName.localizedCaseInsensitiveContains(searchText)
                    || voice.voiceID.localizedCaseInsensitiveContains(searchText)
                    || voice.description.localizedCaseInsensitiveContains(searchText)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var selectedVoice: MiniMaxVoiceOption? {
        companionManager.availableTTSVoices.first {
            $0.voiceID == companionManager.selectedTTSVoiceID
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(DS.Colors.borderSubtle)

            HStack(spacing: 0) {
                voiceBrowser
                    .frame(minWidth: 330, idealWidth: 360, maxWidth: 400)

                Divider().background(DS.Colors.borderSubtle)

                voiceControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(DS.Colors.background)
        .onAppear {
            if companionManager.availableTTSVoices.isEmpty {
                companionManager.loadAvailableTTSVoices()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Voice Settings")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Choose a MiniMax voice and tune how Clicky speaks.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            if companionManager.isLoadingTTSVoices {
                ProgressView()
                    .controlSize(.small)
            }

            Button(action: companionManager.loadAvailableTTSVoices) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textSecondary)
            .pointerCursor()
            .help("Reload voice library")
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 16)
    }

    private var voiceBrowser: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(DS.Colors.textTertiary)
                TextField("Search name, ID, or description", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Picker("Source", selection: $sourceFilter) {
                ForEach(VoiceSourceFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text("\(filteredVoices.count) voices")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
            }

            if let errorMessage = companionManager.ttsVoiceCatalogErrorMessage {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredVoices) { voice in
                        voiceRow(voice)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity)
    }

    private func voiceRow(_ voice: MiniMaxVoiceOption) -> some View {
        let isSelected = companionManager.selectedTTSVoiceID == voice.voiceID

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(voice.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)

                Text(voice.description.isEmpty ? voice.voiceID : voice.description)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: {
                companionManager.previewTTSVoice(voiceID: voice.voiceID, text: normalizedPreviewText)
            }) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textTertiary)
            .pointerCursor()
            .help("Preview this voice")
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(isSelected ? DS.Colors.accent.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            companionManager.setSelectedTTSVoiceID(voice.voiceID)
        }
    }

    private var voiceControls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(selectedVoice?.displayName ?? "Custom voice")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(selectedVoice?.category ?? "Voice ID")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.accent)
                }

                VStack(alignment: .leading, spacing: 7) {
                    settingsLabel("VOICE ID")
                    TextField("MiniMax voice ID", text: Binding(
                        get: { companionManager.selectedTTSVoiceID },
                        set: { companionManager.setSelectedTTSVoiceID($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                }

                Divider().background(DS.Colors.borderSubtle)

                VStack(alignment: .leading, spacing: 8) {
                    settingsLabel("PREVIEW TEXT")
                    TextField("Preview text", text: $previewText)
                        .textFieldStyle(.roundedBorder)

                    Button(action: {
                        companionManager.previewTTSVoice(text: normalizedPreviewText)
                    }) {
                        Label("Preview voice", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.textOnAccent)
                    .background(DS.Colors.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .pointerCursor()
                }

                Divider().background(DS.Colors.borderSubtle)

                tuningSlider(
                    title: "Volume",
                    valueText: companionManager.ttsVolume.formatted(.number.precision(.fractionLength(1))),
                    value: Binding(
                        get: { companionManager.ttsVolume },
                        set: { companionManager.setTTSVolume($0) }
                    ),
                    range: 0.1...10,
                    step: 0.1
                )

                tuningSlider(
                    title: "Speed",
                    valueText: companionManager.ttsSpeed.formatted(.number.precision(.fractionLength(1))) + "x",
                    value: Binding(
                        get: { companionManager.ttsSpeed },
                        set: { companionManager.setTTSSpeed($0) }
                    ),
                    range: 0.5...2,
                    step: 0.1
                )

                tuningSlider(
                    title: "Pitch",
                    valueText: companionManager.ttsPitch.formatted(.number.sign(strategy: .always())),
                    value: Binding(
                        get: { Double(companionManager.ttsPitch) },
                        set: { companionManager.setTTSPitch(Int($0.rounded())) }
                    ),
                    range: -12...12,
                    step: 1
                )

                HStack {
                    Text("Emotion")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Picker("Emotion", selection: Binding(
                        get: { companionManager.ttsEmotion },
                        set: { companionManager.setTTSEmotion($0) }
                    )) {
                        ForEach(supportedEmotions, id: \.id) { emotion in
                            Text(emotion.label).tag(emotion.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }

                Button("Reset adjustments") {
                    companionManager.setTTSVolume(2.5)
                    companionManager.setTTSSpeed(1)
                    companionManager.setTTSPitch(0)
                    companionManager.setTTSEmotion("automatic")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .pointerCursor()
            }
            .padding(24)
        }
    }

    private var normalizedPreviewText: String {
        let trimmedText = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? "你好，我是 Clicky。" : trimmedText
    }

    private func settingsLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func tuningSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text(valueText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Slider(value: value, in: range, step: step)
                .tint(DS.Colors.accent)
        }
    }
}
