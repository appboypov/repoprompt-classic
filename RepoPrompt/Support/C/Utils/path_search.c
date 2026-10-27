#include "path_search.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <regex.h>
#include <stdio.h>
#include "../wildmatch/wildmatch.h"

// Debug logging macros
//#define DEBUG_SEARCH 1
#ifdef DEBUG_SEARCH
#define SEARCH_LOG(...) printf(__VA_ARGS__)
#else
#define SEARCH_LOG(...) ((void)0)
#endif

// A path with the slot it belongs to, as the sorted arrays hold it.
typedef struct {
    char* path;
    size_t original_index;
} path_with_index_t;

// The position of a path in the sorted forward array, or SIZE_MAX when the index does not hold it.
static size_t forward_position(const path_search_index_t* index, const char* path) {
    size_t left = 0;
    size_t right = index->count;
    while (left < right) {
        size_t mid = (left + right) / 2;
        if (strcmp(index->forward_paths[mid], path) < 0) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    if (left < index->count && strcmp(index->forward_paths[left], path) == 0) {
        return left;
    }
    return SIZE_MAX;
}

static bool grow(void** array, size_t capacity, size_t size) {
    void* grown = realloc(*array, capacity * size);
    if (!grown) return false;
    *array = grown;
    return true;
}

// Makes room for `needed` slots. Live paths never outnumber slots, so the sorted arrays share the capacity.
static bool reserve(path_search_index_t* index, size_t needed) {
    if (needed <= index->capacity) return true;
    size_t capacity = index->capacity * 2;
    if (capacity < needed) capacity = needed;
    if (!grow((void**)&index->original_paths, capacity, sizeof(char*))) return false;
    if (!grow((void**)&index->forward_paths, capacity, sizeof(char*))) return false;
    if (!grow((void**)&index->reversed_paths, capacity, sizeof(char*))) return false;
    if (!grow((void**)&index->forward_indices, capacity, sizeof(size_t))) return false;
    if (!grow((void**)&index->reversed_indices, capacity, sizeof(size_t))) return false;
    index->capacity = capacity;
    return true;
}

// Merges `count` sorted entries into the first `live` entries of a sorted array that has room for both.
static void merge_sorted(char** paths, size_t* indices, size_t live, const path_with_index_t* entries, size_t count) {
    size_t i = live;
    size_t j = count;
    size_t w = live + count;
    while (j > 0) {
        if (i > 0 && strcmp(paths[i - 1], entries[j - 1].path) > 0) {
            paths[w - 1] = paths[i - 1];
            indices[w - 1] = indices[i - 1];
            i--;
        } else {
            paths[w - 1] = entries[j - 1].path;
            indices[w - 1] = entries[j - 1].original_index;
            j--;
        }
        w--;
    }
}

// Create path search index
path_search_index_t* path_search_create(const char** paths, size_t count) {
    SEARCH_LOG("path_search_create: count=%zu\n", count);
    if (!paths || count == 0) {
        SEARCH_LOG("path_search_create: invalid input\n");
        return NULL;
    }
    
    path_search_index_t* index = calloc(1, sizeof(path_search_index_t));
    if (!index) return NULL;
    if (!path_search_add(index, paths, count, NULL)) {
        path_search_destroy(index);
        return NULL;
    }
    return index;
}

bool path_search_add(path_search_index_t* index, const char** paths, size_t count, size_t* slots) {
    if (!index || (!paths && count > 0)) return false;
    if (count == 0) return true;
    
    // Slots follow the order of `paths`, so callers can find their own data for a match by slot.
    path_with_index_t* forward = calloc(count, sizeof(path_with_index_t));
    path_with_index_t* reversed = calloc(count, sizeof(path_with_index_t));
    bool ok = forward && reversed;
    size_t added_count = 0;
    for (size_t i = 0; ok && i < count; i++) {
        if (slots) slots[i] = SIZE_MAX;
        if (!paths[i] || forward_position(index, paths[i]) != SIZE_MAX) continue;
        forward[added_count].path = strdup(paths[i]);
        reversed[added_count].path = path_reverse(paths[i]);
        forward[added_count].original_index = index->slot_count + added_count;
        reversed[added_count].original_index = index->slot_count + added_count;
        added_count++;
        if (!forward[added_count - 1].path || !reversed[added_count - 1].path) ok = false;
    }
    ok = ok && reserve(index, index->slot_count + added_count);
    if (!ok) {
        for (size_t k = 0; forward && reversed && k < added_count; k++) {
            free(forward[k].path);
            free(reversed[k].path);
        }
        free(forward);
        free(reversed);
        return false;
    }
    
    for (size_t i = 0, k = 0; slots && i < count; i++) {
        if (k < added_count && paths[i] && strcmp(paths[i], forward[k].path) == 0) {
            slots[i] = forward[k++].original_index;
        }
    }
    for (size_t k = 0; k < added_count; k++) {
        index->original_paths[forward[k].original_index] = forward[k].path;
    }
    index->slot_count += added_count;
    qsort(forward, added_count, sizeof(path_with_index_t),
          (int (*)(const void*, const void*))path_compare);
    qsort(reversed, added_count, sizeof(path_with_index_t),
          (int (*)(const void*, const void*))path_compare);
    merge_sorted(index->forward_paths, index->forward_indices, index->count, forward, added_count);
    merge_sorted(index->reversed_paths, index->reversed_indices, index->count, reversed, added_count);
    index->count += added_count;
    
    free(forward);
    free(reversed);
    return true;
}

size_t path_search_remove(path_search_index_t* index, const char** paths, size_t count, size_t** removed_slots) {
    if (removed_slots) *removed_slots = NULL;
    if (!index || !paths || count == 0 || index->count == 0) return 0;
    
    bool* removed = calloc(index->slot_count, sizeof(bool));
    size_t* list = malloc(index->count * sizeof(size_t));
    if (!removed || !list) {
        free(removed);
        free(list);
        return 0;
    }
    size_t removed_count = 0;
    
    for (size_t i = 0; i < count; i++) {
        if (!paths[i]) continue;
        size_t position = forward_position(index, paths[i]);
        if (position != SIZE_MAX && !removed[index->forward_indices[position]]) {
            removed[index->forward_indices[position]] = true;
            list[removed_count++] = index->forward_indices[position];
        }
        
        // Every path under it starts with "path/", so they sit next to each other in sorted order.
        size_t length = strlen(paths[i]);
        char* prefix = malloc(length + 2);
        if (!prefix) continue;
        memcpy(prefix, paths[i], length);
        prefix[length] = '/';
        prefix[length + 1] = '\0';
        size_t start = path_search_lower_bound((const char**)index->forward_paths, index->count, prefix);
        size_t end = path_search_upper_bound((const char**)index->forward_paths, index->count, prefix);
        for (size_t p = start; p < end; p++) {
            size_t slot = index->forward_indices[p];
            if (!removed[slot]) {
                removed[slot] = true;
                list[removed_count++] = slot;
            }
        }
        free(prefix);
    }
    
    if (removed_count > 0) {
        size_t w = 0;
        for (size_t r = 0; r < index->count; r++) {
            if (removed[index->forward_indices[r]]) continue;
            index->forward_paths[w] = index->forward_paths[r];
            index->forward_indices[w] = index->forward_indices[r];
            w++;
        }
        w = 0;
        for (size_t r = 0; r < index->count; r++) {
            if (removed[index->reversed_indices[r]]) {
                free(index->reversed_paths[r]);
                continue;
            }
            index->reversed_paths[w] = index->reversed_paths[r];
            index->reversed_indices[w] = index->reversed_indices[r];
            w++;
        }
        for (size_t i = 0; i < removed_count; i++) {
            free(index->original_paths[list[i]]);
            index->original_paths[list[i]] = NULL;
        }
        index->count -= removed_count;
    }
    
    free(removed);
    if (removed_count > 0 && removed_slots) {
        *removed_slots = list;
    } else {
        free(list);
    }
    return removed_count;
}

void path_search_free_slots(size_t* slots) {
    free(slots);
}

const char* path_search_path(const path_search_index_t* index, size_t slot) {
    if (!index || slot >= index->slot_count) return NULL;
    return index->original_paths[slot];
}

// Destroy path search index
void path_search_destroy(path_search_index_t* index) {
    if (!index) return;
    
    // The forward array shares its strings with original_paths.
    if (index->original_paths) {
        for (size_t i = 0; i < index->slot_count; i++) {
            free(index->original_paths[i]);
        }
    }
    if (index->reversed_paths) {
        for (size_t i = 0; i < index->count; i++) {
            free(index->reversed_paths[i]);
        }
    }
    free(index->original_paths);
    free(index->forward_paths);
    free(index->reversed_paths);
    free(index->forward_indices);
    free(index->reversed_indices);
    free(index);
}

// Pattern decomposition
pattern_parts_t* pattern_decompose(const char* pattern) {
    if (!pattern) return NULL;
    
    pattern_parts_t* parts = calloc(1, sizeof(pattern_parts_t));
    if (!parts) return NULL;
    
    size_t len = strlen(pattern);
    const char* meta_chars = "*?[]{}()|.+^$\\";
    
    // Check if pattern contains wildcards
    parts->is_wildcard = (strpbrk(pattern, "*?") != NULL);
    
    // Check if pattern contains spaces (for multi-term search)
    bool has_spaces = strchr(pattern, ' ') != NULL && !parts->is_wildcard;
    
    // For non-wildcard patterns, use empty prefix/suffix to search all files
    if (!parts->is_wildcard) {
        parts->prefix = strdup("");
        parts->suffix = strdup("");
    } else {
        // Find prefix (longest literal before first metachar)
        size_t prefix_len = 0;
        for (size_t i = 0; i < len; i++) {
            if (strchr(meta_chars, pattern[i])) {
                break;
            }
            prefix_len++;
        }
        
        parts->prefix = strndup(pattern, prefix_len);
        
        // Find suffix (longest literal after last metachar)
        // For *.swift, we want suffix="swift" not ".swift"
        size_t suffix_start = len;
        for (size_t i = len; i > prefix_len; i--) {
            if (strchr(meta_chars, pattern[i - 1])) {
                suffix_start = i;
                break;
            }
        }
        
        if (suffix_start < len) {
            parts->suffix = strdup(pattern + suffix_start);
        } else {
            parts->suffix = strdup("");
        }
    }
    
    // Convert glob to regex
    char* regex_buf = calloc(len * 10 + 100, sizeof(char)); // Extra space for AND logic
    if (!regex_buf) {
        pattern_parts_destroy(parts);
        return NULL;
    }
    
    char* out = regex_buf;
    
    // Handle space-separated terms as AND conditions
    if (has_spaces) {
        // For space-separated patterns, we'll store the pattern as-is
        // and handle the AND logic during matching
        // Store a special marker to indicate this needs AND processing
        strcpy(out, "SPACE_AND:");
        out += 10;
        strcpy(out, pattern);
        out += strlen(pattern);
        *out = '\0';
    } else {
        // Original single-pattern logic
        // If pattern has no wildcards, search for it as a substring
        if (!parts->is_wildcard) {
            *out++ = '.';
            *out++ = '*';
        } else {
            // For wildcard patterns, check if pattern starts with *
            // If so, we want to match anywhere in the path
            if (pattern[0] == '*') {
                *out++ = '.';
                *out++ = '*';
            } else {
                *out++ = '^';
            }
        }
        
        for (size_t i = 0; i < len; i++) {
            char c = pattern[i];
            
            if (c == '*') {
                // Check for **
                if (i + 1 < len && pattern[i + 1] == '*') {
                    *out++ = '.';
                    *out++ = '*';
                    i++; // Skip next *
                } else {
                    *out++ = '[';
                    *out++ = '^';
                    *out++ = '/';
                    *out++ = ']';
                    *out++ = '*';
                }
            } else if (c == '?') {
                *out++ = '[';
                *out++ = '^';
                *out++ = '/';
                *out++ = ']';
            } else if (strchr("[]{}().|+^$\\", c)) {
                *out++ = '\\';
                *out++ = c;
            } else {
                *out++ = c;
            }
        }
        
        if (!parts->is_wildcard) {
            *out++ = '.';
            *out++ = '*';
        } else {
            *out++ = '$';
        }
        *out = '\0';
    }
    
    parts->regex_pattern = regex_buf;
    
    SEARCH_LOG("pattern_decompose: pattern='%s'\n", pattern);
    SEARCH_LOG("  is_wildcard=%d, has_spaces=%d\n", parts->is_wildcard, has_spaces);
    SEARCH_LOG("  prefix='%s', suffix='%s'\n", parts->prefix, parts->suffix);
    SEARCH_LOG("  regex='%s' (strlen=%zu)\n", parts->regex_pattern, strlen(parts->regex_pattern));
    // Check if regex ends with $
    size_t regex_len = strlen(parts->regex_pattern);
    if (regex_len > 0) {
        SEARCH_LOG("  regex last char: '%c' (0x%02x)\n", 
                   parts->regex_pattern[regex_len-1], 
                   (unsigned char)parts->regex_pattern[regex_len-1]);
    }
    
    return parts;
}

void pattern_parts_destroy(pattern_parts_t* parts) {
    if (!parts) return;
    free(parts->prefix);
    free(parts->suffix);
    free(parts->regex_pattern);
    free(parts);
}

// Binary search for lower bound
size_t path_search_lower_bound(const char** array, size_t count, const char* prefix) {
    if (!array || !prefix || count == 0) return 0;
    
    size_t left = 0;
    size_t right = count;
    size_t prefix_len = strlen(prefix);
    
    while (left < right) {
        size_t mid = (left + right) / 2;
        if (strncmp(array[mid], prefix, prefix_len) < 0) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    
    return left;
}

// Binary search for upper bound
size_t path_search_upper_bound(const char** array, size_t count, const char* prefix) {
    if (!array || !prefix || count == 0) return count;
    
    size_t left = 0;
    size_t right = count;
    size_t prefix_len = strlen(prefix);
    
    while (left < right) {
        size_t mid = (left + right) / 2;
        
        // Compare with prefix
        int cmp = strncmp(array[mid], prefix, prefix_len);
        if (cmp <= 0) {
            // array[mid] is less than prefix OR starts with prefix
            left = mid + 1;
        } else {
            // array[mid] is greater than prefix
            right = mid;
        }
    }
    
    return left;
}

// Main search function
search_result_t* path_search_find(
    path_search_index_t* index,
    const char* pattern,
    size_t limit
) {
    SEARCH_LOG("path_search_find: pattern='%s', limit=%zu\n", pattern, limit);
    if (!index || !pattern) {
        SEARCH_LOG("path_search_find: invalid input\n");
        return NULL;
    }
    
    pattern_parts_t* parts = pattern_decompose(pattern);
    if (!parts) return NULL;
    
    SEARCH_LOG("path_search_find: prefix='%s', suffix='%s', regex='%s'\n", 
           parts->prefix, parts->suffix, parts->regex_pattern);
    
    // Get prefix range
    size_t prefix_start = path_search_lower_bound(
        (const char**)index->forward_paths, index->count, parts->prefix);
    size_t prefix_end = path_search_upper_bound(
        (const char**)index->forward_paths, index->count, parts->prefix);
    
    SEARCH_LOG("path_search_find: prefix range [%zu, %zu) out of %zu paths\n", 
           prefix_start, prefix_end, index->count);
    
    // Create initial candidate set
    size_t* candidates = NULL;
    size_t candidate_count = 0;
    
    if (strlen(parts->suffix) > 0) {
        // Need to intersect with suffix matches
        char* reversed_suffix = path_reverse(parts->suffix);
        
        SEARCH_LOG("path_search_find: suffix='%s', reversed='%s'\n", 
                   parts->suffix, reversed_suffix);
        
        size_t suffix_start = path_search_lower_bound(
            (const char**)index->reversed_paths, index->count, reversed_suffix);
        size_t suffix_end = path_search_upper_bound(
            (const char**)index->reversed_paths, index->count, reversed_suffix);
        
        SEARCH_LOG("path_search_find: suffix range [%zu, %zu)\n", 
                   suffix_start, suffix_end);
        
        
        // Build set of original indices from suffix matches
        bool* suffix_set = calloc(index->slot_count, sizeof(bool));
        for (size_t i = suffix_start; i < suffix_end; i++) {
            suffix_set[index->reversed_indices[i]] = true;
        }
        
        // Intersect with prefix matches
        candidates = calloc(prefix_end - prefix_start, sizeof(size_t));
        for (size_t i = prefix_start; i < prefix_end; i++) {
            size_t orig_idx = index->forward_indices[i];
            if (suffix_set[orig_idx]) {
                candidates[candidate_count++] = orig_idx;
            }
        }
        
        free(suffix_set);
        free(reversed_suffix);
    } else {
        // Just use prefix matches
        candidate_count = prefix_end - prefix_start;
        candidates = calloc(candidate_count, sizeof(size_t));
        for (size_t i = 0; i < candidate_count; i++) {
            candidates[i] = index->forward_indices[prefix_start + i];
        }
    }
    
    
    // Apply regex filter or special space handling
    search_result_t* result = calloc(1, sizeof(search_result_t));
    result->capacity = limit < candidate_count ? limit : candidate_count;
    result->indices = calloc(result->capacity, sizeof(size_t));
    result->count = 0;
    
    // A pattern without wildcards matches every path that holds each of its space-separated terms.
    // A plain substring check is many times faster than the equivalent `.*term.*` regex.
    if (!parts->is_wildcard) {
        const char* space_pattern = pattern;
        
        SEARCH_LOG("path_search_find: handling space-separated AND pattern '%s'\n", space_pattern);
        
        // Split the pattern and check each term
        char* pattern_copy = strdup(space_pattern);
        
        // First, collect all terms
        char* terms[20]; // Max 20 terms
        int term_count = 0;
        char* token = strtok(pattern_copy, " ");
        while (token != NULL && term_count < 20) {
            if (strlen(token) > 0) {
                terms[term_count++] = strdup(token);
            }
            token = strtok(NULL, " ");
        }
        free(pattern_copy);
        
        // Now check each candidate against all terms
        SEARCH_LOG("path_search_find: testing %zu candidates with %d terms\n", candidate_count, term_count);
        for (size_t i = 0; i < candidate_count && result->count < limit; i++) {
            size_t orig_idx = candidates[i];
            const char* path = index->original_paths[orig_idx];
            
            if (path) {
                // Check if all terms are present (case-insensitive)
                int all_match = 1;
                for (int j = 0; j < term_count; j++) {
                    if (strcasestr(path, terms[j]) == NULL) {
                        all_match = 0;
                        break;
                    }
                }
                
                if (all_match) {
                    result->indices[result->count++] = orig_idx;
                    if (result->count <= 5) {
                        SEARCH_LOG("  matched: %s\n", path);
                    }
                }
            }
        }
        
        // Free the terms
        for (int i = 0; i < term_count; i++) {
            free(terms[i]);
        }
    } else {
        // Regular regex matching
        regex_t regex;
        int ret = regcomp(&regex, parts->regex_pattern, REG_EXTENDED | REG_ICASE);
        
        if (ret == 0) {
            SEARCH_LOG("path_search_find: testing %zu candidates with regex\n", candidate_count);
            for (size_t i = 0; i < candidate_count && result->count < limit; i++) {
                size_t orig_idx = candidates[i];
                // Get the original path using the index
                const char* path = index->original_paths[orig_idx];
                
                if (path && regexec(&regex, path, 0, NULL, 0) == 0) {
                    result->indices[result->count++] = orig_idx;
                    if (result->count <= 5) {  // Log first few matches
                        SEARCH_LOG("  matched: %s\n", path);
                    }
                }
            }
            regfree(&regex);
        } else {
            char errbuf[256];
            regerror(ret, &regex, errbuf, sizeof(errbuf));
            SEARCH_LOG("path_search_find: regex compilation failed: %s (error code: %d)\n", errbuf, ret);
        }
    }
    
    free(candidates);
    pattern_parts_destroy(parts);
    
    return result;
}

void search_result_destroy(search_result_t* result) {
    if (!result) return;
    free(result->indices);
    free(result);
}

// Helper: reverse a string
char* path_reverse(const char* path) {
    if (!path) return NULL;
    
    size_t len = strlen(path);
    char* reversed = malloc(len + 1);
    if (!reversed) return NULL;
    
    for (size_t i = 0; i < len; i++) {
        reversed[i] = path[len - 1 - i];
    }
    reversed[len] = '\0';
    
    return reversed;
}

// Helper: compare paths for sorting
int path_compare(const void* a, const void* b) {
    const path_with_index_t* pa = (const path_with_index_t*)a;
    const path_with_index_t* pb = (const path_with_index_t*)b;
    
    return strcmp(pa->path, pb->path);
}