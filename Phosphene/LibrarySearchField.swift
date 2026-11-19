import AppKit
import SwiftUI

struct LibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.search = self
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Field: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = unsafe self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var search: LibrarySearchField

        init(_ search: LibrarySearchField) {
            self.search = search
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            search.text = field.stringValue
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            search.dismiss()
            return true
        }
    }
}
