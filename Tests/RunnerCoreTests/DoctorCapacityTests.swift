import Foundation
import RunnerCore
import Testing

@Suite struct DoctorCapacityTests {
  // MARK: - Requirement

  @Test func physicallyCapableWhenPhysicalMemoryCoversReservePlusLargestDemand() {
    let requirement = DoctorCapacity.Requirement(
      physicalBytes: ByteSize.gibibytes(32).bytes, reserveBytes: ByteSize.gibibytes(6).bytes,
      largestProfileMemoryBytes: ByteSize.gibibytes(12).bytes,
      buildMemoryBytes: ByteSize.gibibytes(4).bytes
    )
    // needed = 6 + max(12, 4) = 18 GiB <= 32 GiB physical
    #expect(requirement.neededBytes == ByteSize.gibibytes(18).bytes)
    #expect(requirement.physicallyCapable)
  }

  @Test func notPhysicallyCapableWhenPhysicalMemoryFallsShort() {
    let requirement = DoctorCapacity.Requirement(
      physicalBytes: ByteSize.gibibytes(16).bytes, reserveBytes: ByteSize.gibibytes(6).bytes,
      largestProfileMemoryBytes: ByteSize.gibibytes(12).bytes,
      buildMemoryBytes: ByteSize.gibibytes(4).bytes
    )
    // needed = 6 + max(12, 4) = 18 GiB > 16 GiB physical
    #expect(!requirement.physicallyCapable)
  }

  @Test func buildMemoryDominatesWhenLargerThanTheLargestProfile() {
    let requirement = DoctorCapacity.Requirement(
      physicalBytes: ByteSize.gibibytes(32).bytes, reserveBytes: ByteSize.gibibytes(6).bytes,
      largestProfileMemoryBytes: ByteSize.gibibytes(4).bytes,
      buildMemoryBytes: ByteSize.gibibytes(16).bytes
    )
    #expect(requirement.neededBytes == ByteSize.gibibytes(22).bytes)
  }

  @Test func exactBoundaryIsCapable() {
    let requirement = DoctorCapacity.Requirement(
      physicalBytes: ByteSize.gibibytes(18).bytes, reserveBytes: ByteSize.gibibytes(6).bytes,
      largestProfileMemoryBytes: ByteSize.gibibytes(12).bytes, buildMemoryBytes: 0
    )
    #expect(requirement.physicallyCapable)
  }

  @Test func zeroProfilesAndZeroBuildBudgetOnlyNeedsTheReserve() {
    let requirement = DoctorCapacity.Requirement(
      physicalBytes: ByteSize.gibibytes(8).bytes, reserveBytes: ByteSize.gibibytes(6).bytes,
      largestProfileMemoryBytes: 0, buildMemoryBytes: 0
    )
    #expect(requirement.neededBytes == ByteSize.gibibytes(6).bytes)
    #expect(requirement.physicallyCapable)
  }

  // MARK: - hasHeadroom

  @Test func headroomPresentWhenFreeMeetsOrExceedsNeeded() {
    #expect(DoctorCapacity.hasHeadroom(freeBytes: 100, neededBytes: 100))
    #expect(DoctorCapacity.hasHeadroom(freeBytes: 200, neededBytes: 100))
  }

  @Test func headroomAbsentWhenFreeFallsShort() {
    #expect(!DoctorCapacity.hasHeadroom(freeBytes: 99, neededBytes: 100))
  }

  // MARK: - vm_stat parsing

  static let sampleVMStat = """
    Mach Virtual Memory Statistics: (page size of 16384 bytes)
    Pages free:                              123456.
    Pages active:                            234567.
    Pages inactive:                          111222.
    Pages speculative:                          333.
    Pages throttled:                              0.
    Pages wired down:                        445566.
    Pages purgeable:                            777.
    "Translation faults":                999999999.
    Pages copy-on-write:                    1234567.
    Pages zero filled:                    123456789.
    Pages reactivated:                        12345.
    Pages purged:                             54321.
    File-backed pages:                       111111.
    Anonymous pages:                         222222.
    Pages stored in compressor:              333333.
    Pages occupied by compressor:            444444.
    Decompressions:                           55555.
    Compressions:                             66666.
    Pageins:                                7777777.
    Pageouts:                                    888.
    Swapins:                                       0.
    Swapouts:                                      0.
    """

  @Test func parsesFreeBytesFromRealisticVMStatOutput() {
    let bytes = DoctorCapacity.freeMemoryBytes(fromVMStatOutput: Self.sampleVMStat)
    #expect(bytes == UInt64(123_456) * 16384)
  }

  @Test func returnsNilWhenPageSizeHeaderIsMissing() {
    let text = "Pages free:                              123456.\n"
    #expect(DoctorCapacity.freeMemoryBytes(fromVMStatOutput: text) == nil)
  }

  @Test func returnsNilWhenFreePagesLineIsMissing() {
    let text = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages active: 1.\n"
    #expect(DoctorCapacity.freeMemoryBytes(fromVMStatOutput: text) == nil)
  }

  @Test func returnsNilForGarbageInput() {
    #expect(DoctorCapacity.freeMemoryBytes(fromVMStatOutput: "not vm_stat output at all") == nil)
    #expect(DoctorCapacity.freeMemoryBytes(fromVMStatOutput: "") == nil)
  }

  @Test func toleratesADifferentPageSize() {
    let text = """
      Mach Virtual Memory Statistics: (page size of 4096 bytes)
      Pages free:                                 1000.
      """
    #expect(DoctorCapacity.freeMemoryBytes(fromVMStatOutput: text) == 1_000 * 4096)
  }
}
