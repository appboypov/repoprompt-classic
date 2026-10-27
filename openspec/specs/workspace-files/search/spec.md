# workspace-files/search Specification

## Purpose
Search lets the user find files and folders of a root folder by name, path and content, whether their folders are opened or not.

## Requirements

### Requirement: Search covers the whole index
Tree search and filter, content search, file mentions, file tag suggestions and pasted path resolution SHALL find files in folders that are not opened.

#### Scenario: Find a file in an unopened folder
- **WHEN** the user searches for the name of a file in a folder they never opened and reading has reached it
- **THEN** the file is in the results

#### Scenario: Mention a file in an unopened folder
- **WHEN** the user types a mention of a file in an unopened folder
- **THEN** the suggestion list offers that file

### Requirement: Search works while reading runs
While a root folder is being read, search SHALL return matches from what is read so far, and its results SHALL grow as reading continues.

#### Scenario: Search during reading
- **WHEN** the user searches while reading is running
- **THEN** the results hold the matches read so far and gain new matches as reading continues
