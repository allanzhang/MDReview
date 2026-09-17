## ADDED Requirements

### Requirement: Language preference supports system, Chinese, and English
The application MUST expose a persistent language preference with exactly three options: Follow System, Chinese, and English.

#### Scenario: First launch without a saved preference
- **WHEN** the application starts and no language preference has been stored
- **THEN** the selected language mode is Follow System

#### Scenario: User selects a language mode
- **WHEN** the user selects Follow System, Chinese, or English from the Language menu
- **THEN** the application stores that mode for future launches and immediately updates all custom user-visible text without relaunching

#### Scenario: Saved preference survives restart
- **WHEN** the application is relaunched after any language-mode selection
- **THEN** the same Follow System, Chinese, or English mode remains selected

#### Scenario: Invalid saved preference
- **WHEN** the stored language preference is not one of the three supported values
- **THEN** the application falls back to Follow System

### Requirement: Follow System resolves Chinese and non-Chinese languages
The Follow System mode MUST use Chinese when the first preferred system language begins with `zh`; otherwise it MUST use English.

#### Scenario: Chinese system language
- **WHEN** Follow System is active and the first preferred system language begins with `zh`
- **THEN** the application displays Simplified Chinese custom UI text

#### Scenario: Non-Chinese system language
- **WHEN** Follow System is active and the first preferred system language does not begin with `zh`
- **THEN** the application displays English custom UI text

#### Scenario: System language changes while Follow System is active
- **WHEN** the system preferred language changes while the application is running with Follow System active
- **THEN** the application immediately resolves and displays the language for the new system preference without relaunching

#### Scenario: System language changes during a manual override
- **WHEN** the system preferred language changes while Chinese or English is selected
- **THEN** the application keeps the manually selected display language

### Requirement: Language selection is available from the View menu
The application MUST provide a Language submenu in the View menu with Follow System, Chinese, and English choices and MUST indicate the active choice.

#### Scenario: Active language indication
- **WHEN** the user opens View > Language
- **THEN** the currently active language mode is visibly checked

#### Scenario: Selecting the active option
- **WHEN** the user selects the language option that is already active
- **THEN** the application remains in that language mode without changing document content or reading position

### Requirement: Custom UI text is localized
The application MUST localize all custom user-visible strings for the selected language, including menus, toolbars, tooltips, context menus, empty states, About, update status, and alerts.

#### Scenario: Chinese interface
- **WHEN** Chinese is active
- **THEN** custom UI text is displayed in Simplified Chinese

#### Scenario: English interface
- **WHEN** English is active
- **THEN** custom UI text is displayed in English

#### Scenario: Document content remains unchanged
- **WHEN** the application language changes
- **THEN** the opened Markdown document text and rendered content are not translated or modified

#### Scenario: Missing translation fallback
- **WHEN** a localized string is missing for the selected language
- **THEN** the application displays the English string instead of an empty value or a translation key

### Requirement: Localization changes preserve reading context
Changing the language MUST NOT relaunch the application, replace the open document, reset reading progress, or change source/rendered mode.

#### Scenario: Change language while reading
- **WHEN** the user changes language while a document is open
- **THEN** the same document remains open at the same reading position and in the same source or rendered mode
