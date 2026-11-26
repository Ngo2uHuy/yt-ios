import CoreFoundation
import Foundation

/// Dynamic accessor for InnerTube's deeply nested, frequently changing JSON.
struct J: @unchecked Sendable {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }
    init(data: Data) { raw = try? JSONSerialization.jsonObject(with: data) }

    subscript(key: String) -> J { J((raw as? [String: Any])?[key]) }

    subscript(index: Int) -> J {
        guard let a = raw as? [Any], a.indices.contains(index) else { return J(nil) }
        return J(a[index])
    }

    private var boolNSNumber: Bool? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }

    var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.stringValue
        }
        return nil
    }

    var int: Int? {
        if let n = raw as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            if let exact = Int(exactly: n) { return exact }
            let d = n.doubleValue
            guard d.isFinite, d >= Double(Int.min), d <= Double(Int.max) else { return nil }
            return Int(d)
        }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    var double: Double? {
        if let n = raw as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        if let s = raw as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }

    var bool: Bool? {
        if let b = boolNSNumber { return b }
        if raw is NSNumber { return nil }
        return raw as? Bool
    }

    var array: [J] { (raw as? [Any])?.map { J($0) } ?? [] }
    var isNull: Bool { raw == nil || raw is NSNull }

    /// Text from `{simpleText}`, `{runs:[{text}]}` or `{content}` shapes.
    var text: String? {
        if let s = self["simpleText"].string { return s }
        let runs = self["runs"].array.compactMap { $0["text"].string }
        if !runs.isEmpty { return runs.joined() }
        if let s = self["content"].string { return s }
        return string
    }

    /// Recursively collects every value stored under one of `keys` (does not descend into matches).
    /// Dictionary keys are visited in sorted order so traversal is deterministic across sibling keys.
    func collect(_ keys: Set<String>) -> [(key: String, value: J)] {
        var out: [(key: String, value: J)] = []
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                for k in d.keys.sorted() {
                    guard let v = d[k] else { continue }
                    if keys.contains(k) { out.append((k, J(v))) } else { walk(v) }
                }
            } else if let a = node as? [Any] {
                for v in a { walk(v) }
            }
        }
        if let raw { walk(raw) }
        return out
    }

    func first(_ key: String) -> J? {
        func find(_ node: Any) -> J? {
            if let d = node as? [String: Any] {
                if let v = d[key] { return J(v) }
                for k in d.keys.sorted() {
                    if let v = d[k], let found = find(v) { return found }
                }
            } else if let a = node as? [Any] {
                for v in a {
                    if let found = find(v) { return found }
                }
            }
            return nil
        }
        guard let raw else { return nil }
        return find(raw)
    }
}
