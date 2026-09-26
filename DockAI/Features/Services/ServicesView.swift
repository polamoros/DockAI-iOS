// tRPC: service.list, service.add, service.remove, service.detectPorts, system.authConfig, mcp.presets, mcp.list, mcp.add, mcp.update, mcp.remove, library.forProject, library.setOverride
import SwiftUI

/// The project's Services tab, as on the web (ProjectDetail → ServicesSection +
/// McpServers + the library's MCP overrides): what the worker serves on a
/// subdomain, and the connectors its conversations can use.
struct ServicesView: View {
    let slug: String
    let project: JSON

    var body: some View {
        if let id = project["id"].string {
            List {
                SvcExposedServices(projectId: id, slug: slug, isRunning: project.psRunning)
                SvcMcpServers(projectId: id)
                SvcLibraryOverrides(projectId: id, kind: "mcp")
            }
            .listStyle(.insetGrouped)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Lowercase letters, digits and hyphens — what the web makes of a typed name
/// before it becomes part of a subdomain.
enum SvcName {
    static func safe(_ s: String) -> String {
        String(s.lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" ? $0 : "-" })
    }
}
