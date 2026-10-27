#ifndef path_search_h
#define path_search_h

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Path search index structure
typedef struct path_search_index {
    char** forward_paths;      // Sorted array of the live paths; each string is the one in original_paths
    char** reversed_paths;     // Sorted array of reversed live paths
    char** original_paths;     // Paths by slot, in the order they were added; NULL once removed
    size_t* forward_indices;   // Maps forward index to slot
    size_t* reversed_indices;  // Maps reversed index to slot
    size_t count;              // Number of live paths
    size_t capacity;           // Allocated slots of original_paths
    size_t slot_count;         // Slots used, live and removed
} path_search_index_t;

// Pattern decomposition result
typedef struct pattern_parts {
    char* prefix;              // Longest literal prefix
    char* suffix;              // Longest literal suffix
    char* regex_pattern;       // Full regex pattern
    bool is_wildcard;          // Contains wildcards
} pattern_parts_t;

// Search result
typedef struct search_result {
    size_t* indices;           // Array of matching indices
    size_t count;              // Number of matches
    size_t capacity;           // Allocated capacity
} search_result_t;

// Index creation and destruction
path_search_index_t* path_search_create(const char** paths, size_t count);
void path_search_destroy(path_search_index_t* index);

// Incremental updates
// Adds the paths that are not in the index yet. When slots is not NULL, slots[i] is the slot of paths[i],
// or SIZE_MAX when the index already held it. Returns false when memory runs out.
bool path_search_add(path_search_index_t* index, const char** paths, size_t count, size_t* slots);
// Removes each path and every path under it ("path/..."). Returns how many it removed and sets
// *removed_slots to their slots, to be freed with path_search_free_slots.
size_t path_search_remove(path_search_index_t* index, const char** paths, size_t count, size_t** removed_slots);
void path_search_free_slots(size_t* slots);
// The path of a slot, or NULL when the slot is removed or out of range.
const char* path_search_path(const path_search_index_t* index, size_t slot);

// Pattern decomposition
pattern_parts_t* pattern_decompose(const char* pattern);
void pattern_parts_destroy(pattern_parts_t* parts);

// Binary search functions
size_t path_search_lower_bound(const char** array, size_t count, const char* prefix);
size_t path_search_upper_bound(const char** array, size_t count, const char* prefix);

// Main search function
search_result_t* path_search_find(
    path_search_index_t* index,
    const char* pattern,
    size_t limit
);
void search_result_destroy(search_result_t* result);

// Helper functions
char* path_reverse(const char* path);
int path_compare(const void* a, const void* b);
bool path_matches_regex(const char* path, const char* regex_pattern);

#ifdef __cplusplus
}
#endif

#endif /* path_search_h */