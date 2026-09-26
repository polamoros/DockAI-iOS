// tRPC: (none — shared building blocks for the Projects feature)
import SwiftUI
import UIKit

/// Small pieces the project screens share. Prefixed `Proj` so they cannot
/// collide with another feature's helpers of the same idea.

/// A card on the Overview: a title line with an optional trailing control,
/// then the body — the web's `Card` with `title`/`icon`/`action`.
struct ProjCard<Content: View, Trailing: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: String, systemImage: String,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
                Spacer()
                trailing()
            }
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

extension ProjCard where Trailing == EmptyView {
    init(_ title: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, systemImage: systemImage, trailing: { EmptyView() }, content: content)
    }
}

/// One label/value line of a card's facts.
struct ProjFact: View {
    let label: String
    let value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(mono ? .footnote.monospaced() : .footnote)
                .multilineTextAlignment(.trailing).lineLimit(2).textSelection(.enabled)
        }
    }
}

/// A usage or resource meter: label, figure, bar, and an optional line under it.
struct ProjMeter: View {
    let label: String
    let pct: Double
    var value: String? = nil
    var caption: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.footnote.weight(.medium))
                Spacer()
                Text(value ?? "\(Int(pct.rounded()))%").font(.footnote.monospacedDigit()).foregroundStyle(tint)
            }
            ProgressView(value: min(max(pct, 0), 100), total: 100).tint(tint)
            if let caption, !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
    private var tint: Color { pct >= 90 ? .red : pct >= 70 ? .orange : .accentColor }
}

/// Copies a string and says so for two seconds.
struct ProjCopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false
    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered).controlSize(.small)
    }
}

/// A shell command in a mono box, copyable — the web's `CommandLine`.
struct ProjCommandLine: View {
    let command: String
    var body: some View {
        HStack(spacing: 8) {
            Text(command).font(.footnote.monospaced()).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            ProjCopyButton(text: command)
        }
    }
}

enum Proj {
    /// "now", "5 min. ago" — from a millisecond timestamp, as the worker reports them.
    static func relative(ms: Double?) -> String {
        guard let ms, ms > 0 else { return "" }
        return Date(timeIntervalSince1970: ms / 1000).relative
    }

    /// OWNER, COLLABORATOR or VIEWER — `project.list` and `getBySlug` carry it.
    static func role(_ p: JSON) -> String {
        let r = p["role"].string
        return r == "VIEWER" || r == "COLLABORATOR" ? r! : "OWNER"
    }
    /// A viewer watches; anyone else may start and stop.
    static func canDrive(_ p: JSON) -> Bool { role(p) != "VIEWER" }
    static func isOwner(_ p: JSON) -> Bool { role(p) == "OWNER" }
    static func startable(_ status: String?) -> Bool { status == "STOPPED" || status == "ERROR" }

    /// Why a restart is owed, if one is: a setting baked in at creation, a
    /// newer worker image, or both — the web's `RestartPendingBanner` reason.
    static func restartReason(_ p: JSON) -> String? {
        let settings = p["restartPending"].bool == true
        let image = p["container"]["imageStale"].bool == true
        switch (settings, image) {
        case (true, true): return "Saved, and a newer worker image is available — restart applies both."
        case (true, false): return "Saved — takes effect after a restart."
        case (false, true): return "A newer worker image is available — restart to use it."
        default: return nil
        }
    }

    /// `owner/repo` from a clone or web URL.
    static func repoName(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        var s = url
        if s.hasSuffix(".git") { s.removeLast(4) }
        let parts = s.split(separator: "/")
        guard parts.count >= 2 else { return s }
        return parts.suffix(2).joined(separator: "/")
    }
}
