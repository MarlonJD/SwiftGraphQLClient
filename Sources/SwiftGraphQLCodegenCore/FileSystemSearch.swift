import Foundation

enum FileSystemSearch {
    static func resolve(patterns: [String], relativeTo baseURL: URL) throws -> [URL] {
        var urls: [URL] = []
        for pattern in patterns {
            urls.append(contentsOf: try resolve(pattern: pattern, relativeTo: baseURL))
        }
        return Array(Set(urls)).sorted { $0.path < $1.path }
    }

    private static func resolve(pattern: String, relativeTo baseURL: URL) throws -> [URL] {
        let absolutePattern: String
        if pattern.hasPrefix("/") {
            absolutePattern = pattern
        } else {
            absolutePattern = baseURL.appendingPathComponent(pattern).standardizedFileURL.path
        }

        if !absolutePattern.contains("*") {
            return FileManager.default.fileExists(atPath: absolutePattern) ? [URL(fileURLWithPath: absolutePattern)] : []
        }

        if let range = absolutePattern.range(of: "**") {
            let root = String(absolutePattern[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let suffix = absolutePattern[range.upperBound...]
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let rootPath = "/" + root
            return try recursiveFiles(root: URL(fileURLWithPath: rootPath), suffix: suffix)
        }

        let directory = URL(fileURLWithPath: absolutePattern).deletingLastPathComponent()
        let wildcard = URL(fileURLWithPath: absolutePattern).lastPathComponent
        let suffix = wildcard.replacingOccurrences(of: "*", with: "")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { suffix.isEmpty || $0.lastPathComponent.hasSuffix(suffix) }
    }

    private static func recursiveFiles(root: URL, suffix: String) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            if suffix.isEmpty || url.path.hasSuffix(suffix) {
                urls.append(url)
            }
        }
        return urls
    }
}
