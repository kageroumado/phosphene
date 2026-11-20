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
        // Clicking empty browser space can leave the toolbar field as first responder.
        let coordinator = context.coordinator
        coordinator.clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak field, weak coordinator] event in
            if let field, let window = unsafe field.window, event.window === window, field.stringValue.isEmpty,
               !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                DispatchQueue.main.async { [weak coordinator] in
                    guard let coordinator, coordinator.search.text.isEmpty else { return }
                    coordinator.search.dismiss()
                }
            }
            return event
        }
        return field
    }

    static func dismantleNSView(_: Field, coordinator: Coordinator) {
        if let monitor = coordinator.clickMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.clickMonitor = nil
        }
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
        var clickMonitor: Any?

        init(_ search: LibrarySearchField) {
            self.search = search
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            search.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField, field.stringValue.isEmpty else { return }
            search.dismiss()
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            search.dismiss()
            return true
        }
    }
}
