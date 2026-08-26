import Foundation
import Testing

@testable import Metrics

@Suite struct PrometheusEncoderTests {
  /// Golden text: the exposition format is a wire contract with every scraper on the host, so the
  /// whole rendering is asserted rather than a substring of it.
  @Test func rendersCountersGaugesAndHistogramsInFormat004() async {
    let metrics = MetricRegistry(definitions: [
      MetricDefinition(name: "rvm_sessions_total", kind: .counter, help: "Sessions."),
      MetricDefinition(name: "rvm_instances", kind: .gauge, help: "Instances."),
      MetricDefinition(
        name: "rvm_job_seconds", kind: .histogram, help: "Jobs.", buckets: [0.5, 1]),
    ])
    await metrics.increment("rvm_sessions_total", labels: ["result": "completed"], by: 2)
    await metrics.setGauge("rvm_instances", labels: ["state": "idle"], to: 1)
    await metrics.observe("rvm_job_seconds", seconds: 0.25)
    await metrics.observe("rvm_job_seconds", seconds: 4)

    let text = PrometheusEncoder.encode(await metrics.snapshot())

    #expect(text == """
      # HELP rvm_instances Instances.
      # TYPE rvm_instances gauge
      rvm_instances{state="idle"} 1
      # HELP rvm_job_seconds Jobs.
      # TYPE rvm_job_seconds histogram
      rvm_job_seconds_bucket{le="0.5"} 1
      rvm_job_seconds_bucket{le="1"} 1
      rvm_job_seconds_bucket{le="+Inf"} 2
      rvm_job_seconds_sum 4.25
      rvm_job_seconds_count 2
      # HELP rvm_sessions_total Sessions.
      # TYPE rvm_sessions_total counter
      rvm_sessions_total{result="completed"} 2

      """)
  }

  @Test func escapesLabelValuesAndHelpText() async {
    let metrics = MetricRegistry(definitions: [
      MetricDefinition(
        name: "rvm_odd", kind: .gauge, help: "back\\slash and a\nnewline"),
    ])
    await metrics.setGauge("rvm_odd", labels: ["name": #"a"b\c"# + "\nd"], to: 1)

    let text = PrometheusEncoder.encode(await metrics.snapshot())

    #expect(text.contains(#"# HELP rvm_odd back\\slash and a\nnewline"#))
    #expect(text.contains(#"rvm_odd{name="a\"b\\c\nd"} 1"#))
  }

  /// A quote is an ordinary character in `# HELP`; only a label value escapes it.
  @Test func helpKeepsQuotesUnescaped() {
    #expect(PrometheusEncoder.escapeHelp(#"say "hi""#) == #"say "hi""#)
    #expect(PrometheusEncoder.escapeValue(#"say "hi""#) == #"say \"hi\""#)
  }

  @Test func formatsWholeNumbersWithoutADecimalPart() {
    #expect(PrometheusEncoder.format(3) == "3")
    #expect(PrometheusEncoder.format(0.5) == "0.5")
    #expect(PrometheusEncoder.format(-2) == "-2")
    #expect(PrometheusEncoder.format(.infinity) == "+Inf")
    #expect(PrometheusEncoder.format(.nan) == "NaN")
  }

  @Test func declaredButUnobservedFamiliesStillCarryHelpAndType() async {
    let metrics = MetricRegistry(definitions: [
      MetricDefinition(name: "rvm_never", kind: .counter, help: "Nothing yet."),
    ])

    let text = PrometheusEncoder.encode(await metrics.snapshot())

    #expect(text == "# HELP rvm_never Nothing yet.\n# TYPE rvm_never counter\n")
  }
}
