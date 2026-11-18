import AppKit
import SwiftUI

/// Plain-text editor with macOS' continuous spell checking: misspelled words get
/// the red dotted underline, right-click offers corrections. Grows with its text.
struct SpellCheckingEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var font: NSFont = .systemFont(ofSize: 14)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.font = font
        tv.textColor = .textColor
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.isContinuousSpellCheckingEnabled = true
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false   // never change words behind the user's back
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 2
        tv.string = text
        DispatchQueue.main.async { context.coordinator.updateHeight(tv) }
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        context.coordinator.parent = self
        if tv.string != text {
            let sel = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = sel.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        }
        DispatchQueue.main.async { context.coordinator.updateHeight(tv) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SpellCheckingEditor
        init(_ parent: SpellCheckingEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            updateHeight(tv)
        }

        func updateHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2 + 4)
            if abs(parent.height - h) > 0.5 { parent.height = max(60, h) }
        }
    }
}
