// tRPC: (none — presentation of a `project.list` row)
import SwiftUI

/// One project as a list row: a title line over one quiet meta line, and the
/// state on the right with what Claude is doing under it. Every row is the
/// same height; a restart owed is a segment of the meta line, not a third line.
struct ProjectListRow: View {
    let project: JSON
    let status: String?
    var busy = false

    var body: some View {
        HStack(spacing: 12) {
            ProjAvatar(name: project["name"].string ?? "?", path: project["avatarUrl"].string)
            VStack(alignment: .leading, spacing: 2) {
                Text(project["name"].string ?? project["slug"].string ?? "—")
                    .font(.body.weight(.semibold)).lineLimit(1)
                meta.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if busy { ProgressView().controlSize(.small) } else { StatusPill(status: status) }
                if status == "RUNNING", let activity = activity {
                    Text(activity).font(.caption2).foregroundStyle(activity == "Working" ? Color.accentColor : .secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// Whose project, a restart owed, then the repo and branch — or the
    /// account when there is no repo.
    private var meta: Text {
        var parts: [Text] = []
        let role = Proj.role(project)
        if role != "OWNER" {
            parts.append(Text(Image(systemName: "person.2")) + Text(role == "VIEWER" ? " Viewer" : " Collaborator"))
        }
        if status == "RUNNING", Proj.restartReason(project) != nil {
            parts.append((Text(Image(systemName: "arrow.clockwise")) + Text(" Restart owed")).foregroundColor(.orange))
        }
        if let repo = Proj.repoName(project["githubRepoUrl"].string) {
            parts.append(Text(repo.split(separator: "/").last.map(String.init) ?? repo))
            if let b = project["githubBranch"].string, !b.isEmpty { parts.append(Text(b)) }
        } else if let account = project["claudeAccount"]["label"].string {
            parts.append(Text(account))
        } else {
            parts.append(Text(project["slug"].string ?? "").font(.caption.monospaced()))
        }
        return parts.enumerated().reduce(Text("")) { acc, item in
            item.offset == 0 ? item.element : acc + Text(" · ") + item.element
        }
    }

    private var activity: String? {
        switch project["claudeStatus"].string {
        case "working": return "Working"
        case .some: return "Idle"
        default: return nil
        }
    }
}

/// The project's avatar — the web's `ProjectAvatar`: the uploaded image when
/// there is one (served from the paired server, no sign-in needed), the
/// initials in a tinted square otherwise and while it loads.
struct ProjAvatar: View {
    let name: String
    var path: String? = nil
    var size: CGFloat = 36
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let url = imageURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
                        .accessibilityHidden(true)
                } else { initialsView }
            }
        } else { initialsView }
    }
    /// An absolute URL as is; a server path (`/api/uploads/…`) on the paired server.
    private var imageURL: URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") { return URL(string: path) }
        guard let server = model.credentials?.server,
              var comps = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        comps.path = parts[0]
        comps.percentEncodedQuery = parts.count > 1 ? parts[1] : nil
        return comps.url
    }
    @ViewBuilder private var initialsView: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
    private var tint: Color {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green, .mint]
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[sum % palette.count]
    }
}
