# Cutting a release

Manual procedure for tagging a version and updating the Homebrew tap
(`andrejvysny/homebrew-runnervm`). No automation exists yet (see TODO.md); every step below is a
plain git/gh command.

1. Confirm `master` is green: `gh run list --branch master --workflow ci`.
2. Tag and push:
   ```sh
   git tag -a v0.1.0 -m "v0.1.0"
   git push origin v0.1.0
   ```
3. Resolve the commit the tag points to (the tap formula pins this, not a tarball checksum):
   ```sh
   git rev-parse v0.1.0
   ```
4. In `andrejvysny/homebrew-runnervm`, edit `Formula/runnervm.rb`:
   - `tag: "v0.1.0"`
   - `revision: "<sha from step 3>"`
5. Sanity-check the formula against the new tag before pushing it:
   ```sh
   brew install --build-from-source ./Formula/runnervm.rb
   brew test runnervm
   brew audit --strict --online runnervm
   ```
6. Commit and push the tap. `brew install andrejvysny/runnervm/runnervm` (or `brew upgrade`) now
   resolves the new version for everyone.

## Version scheme

Semver, starting at `0.x` while `runnerd`'s wire/schema versions and the milestone list in
`TODO.md` are still moving — see `docs/status.md` for what's actually load-bearing at any given
point. Bump to `1.0.0` once the open M8/S3/S5/S7 items in `TODO.md` are resolved or explicitly
deferred and live GitHub verification covers the supported feature surface, not before.
