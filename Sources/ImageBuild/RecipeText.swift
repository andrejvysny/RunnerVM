/// Line-oriented text helpers shared by the parser and planner: whitespace/quote tokenizing and
/// `${VAR}` interpolation. Kept free of parser/planner state so both can reuse it without coupling.
enum RecipeText {
  /// Splits on whitespace, treating `"..."`/`'...'` runs (with `\"`/`\'` escapes for the matching
  /// quote) as a single token even when they contain spaces. Used for FROM flags, COPY operands,
  /// and ENV/LABEL `key=value` lists.
  static func tokenize(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var quote: Character?
    let chars = Array(text)
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if let q = quote {
        if c == "\\", i + 1 < chars.count, chars[i + 1] == q {
          current.append(q)
          i += 2
          continue
        }
        if c == q {
          quote = nil
          i += 1
          continue
        }
        current.append(c)
        i += 1
        continue
      }
      if c == "\"" || c == "'" {
        quote = c
        i += 1
        continue
      }
      if c.isWhitespace {
        if !current.isEmpty {
          tokens.append(current)
          current = ""
        }
        i += 1
        continue
      }
      current.append(c)
      i += 1
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
  }

  /// Expands `${NAME}`, `$NAME`, and `\$` (a literal dollar sign) in `text`. `resolve` is called for
  /// every referenced name; whatever it throws propagates, so callers pick the right error (an
  /// undeclared name vs. a declared-but-unresolved one).
  static func interpolate(_ text: String, resolve: (String) throws -> String) throws -> String {
    var result = ""
    let chars = Array(text)
    var i = 0
    while i < chars.count {
      let c = chars[i]
      if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" {
        result.append("$")
        i += 2
        continue
      }
      if c != "$" {
        result.append(c)
        i += 1
        continue
      }
      i += 1
      if i < chars.count, chars[i] == "{" {
        i += 1
        let start = i
        while i < chars.count, chars[i] != "}" { i += 1 }
        guard i < chars.count else {
          throw InterpolationError.unterminatedBrace(String(chars[start...]))
        }
        let name = String(chars[start..<i])
        i += 1
        result += try resolve(name)
        continue
      }
      let start = i
      while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" { i += 1 }
      guard i > start else {
        result.append("$")
        continue
      }
      result += try resolve(String(chars[start..<i]))
    }
    return result
  }

  enum InterpolationError: Error, Sendable, Equatable {
    case unterminatedBrace(String)
  }
}
