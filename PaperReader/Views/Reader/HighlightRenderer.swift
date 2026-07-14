import Foundation
import AppKit
import PDFKit
import PaperReaderCore

/// Pure PDFKit rendering for highlights: turning a `PDFSelection` into per-page
/// spans, turning a stored `Highlight` into `PDFAnnotation`s on a page, and back.
/// This file owns no persistence — `HighlightRepository` is the source of truth
/// for `Highlight` rows (spec §5); this file only draws/erases what the DB says.

extension HighlightColor {
    /// The translucent fill used for the PDFKit highlight annotation.
    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor.systemYellow
        case .green:  return NSColor.systemGreen
        case .blue:   return NSColor.systemBlue
        case .pink:   return NSColor.systemPink
        }
    }
}

/// One contiguous span of a selection that falls on a single page. A selection
/// crossing a page break produces multiple spans (→ multiple Highlight rows).
struct SelectionSpan {
    let pageIndex: Int
    let rects: [CGRect]   // line rects in PDF page coordinate space
    let text: String
}

/// Serializes `[CGRect]` to/from the JSON stored in `highlight.bounding_boxes`.
enum BoundingBoxCodec {
    private struct Box: Codable {
        var x, y, width, height: Double
    }

    /// Encodes `rects` as a JSON array of `{x,y,width,height}` objects.
    /// Returns `"[]"` if encoding fails.
    static func encode(_ rects: [CGRect]) -> String {
        let boxes = rects.map { rect in
            Box(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
        }
        guard let data = try? JSONEncoder().encode(boxes),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Decodes a JSON array of `{x,y,width,height}` objects into `[CGRect]`.
    /// Returns `[]` if the JSON is missing or malformed.
    static func decode(_ json: String) -> [CGRect] {
        guard let data = json.data(using: .utf8),
              let boxes = try? JSONDecoder().decode([Box].self, from: data) else {
            return []
        }
        return boxes.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
    }
}

/// Stateless PDFKit rendering helpers for highlights. No database access lives
/// here — callers persist/lookup `Highlight` rows via `HighlightRepository` and
/// use this type only to draw/erase the corresponding `PDFAnnotation`s.
enum HighlightRenderer {
    static func locate(sentence: String, on page: PDFPage) -> [CGRect] {
        guard let pageText = page.string, !sentence.isEmpty else { return [] }

        let foundRange: NSRange?
        if let range = pageText.range(of: sentence) {
            foundRange = NSRange(range, in: pageText)
        } else {
            let tokens = sentence.split(whereSeparator: { $0.isWhitespace })
            guard !tokens.isEmpty else { return [] }
            let pattern = tokens
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let whole = NSRange(pageText.startIndex..<pageText.endIndex, in: pageText)
            foundRange = regex.firstMatch(in: pageText, range: whole)?.range
        }

        guard let foundRange, foundRange.location != NSNotFound,
              foundRange.length > 0,
              let selection = page.selection(for: foundRange)
        else { return [] }

        return selection.selectionsByLine().compactMap { line in
            let rect = line.bounds(for: page)
            return rect.isNull || rect.isEmpty ? nil : rect
        }
    }

    /// Adds orange, translucent pending markers that are distinct from stored highlights.
    static func addProposalAnnotations(rects: [CGRect], on page: PDFPage) -> [PDFAnnotation] {
        rects.compactMap { rect in
            guard !rect.isNull, !rect.isEmpty else { return nil }
            let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            annotation.color = NSColor.systemOrange.withAlphaComponent(0.28)
            page.addAnnotation(annotation)
            return annotation
        }
    }

    /// Adds a clickable badge immediately above the top-most pending marker.
    static func addProposalLabel(near rects: [CGRect], on page: PDFPage) -> PDFAnnotation? {
        guard let topRect = rects.max(by: { $0.maxY < $1.maxY }) else { return nil }

        let pageRect = page.bounds(for: .cropBox)
        let inset: CGFloat = 4
        let leftMargin = topRect.minX - pageRect.minX
        var x: CGFloat
        let width: CGFloat = 52
        let height: CGFloat = 13
        if leftMargin >= width + 2 * inset {
            x = pageRect.minX + inset
        } else {
            x = pageRect.maxX - width - inset
        }
        let proposedY = topRect.midY - height / 2
        let y = min(max(proposedY, pageRect.minY + 1), pageRect.maxY - height - 1)
        let bounds = CGRect(x: x, y: y, width: width, height: height)
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = "Key Insight"
        annotation.font = NSFont.boldSystemFont(ofSize: 8)
        annotation.fontColor = .white
        annotation.color = .systemRed
        annotation.alignment = .center
        annotation.isReadOnly = true
        annotation.border = nil
        page.addAnnotation(annotation)
        return annotation
    }

    /// Splits a `PDFSelection` into per-page spans, handling selections that
    /// cross a page break by producing one span per page touched.
    static func spans(from selection: PDFSelection, in document: PDFDocument) -> [SelectionSpan] {
        var rectsByPage: [Int: [CGRect]] = [:]
        var textByPage: [Int: String] = [:]

        for line in selection.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            let idx = document.index(for: page)
            let b = line.bounds(for: page)
            guard !b.isNull, !b.isEmpty else { continue }

            rectsByPage[idx, default: []].append(b)

            let lineText = line.string ?? ""
            if var existing = textByPage[idx] {
                existing += existing.hasSuffix("\n") || existing.isEmpty ? lineText : " " + lineText
                textByPage[idx] = existing
            } else {
                textByPage[idx] = lineText
            }
        }

        return rectsByPage.keys.sorted().map { idx in
            SelectionSpan(
                pageIndex: idx,
                rects: rectsByPage[idx] ?? [],
                text: (textByPage[idx] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Creates and attaches highlight annotations for a stored `Highlight` to its
    /// page, plus a small "has comment" dot when `hasComment` is true. Returns
    /// every annotation added so the caller can map annotations back to the
    /// highlight id and remove them later.
    static func addAnnotations(for highlight: Highlight, hasComment: Bool, to document: PDFDocument) -> [PDFAnnotation] {
        guard let page = document.page(at: highlight.page) else { return [] }

        let rects = BoundingBoxCodec.decode(highlight.boundingBoxes)
        let color = HighlightColor(rawValue: highlight.color)?.nsColor ?? HighlightColor.yellow.nsColor

        var added: [PDFAnnotation] = []

        for rect in rects {
            let a = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            a.color = color
            page.addAnnotation(a)
            added.append(a)
        }

        if hasComment, let topRect = rects.max(by: { $0.maxY < $1.maxY }) {
            let dotRect = CGRect(x: topRect.maxX - 4, y: topRect.maxY - 4, width: 8, height: 8)
            let dot = PDFAnnotation(bounds: dotRect, forType: .circle, withProperties: nil)
            dot.color = NSColor.controlAccentColor
            dot.interiorColor = NSColor.controlAccentColor
            page.addAnnotation(dot)
            added.append(dot)
        }

        return added
    }

    /// Detaches the given annotations from their pages.
    static func removeAnnotations(_ annotations: [PDFAnnotation]) {
        for annotation in annotations {
            annotation.page?.removeAnnotation(annotation)
        }
    }
}
