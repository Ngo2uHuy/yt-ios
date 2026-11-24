import Foundation

/// Dynamic accessor for InnerTube's deeply nested, frequently changing JSON.
struct J {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }
    init(data: Data) { raw = try? JSONSerialization.jsonObject(with: data) }

    subscript(key: String) -> J { J((raw as? [String: Any])?[key]) }

    subscript(index: Int) -> J {
        guard let a = raw as? [Any], a.indices.contains(index) else { return J(nil) }
        return J(a[index])
    }

    var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    var bool: Bool? { raw as? Bool }
    var array: [J] { (raw as? [Any])?.map { J($0) } ?? [] }
    var isNull: Bool { raw == nil || raw is NSNull }

    /// Text from `{simpleText}`, `{runs:[{text}]}` or `{content}` shapes.
    var text: String? {
        if let s = self["simpleText"].string { return s }
        let runs = self["runs"].array.compactMap { $0["text"].string }
        if !runs.isEmpty { return runs.joined() }
        if let s = self["content"].string { return s }
        return raw as? String
    }

    /// Recursively collects every value stored under one of `keys` (does not descend into matches).
    /// Searching by renderer name survives YouTube moving renderers around in the tree.
    func collect(_ keys: Set<String>) -> [(key: String, value: J)] {
        var out: [(key: String, value: J)] = []
        func walk(_ node: Any) {
            if let d = node as? [String: Any] {
                for (k, v) in d {
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
                for (_, v) in d {
                    if let found = find(v) { return found }
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
