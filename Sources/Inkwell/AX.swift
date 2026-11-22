import AppKit
import ApplicationServices

/// Thin helpers over the macOS Accessibility API, used to read and edit text in other apps.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static let systemWide = AXUIElementCreateSystemWide()

    // MARK: Reading

    static func raw(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = raw(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { raw(el, name) as? String }

    static func role(_ el: AXUIElement) -> String { string(el, kAXRoleAttribute) ?? "" }
    static func subrole(_ el: AXUIElement) -> String { string(el, kAXSubroleAttribute) ?? "" }

    static func pid(_ el: AXUIElement) -> pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(el, &p) == .success ? p : nil
    }

    static func focusedElement() -> AXUIElement? { element(systemWide, kAXFocusedUIElementAttribute) }

    static func value(_ el: AXUIElement) -> String? { string(el, kAXValueAttribute) }

    static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var s: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &s) == .success && s.boolValue
    }

    /// Password boxes and other secure inputs. Inkwell never reads these.
    static func isSecure(_ el: AXUIElement) -> Bool {
        role(el) == "AXSecureTextField" || subrole(el) == (kAXSecureTextFieldSubrole as String)
    }

    /// A field the user can type prose into.
    static func isEditableText(_ el: AXUIElement) -> Bool {
        let r = role(el)
        if [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String, "AXSearchField"].contains(r) {
            return true
        }
        // contenteditable in browsers and Electron apps
        if r == (kAXGroupRole as String) || r == "AXWebArea" {
            return isSettable(el, kAXValueAttribute) || (raw(el, "AXEditableAncestor") != nil && value(el) != nil)
        }
        return false
    }

    static func selectedRange(_ el: AXUIElement) -> NSRange? {
        guard let v = raw(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    static func selectedText(_ el: AXUIElement) -> String? { string(el, kAXSelectedTextAttribute) }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = raw(el, kAXPositionAttribute), let s = raw(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func parameterized(_ el: AXUIElement, _ name: String, _ param: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, name as CFString, param, &v) == .success else { return nil }
        return v
    }

    /// Screen rect (top-left origin, global) of a range of text.
    static func bounds(_ el: AXUIElement, _ range: NSRange) -> CGRect? {
        var cf = CFRange(location: range.location, length: range.length)
        guard let param = AXValueCreate(.cfRange, &cf),
              let v = parameterized(el, kAXBoundsForRangeParameterizedAttribute, param),
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return rect
    }

    static func line(_ el: AXUIElement, forIndex i: Int) -> Int? {
        let n = NSNumber(value: i)
        return parameterized(el, kAXLineForIndexParameterizedAttribute, n) as? Int
    }

    static func range(_ el: AXUIElement, forLine line: Int) -> NSRange? {
        let n = NSNumber(value: line)
        guard let v = parameterized(el, kAXRangeForLineParameterizedAttribute, n), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    /// Address of the web page the element is on (browsers expose it on the AXWebArea).
    static func pageURL(_ el: AXUIElement) -> URL? {
        var cur: AXUIElement? = el
        for _ in 0..<40 {
            guard let c = cur else { return nil }
            if role(c) == "AXWebArea", let u = raw(c, kAXURLAttribute) {
                if let url = u as? URL { return url }
                if let s = u as? String { return URL(string: s) }
            }
            cur = element(c, kAXParentAttribute)
        }
        return nil
    }

    // MARK: Writing

    @discardableResult
    static func setSelectedRange(_ el: AXUIElement, _ range: NSRange) -> Bool {
        var cf = CFRange(location: range.location, length: range.length)
        guard let v = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    @discardableResult
    static func setSelectedText(_ el: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    // MARK: App setup

    private static var prepared = Set<pid_t>()

    /// Chromium and Electron apps (Chrome, Slack, Discord, VS Code…) only build their accessibility tree when asked.
    static func prepare(app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard !prepared.contains(pid) else { return }
        prepared.insert(pid)
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let chromium = ["com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
                        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]
        if let id = app.bundleIdentifier, chromium.contains(id) {
            AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
}

extension CGRect {
    /// AX uses a top-left origin on the primary screen; AppKit uses bottom-left.
    var flippedToCocoa: CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: h - maxY, width: width, height: height)
    }
}
