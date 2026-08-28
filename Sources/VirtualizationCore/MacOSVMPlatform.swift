import Foundation
import RunnerCore
import Virtualization

/// macOS guest: `VZMacOSBootLoader` + `VZMacPlatformConfiguration` (hardware model from the image,
/// auxiliary storage cloned per instance, machine identifier minted per instance) + one virtual
/// display with no window.
///
/// The three platform inputs come from three different owners, which is why they are assembled
/// here rather than carried together: the hardware model is an *image* fact (`spec.macos`), the
/// auxiliary storage is a *file* the instance directory owns (`nvram.bin`, cloned from the image),
/// and the machine identifier is *instance state* vmworker mints under the worker lock before this
/// builder ever runs (`MacOSMachineIdentity`).
public struct MacOSVMPlatform: VMPlatformBuilder {
  /// A fixed 1080p display: nothing ever looks at it, so the only thing the numbers have to be is
  /// a resolution macOS itself considers ordinary.
  public static let displayWidthPixels = 1920
  public static let displayHeightPixels = 1080
  public static let displayPixelsPerInch = 80

  public let spec: MacOSInstancePlatformSpec

  public init(spec: MacOSInstancePlatformSpec) {
    self.spec = spec
  }

  public func bootLoader(paths: VMRuntimePaths) throws -> VZBootLoader {
    VZMacOSBootLoader()
  }

  public func platform(paths: VMRuntimePaths) throws -> VZPlatformConfiguration {
    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = try Self.hardwareModel(fromBase64: spec.hardwareModel)
    let nvramPath = paths.nvram.path(percentEncoded: false)
    // `VZMacAuxiliaryStorage(url:)` is lazy -- it does not touch the file until the VM starts -- so
    // a missing clone would otherwise surface as an opaque start failure instead of a named error.
    guard FileManager.default.fileExists(atPath: nvramPath) else {
      throw VMError.macOSAuxiliaryStorageMissing(path: nvramPath)
    }
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: paths.nvram)
    // `load`, never `loadOrCreate`: vmworker mints the identifier under the worker lock before it
    // builds a configuration, so a file that is missing here means the instance directory lost its
    // identity rather than that this is a first boot -- minting a second one would strand the
    // auxiliary storage, which is bound to the first.
    platform.machineIdentifier = try MacOSMachineIdentity.load(at: paths.machineIdentifier)
    return platform
  }

  /// One display, no window. Apple's own macOS virtualization samples and tart configure a
  /// graphics device even when nothing renders it: the guest's WindowServer expects a framebuffer,
  /// and a macOS guest without one boots into a degraded state. RunnerVM never creates a
  /// `VZVirtualMachineView`, so the framebuffer is written and never read.
  public func graphicsDevices() -> [VZGraphicsDeviceConfiguration] {
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [
      VZMacGraphicsDisplayConfiguration(
        widthInPixels: Self.displayWidthPixels,
        heightInPixels: Self.displayHeightPixels,
        pixelsPerInch: Self.displayPixelsPerInch)
    ]
    return [graphics]
  }

  /// `.cached` avoids guest filesystem corruption observed with the default mode (tart PR #675).
  public var diskCachingMode: VZDiskImageCachingMode { .cached }

  /// Decodes the image's opaque hardware model.
  ///
  /// Split into two errors because the operator's next move differs: bad base64 or bytes the
  /// framework rejects mean the *image metadata* is wrong (re-import it with the right
  /// `--hardware-model`), while a decodable model this host cannot run means the *host* is wrong
  /// (an image sealed on newer or different silicon).
  public static func hardwareModel(fromBase64 string: String) throws -> VZMacHardwareModel {
    guard let data = Data(base64Encoded: string) else {
      throw VMError.macOSHardwareModelInvalid(reason: "not base64")
    }
    guard let model = VZMacHardwareModel(dataRepresentation: data) else {
      throw VMError.macOSHardwareModelInvalid(
        reason: "\(data.count) bytes are not a VZMacHardwareModel")
    }
    guard model.isSupported else { throw VMError.macOSHardwareModelUnsupported }
    return model
  }
}
