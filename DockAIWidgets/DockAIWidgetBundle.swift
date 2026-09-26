import SwiftUI
import WidgetKit

/// The widget extension: the usage widget and the run Live Activity.
@main
struct DockAIWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        RunActivity()
    }
}
