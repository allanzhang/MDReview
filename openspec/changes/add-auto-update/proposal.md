## Why

MDReview is already distributed through GitHub Releases, but users must manually find and install each update. A small in-app updater removes that friction while keeping the current lightweight release process.

## What Changes

- Replace the default About panel with a custom About MDReview window that shows the current version and build.
- Add a manual `Check for Updates…` action in the About window.
- Always check for updates automatically when the app launches; no user setting or toggle.
- When a newer stable GitHub Release exists, show a confirmation dialog with the current and available versions.
- After confirmation, download the official release ZIP, verify its digest and bundle metadata, replace the installed app, and restart.
- Keep automatic-check failures silent, while manual checks and installation failures show actionable errors.
- Preserve the existing renderer, document behavior, and release artifact format.

## Capabilities

### New Capabilities

- `app-update`: Covers the About window, startup and manual update checks, release validation, installation, restart, and user-visible update states.

### Modified Capabilities

<!-- No existing OpenSpec capabilities are being modified. -->

## Impact

- Affects `Sources/MDReviewApp.swift`, the app launch lifecycle, and the About menu/window.
- Adds an update service and About view under `Sources/`.
- Adds GitHub Releases network access from the app; no third-party dependency is introduced.
- Requires updating both `project.yml` and the checked-in Xcode project so new Swift files are compiled.
- Leaves the renderer, document format, current release artifact naming, and existing tests unchanged.
