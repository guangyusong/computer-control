import SwiftUI

struct PermissionsView: View {
    @Environment(PermissionStore.self) private var permissions

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PermissionChecklistRow(
                        title: "Accessibility",
                        detail: "Keyboard, typing, scrolling, clicking, menus, and UI inspection.",
                        state: permissions.accessibility,
                        primaryTitle: permissions.accessibility == .granted ? "Ready" : "Request",
                        primaryAction: permissions.requestAccessibility,
                        settingsAction: permissions.openAccessibilitySettings
                    )

                    PermissionChecklistRow(
                        title: "Screen Recording",
                        detail: "Screenshots and visual computer-use loops.",
                        state: permissions.screenRecording,
                        primaryTitle: permissions.screenRecording == .granted ? "Ready" : "Request",
                        primaryAction: permissions.requestScreenRecording,
                        settingsAction: permissions.openScreenRecordingSettings
                    )

                    PermissionChecklistRow(
                        title: "Microphone",
                        detail: "Realtime voice input.",
                        state: permissions.microphone,
                        primaryTitle: permissions.microphone == .granted ? "Ready" : "Request",
                        primaryAction: permissions.requestMicrophone,
                        settingsAction: permissions.openMicrophoneSettings
                    )

                    PermissionChecklistRow(
                        title: "Automation",
                        detail: "Apple Events prompts for scriptable target apps.",
                        state: permissions.automation,
                        primaryTitle: "Open Settings",
                        primaryAction: permissions.openAutomationSettings,
                        settingsAction: permissions.openAutomationSettings
                    )
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Permissions")
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Permissions")
                    .font(.headline)
                Text(permissionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                permissions.requestAllCorePermissions()
            } label: {
                Label("Request All", systemImage: "checkmark.shield")
            }

            Button {
                permissions.openPrivacySettings()
            } label: {
                Label("Privacy", systemImage: "gear")
            }

            Button {
                permissions.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 18, height: 18)
            }
            .help("Refresh")
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var permissionSummary: String {
        "\(grantedPermissionCount) of 3 core permissions ready"
    }

    private var grantedPermissionCount: Int {
        [permissions.accessibility, permissions.screenRecording, permissions.microphone]
            .filter { $0 == .granted }
            .count
    }
}

private struct PermissionChecklistRow: View {
    var title: String
    var detail: String
    var state: PermissionState
    var primaryTitle: String
    var primaryAction: () -> Void
    var settingsAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(state == .granted ? .green : .orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.callout)
                        .fontWeight(.semibold)
                    Text(state.rawValue)
                        .font(.caption)
                        .foregroundStyle(state == .granted ? .green : .orange)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)

            Button(primaryTitle, action: primaryAction)
                .disabled(state == .granted && primaryTitle == "Ready")

            Button {
                settingsAction()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .help("Open settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary)
        }
    }
}
