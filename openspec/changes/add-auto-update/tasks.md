## 1. Project Structure

- [x] 1.1 Add `Sources/UpdateManager.swift` for update state, GitHub release lookup, download, validation, and installation coordination.
- [x] 1.2 Add `Sources/AboutView.swift` and an AppKit-hosted About window controller for the custom About page.
- [x] 1.3 Add the new source files to `project.yml` and the checked-in Xcode project without changing the renderer target.

## 2. Version and Release Logic

- [x] 2.1 Implement strict release-tag parsing and numeric version comparison for values such as `v1.4.2`.
- [x] 2.2 Implement the GitHub `releases/latest` request with the fixed `allanzhang/MDReview` repository and required request headers.
- [x] 2.2a Apply a bounded timeout to update requests.
- [x] 2.3 Decode the stable release version, expected `MDReview-<version>.zip` asset URL, and `sha256:` digest.
- [x] 2.4 Reject missing, malformed, draft, prerelease, or otherwise unusable releases without downloading anything.

## 3. Download and Validation

- [x] 3.1 Download the confirmed asset asynchronously and expose progress to the About view.
- [x] 3.2 Extract the ZIP into a unique temporary update directory with `ditto -x -k`.
- [x] 3.3 Verify the downloaded SHA256 against the GitHub digest before extraction.
- [x] 3.4 Validate the extracted bundle identifier, short version, and that the new version is newer than the running version.
- [x] 3.5 Ensure every validation failure leaves the running app and its bundle untouched with a user-visible manual-check error.

## 4. Installation and Restart

- [x] 4.1 Detect whether the current app bundle location is writable before starting installation.
- [x] 4.2 Generate and launch a minimal helper process that waits for the current app process to exit.
- [x] 4.3 Implement backup, replacement, relaunch, cleanup, and rollback-on-failure behavior in the helper.
- [x] 4.4 Terminate the current process only after the helper has started successfully.

## 5. About UI and Lifecycle

- [x] 5.1 Replace the system About command with `About MDReview` and add a `Check for Updates…` application-menu command.
- [x] 5.2 Build the About view with icon, short version, build number, manual check button, and update-state/progress text.
- [x] 5.3 Wire the startup lifecycle to perform exactly one automatic check per launch with no preference toggle.
- [x] 5.4 Show the current-to-new version confirmation dialog for available updates and suppress further automatic prompts after `Later`.
- [x] 5.5 Keep automatic-check failures silent while making manual-check and installation failures actionable.

## 6. Verification

- [x] 6.1 Add or run a focused automated check for tag parsing and numeric version comparison.
- [x] 6.2 Run `node Tests/run.js` and the existing app build command.
- [ ] 6.3 Verify no-update, update-available, `Later`, invalid-digest, invalid-bundle-version, unwritable-destination, successful replacement, and restart behavior.
- [ ] 6.4 Run `openspec validate --strict add-auto-update` and confirm all tasks are complete before release.
