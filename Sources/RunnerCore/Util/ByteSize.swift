import Foundation

/// A byte count that reads and writes as a human string ("8GiB") but is exact internally.
///
/// Config files are edited by humans, yet capacity math must be integral: a `Double` GiB value
/// would silently drift when multiplied out, so parsing resolves to `UInt64` immediately.
public struct ByteSize: Hashable, Sendable, Comparable, CustomStringConvertible {
  public let bytes: UInt64

  public init(bytes: UInt64) {
    self.bytes = bytes
  }

  public static func < (lhs: ByteSize, rhs: ByteSize) -> Bool { lhs.bytes < rhs.bytes }

  public static func kibibytes(_ value: UInt64) -> ByteSize { ByteSize(bytes: value * Unit.kib.factor) }
  public static func mebibytes(_ value: UInt64) -> ByteSize { ByteSize(bytes: value * Unit.mib.factor) }
  public static func gibibytes(_ value: UInt64) -> ByteSize { ByteSize(bytes: value * Unit.gib.factor) }
  public static func tebibytes(_ value: UInt64) -> ByteSize { ByteSize(bytes: value * Unit.tib.factor) }

  public static let zero = ByteSize(bytes: 0)

  // MARK: - Units

  /// Ordered largest-first; `parse` matches the longest suffix so "GiB" wins over "B".
  enum Unit: String, CaseIterable {
    case pib = "PiB", tib = "TiB", gib = "GiB", mib = "MiB", kib = "KiB"
    case pb = "PB", tb = "TB", gb = "GB", mb = "MB", kb = "KB"
    case b = "B"

    var factor: UInt64 {
      switch self {
      case .kib: 1 << 10
      case .mib: 1 << 20
      case .gib: 1 << 30
      case .tib: 1 << 40
      case .pib: 1 << 50
      case .kb: 1_000
      case .mb: 1_000_000
      case .gb: 1_000_000_000
      case .tb: 1_000_000_000_000
      case .pb: 1_000_000_000_000_000
      case .b: 1
      }
    }

    var isBinary: Bool {
      switch self {
      case .kib, .mib, .gib, .tib, .pib: true
      default: false
      }
    }
  }

  // MARK: - Parsing

  public struct ParseError: Error, Hashable, Sendable, CustomStringConvertible {
    public let input: String
    public var description: String { "invalid byte size '\(input)'" }
  }

  public init(parsing text: String) throws {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw ParseError(input: text) }
    let unit = Unit.allCases.first { trimmed.lowercased().hasSuffix($0.rawValue.lowercased()) }
    let numberPart = unit.map { String(trimmed.dropLast($0.rawValue.count)) } ?? trimmed
    let number = numberPart.trimmingCharacters(in: .whitespaces)
    guard !number.isEmpty else { throw ParseError(input: text) }
    let factor = unit?.factor ?? 1
    if let whole = UInt64(number) {
      let (product, overflow) = whole.multipliedReportingOverflow(by: factor)
      guard !overflow else { throw ParseError(input: text) }
      self.init(bytes: product)
      return
    }
    self.init(bytes: try Self.fractionalBytes(number, factor: factor, input: text))
  }

  /// "1.5GiB" style values: exact only when the fraction lands on a whole byte.
  private static func fractionalBytes(_ number: String, factor: UInt64, input: String) throws -> UInt64 {
    let parts = number.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let whole = UInt64(parts[0]), !parts[1].isEmpty,
          parts[1].allSatisfy(\.isNumber), let fractionDigits = UInt64(parts[1])
    else { throw ParseError(input: input) }
    var scale: UInt64 = 1
    for _ in 0..<parts[1].count {
      let (next, overflow) = scale.multipliedReportingOverflow(by: 10)
      guard !overflow else { throw ParseError(input: input) }
      scale = next
    }
    let (wholeBytes, o1) = whole.multipliedReportingOverflow(by: factor)
    let (scaled, o2) = fractionDigits.multipliedReportingOverflow(by: factor)
    guard !o1, !o2, scaled % scale == 0 else { throw ParseError(input: input) }
    let (total, o3) = wholeBytes.addingReportingOverflow(scaled / scale)
    guard !o3 else { throw ParseError(input: input) }
    return total
  }

  // MARK: - Formatting

  /// Largest binary unit that divides the byte count exactly, so `parse(format(x)) == x` always.
  public var description: String {
    guard bytes > 0 else { return "0B" }
    for unit in Unit.allCases where unit.isBinary && bytes % unit.factor == 0 {
      return "\(bytes / unit.factor)\(unit.rawValue)"
    }
    return "\(bytes)B"
  }
}

extension ByteSize: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    do {
      try self.init(parsing: text)
    } catch {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid byte size '\(text)'")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}
