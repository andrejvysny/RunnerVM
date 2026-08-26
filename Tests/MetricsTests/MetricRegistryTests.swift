import Foundation
import Testing

@testable import Metrics

@Suite struct MetricRegistryTests {
  private func registry() -> MetricRegistry {
    MetricRegistry(definitions: [
      MetricDefinition(name: "rvm_calls_total", kind: .counter, help: "Calls."),
      MetricDefinition(name: "rvm_queue", kind: .gauge, help: "Queue depth."),
      MetricDefinition(
        name: "rvm_wait_seconds", kind: .histogram, help: "Waits.", buckets: [1, 5, 10]),
    ])
  }

  @Test func countersAccumulatePerLabelSet() async {
    let metrics = registry()
    await metrics.increment("rvm_calls_total", labels: ["class": "ok"])
    await metrics.increment("rvm_calls_total", labels: ["class": "ok"], by: 3)
    await metrics.increment("rvm_calls_total", labels: ["class": "error"])

    #expect(await metrics.counter(name: "rvm_calls_total", labels: ["class": "ok"]) == 4)
    #expect(await metrics.counter(name: "rvm_calls_total", labels: ["class": "error"]) == 1)
    #expect(await metrics.counter(name: "rvm_calls_total", labels: ["class": "other"]) == 0)
  }

  @Test func setCounterNeverMovesBackwards() async {
    let metrics = registry()
    await metrics.setCounter("rvm_calls_total", to: 7)
    await metrics.setCounter("rvm_calls_total", to: 3)

    #expect(await metrics.counter(name: "rvm_calls_total") == 7)
  }

  @Test func replaceGaugeDropsLabelSetsThatAreGone() async {
    let metrics = registry()
    await metrics.replaceGauge("rvm_queue", with: [(["state": "idle"], 2), (["state": "busy"], 1)])
    await metrics.replaceGauge("rvm_queue", with: [(["state": "busy"], 3)])

    #expect(await metrics.gauge(name: "rvm_queue", labels: ["state": "idle"]) == nil)
    #expect(await metrics.gauge(name: "rvm_queue", labels: ["state": "busy"]) == 3)
  }

  /// The upper bound is inclusive, and anything past the last bound lands in the `+Inf` slot.
  @Test func histogramBucketsObservationsInclusively() async {
    let metrics = registry()
    for value in [0.5, 1.0, 5.0, 7.0, 99.0] {
      await metrics.observe("rvm_wait_seconds", seconds: value)
    }
    let histogram = try! #require(await metrics.histogram(name: "rvm_wait_seconds"))

    #expect(histogram.counts == [2, 1, 1, 1])
    #expect(histogram.cumulativeCounts == [2, 3, 4, 5])
    #expect(histogram.count == 5)
    #expect(histogram.sum == 112.5)
  }

  @Test func nonFiniteObservationsAreIgnored() async {
    let metrics = registry()
    await metrics.observe("rvm_wait_seconds", seconds: .nan)
    await metrics.observe("rvm_wait_seconds", seconds: .infinity)

    #expect(await metrics.histogram(name: "rvm_wait_seconds") == nil)
  }

  /// A series is identified by its label set, not by the order the caller wrote it in.
  @Test func labelsAreSortedIntoAStableKey() async {
    let metrics = registry()
    await metrics.setGauge("rvm_queue", labels: ["b": "2", "a": "1"], to: 9)

    #expect(await metrics.gauge(name: "rvm_queue", labels: ["a": "1", "b": "2"]) == 9)
    let sample = await metrics.snapshot().family("rvm_queue")?.samples.first
    #expect(sample?.labels.map(\.name) == ["a", "b"])
  }

  @Test func snapshotSortsFamiliesAndKeepsDeclaredHelpAndType() async {
    let metrics = registry()
    let snapshot = await metrics.snapshot()

    #expect(snapshot.families.map(\.name) == ["rvm_calls_total", "rvm_queue", "rvm_wait_seconds"])
    #expect(snapshot.family("rvm_wait_seconds")?.type == .histogram)
    #expect(snapshot.family("rvm_queue")?.help == "Queue depth.")
    // Declared but unobserved families still carry their metadata.
    #expect(snapshot.family("rvm_calls_total")?.samples.isEmpty == true)
  }

  @Test func samplesAreOrderedByLabelValue() async {
    let metrics = registry()
    for state in ["idle", "busy", "cleaning"] {
      await metrics.setGauge("rvm_queue", labels: ["state": state], to: 1)
    }
    let samples = await metrics.snapshot().family("rvm_queue")?.samples ?? []

    #expect(samples.compactMap { $0.labels.first?.value } == ["busy", "cleaning", "idle"])
  }

  @Test func undeclaredNamesAutoRegisterWithTheCallersKind() async {
    let metrics = MetricRegistry(definitions: [])
    await metrics.increment("rvm_unknown_total")
    await metrics.observe("rvm_unknown_seconds", seconds: 0.2)

    let snapshot = await metrics.snapshot()
    #expect(snapshot.family("rvm_unknown_total")?.type == .counter)
    #expect(snapshot.family("rvm_unknown_seconds")?.type == .histogram)
    #expect(
      snapshot.family("rvm_unknown_seconds")?.samples.first?.histogram?.buckets
        == MetricRegistry.defaultSecondsBuckets)
  }

  @Test func snapshotRoundTripsThroughJSON() async throws {
    let metrics = registry()
    await metrics.increment("rvm_calls_total", labels: ["class": "ok"])
    await metrics.observe("rvm_wait_seconds", seconds: 2)
    let snapshot = await metrics.snapshot()

    let data = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(MetricsSnapshot.self, from: data) == snapshot)
  }
}
