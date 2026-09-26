// tRPC: project.restart (via PSRestartOwedSection)
import SwiftUI

/// A project's settings, grouped as on the web (SettingsTab.tsx): General;
/// Claude; then the worker's pages — Worker, Terminals & SSH, Browser, Your
/// computer, .env. A setting is found by asking "is this about Claude or about
/// the worker".
struct ProjectSettingsView: View {
    let slug: String
    let project: JSON
    let onChange: () -> Void

    var body: some View {
        if project.isNull {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                PSRestartOwedSection(project: project, onRestarted: onChange)
                Section {
                    link("General", icon: "gearshape") { PSGeneralSettings(slug: slug, project: project, onChange: onChange) }
                }
                Section {
                    link("Claude", icon: "sparkles") { PSClaudeSettings(slug: slug, project: project, onChange: onChange) }
                }
                Section {
                    link("Worker", icon: "shippingbox", alert: project["restartPending"].bool == true) {
                        PSWorkerSettings(slug: slug, project: project, onChange: onChange)
                    }
                    link("Terminals & SSH", icon: "terminal") { PSTerminalsSettings(slug: slug, project: project) }
                    link("Browser", icon: "globe") { PSBrowserSettings(slug: slug, project: project, onChange: onChange) }
                    link("Your computer", icon: "laptopcomputer") { PSComputerSettings(slug: slug, project: project, onChange: onChange) }
                    if project.psCan("own") {
                        link(".env", icon: "doc.text") { PSEnvSettings(slug: slug) }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func link<D: View>(_ title: String, icon: String, alert: Bool = false, @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination().navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } label: {
            HStack {
                Label(title, systemImage: icon)
                if alert {
                    Spacer()
                    Circle().fill(.orange).frame(width: 8, height: 8).accessibilityLabel("Restart owed")
                }
            }
        }
    }
}
