## ADDED Requirements

### Requirement: About window shows app identity and manual update action
The app SHALL provide a custom About MDReview window that displays the current short version and build number and offers a manual update check.

#### Scenario: Opening About
- **WHEN** the user chooses `About MDReview`
- **THEN** the app displays a window containing the app icon, `CFBundleShortVersionString`, `CFBundleVersion`, and a `Check for Updates…` button

#### Scenario: Manual check finds no update
- **WHEN** the user starts a manual check and the current version is equal to or newer than the latest stable release
- **THEN** the About window reports that MDReview is up to date

#### Scenario: Manual check finds an update
- **WHEN** the user starts a manual check and a newer stable release is available
- **THEN** the app shows the same confirmation dialog containing the current version and the available version

#### Scenario: Manual check fails
- **WHEN** the user starts a manual check and the request, decoding, or validation fails
- **THEN** the About window reports an actionable error without blocking the application

### Requirement: App checks for updates automatically on launch
The app SHALL perform one automatic update check after each application launch without requiring a user preference or toggle.

#### Scenario: Automatic check finds no update
- **WHEN** the app launches and the latest stable release is not newer than the running version
- **THEN** no update prompt is shown and document behavior continues normally

#### Scenario: Automatic check fails
- **WHEN** the app launches and the update request or release parsing fails
- **THEN** the failure is not shown as a blocking alert

#### Scenario: Automatic check finds an update
- **WHEN** the app launches and a newer stable release is available
- **THEN** the app shows a confirmation dialog containing the current version and the available version

#### Scenario: User postpones an update
- **WHEN** the update confirmation dialog is shown and the user chooses `Later`
- **THEN** the app closes the dialog and does not show another automatic update prompt during the current launch

### Requirement: Confirmed updates are downloaded and validated
The app SHALL download and validate the official release asset only after the user chooses `Update Now`.

#### Scenario: User confirms an update
- **WHEN** the user chooses `Update Now`
- **THEN** the app opens the About window, downloads `MDReview-<version>.zip`, and reports download progress

#### Scenario: Release asset is valid
- **WHEN** the downloaded asset has a matching SHA256 digest, bundle identifier `com.doubleeagle.MDReview`, and a newer bundle version
- **THEN** the app proceeds to installation

#### Scenario: Release asset is invalid
- **WHEN** the expected asset is missing, its digest is missing or malformed, its SHA256 does not match, its bundle identifier is incorrect, or its bundle version is not newer
- **THEN** the app stops the update, keeps the current application untouched, and reports a validation error

### Requirement: Updates are installed and the app restarts
The app SHALL replace the running application bundle with the validated new bundle and restart the application.

#### Scenario: Installation succeeds
- **WHEN** the validated new bundle is ready and the current app bundle location is writable
- **THEN** the app launches a helper, exits, replaces the current bundle, starts the new version, and removes the temporary update files

#### Scenario: Installation cannot access the destination
- **WHEN** the current app bundle location is not writable
- **THEN** the app does not terminate, keeps the current bundle, and reports an installation error

#### Scenario: Helper cannot start
- **WHEN** the app cannot start the installation helper
- **THEN** the app does not terminate, keeps the current bundle, and reports an installation error

#### Scenario: Replacement fails
- **WHEN** the helper cannot replace the current bundle
- **THEN** the helper restores the backup bundle and leaves a usable MDReview application at the original location

### Requirement: Update source and release channel are constrained
The app SHALL use only the official MDReview GitHub repository and SHALL ignore non-stable releases.

#### Scenario: Latest release is stable
- **WHEN** GitHub returns a published non-prerelease release from `allanzhang/MDReview`
- **THEN** the app may use that release for an update check

#### Scenario: Latest release is not usable
- **WHEN** the release is missing, is a draft or prerelease, uses a malformed version tag, or does not contain the expected ZIP asset
- **THEN** the app treats the update as unavailable and does not download or install anything
