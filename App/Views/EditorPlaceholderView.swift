import SwiftUI

/// Stand-in for the editor window (task 2.2).
struct EditorPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Editor coming soon",
            systemImage: "slider.horizontal.3",
            description: Text("Profile editing will live here.")
        )
        .frame(minWidth: 480, minHeight: 320)
    }
}
