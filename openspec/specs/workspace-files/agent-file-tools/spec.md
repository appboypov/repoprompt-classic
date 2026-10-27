# workspace-files/agent-file-tools Specification

## Purpose
Agent file tools give agents the file tree, search, file reads, selection management, workspace context and file operations of a workspace, always from the complete picture of each root folder.

## Requirements

### Requirement: Agent tools answer from the complete index
Agent tools that need the full picture of a root folder (file tree, file search, selection by folder, workspace context) SHALL wait until reading of that root folder is complete and then answer from the complete index.

#### Scenario: File tree requested during reading
- **WHEN** an agent requests the file tree of a root folder that is still being read
- **THEN** the answer arrives after reading completes and holds every file and folder of the index

#### Scenario: File search during reading
- **WHEN** an agent searches a root folder that is still being read
- **THEN** the results come from the complete index

### Requirement: Agent answers do not depend on opened folders
Agent tool answers SHALL be the same for the same root folders and selection, whichever folders are opened in the tree.

#### Scenario: Read a file in an unopened folder
- **WHEN** an agent reads a file by path in a folder the user never opened
- **THEN** it gets the file's content

#### Scenario: Select a folder the user never opened
- **WHEN** an agent selects a folder by path that the user never opened
- **THEN** every file under it is selected, as with an opened folder

#### Scenario: Workspace context with unopened folders
- **WHEN** an agent requests the workspace context
- **THEN** the selection, token counts and file tree match what the user's prompt would hold

### Requirement: File operations update the index
Files that agents create, edit, move or delete in any folder SHALL be reflected in the index before the next agent tool call answers.

#### Scenario: Create then search
- **WHEN** an agent creates a file in an unopened folder and then searches for it
- **THEN** the search finds it
