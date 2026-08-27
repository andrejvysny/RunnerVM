/// The fully resolved result of applying build arguments to a `Recipe`: concrete steps, resolved
/// ARG values, and the labels a builder should attach to the resulting image.
public struct RecipePlan: Sendable, Hashable {
  public var from: RecipeFrom
  public var steps: [BuildStep]
  public var resolvedArgs: [String: String]
  public var labels: [String: String]
  public var imageName: String?
  /// Real (non-synthetic) step count -- what a build-progress UI should show as "step X of N".
  public var totalSteps: Int

  public init(
    from: RecipeFrom, steps: [BuildStep], resolvedArgs: [String: String], labels: [String: String],
    imageName: String?, totalSteps: Int
  ) {
    self.from = from
    self.steps = steps
    self.resolvedArgs = resolvedArgs
    self.labels = labels
    self.imageName = imageName
    self.totalSteps = totalSteps
  }
}
