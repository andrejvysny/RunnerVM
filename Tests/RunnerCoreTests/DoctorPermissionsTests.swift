import Foundation
import RunnerCore
import Testing

@Suite struct DoctorPermissionsTests {
  // MARK: - permissionBits / exceeds

  @Test func maskDropsFileTypeBits() {
    // S_IFDIR (0o040000) | 0750
    #expect(DoctorPermissions.permissionBits(0o040_750) == 0o750)
  }

  @Test func exactModeNeverExceedsItsOwnCeiling() {
    #expect(!DoctorPermissions.exceeds(mode: 0o750, ceiling: 0o750))
    #expect(!DoctorPermissions.exceeds(mode: 0o700, ceiling: 0o700))
  }

  @Test func stricterModeNeverExceedsALooserCeiling() {
    #expect(!DoctorPermissions.exceeds(mode: 0o700, ceiling: 0o750))
    #expect(!DoctorPermissions.exceeds(mode: 0o600, ceiling: 0o640))
  }

  @Test func looserModeExceedsAStricterCeiling() {
    #expect(DoctorPermissions.exceeds(mode: 0o755, ceiling: 0o750))
    #expect(DoctorPermissions.exceeds(mode: 0o644, ceiling: 0o640))
    #expect(DoctorPermissions.exceeds(mode: 0o750, ceiling: 0o700))
  }

  @Test func aDifferentBitInTheSameFamilyStillExceeds() {
    // 0640 sets group-write instead of group-read: neither is a subset of the other.
    #expect(DoctorPermissions.exceeds(mode: 0o640, ceiling: 0o604))
  }

  // MARK: - isWorldAccessible

  @Test func flagsAnyWorldBit() {
    #expect(DoctorPermissions.isWorldAccessible(mode: 0o751))
    #expect(DoctorPermissions.isWorldAccessible(mode: 0o752))
    #expect(DoctorPermissions.isWorldAccessible(mode: 0o754))
  }

  @Test func noWorldBitsIsNotWorldAccessible() {
    #expect(!DoctorPermissions.isWorldAccessible(mode: 0o750))
    #expect(!DoctorPermissions.isWorldAccessible(mode: 0o700))
    #expect(!DoctorPermissions.isWorldAccessible(mode: 0o000))
  }

  // MARK: - octal rendering

  @Test func rendersLeadingZeroOctal() {
    #expect(DoctorPermissions.octal(0o750) == "0750")
    #expect(DoctorPermissions.octal(0o600) == "0600")
    #expect(DoctorPermissions.octal(0o000) == "0000")
  }

  // MARK: - DoctorServiceAccount

  @Test func productionRootDirExpectsTheDefaultServiceUser() {
    let name = DoctorServiceAccount.expectedAccountName(
      rootDirPath: DoctorServiceAccount.productionRootDir, override: nil)
    #expect(name == DoctorServiceAccount.defaultServiceUser)
  }

  @Test func developmentRootDirExpectsNoSingleAccount() {
    let name = DoctorServiceAccount.expectedAccountName(
      rootDirPath: "/Users/dev/Library/Application Support/RunnerVM", override: nil)
    #expect(name == nil)
  }

  @Test func overrideAlwaysWinsRegardlessOfLayout() {
    #expect(
      DoctorServiceAccount.expectedAccountName(
        rootDirPath: DoctorServiceAccount.productionRootDir, override: "custom-user")
        == "custom-user"
    )
    #expect(
      DoctorServiceAccount.expectedAccountName(
        rootDirPath: "/Users/dev/Library/Application Support/RunnerVM", override: "custom-user")
        == "custom-user"
    )
  }

  @Test func emptyOverrideIsTreatedAsAbsent() {
    let name = DoctorServiceAccount.expectedAccountName(
      rootDirPath: DoctorServiceAccount.productionRootDir, override: "")
    #expect(name == DoctorServiceAccount.defaultServiceUser)
  }
}
