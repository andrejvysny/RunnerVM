import Foundation

/// One stream's retained bytes: the first `limit` and the last `limit`, with a marker where the
/// middle used to be.
///
/// A build's provisioning transcript is tens of megabytes and is streamed to `build.log` as it
/// arrives; keeping all of it in memory a second time only to put it in an error message is how a
/// diagnostic becomes an allocation problem. Both ends are kept because the useful parts of a
/// failed tool run are its first lines (what it was asked to do) and its last (why it stopped).
struct OutputCapture: Sendable {
  private let limit: Int
  private var head = Data()
  private var tail = Data()
  private(set) var total = 0

  init(limit: Int) {
    self.limit = max(0, limit)
  }

  mutating func append(_ bytes: UnsafeRawBufferPointer) {
    total += bytes.count
    var rest = bytes[...]
    if head.count < limit {
      let take = min(limit - head.count, rest.count)
      head.append(contentsOf: rest.prefix(take))
      rest = rest.dropFirst(take)
    }
    guard !rest.isEmpty, limit > 0 else { return }
    tail.append(contentsOf: rest)
    if tail.count > limit { tail.removeFirst(tail.count - limit) }
  }

  var truncated: Bool { total > head.count + tail.count }

  var text: String {
    guard truncated else { return String(decoding: head + tail, as: UTF8.self) }
    let elided = total - head.count - tail.count
    return String(decoding: head, as: UTF8.self)
      + "\n... \(elided) bytes elided ...\n"
      + String(decoding: tail, as: UTF8.self)
  }
}
