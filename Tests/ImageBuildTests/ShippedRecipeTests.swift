import Foundation
import ImageBuild
import Testing

/// Parses and plans every `images/recipes/*/Runnerfile` shipped with the repo, so a recipe that
/// stops parsing or planning fails CI instead of silently rotting.
@Suite struct ShippedRecipeTests {
  static let recipesRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    url.deleteLastPathComponent() // ShippedRecipeTests.swift
    url.deleteLastPathComponent() // ImageBuildTests
    url.deleteLastPathComponent() // Tests
    return url.appendingPathComponent("images/recipes", isDirectory: true)
  }()

  static let recipeDirectories: [URL] = {
    let fileManager = FileManager.default
    guard let entries = try? fileManager.contentsOfDirectory(
      at: recipesRoot, includingPropertiesForKeys: nil
    ) else { return [] }
    return entries
      .filter { fileManager.fileExists(atPath: $0.appendingPathComponent(RecipeParser.defaultFileName).path) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }()

  @Test(arguments: recipeDirectories)
  func shippedRecipeParsesAndPlans(directory: URL) throws {
    let name = directory.lastPathComponent
    let runnerfilePath = directory.appendingPathComponent(RecipeParser.defaultFileName)
    let text = String(decoding: try Data(contentsOf: runnerfilePath), as: UTF8.self)
    let recipe = try RecipeParser.parse(text, path: runnerfilePath.path, sha256: "test-sha")

    // Every recipe that declares these gets the same universal override; anything else resolves
    // through the recipe's own ARG default.
    var args: [String: String] = [:]
    if recipe.declaredArgs.contains("RUNNER_VERSION") { args["RUNNER_VERSION"] = "2.331.0" }
    if recipe.declaredArgs.contains("RUNNER_SHA256") {
      args["RUNNER_SHA256"] = String(repeating: "a", count: 64)
    }
    let plan = try RecipePlanner.plan(recipe, args: args)

    #expect(plan.labels[RecipePlanner.imageNameLabel] == name, "\(name): image-name label")
    #expect(plan.labels["dev.runnervm.image.family"] == "ubuntu-24", "\(name): family label")
    #expect(plan.totalSteps > 0, "\(name): must have at least one real step")

    for step in plan.steps {
      let argv = step.execArgv(contextRoot: BuildScripts.contextRoot)
      #expect(
        argv.first?.hasPrefix("/") == true,
        "\(name) step \(step.index) (\(step.display)): argv[0] must be absolute, got \(argv.first ?? "<empty>")"
      )
    }
  }

  @Test func atLeastTheExpectedFamilyOfRecipesIsPresent() {
    let names = Set(Self.recipeDirectories.map(\.lastPathComponent))
    let expected: Set<String> = [
      "ubuntu-24-minimal", "ubuntu-24", "ubuntu-24-node", "ubuntu-24-python", "ubuntu-24-go",
      "ubuntu-24-jvm", "ubuntu-24-rust", "ubuntu-24-dotnet",
    ]
    #expect(expected.isSubset(of: names))
  }
}
