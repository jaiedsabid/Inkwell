import AppKit
import ApplicationServices

/// Swaps text inside another app's field. Tries Accessibility first, then falls back to select + paste.
@MainActor
enum Replacer {
    enum Outcome { case replaced, pasted, failed }

    /// Replaces `range` (which must still contain `expected`) with `new`.
    static func replace(in el: AXUIElement, range: NSRange, expected: String, with new: String) async -> Outcome {
        guard let value = AX.value(el) else { return await pasteOverSelection(el, range: range, new: new) }
        let ns = value as NSString
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == expected else { return .failed }
        let target = ns.replacingCharacters(in: range, with: new)
        let caret = NSRange(location: range.location + (new as NSString).length, length: 0)

        if AX.setSelectedRange(el, range), AX.setSelectedText(el, new) {
            try? await Task.sleep(nanoseconds: 80_000_000)
            let now = AX.value(el)
            if now == target { AX.setSelectedRange(el, caret); return .replaced }
            if now != value { return now == target ? .replaced : .failed }  // changed to something else: don't touch it again
        }
        return await pasteOverSelection(el, range: range, new: new)
    }

    private static func pasteOverSelection(_ el: AXUIElement, range: NSRange, new: String) async -> Outcome {
        guard AX.setSelectedRange(el, range) else { return .failed }
        try? await Task.sleep(nanoseconds: 40_000_000)
        guard AX.selectedRange(el) == range else { return .failed }
        await paste(new)
        return .pasted
    }

    /// Types `text` into the focused app with ⌘V, then puts the user's clipboard back.
    static func paste(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = Clipboard.snapshot()
        pb.clearContents()
        pb.setString(text, forType: .string)
        Keys.post(key: 9, flags: .maskCommand)   // V
        try? await Task.sleep(nanoseconds: 350_000_000)
        Clipboard.restore(saved)
    }

    /// Reads the selection by sending ⌘C, for apps that don't expose it through Accessibility.
    static func copySelection() async -> String? {
        let pb = NSPasteboard.general
        let saved = Clipboard.snapshot()
        let before = pb.changeCount
        Keys.post(key: 8, flags: .maskCommand)   // C
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            if pb.changeCount != before { break }
        }
        let text = pb.changeCount != before ? pb.string(forType: .string) : nil
        Clipboard.restore(saved)
        return text
    }
}

enum Keys {
    static func post(key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

enum Clipboard {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]

    static func snapshot() -> Snapshot {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
    }

    static func restore(_ s: Snapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let items = s.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in dict { item.setData(data, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
