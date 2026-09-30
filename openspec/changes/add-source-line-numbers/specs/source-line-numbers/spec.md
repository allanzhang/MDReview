## ADDED Requirements

### Requirement: Source view displays a line number gutter

The source view MUST display a line number gutter on the left side of the text, always visible with no user toggle, numbered from 1 for the first logical line.

The gutter MUST be visually consistent with the rendered code block gutter: monospaced font, right-aligned numbers, muted gray, and not selectable.

#### Scenario: Source view is open
- **WHEN** the user opens a Markdown document in source view
- **THEN** a line number gutter appears on the left showing the number of each line

#### Scenario: User has finished reading
- **WHEN** the source view has been open for an arbitrary duration
- **THEN** the gutter remains visible and no toggle state has changed

#### Scenario: Gutter is clicked
- **WHEN** the user clicks inside the gutter area
- **THEN** the click reaches the text view and text selection still works

### Requirement: Line numbers follow logical lines with wrapped continuations blank

The source view MUST number logical lines. When a logical line wraps across multiple visual rows because of soft wrapping, the gutter MUST show the number only on the first visual row and leave continuation rows blank.

#### Scenario: A line wraps across multiple rows
- **WHEN** a logical line is soft-wrapped into three visual rows
- **THEN** the number appears only beside the first row and the two continuation rows are blank

#### Scenario: Empty lines
- **WHEN** the document contains blank lines or consecutive blank lines
- **THEN** each blank line receives its own correct number and alignment with the text

#### Scenario: Last line has a trailing newline
- **WHEN** the document ends with a newline character
- **THEN** no line number is drawn for a non-existent line beyond the document content

### Requirement: Gutter width adapts to line number digits

The gutter width MUST accommodate the full digit count of the document's line count, and the text view's left inset MUST leave matching space so text never overlaps the gutter.

#### Scenario: Document gains lines
- **WHEN** the document changes and the line count gains a digit
- **THEN** the gutter widens and the text left inset increases to match

#### Scenario: Window is resized
- **WHEN** the user resizes the window horizontally
- **THEN** the gutter width is unchanged and line numbers remain aligned with text after re-wrapping

### Requirement: Selected lines are highlighted across the full width

The source view MUST highlight every line covered by the current selection, spanning the full text width. When a selected line wraps across multiple visual rows, the highlight MUST cover all of its rows.

The gutter MUST render the number of the selection's first line with an emphasized color so the current line is identifiable.

#### Scenario: Empty selection at document start
- **WHEN** the source view opens with no active selection
- **THEN** the first line is highlighted and its number is emphasized

#### Scenario: User clicks in a line
- **WHEN** the user clicks inside a line
- **THEN** that line is highlighted and its gutter number switches to the emphasized color

#### Scenario: User drags a selection across multiple lines
- **WHEN** the user selects text spanning several lines
- **THEN** all selected lines are highlighted and the first line's number is emphasized

#### Scenario: Selection covers a soft-wrapped line
- **WHEN** the selection is inside a line that wraps across three visual rows
- **THEN** the highlight covers all three rows

#### Scenario: Selection at end of document
- **WHEN** the selection ends at the final character
- **THEN** the last line is highlighted and no out-of-range access occurs

### Requirement: Selection highlight tracks all selection changes

The current line highlight MUST update in response to every selection change, including mouse clicks, drag selection, and full-text search jumps.

#### Scenario: Search jumps to a match
- **WHEN** a full-text search selects a match in the source view
- **THEN** the matched line becomes the highlighted current line

#### Scenario: Text is refreshed from disk
- **WHEN** the document is reloaded from disk with different content
- **THEN** line numbers are renumbered and the highlight is recomputed against the new content

### Requirement: Gutter follows content scrolling without redrawing

The gutter MUST scroll with the document content and MUST NOT require redrawing while scrolling.

#### Scenario: User scrolls the source view
- **WHEN** the user scrolls down through a long document
- **THEN** line numbers stay aligned with their lines with no visible flicker or lag

### Requirement: Gutter colors follow the application appearance

The gutter numbers and the current-line highlight MUST use colors consistent with the active light or dark appearance.

#### Scenario: User switches to dark appearance
- **WHEN** the application switches to dark appearance while the source view is visible
- **THEN** gutter numbers and the current-line highlight use dark-mode colors

#### Scenario: System appearance changes
- **WHEN** the system appearance changes while the source view is visible
- **THEN** gutter numbers and the current-line highlight are redrawn for the new appearance

### Requirement: Source and rendered mode round trip preserves the source view state

Switching from source view to rendered view and back MUST preserve the line number gutter and current-line highlight.

#### Scenario: User toggles to rendered and back
- **WHEN** the user switches to rendered view and then returns to source view
- **THEN** line numbers and the current-line highlight are still displayed

### Requirement: Rendering cost of the gutter is independent of document size

The gutter MUST only compute and draw line fragments within the visible region, so its cost does not scale with total document length.

#### Scenario: Large document is opened in source view
- **WHEN** a document with hundreds of thousands of characters is opened in source view
- **THEN** scrolling remains responsive and opening does not appear to hang
