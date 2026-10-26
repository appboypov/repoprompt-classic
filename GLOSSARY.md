# Repo Prompt Classic

A macOS app that turns the files of a workspace into prompts and tool answers for models and agents.

## Files

**Workspace**:
A named set of root folders that the user works in at one time.
_Avoid_: Project, session

**Root folder**:
A folder on disk that the user adds to a workspace, with everything under it.
_Avoid_: Repo, root path

**Index**:
The complete list of files and folders of a root folder that the app knows, after ignore rules.
_Avoid_: File cache, path tracker

**Reading**:
The background work that fills the index of a root folder from disk.
_Avoid_: Scanning, crawling, loading

**Opened folder**:
A folder the user has expanded in the file tree, so its direct children are shown.
_Avoid_: Loaded folder, materialised folder

**Empty folder**:
A folder with no file under it after ignore rules, at any depth.

## Selection

**Selection**:
The set of files, named by path, that go into the prompt and agent context.
_Avoid_: Checked files, picked files

**Ticked folder**:
A folder whose every file in the index is in the selection.
_Avoid_: Checked folder
