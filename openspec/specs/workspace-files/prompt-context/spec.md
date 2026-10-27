# workspace-files/prompt-context Specification

## Purpose
The prompt context is what the app builds from the selection and the index for the model: the prompt file tree, file contents, codemaps and token counts.

## Requirements

### Requirement: Prompt context does not depend on opened folders
The prompt file tree, the file contents, the codemaps and the token counts SHALL be the same for the same root folders and selection, whichever folders are opened in the tree.

#### Scenario: Prompt file tree with unopened folders
- **WHEN** the user builds a prompt while no folder is opened
- **THEN** the prompt file tree holds the same entries as when every folder is opened

#### Scenario: Token count for files in unopened folders
- **WHEN** files in unopened folders are selected
- **THEN** the token count includes their full content as it would with their folders opened

### Requirement: Every code file gets a codemap in the background
After reading of a root folder completes, every code file in its index SHALL get a codemap at low priority, without slowing the tree or the selection.

#### Scenario: Codemap for a file in an unopened folder
- **WHEN** reading is complete and the background codemap work has finished
- **THEN** a code file in a folder the user never opened has a codemap that auto codemaps and the complete codemap mode use
