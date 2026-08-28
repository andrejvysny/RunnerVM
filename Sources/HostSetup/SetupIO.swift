import Foundation

/// The wizard's whole view of the terminal. Everything `SetupWizard` and `HostInstaller` print or
/// ask goes through this, so a transcript test is the wizard's test.
public protocol SetupIO: Sendable {
  func say(_ text: String)
  /// A free-text answer; empty input takes `default` when one is offered.
  func ask(_ prompt: String, default: String?) -> String
  /// Same, with terminal echo off.
  func askSecret(_ prompt: String) -> String
  func confirm(_ prompt: String, default: Bool) -> Bool
  /// Returns the index of the chosen option.
  func choose(_ prompt: String, options: [String], default: Int) -> Int
}

extension SetupIO {
  public func ask(_ prompt: String) -> String { ask(prompt, default: nil) }

  /// A blank line, for separating wizard sections.
  public func blank() { say("") }

  public func heading(_ text: String) {
    say("")
    say(text)
    say(String(repeating: "-", count: text.count))
  }
}

/// stdin/stdout, with `askSecret` reading through `/dev/tty` with `ECHO` off.
///
/// Reading the secret from `/dev/tty` rather than stdin is deliberate: `setup` may itself have been
/// piped a script, and a PAT must never be echoed into a terminal transcript or a scrollback
/// buffer either way.
public struct TTYSetupIO: SetupIO {
  /// Raw output: no newline is appended, so a prompt and the answer typed after it stay on one
  /// line. `say` adds the newline itself.
  private let write: @Sendable (String) -> Void

  public init(
    write: @escaping @Sendable (String) -> Void = {
      FileHandle.standardOutput.write(Data($0.utf8))
    }
  ) {
    self.write = write
  }

  public func say(_ text: String) { write(text + "\n") }

  private func prompt(_ text: String) { write(text) }

  public func ask(_ prompt: String, default defaultValue: String?) -> String {
    let suffix = defaultValue.map { " [\($0)]" } ?? ""
    self.prompt("\(prompt)\(suffix): ")
    let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
    if answer.isEmpty, let defaultValue { return defaultValue }
    return answer
  }

  public func askSecret(_ prompt: String) -> String {
    self.prompt("\(prompt) (input hidden, empty to skip): ")
    guard let tty = fopen("/dev/tty", "r") else {
      // No controlling terminal: fall back to plain stdin rather than refusing to run at all.
      return (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
    }
    defer { fclose(tty) }
    let descriptor = fileno(tty)
    var original = termios()
    let restorable = tcgetattr(descriptor, &original) == 0
    if restorable {
      var quiet = original
      quiet.c_lflag &= ~tcflag_t(ECHO)
      _ = tcsetattr(descriptor, TCSAFLUSH, &quiet)
    }
    defer {
      if restorable {
        var restore = original
        _ = tcsetattr(descriptor, TCSAFLUSH, &restore)
        // The Return the operator pressed was never echoed; close the line ourselves.
        say("")
      }
    }
    var buffer = [CChar](repeating: 0, count: 1_024)
    guard fgets(&buffer, Int32(buffer.count), tty) != nil else { return "" }
    return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func confirm(_ prompt: String, default defaultValue: Bool) -> Bool {
    let hint = defaultValue ? "Y/n" : "y/N"
    while true {
      self.prompt("\(prompt) [\(hint)]: ")
      let answer = (readLine(strippingNewline: true) ?? "")
        .trimmingCharacters(in: .whitespaces).lowercased()
      switch answer {
      case "": return defaultValue
      case "y", "yes": return true
      case "n", "no": return false
      default: say("please answer y or n")
      }
    }
  }

  public func choose(_ prompt: String, options: [String], default defaultIndex: Int) -> Int {
    guard !options.isEmpty else { return 0 }
    say(prompt)
    for (index, option) in options.enumerated() {
      say("  \(index + 1)) \(option)\(index == defaultIndex ? "  (recommended)" : "")")
    }
    while true {
      self.prompt("choice [\(defaultIndex + 1)]: ")
      let answer = (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
      if answer.isEmpty { return defaultIndex }
      if let choice = Int(answer), (1...options.count).contains(choice) { return choice - 1 }
      say("please enter a number between 1 and \(options.count)")
    }
  }
}

/// A scripted `SetupIO` for tests: answers come from a queue, output is collected.
///
/// `@unchecked Sendable` with a lock, for the same reason `FakeClock` is: `SetupIO`'s methods are
/// synchronous by design (a wizard is a straight line of questions), which an actor cannot back.
public final class ScriptedSetupIO: SetupIO, @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [String]
  private var _transcript: [String] = []
  /// Every prompt the wizard asked, in order — the other half of a transcript assertion.
  private var _prompts: [String] = []

  /// Answers are consumed in order. An exhausted queue answers "" (accept the default), which is
  /// what a test that only cares about the first few questions wants.
  public init(answers: [String]) {
    self.answers = answers
  }

  public var transcript: [String] { lock.withLock { _transcript } }
  public var prompts: [String] { lock.withLock { _prompts } }
  public var output: String { transcript.joined(separator: "\n") }
  public var remainingAnswers: Int { lock.withLock { answers.count } }

  private func next(_ prompt: String) -> String {
    lock.withLock {
      _prompts.append(prompt)
      return answers.isEmpty ? "" : answers.removeFirst()
    }
  }

  public func say(_ text: String) {
    lock.withLock { _transcript.append(text) }
  }

  public func ask(_ prompt: String, default defaultValue: String?) -> String {
    let answer = next(prompt)
    if answer.isEmpty, let defaultValue { return defaultValue }
    return answer
  }

  public func askSecret(_ prompt: String) -> String { next(prompt) }

  public func confirm(_ prompt: String, default defaultValue: Bool) -> Bool {
    switch next(prompt).lowercased() {
    case "y", "yes": true
    case "n", "no": false
    default: defaultValue
    }
  }

  public func choose(_ prompt: String, options: [String], default defaultIndex: Int) -> Int {
    let answer = next(prompt)
    guard let choice = Int(answer), (1...options.count).contains(choice) else { return defaultIndex }
    return choice - 1
  }
}
