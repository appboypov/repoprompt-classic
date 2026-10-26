## Purpose

Reading fills the index of every root folder from disk in the background, so the app knows all files and folders of huge root folders without blocking the user.

## ADDED Requirements

### Requirement: Reading fills a complete index
Reading SHALL fill the index of a root folder with exactly the files and folders that pass the ignore rules, with no limit on their number.

#### Scenario: Same files as the ignore rules allow
- **WHEN** a root folder with nested ignore files is added to a workspace and reading completes
- **THEN** the index holds every file and folder that the ignore rules allow and none that they exclude

#### Scenario: No file limit
- **WHEN** a root folder holds hundreds of thousands of files
- **THEN** reading indexes all of them

### Requirement: Reading runs in the background without freezing the app
Reading SHALL run off the main thread on all cores at background priority, and the main thread SHALL NOT be blocked for more than a tenth of a second at a time while a root folder is read.

#### Scenario: App stays responsive during reading
- **WHEN** a huge root folder is being read
- **THEN** the user can scroll, type and click without a freeze longer than a tenth of a second

### Requirement: Reading reports progress per root folder
The app SHALL report for each root folder whether reading is complete and how many files are read so far.

#### Scenario: Progress while reading
- **WHEN** reading of a root folder is running
- **THEN** the root folder reports "reading" with the number of files read so far

#### Scenario: Progress when complete
- **WHEN** reading of a root folder finishes
- **THEN** the root folder reports reading as complete

### Requirement: Folders the user needs are read first
Reading SHALL list an opened folder that reading has not reached yet at once, and SHALL read the subtree of a ticked folder ahead of the rest of the root folder.

#### Scenario: Opening an unread folder
- **WHEN** the user opens a folder that reading has not reached
- **THEN** its direct children are shown without waiting for the rest of the root folder

#### Scenario: Ticking an unread folder
- **WHEN** the user ticks a folder whose subtree is not fully read
- **THEN** that subtree is read before other unread folders

### Requirement: Active workspace reads first
The active workspace's root folders SHALL be read before the root folders of hidden workspaces, which SHALL be read afterwards at low priority.

#### Scenario: Launch with several workspaces
- **WHEN** the app launches with several workspaces
- **THEN** reading of the active workspace's root folders starts first and hidden workspaces follow at low priority

### Requirement: The index follows changes on disk
The index SHALL reflect files and folders that are added, changed, moved or removed on disk anywhere in a root folder, opened or not.

#### Scenario: File added in an unopened folder
- **WHEN** a file is created on disk in a folder the user never opened
- **THEN** the index holds it and search and agent tools find it

#### Scenario: Folder removed
- **WHEN** a folder is removed on disk
- **THEN** the index no longer holds it or anything under it

### Requirement: Removing a root folder frees its index
Removing a root folder from a workspace SHALL drop its index and its tree items.

#### Scenario: Root folder removed
- **WHEN** the user removes a root folder
- **THEN** no file of that root folder appears in the tree, selection, search or agent answers
