import Foundation
import SwiftUI

/// Centralizes the "click selects, click-again opens" decision for paper
/// cards in the home grid (Session 11). Kept separate from the grid/card
/// views so a future list view can reuse the exact same click semantics
/// without duplicating the logic.
///
/// Selection here is transient UI state — it is never persisted and is
/// reset whenever the app relaunches or the view is torn down.
@MainActor
final class PaperSelectionController: ObservableObject {
    /// The ids of the currently-selected paper cards.
    @Published var selectedIDs: Set<String> = []

    /// The last card clicked without shift, used as the range-select anchor
    /// for a subsequent shift-click (Finder-like behavior).
    private var anchorID: String?

    /// Whether `id` is part of the current selection.
    func isSelected(_ id: String) -> Bool {
        selectedIDs.contains(id)
    }

    /// The single source of truth for what a click on a card does.
    ///
    /// - Shift-click: selects EXACTLY TWO cards — the anchor (the last card
    ///   selected without shift) and the newly-clicked card — regardless of
    ///   how many were selected before (Session 12 Task 5: this replaced the
    ///   earlier Finder-style range-select). If nothing was selected yet, it
    ///   just selects `id` and makes it the anchor.
    /// - Plain click: if `id` is already the sole selected card, `open(id)`
    ///   is invoked (second click on an already-solely-selected card opens
    ///   it). Otherwise the click selects only `id` (and moves the anchor to
    ///   it) without opening anything.
    func handleTap(_ id: String, shiftDown: Bool, orderedIDs: [String], open: (String) -> Void) {
        if shiftDown {
            if let anchor = anchorID, anchor != id {
                selectedIDs = [anchor, id]   // exactly the two
            } else {
                selectedIDs = [id]           // nothing was selected before → just this one
                anchorID = id
            }
            return
        }

        if selectedIDs == [id] {
            open(id)
        } else {
            selectedIDs = [id]
            anchorID = id
        }
    }

    /// Clears the selection entirely (e.g. a click on empty grid space).
    func deselectAll() {
        selectedIDs.removeAll()
        anchorID = nil
    }

    /// Replaces the current selection with one paper (for keyboard navigation)
    /// and makes it the anchor for any subsequent shift-click.
    func selectOnly(_ id: String) {
        selectedIDs = [id]
        anchorID = id
    }

    /// Drops `ids` from the selection (e.g. after those papers are deleted).
    func remove(_ ids: Set<String>) {
        selectedIDs.subtract(ids)
        if let anchorID, ids.contains(anchorID) {
            self.anchorID = nil
        }
    }
}
