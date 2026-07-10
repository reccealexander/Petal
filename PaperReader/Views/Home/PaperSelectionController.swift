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
    /// - Shift-click: RANGE-selects from `anchorID` (or from `id` itself if
    ///   there is no anchor yet) to `id`, inclusive, within `orderedIDs`, and
    ///   unions that range into `selectedIDs`. The anchor is left unchanged
    ///   (matching Finder: repeated shift-clicks extend/shrink relative to
    ///   the same anchor, not the last-clicked card).
    /// - Plain click: if `id` is already the sole selected card, `open(id)`
    ///   is invoked (second click on an already-solely-selected card opens
    ///   it). Otherwise the click selects only `id` (and moves the anchor to
    ///   it) without opening anything.
    func handleTap(_ id: String, shiftDown: Bool, orderedIDs: [String], open: (String) -> Void) {
        if shiftDown {
            let effectiveAnchor = anchorID ?? id
            if let anchorIndex = orderedIDs.firstIndex(of: effectiveAnchor),
               let targetIndex = orderedIDs.firstIndex(of: id) {
                let range = anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
                let idsInRange = orderedIDs[range]
                selectedIDs.formUnion(idsInRange)
            } else {
                // Fallback: id or anchor not found in the visible order
                // (shouldn't normally happen) — additive toggle of id.
                selectedIDs.insert(id)
            }
            if anchorID == nil {
                anchorID = effectiveAnchor
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

    /// Drops `ids` from the selection (e.g. after those papers are deleted).
    func remove(_ ids: Set<String>) {
        selectedIDs.subtract(ids)
        if let anchorID, ids.contains(anchorID) {
            self.anchorID = nil
        }
    }
}
