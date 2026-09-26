import ActivityKit
import Foundation

/// An agent run or automation run started from the app, on the lock screen
/// and in the Dynamic Island.
///
/// In Core, which both the app and the widget extension compile: the app
/// starts the activity and the widget extension draws it, and ActivityKit
/// matches the two by this type's name and shape — one definition for both.
struct RunActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// pending | running | completed | failed | canceled (AgentRun.status)
        var status: String
        /// The last thing the run said, one line.
        var lastLine: String
        var startedAt: Date
        var finishedAt: Date?
    }

    var slug: String
    var projectName: String
    /// The automation's name, or "Run" for a typed prompt.
    var title: String
}

extension RunActivityAttributes.ContentState {
    var finished: Bool { ["completed", "failed", "canceled"].contains(status) }
    var statusText: String {
        switch status {
        case "pending": "Starting"
        case "running": "Running"
        case "completed": "Done"
        case "failed": "Failed"
        case "canceled": "Canceled"
        default: status.capitalized
        }
    }
    var symbol: String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "failed": "xmark.octagon.fill"
        case "canceled": "stop.circle.fill"
        default: "cpu"
        }
    }
}
