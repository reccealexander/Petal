import Foundation

/// The four highlight color categories (spec §1 `color` column; default "yellow").
/// Raw values match the strings persisted in `highlight.color`.
public enum HighlightColor: String, CaseIterable, Codable, Sendable, Identifiable {
    case yellow
    case green
    case blue
    case pink

    public var id: String { rawValue }

    /// Human-facing name, e.g. for tooltips.
    public var displayName: String { rawValue.capitalized }
}
