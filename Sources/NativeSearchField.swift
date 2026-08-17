import AppKit
import SwiftUI

/// 工具栏原生搜索框：NSSearchField 包装，保留 Enter/Shift+Enter 跳转。
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusSignal: UUID
    let onNext: () -> Void
    let onPrev: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldAction(_:))
        context.coordinator.field = field
        context.coordinator.observeEndEditing(field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocus != focusSignal {
            context.coordinator.lastFocus = focusSignal
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        weak var field: NSSearchField?
        var lastFocus: UUID?

        init(parent: NativeSearchField) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observeEndEditing(_ field: NSSearchField) {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(textDidEndEditing(_:)),
                name: NSControl.textDidEndEditingNotification,
                object: field
            )
        }

        @objc private func textDidEndEditing(_ note: Notification) {
            parent.onCancel()
        }

        func controlTextDidChange(_ obj: Notification) {
            let value = (obj.object as? NSSearchField)?.stringValue ?? ""
            parent.text = value
        }

        @objc func searchFieldAction(_ sender: NSSearchField) {
            if sender.stringValue.isEmpty {
                parent.text = ""
            }
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    parent.onPrev()
                } else {
                    parent.onNext()
                }
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.text = ""
                field?.stringValue = ""
                return true
            }
            return false
        }
    }
}

/// 搜索框 + 计数/无结果提示，整体放在工具栏里。
struct SearchFieldToolbarItem: View {
    @ObservedObject var renderer: MarkdownRenderer
    @Binding var text: String
    @Binding var focusSignal: UUID
    let searchNext: () -> Void
    let searchPrev: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            NativeSearchField(text: $text,
                              focusSignal: focusSignal,
                              onNext: searchNext,
                              onPrev: searchPrev,
                              onCancel: onCancel)
                .frame(width: 260)
            if !text.isEmpty {
                Text(renderer.searchCount > 0
                     ? "\(renderer.searchCurrent)/\(renderer.searchCount)"
                     : "0")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.trailing, 28)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 260)
    }
}
