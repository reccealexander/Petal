import AppKit
import SwiftUI

/// Rich-text editing surface and formatting controls used by the detached note window.
struct RichTextEditorView: View {
    @Binding var text: NSAttributedString
    let onEdit: () -> Void
    let onOpenHighlight: (URL) -> Void

    @StateObject private var formatting = RichTextFormattingController()
    @State private var fontFamily = NSFont.systemFont(ofSize: NSFont.systemFontSize).familyName ?? "Helvetica"
    @State private var fontSize = Double(NSFont.systemFontSize)
    @State private var textColor = Color.primary

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("Font", selection: $fontFamily) {
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: fontFamily) { _, family in formatting.setFontFamily(family) }

                TextField("Size", value: $fontSize, format: .number)
                    .frame(width: 42)
                    .onSubmit { formatting.setFontSize(CGFloat(fontSize)) }

                Divider().frame(height: 18)
                formatButton("Bold", systemImage: "bold") { formatting.toggle(.boldFontMask) }
                formatButton("Italic", systemImage: "italic") { formatting.toggle(.italicFontMask) }
                formatButton("Underline", systemImage: "underline") { formatting.toggleUnderline() }

                ColorPicker("Text Color", selection: $textColor, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: textColor) { _, color in formatting.setTextColor(NSColor(color)) }

                Divider().frame(height: 18)
                formatButton("Bulleted List", systemImage: "list.bullet") { formatting.setList(.disc) }
                formatButton("Numbered List", systemImage: "list.number") { formatting.setList(.decimal) }
                Divider().frame(height: 18)
                formatButton("Align Left", systemImage: "text.alignleft") { formatting.setAlignment(.left) }
                formatButton("Align Center", systemImage: "text.aligncenter") { formatting.setAlignment(.center) }
                formatButton("Align Right", systemImage: "text.alignright") { formatting.setAlignment(.right) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            RichTextEditorRepresentable(
                text: $text,
                formatting: formatting,
                onEdit: onEdit,
                onOpenHighlight: onOpenHighlight)
        }
    }

    private func formatButton(
        _ help: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: systemImage) }
            .buttonStyle(.borderless)
            .help(help)
    }
}

@MainActor
private final class RichTextFormattingController: ObservableObject {
    weak var textView: NSTextView?

    func toggle(_ trait: NSFontTraitMask) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        let manager = NSFontManager.shared
        mutateFonts { font in
            let hasTrait = manager.traits(of: font).contains(trait)
            return hasTrait
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
        }
    }

    func setFontFamily(_ family: String) {
        mutateFonts { NSFontManager.shared.convert($0, toFamily: family) }
    }

    func setFontSize(_ size: CGFloat) {
        guard size >= 6, size <= 144 else { return }
        mutateFonts { NSFontManager.shared.convert($0, toSize: size) }
    }

    func toggleUnderline() {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            let current = textView.typingAttributes[.underlineStyle] as? Int ?? 0
            textView.typingAttributes[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        } else if let storage = textView.textStorage {
            let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
            storage.addAttribute(.underlineStyle, value: current == 0 ? NSUnderlineStyle.single.rawValue : 0, range: range)
            textView.didChangeText()
        }
    }

    func setTextColor(_ color: NSColor) {
        applyAttribute(.foregroundColor, value: color)
    }

    func setAlignment(_ alignment: NSTextAlignment) {
        guard let textView else { return }
        textView.setAlignment(alignment, range: paragraphRange(in: textView))
    }

    func setList(_ marker: NSTextList.MarkerFormat) {
        guard let textView, let storage = textView.textStorage else { return }
        let range = paragraphRange(in: textView)
        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                ?? NSMutableParagraphStyle()
            style.textLists = [NSTextList(markerFormat: marker, options: 0)]
            style.headIndent = 24
            style.firstLineHeadIndent = 8
            storage.addAttribute(.paragraphStyle, value: style, range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private func mutateFonts(_ transform: (NSFont) -> NSFont) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            let font = textView.typingAttributes[.font] as? NSFont ?? textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            textView.typingAttributes[.font] = transform(font)
        } else if let storage = textView.textStorage {
            storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let font = value as? NSFont ?? textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
                storage.addAttribute(.font, value: transform(font), range: subrange)
            }
            textView.didChangeText()
        }
    }

    private func applyAttribute(_ key: NSAttributedString.Key, value: Any) {
        guard let textView else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            textView.typingAttributes[key] = value
        } else {
            textView.textStorage?.addAttribute(key, value: value, range: range)
            textView.didChangeText()
        }
    }

    private func paragraphRange(in textView: NSTextView) -> NSRange {
        (textView.string as NSString).paragraphRange(for: textView.selectedRange())
    }
}

private struct RichTextEditorRepresentable: NSViewRepresentable {
    @Binding var text: NSAttributedString
    let formatting: RichTextFormattingController
    let onEdit: () -> Void
    let onOpenHighlight: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(text)
        scrollView.documentView = textView
        formatting.textView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView,
              !textView.attributedString().isEqual(to: text) else { return }
        let selection = textView.selectedRange()
        context.coordinator.isApplyingBinding = true
        textView.textStorage?.setAttributedString(text)
        textView.setSelectedRange(NSRange(location: min(selection.location, text.length), length: 0))
        context.coordinator.isApplyingBinding = false
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditorRepresentable
        weak var textView: NSTextView?
        var isApplyingBinding = false

        init(parent: RichTextEditorRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingBinding, let textView else { return }
            parent.text = NSAttributedString(attributedString: textView.attributedString())
            parent.onEdit()
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            if let value = link as? URL { url = value }
            else if let value = link as? String { url = URL(string: value) }
            else { url = nil }
            guard let url, HighlightLink.parse(url) != nil else { return false }
            parent.onOpenHighlight(url)
            return true
        }
    }
}
