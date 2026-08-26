/// OCIRegistry — OCI Distribution transport for RunnerVM images (spec §54–§57, §79, §119–§120).
///
/// Layering, outermost first:
///
///   RunnerVMImageTransfer   push/pull of a whole image; the API `ImageManager` calls
///   DiskLayerizer/NVRAMLayer chunk + compress on push, sparse reassembly on pull
///   RunnerVMArtifact         RunnerVM's OCI artifact schema (media types, annotations)
///   RegistryClient           OCI Distribution v2 verbs
///   RegistryAuthenticator    Docker token / basic auth
///
/// Nothing here touches the local image store: the layerizer writes to a caller-supplied staging
/// path and `ImageStore` owns verification and atomic publication (spec §120).
public enum OCIRegistryModule {
  public static let name = "OCIRegistry"

  /// Sent on every registry request. Some registries route or rate-limit on it.
  public static let defaultUserAgent = "RunnerVM/1.0 (OCIRegistry)"
}
