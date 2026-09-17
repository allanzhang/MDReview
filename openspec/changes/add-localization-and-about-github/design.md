## Context

MDReview currently has no localization resources. Custom UI strings are hardcoded in English across SwiftUI views, AppKit menus, alerts, tooltips, and update status. The language has therefore been independent of the user's system preference, and the About page does not expose project attribution or a source-code entry point.

The application already centralizes app-level preferences and observable state in `DocState`. The View menu already contains an Appearance submenu, which provides a consistent location for a Language submenu. The repository URL is already documented as `https://github.com/allanzhang/MDReview`.

## Goals / Non-Goals

**Goals:**

- Provide persistent Follow System, Chinese, and English language modes.
- Resolve Follow System from the first preferred system language at launch and whenever the system language changes while the application is running.
- Apply every language-mode change immediately without relaunching, while preserving the open document, reading position, and source/rendered mode.
- Localize every custom user-visible string in SwiftUI and AppKit surfaces.
- Add `© 2026 MDReview` and a localized GitHub project button to About.
- Keep Markdown document content unchanged when the UI language changes.

**Non-Goals:**

- Translating Markdown document content.
- Supporting Traditional Chinese-specific copy or languages other than Chinese and English.
- Adding a separate Settings scene.
- Relying on a process-level `AppleLanguages` override or application relaunch to switch languages.
- Performing network requests when opening the GitHub project page.

## Decisions

### Decision: Use an explicit AppLanguage enum with Follow System as the default

`AppLanguage` will contain `system`, `chinese`, and `english`. Its raw values will be persisted in `UserDefaults` under a versioned key. Unknown values will resolve to `system`.

This is preferred over relying only on Bundle localization because Bundle localization cannot provide the requested manual override. It is preferred over storing a full locale identifier because the product exposes only three stable modes.

### Decision: Use String Catalog resources with English fallback

Custom strings will be stored in a String Catalog containing English and Simplified Chinese entries. English will be the fallback for missing translations.

This is preferred over separate hand-maintained dictionaries because Xcode can validate catalog keys and the project already targets modern macOS. The localization helper will return English when a key is missing, preventing empty labels or raw keys in the UI.

### Decision: Publish both selected mode and resolved language through DocState

The selected mode and the currently resolved display language will live in `DocState` as distinct state. The selected mode is persisted, while the resolved language is recomputed when the mode changes or when the system language changes in Follow System mode. SwiftUI content will receive the resolved locale through the environment. AppKit menus, alerts, tooltips, and the separately hosted About window will use a shared L10n helper that resolves strings with the published display language explicitly.

This is preferred over a computed-only resolved language because changes in `Locale.preferredLanguages` do not mutate the persisted mode and therefore would not notify observers. It is preferred over independently localizing each AppKit surface because a shared helper keeps fallback behavior consistent.

### Decision: Refresh Follow System from locale notifications with activation fallback

While Follow System is selected, the application will observe the system locale-change notification and recompute the resolved display language. It will also re-check the preferred language when the application becomes active, covering system changes that are not delivered to a background application. A refresh that resolves to the same display language is a no-op.

This is preferred over continuous polling because language changes are rare and event-driven updates avoid unnecessary work. The activation check is retained as a low-cost reliability fallback.

### Decision: Do not mutate AppleLanguages or relaunch the application

Language switching will remain inside the application's localization state. The implementation will not write the process-level `AppleLanguages` preference, launch a replacement application instance, or terminate the current instance. Existing windows and document state remain alive while their localized labels update in place.

This is required for genuine immediate switching and avoids mixed behavior caused by framework localization caches during runtime overrides.

The shared application state factory will remove an `AppleLanguages` value left in the application preference domain by the incomplete implementation before it reads `Locale.preferredLanguages`. This one-time compatibility cleanup prevents the legacy override from contaminating the first Follow System resolution; it is not used for active language switching.

### Decision: Place Language in the View menu beside Appearance

The View menu will contain a Language submenu with exactly three choices and a visible checkmark for the active mode. Changing the option will update `DocState` immediately.

This is preferred over a new Settings window because the application currently has no settings architecture and already uses the View menu for appearance preferences. The option labels will be `Follow System`, `中文`, and `English`; the submenu title will be localized.

### Decision: Open the GitHub page with NSWorkspace

The About page will call `NSWorkspace.shared.open` with the fixed project URL. The button label will be localized and the fixed URL will not be user-editable.

This is preferred over embedding a web view because the requested behavior is to enter the project homepage in the user's browser. It is preferred over adding a URL configuration surface because the project homepage is a stable application constant.

### Decision: About window observes language state

The About window will continue to use its existing hosting-controller architecture, but its root view will observe `DocState` and use explicit localized strings for text and button labels. This allows an already-open About window to update when the language changes.

This is preferred over recreating the About window on every language change because preserving window state is simpler and avoids flicker.

## Risks / Trade-offs

- [Some hardcoded strings may be missed] → Add a source scan test for user-visible literals and verify all listed UI surfaces in both languages.
- [SwiftUI environment locale may not update AppKit menus or alerts] → Route those strings through the shared L10n helper and test both language modes.
- [The About window is created once and may capture stale language] → Observe `DocState` and recompute localized strings in the hosted view; update the root view when the language changes.
- [Translation keys can be incomplete] → Use English fallback and validate that every catalog key resolves in both languages before build.
- [Changing language could disrupt reading] → Language changes only update copy and locale; they do not modify renderer input, document URL, scroll offsets, or source/rendered state.
- [System language changes are not always broadcast while the app is running] → Observe locale changes and also recompute when the application becomes active.
- [System-provided menu items may not react to the app-owned locale] → Update known main-menu titles in place through `MainMenuLocalizer` without changing process language or rebuilding the application.

## Migration Plan

1. Add the language preference with a default of Follow System; no existing user data needs migration.
2. Invalid or absent stored values resolve to Follow System.
3. Add localization resources and replace hardcoded strings surface by surface.
4. Add the About copyright and GitHub link.
5. Replace any restart-based language switching with in-process reactive state before release.
6. Rollback consists of removing the Language submenu and localization resources and restoring the current English literals; the stored preference is ignored by the previous version.

## Open Questions

None.
