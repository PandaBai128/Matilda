import SwiftUI

struct CodexUsageSettingsView: View {
    @ObservedObject var usageMonitor: CodexUsageMonitor
    @ObservedObject var usageSettings: CodexUsageSettings

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(DS.Colors.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    currentUsageSection
                    menuBarSection
                    privacyNote
                }
                .padding(24)
            }
        }
        .background(DS.Colors.background)
        .task {
            if usageMonitor.isSnapshotStale() {
                await usageMonitor.refresh()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Colors.blue500.opacity(0.16))
                    .frame(width: 42, height: 42)

                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(DS.Colors.blue400)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Usage")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Keep the limits you care about visible at a glance.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Button {
                Task { await usageMonitor.refresh() }
            } label: {
                Group {
                    if usageMonitor.refreshState == .refreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
            }
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.textSecondary)
            .disabled(usageMonitor.refreshState == .refreshing)
            .pointerCursor(isEnabled: usageMonitor.refreshState != .refreshing)
            .help("Refresh Codex usage")
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var currentUsageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("CURRENT USAGE")

            if let snapshot = usageMonitor.snapshot,
               snapshot.weeklyLimit != nil || snapshot.fiveHourLimit != nil {
                TimelineView(.periodic(from: .now, by: 60)) { timelineContext in
                    VStack(spacing: 0) {
                        if let weeklyLimit = snapshot.weeklyLimit {
                            usageRow(
                                title: "Weekly limit",
                                shortLabel: "WEEK",
                                quotaWindow: weeklyLimit,
                                currentDate: timelineContext.date
                            )
                        }

                        if snapshot.weeklyLimit != nil, snapshot.fiveHourLimit != nil {
                            Divider().background(DS.Colors.borderSubtle)
                        }

                        if let fiveHourLimit = snapshot.fiveHourLimit {
                            usageRow(
                                title: "5-hour limit",
                                shortLabel: "5 HR",
                                quotaWindow: fiveHourLimit,
                                currentDate: timelineContext.date
                            )
                        }
                    }
                }
                .background(DS.Colors.surface1)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

                Text(CodexUsageFormatting.refreshDescription(refreshedAt: snapshot.refreshedAt))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(usageMonitor.errorMessage ?? "Open Codex once, then refresh to show your usage.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("Matilda reads your existing local Codex sign-in and never stores or changes it.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(DS.Colors.surface1)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
        }
    }

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("MENU BAR")

            VStack(spacing: 0) {
                settingsToggle(
                    title: "Show Codex usage",
                    detail: "Display remaining usage beside 壮壮.",
                    isOn: $usageSettings.isMenuBarUsageVisible
                )

                Divider().background(DS.Colors.borderSubtle)

                settingsToggle(
                    title: "Weekly limit",
                    detail: "Show the current weekly allowance.",
                    isOn: $usageSettings.isWeeklyLimitVisible
                )
                .disabled(!usageSettings.isMenuBarUsageVisible)
                .opacity(usageSettings.isMenuBarUsageVisible ? 1 : 0.45)

                if usageMonitor.snapshot?.fiveHourLimit != nil {
                    Divider().background(DS.Colors.borderSubtle)

                    settingsToggle(
                        title: "5-hour limit",
                        detail: "Available because Codex currently reports this window.",
                        isOn: $usageSettings.isFiveHourLimitVisible
                    )
                    .disabled(!usageSettings.isMenuBarUsageVisible)
                    .opacity(usageSettings.isMenuBarUsageVisible ? 1 : 0.45)
                }

                Divider().background(DS.Colors.borderSubtle)

                settingsToggle(
                    title: "Show recovery time at 0%",
                    detail: "Replace 0% with a compact reset countdown.",
                    isOn: $usageSettings.showsResetCountdownWhenExhausted
                )
                .disabled(!usageSettings.isMenuBarUsageVisible)
                .opacity(usageSettings.isMenuBarUsageVisible ? 1 : 0.45)
            }
            .background(DS.Colors.surface1)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Text("Usage refreshes about every two minutes. Only the last successful usage snapshot is cached; Codex credentials remain in Codex's own local files.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func usageRow(
        title: String,
        shortLabel: String,
        quotaWindow: CodexQuotaWindow,
        currentDate: Date
    ) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(CodexUsageFormatting.resetDescription(for: quotaWindow, currentDate: currentDate))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(quotaWindow.remainingPercent)%")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textPrimary)

                Text(shortLabel)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                    .tracking(0.5)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 62)
    }

    private func settingsToggle(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
                .pointerCursor()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(DS.Colors.textTertiary)
            .tracking(0.4)
    }
}
