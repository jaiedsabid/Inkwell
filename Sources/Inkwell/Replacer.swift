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

    /// Puts `text` into the focused app. Short single-line text is typed as key presses, so the clipboard is never
    /// touched. Longer text is pasted with ⌘V, marked so clipboard managers skip it, and the user's clipboard comes back.
    static func paste(_ text: String) async {
        if text.utf16.count <= 400, !text.contains(where: \.isNewline) {
            await Keys.type(text)
            return
        }
        let pb = NSPasteboard.general
        let saved = Clipboard.snapshot()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        Clipboard.markTransient(item)
        pb.writeObjects([item])
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

    /// Types text as Unicode key presses (no clipboard). Events carry at most 20 UTF-16 units each.
    static func type(_ text: String) async {
        let src = CGEventSource(stateID: .privateState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var end = min(i + 20, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }   // don't split an emoji
            var chunk = Array(units[i..<end])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                e?.post(tap: .cghidEventTap)
            }
            i = end
            try? await Task.sleep(nanoseconds: 4_000_000)
        }
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
        // The user's own content: clipboard managers already have it, so they shouldn't log it a second time.
        items.forEach(markTransient)
        if !items.isEmpty { pb.writeObjects(items) }
    }

    /// The nspasteboard.org markers that Maccy, Paste, Raycast, Alfred and other clipboard managers skip.
    static func markTransient(_ item: NSPasteboardItem) {
        for t in ["org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"] {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(t))
        }
    }
}
