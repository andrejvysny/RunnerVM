import Foundation
import Testing
import VirtualizationCore

@Suite struct HostCapabilitiesTests {
  @Test func probeReportsSaneLimits() {
    let caps = HostCapabilities.probe()
    #expect(caps.logicalCPUCount >= 1)
    #expect(caps.minimumAllowedCPUCount >= 1)
    #expect(caps.maximumAllowedCPUCount >= caps.minimumAllowedCPUCount)
    #expect(caps.minimumAllowedMemoryBytes > 0)
    #expect(caps.macOSGuestLimit == 2)
  }

  @Test func encodesAsJSON() throws {
    let data = try JSONEncoder().encode(HostCapabilities.probe())
    let decoded = try JSONDecoder().decode(HostCapabilities.self, from: data)
    #expect(decoded == HostCapabilities.probe())
  }
}
