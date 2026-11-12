import AppKit
import SwiftUI

/// The editor's tags, as tokens: type a tag and a comma or Return. Completes
/// from the tags already in use.
struct TagField: NSViewRepresentable {
    @Binding var tags: [String]
    let suggestions: [String]

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        field.placeholderString = "Add Tags"
        field.objectValue = tags
        field.setAccessibilityLabel("Tags")
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        // Leave the field alone while someone types in it.
        if field.currentEditor() == nil, (field.objectValue as? [String]) != tags {
            field.objectValue = tags
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: TagField

        init(parent: TagField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            take(from: notification)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            take(from: notification)
        }

        private func take(from notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            let tags = ConnectionDraft.normalizedTags(field.objectValue as? [String] ?? [])
            if tags != parent.tags { parent.tags = tags }
        }

        func tokenField(
            _ tokenField: NSTokenField, completionsForSubstring substring: String,
            indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            parent.suggestions.filter { $0.range(of: substring, options: [.caseInsensitive, .anchored]) != nil }
        }
    }
}
