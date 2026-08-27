import Foundation

/// A minimal `.gitignore`-alike for trimming the build context before it is tarred into the guest:
/// `#` comments, a trailing `/` for directory-only patterns, a leading `/` to anchor to the context
/// root, `*`/`**` globs, and `!` negation. `.git/` is always excluded, unconditionally.
public struct RecipeIgnore: Sendable {
  public static let fileName = ".runnerignore"

  private var patterns: [Pattern]

  private struct Pattern: Sendable {
    var negated: Bool
    var dirOnly: Bool
    var segments: [String]
  }

  private init(patterns: [Pattern]) {
    self.patterns = patterns
  }

  public static func parse(_ text: String) -> RecipeIgnore {
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    let patterns = normalized.components(separatedBy: "\n").compactMap(parsePattern)
    return RecipeIgnore(patterns: patterns)
  }

  private static func parsePattern(_ rawLine: String) -> Pattern? {
    var line = rawLine.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
    var negated = false
    if line.hasPrefix("!") {
      negated = true
      line = String(line.dropFirst())
    }
    var dirOnly = false
    if line.hasSuffix("/") {
      dirOnly = true
      line = String(line.dropLast())
    }
    guard !line.isEmpty else { return nil }
    let rootAnchored = line.hasPrefix("/")
    if rootAnchored { line = String(line.dropFirst()) }
    var segments = line.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    // A pattern with no slash at all (other than the trailing one already stripped) matches at any
    // depth, like `**/name`; one with an internal slash is anchored to the context root.
    if !rootAnchored, segments.count <= 1 { segments = ["**"] + segments }
    return Pattern(negated: negated, dirOnly: dirOnly, segments: segments)
  }

  /// `relativePath` is relative to the build context root, `/`-separated, no leading slash needed
  /// (one is tolerated). Ancestor directories are checked too: once a directory matches an
  /// exclude pattern, everything under it is excluded, matching real gitignore semantics -- a
  /// deeper negation cannot resurrect a file whose parent directory is already excluded.
  public func excludes(relativePath: String, isDirectory: Bool) -> Bool {
    let normalized = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !normalized.isEmpty else { return false }
    if normalized == ".git" || normalized.hasPrefix(".git/") { return true }

    let segments = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    for depth in 1...segments.count {
      let ancestorIsDirectory = depth < segments.count || isDirectory
      if isExcludedAtThisLevel(Array(segments.prefix(depth)), isDirectory: ancestorIsDirectory) {
        return true
      }
    }
    return false
  }

  private func isExcludedAtThisLevel(_ pathSegments: [String], isDirectory: Bool) -> Bool {
    var excluded = false
    for pattern in patterns where !pattern.dirOnly || isDirectory {
      if Self.matchesSegments(pathSegments, pattern.segments) {
        excluded = !pattern.negated
      }
    }
    return excluded
  }

  // MARK: - Glob matching

  private static func matchesSegments(_ path: [String], _ pattern: [String]) -> Bool {
    guard let firstPattern = pattern.first else { return path.isEmpty }
    if firstPattern == "**" {
      let rest = Array(pattern.dropFirst())
      if matchesSegments(path, rest) { return true }
      guard let firstPath = path.first else { return false }
      _ = firstPath
      return matchesSegments(Array(path.dropFirst()), pattern)
    }
    guard let firstPath = path.first, segmentMatches(firstPath, firstPattern) else { return false }
    return matchesSegments(Array(path.dropFirst()), Array(pattern.dropFirst()))
  }

  /// Classic greedy `*`/`?` wildcard matching within a single path segment (never crosses `/`).
  private static func segmentMatches(_ text: String, _ pattern: String) -> Bool {
    let t = Array(text)
    let p = Array(pattern)
    var ti = 0, pi = 0, starIdx = -1, matchIdx = 0
    while ti < t.count {
      if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
        ti += 1
        pi += 1
      } else if pi < p.count, p[pi] == "*" {
        starIdx = pi
        matchIdx = ti
        pi += 1
      } else if starIdx != -1 {
        pi = starIdx + 1
        matchIdx += 1
        ti = matchIdx
      } else {
        return false
      }
    }
    while pi < p.count, p[pi] == "*" { pi += 1 }
    return pi == p.count
  }
}
