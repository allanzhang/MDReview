## Context

MDReview is a single-window macOS application distributed as `MDReview-<version>.zip` attachments on GitHub Releases. The app currently uses the system About panel and has no update service. The application is ad-hoc signed, has no third-party runtime dependencies, and already centralizes application lifecycle behavior in `MDReviewApp.swift` and `AppDelegate`.

The updater must fit the existing release process, remain lightweight, and avoid changing renderer or document behavior. The app is launched interactively, so update installation may only replace the running bundle after the current process exits.

## Goals / Non-Goals

**Goals:**

- Provide a custom About MDReview window with current version/build information.
- Always check the official GitHub repository for a newer stable Release when the app launches.
- Allow the user to check manually from the About window and the application menu.
- Confirm with the user before downloading or installing an update.
- Verify the official release asset before replacing the installed app.
- Install the update safely and restart the application.
- Keep automatic-check failures silent and make manual-check or installation failures actionable.

**Non-Goals:**

- Incremental or delta updates.
- Beta, nightly, or prerelease update channels.
- Periodic background polling.
- Downgrades or user-selectable rollback versions.
- Sparkle or another third-party update framework.
- Notarization, Developer ID signing, or changes to the existing release artifact format.

## Decisions

### Use a lightweight GitHub Releases updater

The updater will call `https://api.github.com/repos/allanzhang/MDReview/releases/latest`, decode the latest stable release, and select the asset named `MDReview-<version>.zip`. This matches the existing release process and avoids adding a dependency or a separate appcast/signing pipeline.

Alternatives considered:

- **Sparkle**: More mature installation and signature handling, but requires an SPM dependency, appcast generation, and EdDSA signing infrastructure that is disproportionate for this app.
- **Open the Releases page only**: Minimal implementation, but does not satisfy automatic upgrade and restart.

### Keep update state in one main-actor service

A new `UpdateManager` will own the state machine for checking, available, downloading, installing, up-to-date, and failed states. It will be a main-actor `ObservableObject` singleton so the About view and app lifecycle observe the same state. Network and filesystem work will be performed asynchronously without blocking the UI.

### Use a custom About window

A new `AboutView` will show the app icon, `CFBundleShortVersionString`, `CFBundleVersion`, a manual check button, and current update status. An `AboutWindowController` will host the SwiftUI view in a small AppKit window so the same window can be opened from the app menu and from a startup update prompt.

The standard About command will be replaced by `About MDReview`. A `Check for Updates…` command will also be available in the application menu.

### Check once per app launch

The app will schedule one automatic check after launch, with a short delay to avoid competing with initial document rendering. There is no automatic-check preference or toggle. Network requests use a bounded timeout so a stalled request cannot leave the updater busy indefinitely. The check is silent when no update exists or when the network/API fails. A successful check that finds an update presents a confirmation dialog with the current and available versions.

Choosing `Later` dismisses the prompt and suppresses further automatic prompts for the current launch. Choosing `Update Now` opens the About window and starts the download. Manual checks always show their result, including errors.

### Validate before installation

The updater will require:

- A stable release from the fixed official repository.
- An asset named exactly `MDReview-<version>.zip`.
- A GitHub-provided `sha256:` asset digest.
- A downloaded ZIP whose SHA256 matches the digest.
- An extracted `MDReview.app` whose bundle identifier is `com.doubleeagle.MDReview`.
- An extracted bundle version that is newer than the running version.

The ZIP will be downloaded to a unique directory under the user's Caches directory and extracted with `ditto -x -k`. Failure at any validation step leaves the running application untouched.

### Replace through a short-lived helper process

Because macOS may not allow a running bundle to replace itself reliably, the app will create a temporary shell helper and start it before terminating. The helper will:

1. Wait for the current process ID to exit.
2. Move the current app bundle to a timestamped backup beside the original.
3. Copy the validated new bundle into the original location.
4. Launch the new bundle.
5. Remove the backup and temporary update directory after success.
6. Restore the backup if replacement or launch preparation fails.

The helper will be minimal and only operate on the current bundle path and the validated temporary bundle. If the destination is not writable, installation will stop with an error before the current process exits.

## Risks / Trade-offs

- **GitHub API rate limits or network outages** → Automatic checks fail silently; manual checks report a retryable error.
- **A network request stalls** → The request times out; automatic checks return to idle and manual checks report a retryable error.
- **A compromised GitHub repository or release asset** → HTTPS and the GitHub digest protect against transfer corruption, but cannot replace a trusted code-signing identity. This risk is accepted for the current ad-hoc-signed distribution and is documented as a limitation.
- **The app is running from a non-writable or development location** → Installation stops before replacing anything and the current app remains usable.
- **The helper is interrupted during replacement** → The helper keeps a backup and restores it when replacement fails; users retain a recoverable app bundle.
- **Version parsing edge cases** → The updater uses numeric component comparison and ignores the leading `v` in release tags; malformed tags are rejected rather than treated as newer.
- **Startup prompt interrupts reading** → The check is delayed briefly and only prompts when a valid newer stable release exists; `Later` suppresses the prompt for the current launch.

## Migration Plan

1. Add the update service, About view/window, and lifecycle wiring.
2. Add the new source files to both `project.yml` and the checked-in Xcode project.
3. Build and run the existing renderer tests and app build gate.
4. Manually verify no-update, update-available, `Later`, validation-failure, and successful replacement flows.
5. Publish the feature in the next normal release; no existing Release or user data migration is required.

Rollback is limited to reverting the feature commit. The updater does not modify document files, renderer resources, or user defaults outside the update state.

## Open Questions

- None. The update source, confirmation behavior, default launch behavior, and installation path strategy are fixed by the approved proposal.
