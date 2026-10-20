// Helpers that reproduce the exact output of the original Python exporters
// (json.loads/str()/repr()/json.dumps/slugify/strip). Sync compares rendered
// Markdown byte-for-byte against what's on disk, so any drift here would make
// every sync rewrite every file.
import Foundation

// MARK: - JSON (order-preserving, keeps Python's int/float distinction)

enum JSON {
    case string(String)
    case int(String)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSON])
    case object(keys: [String], values: [JSON])  // parallel arrays keep insertion order

    subscript(key: String) -> JSON? {
        guard case .object(let keys, let values) = self, let i = keys.firstIndex(of: key) else { return nil }
        return values[i]
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    var truthy: Bool {
        switch self {
        case .string(let s): return !s.isEmpty
        case .int(let t): return t != "0"
        case .double(let d): return d != 0
        case .bool(let b): return b
        case .null: return false
        case .array(let a): return !a.isEmpty
        case .object(let k, _): return !k.isEmpty
        }
    }
}

struct JSONParser {
    struct Fail: Error {}
    let b: UnsafeBufferPointer<UInt8>
    var i: Int
    let end: Int

    static func parse(_ b: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) -> JSON? {
        var p = JSONParser(b: b, i: start, end: end)
        do {
            p.ws()
            let v = try p.value()
            p.ws()
            return p.i == end ? v : nil
        } catch {
            return nil
        }
    }

    static func parse(_ s: String) -> JSON? {
        let bytes = Array(s.utf8)
        return bytes.withUnsafeBufferPointer { parse($0, 0, $0.count) }
    }

    mutating func ws() {
        while i < end, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
    }

    mutating func lit(_ s: StaticString) throws {
        let n = s.utf8CodeUnitCount
        guard i + n <= end else { throw Fail() }
        let p = s.utf8Start
        for k in 0..<n where b[i + k] != p[k] { throw Fail() }
        i += n
    }

    mutating func value() throws -> JSON {
        guard i < end else { throw Fail() }
        switch b[i] {
        case 0x7B: return try object()
        case 0x5B: return try array()
        case 0x22: return .string(try string())
        case 0x74: try lit("true"); return .bool(true)
        case 0x66: try lit("false"); return .bool(false)
        case 0x6E: try lit("null"); return .null
        case 0x4E: try lit("NaN"); return .double(.nan)
        case 0x49: try lit("Infinity"); return .double(.infinity)
        case 0x2D, 0x30...0x39: return try number()
        default: throw Fail()
        }
    }

    func isDigit(_ k: Int) -> Bool { k < end && b[k] >= 0x30 && b[k] <= 0x39 }

    mutating func number() throws -> JSON {
        let start = i
        if b[i] == 0x2D {
            i += 1
            if i < end, b[i] == 0x49 { try lit("Infinity"); return .double(-.infinity) }
        }
        guard isDigit(i) else { throw Fail() }
        if b[i] == 0x30 { i += 1 } else { while isDigit(i) { i += 1 } }
        var isFloat = false
        if i < end, b[i] == 0x2E, isDigit(i + 1) {
            isFloat = true
            i += 1
            while isDigit(i) { i += 1 }
        }
        if i < end, b[i] == 0x65 || b[i] == 0x45 {
            var j = i + 1
            if j < end, b[j] == 0x2B || b[j] == 0x2D { j += 1 }
            if isDigit(j) {
                isFloat = true
                i = j
                while isDigit(i) { i += 1 }
            }
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
        if isFloat { return .double(Double(text) ?? .nan) }
        return .int(text == "-0" ? "0" : text)
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= end else { throw Fail() }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = b[i]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw Fail()
            }
            v = v * 16 + d
            i += 1
        }
        return v
    }

    mutating func string() throws -> String {
        i += 1
        var start = i
        var buf: [UInt8]? = nil
        while true {
            guard i < end else { throw Fail() }
            let c = b[i]
            if c == 0x22 {
                let s: String
                if var bb = buf {
                    bb.append(contentsOf: UnsafeBufferPointer(rebasing: b[start..<i]))
                    s = String(decoding: bb, as: UTF8.self)
                } else {
                    s = String(decoding: UnsafeBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
                }
                i += 1
                return s
            }
            if c < 0x20 { throw Fail() }
            if c == 0x5C {
                if buf == nil { buf = [] }
                buf!.append(contentsOf: UnsafeBufferPointer(rebasing: b[start..<i]))
                i += 1
                guard i < end else { throw Fail() }
                let e = b[i]
                i += 1
                switch e {
                case 0x22: buf!.append(0x22)
                case 0x5C: buf!.append(0x5C)
                case 0x2F: buf!.append(0x2F)
                case 0x62: buf!.append(0x08)
                case 0x66: buf!.append(0x0C)
                case 0x6E: buf!.append(0x0A)
                case 0x72: buf!.append(0x0D)
                case 0x74: buf!.append(0x09)
                case 0x75:
                    var u = try hex4()
                    if (0xD800...0xDBFF).contains(u), i + 6 <= end, b[i] == 0x5C, b[i + 1] == 0x75 {
                        let save = i
                        i += 2
                        let u2 = try hex4()
                        if (0xDC00...0xDFFF).contains(u2) {
                            u = 0x10000 + ((u - 0xD800) << 10) + (u2 - 0xDC00)
                        } else {
                            i = save
                        }
                    }
                    let scalar = Unicode.Scalar(u) ?? "\u{FFFD}"
                    buf!.append(contentsOf: Array(String(scalar).utf8))
                default:
                    throw Fail()
                }
                start = i
                continue
            }
            i += 1
        }
    }

    mutating func object() throws -> JSON {
        i += 1
        ws()
        var keys: [String] = []
        var values: [JSON] = []
        if i < end, b[i] == 0x7D { i += 1; return .object(keys: [], values: []) }
        while true {
            guard i < end, b[i] == 0x22 else { throw Fail() }
            let k = try string()
            ws()
            guard i < end, b[i] == 0x3A else { throw Fail() }
            i += 1
            ws()
            let v = try value()
            // Duplicate key: Python keeps the first position, last value.
            if let idx = keys.firstIndex(of: k) { values[idx] = v } else { keys.append(k); values.append(v) }
            ws()
            guard i < end else { throw Fail() }
            if b[i] == 0x2C { i += 1; ws(); continue }
            if b[i] == 0x7D { i += 1; return .object(keys: keys, values: values) }
            throw Fail()
        }
    }

    mutating func array() throws -> JSON {
        i += 1
        ws()
        var items: [JSON] = []
        if i < end, b[i] == 0x5D { i += 1; return .array([]) }
        while true {
            items.append(try value())
            ws()
            guard i < end else { throw Fail() }
            if b[i] == 0x2C { i += 1; ws(); continue }
            if b[i] == 0x5D { i += 1; return .array(items) }
            throw Fail()
        }
    }
}

/// Iterates JSONL like Python's `for line in open(...)`: universal newlines,
/// `line.strip()`, `json.loads`, skipping undecodable lines. Return false to stop.
func forEachJSONLine(_ data: Data, _ body: (JSON) -> Bool) {
    data.withUnsafeBytes { raw in
        let b = raw.bindMemory(to: UInt8.self)
        let n = b.count
        var stop = false

        func asciiSpace(_ c: UInt8) -> Bool {
            (c >= 0x09 && c <= 0x0D) || (c >= 0x1C && c <= 0x20)
        }

        func handle(_ s: Int, _ e: Int) {
            guard s < e, !stop else { return }
            let parsed: JSON?
            if b[s] < 0x80, !asciiSpace(b[s]), b[e - 1] < 0x80, !asciiSpace(b[e - 1]) {
                parsed = JSONParser.parse(b, s, e)
            } else {
                let stripped = pyStrip(String(decoding: UnsafeBufferPointer(rebasing: b[s..<e]), as: UTF8.self))
                if stripped.isEmpty { return }
                parsed = JSONParser.parse(stripped)
            }
            if let v = parsed, v.isObject, !body(v) { stop = true }
        }

        var lineStart = 0
        var i = 0
        while i < n && !stop {
            let c = b[i]
            if c == 0x0A || c == 0x0D {
                handle(lineStart, i)
                if c == 0x0D, i + 1 < n, b[i + 1] == 0x0A { i += 1 }
                i += 1
                lineStart = i
            } else {
                i += 1
            }
        }
        if lineStart < n { handle(lineStart, n) }
    }
}

func parseJSONL(_ url: URL) -> [JSON] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    var out: [JSON] = []
    forEachJSONLine(data) { out.append($0); return true }
    return out
}

// MARK: - Python str() / repr() / json.dumps()

func pyStr(_ v: JSON) -> String {
    switch v {
    case .string(let s): return s
    case .int(let t): return t
    case .double(let d): return pyFloatRepr(d)
    case .bool(let b): return b ? "True" : "False"
    case .null: return "None"
    case .array, .object: return pyRepr(v)
    }
}

func pyRepr(_ v: JSON) -> String {
    switch v {
    case .string(let s): return pyReprString(s)
    case .array(let a): return "[" + a.map(pyRepr).joined(separator: ", ") + "]"
    case .object(let k, let vals): return "{" + zip(k, vals).map { pyReprString($0) + ": " + pyRepr($1) }.joined(separator: ", ") + "}"
    default: return pyStr(v)
    }
}

private let hexDigits = Array("0123456789abcdef")

private func hex(_ v: UInt32, _ width: Int) -> String {
    var out = ""
    for shift in stride(from: (width - 1) * 4, through: 0, by: -4) {
        out.append(hexDigits[Int((v >> UInt32(shift)) & 0xF)])
    }
    return out
}

private func pyIsPrintable(_ sc: Unicode.Scalar) -> Bool {
    if sc.value == 0x20 { return true }
    switch sc.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned,
         .lineSeparator, .paragraphSeparator, .spaceSeparator:
        return false
    default:
        return true
    }
}

func pyReprString(_ s: String) -> String {
    let hasSingle = s.unicodeScalars.contains("'")
    let hasDouble = s.unicodeScalars.contains("\"")
    let quote: Unicode.Scalar = (hasSingle && !hasDouble) ? "\"" : "'"
    var out = String(quote)
    for sc in s.unicodeScalars {
        let c = sc.value
        if sc == quote || sc == "\\" {
            out += "\\" + String(sc)
        } else if sc == "\t" {
            out += "\\t"
        } else if sc == "\n" {
            out += "\\n"
        } else if sc == "\r" {
            out += "\\r"
        } else if c < 0x20 || c == 0x7F {
            out += "\\x" + hex(c, 2)
        } else if c < 0x7F {
            out.unicodeScalars.append(sc)
        } else if !pyIsPrintable(sc) {
            if c <= 0xFF { out += "\\x" + hex(c, 2) }
            else if c <= 0xFFFF { out += "\\u" + hex(c, 4) }
            else { out += "\\U" + hex(c, 8) }
        } else {
            out.unicodeScalars.append(sc)
        }
    }
    out.unicodeScalars.append(quote)
    return out
}

/// Python's repr(float): shortest round-trip digits, fixed notation when
/// -4 < decimal exponent <= 16, otherwise scientific with a 2+ digit exponent.
func pyFloatRepr(_ d: Double) -> String {
    if d.isNaN { return "nan" }
    if d.isInfinite { return d < 0 ? "-inf" : "inf" }
    if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
    let swiftText = "\(abs(d))"
    let parts = swiftText.split(separator: "e", maxSplits: 1)
    let mantissa = String(parts[0])
    let exp = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    let mParts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    let intPart = String(mParts[0])
    let fracPart = mParts.count > 1 ? String(mParts[1]) : ""
    var digits = Array(intPart + fracPart)
    var decpt = intPart.count + exp
    while digits.first == "0" { digits.removeFirst(); decpt -= 1 }
    while digits.last == "0" { digits.removeLast() }
    let sign = d < 0 ? "-" : ""
    if decpt <= -4 || decpt > 16 {
        let e = decpt - 1
        var m = String(digits[0])
        if digits.count > 1 { m += "." + String(digits[1...]) }
        let eAbs = abs(e)
        return sign + m + "e" + (e < 0 ? "-" : "+") + (eAbs < 10 ? "0" : "") + String(eAbs)
    }
    if decpt <= 0 { return sign + "0." + String(repeating: "0", count: -decpt) + String(digits) }
    if decpt >= digits.count { return sign + String(digits) + String(repeating: "0", count: decpt - digits.count) + ".0" }
    return sign + String(digits[..<decpt]) + "." + String(digits[decpt...])
}

/// json.dumps(str) with ensure_ascii=True.
func pyJSONDumps(_ s: String) -> String {
    var out = "\""
    for sc in s.unicodeScalars {
        let c = sc.value
        switch sc {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if c >= 0x20 && c <= 0x7E {
                out.unicodeScalars.append(sc)
            } else if c < 0x10000 {
                out += "\\u" + hex(c, 4)
            } else {
                let v = c - 0x10000
                out += "\\u" + hex(0xD800 + (v >> 10), 4) + "\\u" + hex(0xDC00 + (v & 0x3FF), 4)
            }
        }
    }
    return out + "\""
}

// MARK: - Python str methods (code-point based)

func isPySpace(_ c: UInt32) -> Bool {
    switch c {
    case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
         0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
        return true
    default:
        return false
    }
}

func pyStrip(_ s: String) -> String {
    let u = s.unicodeScalars
    guard let f = u.first, let l = u.last else { return s }
    if !isPySpace(f.value) && !isPySpace(l.value) { return s }
    let sc = Array(u)
    var a = 0, z = sc.count
    while a < z, isPySpace(sc[a].value) { a += 1 }
    while z > a, isPySpace(sc[z - 1].value) { z -= 1 }
    return scalarsToString(sc[a..<z])
}

func scalarsToString<S: Sequence>(_ s: S) -> String where S.Element == Unicode.Scalar {
    var v = String.UnicodeScalarView()
    v.append(contentsOf: s)
    return String(v)
}

func pyLen(_ s: String) -> Int { s.unicodeScalars.count }
func pyPrefix(_ s: String, _ n: Int) -> String { scalarsToString(s.unicodeScalars.prefix(n)) }
func pySuffix(_ s: String, _ n: Int) -> String { scalarsToString(s.unicodeScalars.suffix(n)) }

private func isPyWord(_ sc: Unicode.Scalar) -> Bool {
    if sc == "_" { return true }
    switch sc.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
        return true
    default:
        return sc.properties.numericType != nil
    }
}

func slugify(_ text: String, maxLen: Int = 45) -> String {
    let lowered = pyStrip(text.lowercased())
    var collapsed: [Unicode.Scalar] = []
    for sc in lowered.unicodeScalars {
        let space = isPySpace(sc.value)
        guard space || sc == "-" || isPyWord(sc) else { continue }
        let dash = space || sc == "_" || sc == "-"
        if dash {
            if collapsed.last != "-" { collapsed.append("-") }
        } else {
            collapsed.append(sc)
        }
    }
    while collapsed.first == "-" { collapsed.removeFirst() }
    while collapsed.last == "-" { collapsed.removeLast() }
    var cut = Array(collapsed.prefix(maxLen))
    while cut.last == "-" { cut.removeLast() }
    return scalarsToString(cut)
}

// MARK: - Timestamps

struct Stamp {
    let date: String        // %Y-%m-%d
    let dateTime: String    // %Y-%m-%d %H:%M
    let hourMinDash: String // %H-%M

    init(y: Int, mo: Int, d: Int, h: Int, mi: Int) {
        date = String(format: "%04d-%02d-%02d", y, mo, d)
        dateTime = date + String(format: " %02d:%02d", h, mi)
        hourMinDash = String(format: "%02d-%02d", h, mi)
    }

    init(local: Date) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: local)
        self.init(y: c.year!, mo: c.month!, d: c.day!, h: c.hour!, mi: c.minute!)
    }

    /// datetime.fromisoformat(ts.replace("Z", "+00:00")) then strftime — an
    /// aware datetime prints its own wall-clock fields, so no TZ conversion.
    init?(iso raw: String) {
        let s = Array(raw.replacingOccurrences(of: "Z", with: "+00:00").unicodeScalars)
        func num(_ at: Int, _ n: Int) -> Int? {
            guard at >= 0, at + n <= s.count else { return nil }
            var v = 0
            for k in at..<(at + n) {
                let c = s[k].value
                guard c >= 0x30 && c <= 0x39 else { return nil }
                v = v * 10 + Int(c - 0x30)
            }
            return v
        }
        guard s.count >= 10, let y = num(0, 4), s[4] == "-", let mo = num(5, 2), s[7] == "-", let d = num(8, 2),
              y >= 1, (1...12).contains(mo) else { return nil }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let dim = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][mo - 1]
        guard (1...dim).contains(d) else { return nil }
        if s.count == 10 { self.init(y: y, mo: mo, d: d, h: 0, mi: 0); return }

        var p = 11
        guard let h = num(p, 2), h <= 23 else { return nil }
        p += 2
        var mi = 0
        func field() -> Int? {
            if p < s.count, s[p] == ":" { if let v = num(p + 1, 2) { p += 3; return v }; return nil }
            if let v = num(p, 2) { p += 2; return v }
            return nil
        }
        if p < s.count, s[p] != "+", s[p] != "-" {
            guard let m = field(), m <= 59 else { return nil }
            mi = m
            if p < s.count, s[p] != "+", s[p] != "-" {
                guard let sec = field(), sec <= 59 else { return nil }
                if p < s.count, s[p] == "." || s[p] == "," {
                    p += 1
                    guard num(p, 1) != nil else { return nil }
                    while num(p, 1) != nil { p += 1 }
                }
            }
        }
        if p < s.count, s[p] == "+" || s[p] == "-" {
            p += 1
            guard let th = num(p, 2), th <= 23 else { return nil }
            p += 2
            if p < s.count {
                guard let tm = field(), tm <= 59 else { return nil }
                if p < s.count {
                    guard field() != nil else { return nil }
                    if p < s.count, s[p] == "." {
                        p += 1
                        while num(p, 1) != nil { p += 1 }
                    }
                }
            }
        }
        guard p == s.count else { return nil }
        self.init(y: y, mo: mo, d: d, h: h, mi: mi)
    }
}

func nowString() -> String { Stamp(local: Date()).dateTime }

// MARK: - Filesystem (mirrors pathlib semantics)

/// readdir order, like os.scandir — FileManager doesn't guarantee it.
func listDir(_ url: URL) -> [String] {
    guard let dir = opendir(url.path) else { return [] }
    defer { closedir(dir) }
    var names: [String] = []
    while let ent = readdir(dir) {
        let name = withUnsafePointer(to: ent.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.pointee.d_namlen) + 1) { String(cString: $0) }
        }
        if name != "." && name != ".." { names.append(name) }
    }
    return names
}

/// sorted(Path.iterdir()) — code-point order, not Swift's canonical ordering.
func pySorted(_ names: [String]) -> [String] {
    names.sorted { a, b in
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }
}

func isDir(_ url: URL) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

func mtime(_ url: URL) -> Double {
    var st = stat()
    guard stat(url.path, &st) == 0 else { return 0 }
    return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
}

/// Path.read_text(): universal newlines.
func readText(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

func head800(_ url: URL) -> String {
    guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? h.close() }
    return String(decoding: h.readData(ofLength: 800), as: UTF8.self)
}

func writeText(_ url: URL, _ s: String) {
    try? Data(s.utf8).write(to: url)
}

func appendText(_ url: URL, _ s: String) {
    guard let h = try? FileHandle(forWritingTo: url) else { return }
    defer { try? h.close() }
    h.seekToEndOfFile()
    h.write(Data(s.utf8))
}

func mkdirs(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

func firstMatch(_ pattern: String, in s: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = s as NSString
    guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
    return ns.substring(with: m.range(at: 1))
}

func sameBytes(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
