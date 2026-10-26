# Path-Based Selection and a Lazy File Tree

Root folders such as `~/hq` hold about 500k files, and building a tree item for every file froze the app and took minutes. We decided that the index and the selection name files by path, and that the file tree builds items only for opened folders, while reading fills the index in the background on all cores. Every result the user and agents see stays the same as with a full tree: prompt file trees, token counts, search, codemaps and tool answers come from the index, and agent requests wait until the index of their root folder is complete.

## Considered Options

- Keep a tree item for every file and only make building it cheaper: rejected, because the item count itself is the cost and select-all on a big folder stays slow.
- List only opened folders and skip the full read: rejected, because search, token counts and agents need the complete picture.
- Give agents partial answers while reading runs: rejected, because an agent could conclude that a file does not exist.
