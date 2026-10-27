# workspace-files/file-tree Specification

## Purpose
The file tree shows the root folders of a workspace and the folders the user opens, at once and without waiting for reading to finish.

## Requirements

### Requirement: The tree shows at once
The file tree of a root folder SHALL show within one second of adding or restoring it, whatever its size.

#### Scenario: Adding a huge root folder
- **WHEN** the user adds a root folder with hundreds of thousands of files
- **THEN** the root folder and its direct children are visible within one second

### Requirement: Only opened folders show children
The tree SHALL show the children of root folders and opened folders only, and opening a folder SHALL show its direct children at once.

#### Scenario: Opening a folder
- **WHEN** the user opens a folder
- **THEN** its direct files and folders are shown

#### Scenario: Opened folder follows disk
- **WHEN** a file is added or removed on disk in an opened folder
- **THEN** the tree shows the change

### Requirement: Opened folders are restored
Folders the user had opened SHALL be open again after a restart, a workspace switch or a tab switch.

#### Scenario: Restart
- **WHEN** the app restarts with a workspace whose folders were open
- **THEN** the same folders are open again

### Requirement: Reading state on the root folder row
The row of a root folder SHALL show a spinner and the number of files read so far while reading runs, and SHALL show neither once reading is complete.

#### Scenario: Reading running
- **WHEN** a root folder is being read
- **THEN** its row shows a spinner and the files-read count

#### Scenario: Reading complete
- **WHEN** reading of a root folder completes
- **THEN** its row shows no spinner and no count

### Requirement: Empty folders show by default
The tree SHALL show empty folders unless the user turns on hiding of empty folders. With hiding on, a folder SHALL leave the tree once reading of its subtree is complete and it holds no file.

#### Scenario: Default setting
- **WHEN** a root folder holds a folder with no files under it and the user did not change the setting
- **THEN** the tree shows that folder

#### Scenario: Hiding turned on
- **WHEN** hiding of empty folders is on and reading finds a folder with no files under it
- **THEN** that folder leaves the tree
