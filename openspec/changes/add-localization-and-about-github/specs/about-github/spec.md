## ADDED Requirements

### Requirement: About page shows copyright
The About page MUST display the copyright text `© 2026 MDReview`.

#### Scenario: About page opens
- **WHEN** the user opens the About page
- **THEN** the page displays `© 2026 MDReview`

### Requirement: About page provides a GitHub project button
The About page MUST provide a GitHub button that opens `https://github.com/allanzhang/MDReview` in the system default browser.

#### Scenario: Chinese interface
- **WHEN** Chinese is active and the About page is visible
- **THEN** the button label is `GitHub 项目主页`

#### Scenario: English interface
- **WHEN** English is active and the About page is visible
- **THEN** the button label is `GitHub Project`

#### Scenario: User opens the project page
- **WHEN** the user clicks the GitHub button
- **THEN** the system default browser opens `https://github.com/allanzhang/MDReview`

#### Scenario: Browser cannot open the URL
- **WHEN** the system cannot open the GitHub URL
- **THEN** the application remains running and the About page remains usable
