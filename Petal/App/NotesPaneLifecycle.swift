import Foundation

extension Notification.Name {
    /// Requests that the notes UI for one paper close wherever it is hosted.
    /// userInfo: ["paperId": String].
    static let notesPaneShouldClose = Notification.Name("Petal.notesPaneShouldClose")
}

/// A paper-keyed close request shared by standalone notes windows, joined
/// notes panes, and every note-deletion entry point.
@MainActor
enum NotesPaneCloseRequest {
    private static let paperIdKey = "paperId"

    static func post(paperId: String) {
        // Delete actions run inside SwiftUI alerts. Deliver on the next main
        // runloop turn so the alert has finished dismissing before its window
        // owner tears down the containing scene.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .notesPaneShouldClose,
                object: nil,
                userInfo: [paperIdKey: paperId]
            )
        }
    }

    static func paperId(from notification: Notification) -> String? {
        notification.userInfo?[paperIdKey] as? String
    }
}
