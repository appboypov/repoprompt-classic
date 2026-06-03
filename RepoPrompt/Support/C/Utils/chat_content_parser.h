/*
 * chat_content_parser.h
 *
 * C implementation of ChatContentParser functionality
 * Provides high-performance parsing of chat content including files, plans, and changes
 */

#ifndef CHAT_CONTENT_PARSER_H
#define CHAT_CONTENT_PARSER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* MARK: - Type Definitions */

typedef enum {
    CONTENT_TYPE_TEXT,
    CONTENT_TYPE_FILE,
    CONTENT_TYPE_CODE
} ContentItemType;

typedef enum {
    LINE_SEGMENT_TYPE_TEXT,
    LINE_SEGMENT_TYPE_CODE,
    LINE_SEGMENT_TYPE_FILE
} LineSegmentType;

typedef struct {
    char *id;
    LineSegmentType type;
    char *text;
} LineSegment;

typedef struct {
    int start_index_in_stream;
    ContentItemType type;
    char *content;
    char *file_path;       /* NULL unless type == CONTENT_TYPE_FILE */
    char *action;          /* NULL unless type == CONTENT_TYPE_FILE */
    char **changes;        /* Array of change strings, NULL terminated */
    char **descriptions;   /* Array of description strings, NULL terminated */
    LineSegment *line_segments;
    size_t line_segment_count;
    LineSegment **change_line_segments; /* Array of LineSegment arrays, one per change */
    size_t *change_line_segment_counts; /* Array of counts for each change's segments */
    size_t change_count;                /* Number of changes (for array bounds) */
} ContentItem;

typedef struct {
    char *description;
    char *code_snippet;
    int complexity;
} DelegateEditChange;

typedef struct {
    char *file_path;
    DelegateEditChange *changes;
    size_t change_count;
} DelegateEditItem;

typedef struct {
    ContentItem *items;
    size_t item_count;
    char *core_content;
    DelegateEditItem *delegate_edits;
    size_t delegate_edit_count;
} ParseResult;

/* MARK: - Public Functions */

/**
 * Main entry point for parsing content.
 * 
 * @param content The raw content to parse
 * @param processed_hashes Set of already processed delegate edit hashes (can be NULL)
 * @param hash_count Number of hashes in processed_hashes array
 * @param is_final Whether this is a final parse (vs streaming/partial)
 * @param enable_debug Enable debug logging
 * @return ParseResult structure containing parsed items (must be freed with repo_free_parse_result)
 */
ParseResult* repo_parse_content(
    const char *content,
    int64_t *processed_hashes,
    size_t hash_count,
    bool is_final,
    bool enable_debug
);

/**
 * Frees all memory associated with a ParseResult
 */
void repo_free_parse_result(ParseResult *result);

/**
 * Removes CDATA tags from content
 */
char* repo_strip_cdata(const char *content);

/**
 * Extracts content between XML-like tags
 * 
 * @param content The content to search in
 * @param tag The tag name (without angle brackets)
 * @param flexible Whether to be flexible about tag format
 * @return Dynamically allocated string (must be freed) or NULL
 */
char* repo_extract_content(const char *content, const char *tag, bool flexible);

/**
 * Splits content into lines preserving line endings
 * 
 * @param content The content to split
 * @param preserve_empty Whether to preserve empty lines
 * @param out_lines Output array of lines (must be freed)
 * @param out_count Output line count
 * @return The detected line ending
 */
char* repo_split_content_to_lines(const char *content, bool preserve_empty, 
                                 char ***out_lines, size_t *out_count);

/**
 * Parses and removes chat name from content
 * 
 * @param content The content to parse (will be modified)
 * @return The extracted chat name (must be freed) or NULL
 */
char* repo_parse_and_remove_chat_name(char **content);

/**
 * Extracts the scope description from a code snippet
 * 
 * @param snippet The code snippet to search
 * @return The extracted description (must be freed) or empty string
 */
char* repo_extract_scope_description(const char *snippet);

/**
 * Decodes indentation in a code block
 * 
 * @param code_block The code block to decode
 * @return Decoded code block (must be freed)
 */
char* repo_decode_indentation_in_code_block(const char *code_block);

/**
 * Hash a delegate edit item for deduplication
 * 
 * @param item The delegate edit item to hash
 * @return Hash value
 */
int64_t repo_hash_delegate_edit_item(const DelegateEditItem *item);

/**
 * Enable or disable debug logging
 */
void repo_set_debug_logging(bool enabled);

/* MARK: - Utility Functions (already implemented in string_extensions_wrapper.c) */

/* These are already declared in string_extensions_wrapper.h:
 * - repo_remove_outer_backticks
 * - repo_trim_leading_whitespace
 * - repo_extract_description
 * - repo_extract_complexity
 * - repo_decode_indentation
 */

#ifdef __cplusplus
}
#endif

#endif /* CHAT_CONTENT_PARSER_H */