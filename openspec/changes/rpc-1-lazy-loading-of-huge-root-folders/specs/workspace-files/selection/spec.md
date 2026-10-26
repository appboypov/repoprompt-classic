## Purpose

The selection is the set of files, named by path, that go into the prompt and agent context, and it works for every file of a root folder whether its folder is opened or not.

## ADDED Requirements

### Requirement: Ticking a folder selects every file under it
Ticking a folder SHALL put every file under it in the index into the selection, whether or not the folder or its subfolders are opened.

#### Scenario: Tick an unopened folder that is fully read
- **WHEN** the user ticks a folder they never opened and its subtree is fully read
- **THEN** every file under it is selected and the token count includes them

#### Scenario: Untick a folder
- **WHEN** the user unticks a ticked folder
- **THEN** no file under it is selected

### Requirement: Ticking a folder that is still being read
A ticked folder whose subtree is not fully read SHALL show a spinner on its checkbox until every file under it is found, then SHALL show ticked with all those files selected and the token count updated.

#### Scenario: Tick during reading
- **WHEN** the user ticks a folder whose subtree reading has not finished
- **THEN** its checkbox shows a spinner, and once the subtree is read every file under it is selected and the checkbox shows ticked

### Requirement: Folder checkbox state comes from the whole subtree
A folder's checkbox SHALL show ticked when every file under it is selected, mixed when some are, and empty when none are, for opened and unopened folders alike.

#### Scenario: Unopened folder with some files selected
- **WHEN** an agent selects one file deep inside a folder the user never opened
- **THEN** that folder and each folder above it show mixed

### Requirement: Selections restore by path
A saved selection, including selection slices of files, SHALL restore for every file that still exists, including files in folders that are not opened.

#### Scenario: Restore a selection in unopened folders
- **WHEN** the user switches back to a tab whose selection holds files in folders that are not opened
- **THEN** exactly those files are selected again and the token count matches

### Requirement: New files on disk keep today's selection rule
A file that appears on disk inside a ticked folder SHALL NOT be selected, unless an agent created it through the app.

#### Scenario: File appears in a ticked folder
- **WHEN** a file is created on disk outside the app inside a ticked folder
- **THEN** the file is not selected and the folder shows mixed

#### Scenario: Agent creates a file
- **WHEN** an agent creates a file through the app
- **THEN** the file is selected
