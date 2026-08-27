import ImageBuild
import Testing

@Suite struct RecipeIgnoreTests {
  @Test func rootAnchoredPatternMatchesOnlyAtRoot() {
    let ignore = RecipeIgnore.parse("/build.log\n")
    #expect(ignore.excludes(relativePath: "build.log", isDirectory: false))
    #expect(!ignore.excludes(relativePath: "sub/build.log", isDirectory: false))
  }

  @Test func unanchoredPatternMatchesAtAnyDepth() {
    let ignore = RecipeIgnore.parse("*.log\n")
    #expect(ignore.excludes(relativePath: "build.log", isDirectory: false))
    #expect(ignore.excludes(relativePath: "a/b/build.log", isDirectory: false))
  }

  @Test func internalSlashAnchorsToTheContextRoot() {
    let ignore = RecipeIgnore.parse("dist/out.bin\n")
    #expect(ignore.excludes(relativePath: "dist/out.bin", isDirectory: false))
    #expect(!ignore.excludes(relativePath: "a/dist/out.bin", isDirectory: false))
  }

  @Test func doubleStarMatchesAnyNumberOfDirectories() {
    let ignore = RecipeIgnore.parse("**/node_modules\n")
    #expect(ignore.excludes(relativePath: "node_modules", isDirectory: true))
    #expect(ignore.excludes(relativePath: "a/b/node_modules", isDirectory: true))
  }

  @Test func trailingSlashIsDirectoryOnly() {
    let ignore = RecipeIgnore.parse("build/\n")
    #expect(ignore.excludes(relativePath: "build", isDirectory: true))
    #expect(!ignore.excludes(relativePath: "build", isDirectory: false))
  }

  @Test func negationReincludesAPreviouslyExcludedPath() {
    let ignore = RecipeIgnore.parse("*.log\n!important.log\n")
    #expect(ignore.excludes(relativePath: "debug.log", isDirectory: false))
    #expect(!ignore.excludes(relativePath: "important.log", isDirectory: false))
  }

  @Test func excludedDirectoryHidesEverythingInsideEvenWithANegation() {
    // Real gitignore semantics: once a directory is excluded, a file-level negation inside it
    // cannot resurrect anything -- git never even looks inside an excluded directory.
    let ignore = RecipeIgnore.parse("build/\n!build/keep.txt\n")
    #expect(ignore.excludes(relativePath: "build/keep.txt", isDirectory: false))
  }

  @Test func negatingTheDirectoryItselfRestoresItsContents() {
    let ignore = RecipeIgnore.parse("important/\n!important/\n")
    #expect(!ignore.excludes(relativePath: "important/file.txt", isDirectory: false))
  }

  @Test func gitDirectoryIsAlwaysExcludedImplicitly() {
    let ignore = RecipeIgnore.parse("")
    #expect(ignore.excludes(relativePath: ".git", isDirectory: true))
    #expect(ignore.excludes(relativePath: ".git/HEAD", isDirectory: false))
  }

  @Test func commentsAndBlankLinesAreIgnored() {
    let ignore = RecipeIgnore.parse("# comment\n\n*.tmp\n")
    #expect(ignore.excludes(relativePath: "a.tmp", isDirectory: false))
    #expect(!ignore.excludes(relativePath: "a.txt", isDirectory: false))
  }
}
