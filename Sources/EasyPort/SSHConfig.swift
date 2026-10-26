import Foundation

/// ~/.ssh/config에서 와일드카드가 아닌 Host 별칭을 읽는다. Include 지시문도 따라간다.
enum SSHConfig {
    static func hostNames() -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        parse(file: NSHomeDirectory() + "/.ssh/config", depth: 0) { name in
            if seen.insert(name).inserted { names.append(name) }
        }
        return names
    }

    private static func parse(file: String, depth: Int, emit: (String) -> Void) {
        guard depth < 8, let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].lowercased() {
            case "host":
                for name in value.split(separator: " ")
                where !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") {
                    emit(String(name).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
                }
            case "include":
                for pattern in value.split(separator: " ") {
                    for path in expand(String(pattern)) {
                        parse(file: path, depth: depth + 1, emit: emit)
                    }
                }
            default:
                break
            }
        }
    }

    private static func expand(_ pattern: String) -> [String] {
        var path = pattern
        if path.hasPrefix("~") {
            path = NSHomeDirectory() + path.dropFirst()
        } else if !path.hasPrefix("/") {
            path = NSHomeDirectory() + "/.ssh/" + path
        }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(path, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_pathc)).compactMap { g.gl_pathv[$0].map { String(cString: $0) } }
    }
}
