# Implementation Tasks

## Gate Summary

- 既有规格曾通过 spec-lint v1.7.0，但其“系统语言仅在下次启动生效”的结论已被新需求替代。
- 方案 A 的规格修订完成后，必须重新执行 spec-lint 与 `openspec validate --strict`。
- 新门禁通过前，不得将运行时即时跟随系统标记为完成。

## 1. Language Preference Foundation

- [x] 1.1 Add an `AppLanguage` model with `system`, `chinese`, and `english` modes.
- [x] 1.2 Persist the selected mode in `UserDefaults` and default missing or invalid values to `system`.
- [x] 1.3 Implement resolution so `system` maps languages beginning with `zh` to Chinese and all others to English.
- [x] 1.4 Publish the resolved locale and selected mode from `DocState` so views and commands update when the selection changes.
- [x] 1.5 Add unit tests for default resolution, manual resolution, persistence, invalid values, and Chinese/non-Chinese system language splitting.

## 2. Localization Resources and Helper

- [x] 2.1 Add a String Catalog containing English and Simplified Chinese entries for every custom user-visible string.
- [x] 2.2 Add an `L10n` helper that resolves a key for an explicit `AppLanguage` and returns the English value when a translation is missing.
- [x] 2.3 Add a test that fails when a required localization key is absent from either English or Chinese.
- [x] 2.4 Add a source-scan test that detects newly introduced user-visible string literals outside the localization mechanism.

## 3. Language Menu

- [x] 3.1 Add a localized Language submenu to the View menu beside Appearance.
- [x] 3.2 Add exactly three options: Follow System, 中文, and English, with a visible checkmark on the active option.
- [x] 3.3 Apply selection immediately without reloading the document or changing reading progress, scroll offset, or source/rendered mode.
- [x] 3.4 Verify that selecting the already-active option is a no-op.

## 4. Localize Application Surfaces

- [x] 4.1 Localize main-window empty state, toolbar labels, help text, and controls.
- [x] 4.2 Localize Outline, Recent, context menus, copy actions, and source/rendered actions.
- [x] 4.3 Localize export actions, completion dialogs, and error alerts.
- [x] 4.4 Localize update status, update notices, confirmation alerts, and About menu actions.
- [x] 4.5 Localize the renderer's AppKit context menu while leaving Markdown document content unchanged.
- [x] 4.6 Verify that switching language preserves the current document, scroll position, and source/rendered mode.

## 5. About GitHub Information

- [x] 5.1 Add `© 2026 MDReview` to the About page.
- [x] 5.2 Add a GitHub button whose visible label is `GitHub 项目主页` in Chinese and `GitHub Project` in English.
- [x] 5.3 Open `https://github.com/allanzhang/MDReview` through `NSWorkspace` when the button is clicked.
- [x] 5.4 Update the About window layout so copyright and GitHub controls fit without clipping at the minimum window height.
- [x] 5.5 Add tests for the localized button labels and the fixed project URL.

## 6. Verification and Acceptance

- [x] 6.1 Run `node Tests/run.js` and record the result.
- [x] 6.2 Run the macOS 27 SDK `xcodebuild` command and record the result.
- [x] 6.3 Run `openspec validate --strict add-localization-and-about-github` and record the result.
- [ ] 6.4 Smoke-test English and Chinese in a running app, including menus, context menus, About, alerts, and update status.
- [x] 6.5 Verify that an open Markdown document is not translated or reloaded when language changes.
- [ ] 6.6 Verify that the About GitHub button opens the expected repository URL.
- [ ] 6.7 Record the human visual acceptance result for the localized About layout and language menu.

## 7. Reactive Language Switching Repair

- [x] 7.1 Add failing tests proving that all three language modes persist and switch without requesting an application relaunch.
- [x] 7.2 Publish the resolved display language as observable application state instead of relying on a computed property alone.
- [x] 7.3 Observe system locale changes in Follow System mode and add an application-activation recheck as a delivery fallback.
- [x] 7.4 Keep Chinese and English manual overrides unchanged when the system language changes.
- [x] 7.5 Remove the `AppleLanguages` mutation, replacement-process launch, and current-process termination used for language switching.
- [x] 7.6 Refresh SwiftUI content, the existing About window, update-status text, and the AppKit main menu in place when the resolved language changes.
- [x] 7.7 Run automated tests, strict OpenSpec validation, and a macOS build; then prepare Chinese, English, and Follow System cases for human visual acceptance.
