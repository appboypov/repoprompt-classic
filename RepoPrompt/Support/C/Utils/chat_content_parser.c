/*
 * chat_content_parser.c
 *
 * C implementation of ChatContentParser functionality
 */

#include "chat_content_parser.h"
#include "string_extensions_wrapper.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <regex.h>
#include <ctype.h>
#include <limits.h>

/* MARK: - Debug Configuration */
static bool g_enable_debug_logging = false;

void repo_set_debug_logging(bool enabled) {
    g_enable_debug_logging = enabled;
    if (enabled) {
        printf("[ChatContentParser] 🐛 Debug logging ENABLED\n");
    } else {
        printf("[ChatContentParser] 🐛 Debug logging DISABLED\n");
    }
}

/* MARK: - Helper Macros */
#define DEBUG_LOG(...) do { \
    if (g_enable_debug_logging) { \
        printf("[ChatContentParser] "); \
        printf(__VA_ARGS__); \
        printf("\n"); \
    } \
} while(0)

/* MARK: - Regex Pattern Definitions */
typedef struct {
    regex_t file_regex;
    regex_t file_end_regex;
    regex_t plan_regex;
    regex_t plan_end_regex;
    regex_t change_regex;
    regex_t change_end_regex;
    regex_t description_regex;
    regex_t complexity_regex;
    regex_t delegate_edit_regex;
    regex_t scope_marker_regex;
    regex_t chat_name_regex;
} ParserRegexes;

static ParserRegexes *g_regexes = NULL;

/* Initialize regex patterns */
static bool init_regexes(void) {
    if (g_regexes) return true;
    
    g_regexes = calloc(1, sizeof(ParserRegexes));
    if (!g_regexes) return false;
    
    /* File regex: <file path="..." action="..."> */
    if (regcomp(&g_regexes->file_regex,
                "<file[[:space:]]+path[[:space:]]*=[[:space:]]*\"([^\"]+)\"[[:space:]]+action[[:space:]]*=[[:space:]]*\"([^\"]+)\"[^>]*>",
                REG_EXTENDED | REG_ICASE) != 0) goto error;
    
    /* File end regex: </file> */
    if (regcomp(&g_regexes->file_end_regex,
                "</file[[:space:]]*>",
                REG_EXTENDED | REG_ICASE) != 0) goto error;
    
    /* Plan regex: <Plan> */
    if (regcomp(&g_regexes->plan_regex,
                "<Plan[^>]*>",
                REG_EXTENDED | REG_ICASE) != 0) goto error;
    
    /* Plan end regex: </Plan> */
    if (regcomp(&g_regexes->plan_end_regex,
                "</Plan[[:space:]]*>",
                REG_EXTENDED | REG_ICASE) != 0) goto error;
    
    /* Change regex: <change> */
    if (regcomp(&g_regexes->change_regex,
                "<change[[:space:]]*>",
                REG_EXTENDED | REG_ICASE) != 0) goto error;
    
    /* Change end regex: </change> */
    if (regcomp(&g_regexes->change_end_regex,
                "</change[[:space:]]*>",
                REG_EXTENDED | REG_ICASE) != 0) goto error;
    
    /* Description regex: <description>(.*?)</description> */
    if (regcomp(&g_regexes->description_regex,
                "<description>([^<]*)</description>",
                REG_EXTENDED) != 0) goto error;
    
    /* Complexity regex: <complexity>(\d+)</complexity> */
    if (regcomp(&g_regexes->complexity_regex,
                "<complexity>([0-9]+)</complexity>",
                REG_EXTENDED) != 0) goto error;
    
    /* Delegate edit action regex */
    if (regcomp(&g_regexes->delegate_edit_regex,
                "action[[:space:]]*=[[:space:]]*\"delegate[[:space:]]+edit\"",
                REG_EXTENDED | REG_ICASE) != 0) goto error;
    
    /* Scope marker regex - capture description after dash */
    if (regcomp(&g_regexes->scope_marker_regex,
                "^[[:space:]]*(//|#|--|<!--)[[:space:]]*REPOMARK[[:space:]]*:[[:space:]]*SCOPE[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*-[[:space:]]*([^[:space:]].*[^[:space:]]|[^[:space:]])[[:space:]]*$",
                REG_EXTENDED | REG_ICASE) != 0) goto error;
    
    /* Chat name regex */
    if (regcomp(&g_regexes->chat_name_regex,
                "<chatName[[:space:]]*=[[:space:]]*\"([^\"]+)\"[[:space:]]*(/?)>",
                REG_EXTENDED) != 0) goto error;
    
    return true;
    
error:
    /* Free any successfully compiled regexes */
    if (g_regexes) {
        /* We don't know which regexes succeeded, so we need to be careful */
        /* In production, you'd track which ones were initialized */
        free(g_regexes);
        g_regexes = NULL;
    }
    DEBUG_LOG("Failed to compile regex patterns");
    return false;
}

/* MARK: - String Utilities */

static char* str_substring(const char *str, size_t start, size_t length) {
    if (!str) return NULL;
    
    size_t str_len = strlen(str);
    if (start >= str_len) return strdup("");
    
    /* Check for overflow/underflow */
    if (length > str_len || start + length < start) {
        return strdup("");
    }
    
    if (start + length > str_len) {
        length = str_len - start;
    }
    
    /* Additional safety check for extremely large allocations */
    if (length > 10 * 1024 * 1024) { /* 10MB limit */
        return NULL;
    }
    
    char *result = malloc(length + 1);
    if (!result) return NULL;
    
    memcpy(result, str + start, length);
    result[length] = '\0';
    
    return result;
}

static char* str_trim(const char *str) {
    if (!str) return NULL;
    
    /* Skip leading whitespace */
    while (*str && isspace((unsigned char)*str)) str++;
    
    if (*str == '\0') return strdup("");
    
    /* Find end */
    const char *end = str + strlen(str) - 1;
    while (end > str && isspace((unsigned char)*end)) end--;
    
    size_t len = (end - str) + 1;
    char *result = malloc(len + 1);
    if (!result) return NULL;
    memcpy(result, str, len);
    result[len] = '\0';
    return result;
}

static bool str_contains(const char *haystack, const char *needle) {
    if (!haystack || !needle) return false;
    return strstr(haystack, needle) != NULL;
}

static bool str_starts_with(const char *str, const char *prefix) {
    if (!str || !prefix) return false;
    return strncmp(str, prefix, strlen(prefix)) == 0;
}

static bool str_ends_with(const char *str, const char *suffix) {
    if (!str || !suffix) return false;
    size_t str_len = strlen(str);
    size_t suffix_len = strlen(suffix);
    if (suffix_len > str_len) return false;
    return strcmp(str + str_len - suffix_len, suffix) == 0;
}

/* MARK: - Line Segment Management */

static LineSegmentType content_type_to_line_segment_type(ContentItemType type) {
    switch (type) {
    case CONTENT_TYPE_TEXT:
        return LINE_SEGMENT_TYPE_TEXT;
    case CONTENT_TYPE_FILE:
        return LINE_SEGMENT_TYPE_FILE;
    case CONTENT_TYPE_CODE:
        return LINE_SEGMENT_TYPE_CODE;
    default:
        return LINE_SEGMENT_TYPE_TEXT;
    }
}

static LineSegment* create_line_segments(const char *content, ContentItemType item_type, 
                                       int base_start_index, size_t *out_count) {
    if (!content || !out_count) {
        if (out_count) *out_count = 0;
        return NULL;
    }
    
    /* Normalize line endings (CRLF -> LF) */
    char *normalized = strdup(content);
    if (!normalized) {
        *out_count = 0;
        return NULL;
    }
    
    /* Replace \r\n with \n */
    char *read = normalized;
    char *write = normalized;
    while (*read) {
        if (*read == '\r' && *(read + 1) == '\n') {
            *write++ = '\n';
            read += 2;
        } else {
            *write++ = *read++;
        }
    }
    *write = '\0';
    
    /* Split into chunks based on type */
    char **chunks = NULL;
    size_t chunk_count = 0;
    
    if (item_type == CONTENT_TYPE_TEXT) {
        /* For text, split on double newlines */
        /* This is simplified - in production you'd want proper paragraph splitting */
        char **lines = NULL;
        size_t line_count = 0;
        char *line_ending = repo_split_content_to_lines(normalized, true, &lines, &line_count);
        free(line_ending);
        
        if (!lines || line_count == 0) {
            free(normalized);
            *out_count = 0;
            return NULL;
        }
        
        /* Group lines into paragraphs */
        size_t chunk_capacity = 16;
        chunks = calloc(chunk_capacity, sizeof(char*));
        if (!chunks) {
            for (size_t i = 0; i < line_count; i++) free(lines[i]);
            free(lines);
            free(normalized);
            *out_count = 0;
            return NULL;
        }
        
        size_t paragraph_capacity = 4096;
        char *paragraph = malloc(paragraph_capacity);
        if (!paragraph) {
            free(chunks);
            for (size_t i = 0; i < line_count; i++) free(lines[i]);
            free(lines);
            free(normalized);
            *out_count = 0;
            return NULL;
        }
        paragraph[0] = '\0';
        size_t paragraph_len = 0;
        
        for (size_t i = 0; i < line_count; i++) {
            if (strlen(lines[i]) == 0 && paragraph_len > 0) {
                /* Empty line - end paragraph */
                if (chunk_count >= chunk_capacity) {
                    chunk_capacity *= 2;
                    chunks = realloc(chunks, chunk_capacity * sizeof(char*));
                }
                chunks[chunk_count++] = strdup(paragraph);
                paragraph[0] = '\0';
                paragraph_len = 0;
            } else if (strlen(lines[i]) > 0) {
                /* Add to paragraph with bounds checking */
                size_t line_len = strlen(lines[i]);
                size_t needed = paragraph_len + (paragraph_len > 0 ? 1 : 0) + line_len + 1;
                
                if (needed > paragraph_capacity) {
                    /* Grow paragraph buffer */
                    size_t new_capacity = paragraph_capacity * 2;
                    while (new_capacity < needed) {
                        new_capacity *= 2;
                    }
                    char *new_paragraph = realloc(paragraph, new_capacity);
                    if (!new_paragraph) {
                        free(paragraph);
                        free(chunks);
                        for (size_t j = i; j < line_count; j++) free(lines[j]);
                        free(lines);
                        free(normalized);
                        *out_count = 0;
                        return NULL;
                    }
                    paragraph = new_paragraph;
                    paragraph_capacity = new_capacity;
                }
                
                if (paragraph_len > 0) {
                    paragraph[paragraph_len++] = '\n';
                }
                memcpy(paragraph + paragraph_len, lines[i], line_len);
                paragraph_len += line_len;
                paragraph[paragraph_len] = '\0';
            }
            free(lines[i]);
        }
        
        /* Don't forget last paragraph */
        if (paragraph_len > 0) {
            if (chunk_count >= chunk_capacity) {
                chunk_capacity *= 2;
                chunks = realloc(chunks, chunk_capacity * sizeof(char*));
            }
            chunks[chunk_count++] = strdup(paragraph);
        }
        
        free(paragraph);
        free(lines);
    } else {
        /* For code/file, split on newlines */
        char **lines = NULL;
        char *line_ending = repo_split_content_to_lines(normalized, false, &lines, &chunk_count);
        free(line_ending);
        chunks = lines;
        
        if (!chunks || chunk_count == 0) {
            free(normalized);
            *out_count = 0;
            return NULL;
        }
    }
    
    /* Create segments */
    if (chunk_count == 0) {
        /* No chunks - return empty array */
        free(chunks);
        free(normalized);
        *out_count = 0;
        return NULL;
    }
    
    LineSegment *segments = calloc(chunk_count + 1, sizeof(LineSegment));
    if (!segments) {
        for (size_t i = 0; i < chunk_count; i++) free(chunks[i]);
        free(chunks);
        free(normalized);
        *out_count = 0;
        return NULL;
    }
    
    LineSegmentType seg_type = content_type_to_line_segment_type(item_type);
    
    for (size_t i = 0; i < chunk_count; i++) {
        /* Create ID */
        char id[256];
        const char *type_str = item_type == CONTENT_TYPE_TEXT ? "text" :
                              item_type == CONTENT_TYPE_CODE ? "code" : "file";
        snprintf(id, sizeof(id), "%s-%d+%zu", type_str, base_start_index, i);
        
        segments[i].id = strdup(id);
        segments[i].type = seg_type;
        segments[i].text = strdup(chunks[i]);
        
        free(chunks[i]);
    }
    
    /* Add trailing newline segment for non-text if needed */
    if (item_type != CONTENT_TYPE_TEXT && str_ends_with(normalized, "\n")) {
        char id[256];
        const char *type_str = item_type == CONTENT_TYPE_CODE ? "code" : "file";
        snprintf(id, sizeof(id), "%s-%d+%zu", type_str, base_start_index, chunk_count);
        
        segments[chunk_count].id = strdup(id);
        segments[chunk_count].type = seg_type;
        segments[chunk_count].text = strdup("");
        chunk_count++;
    }
    
    free(chunks);
    free(normalized);
    
    *out_count = chunk_count;
    return segments;
}

static void free_line_segments(LineSegment *segments, size_t count) {
    if (!segments) return;
    for (size_t i = 0; i < count; i++) {
        free(segments[i].id);
        free(segments[i].text);
    }
    free(segments);
}

/* MARK: - ContentItem Management */

static ContentItem* create_content_item(int start_index, ContentItemType type, const char *content) {
    ContentItem *item = calloc(1, sizeof(ContentItem));
    if (!item) return NULL;
    
    item->start_index_in_stream = start_index;
    item->type = type;
    item->content = strdup(content ? content : "");
    
    /* Create line segments */
    item->line_segments = create_line_segments(item->content, type, start_index, &item->line_segment_count);
    
    if (g_enable_debug_logging) {
        printf("[DEBUG] Created content item type=%d, start=%d, segments=%zu\n", 
               type, start_index, item->line_segment_count);
        for (size_t i = 0; i < item->line_segment_count; i++) {
            if (item->line_segments && item->line_segments[i].id) {
                printf("[DEBUG]   Segment %zu: id='%s', text='%s'\n", 
                       i, item->line_segments[i].id, 
                       item->line_segments[i].text ? item->line_segments[i].text : "(null)");
            }
        }
    }
    
    return item;
}

static void free_content_item(ContentItem *item) {
    if (!item) return;
    
    free(item->content);
    free(item->file_path);
    free(item->action);
    
    /* Free changes array */
    if (item->changes) {
        for (char **p = item->changes; *p; p++) {
            free(*p);
        }
        free(item->changes);
    }
    
    /* Free descriptions array */
    if (item->descriptions) {
        for (char **p = item->descriptions; *p; p++) {
            free(*p);
        }
        free(item->descriptions);
    }
    
    free_line_segments(item->line_segments, item->line_segment_count);
    
    /* Free change line segments */
    if (item->change_line_segments) {
        for (size_t i = 0; i < item->change_count; i++) {
            if (item->change_line_segments[i]) {
                free_line_segments(item->change_line_segments[i], item->change_line_segment_counts[i]);
            }
        }
        free(item->change_line_segments);
    }
    
    free(item->change_line_segment_counts);
    free(item);
}

/* MARK: - DelegateEditItem Management */

static DelegateEditItem* create_delegate_edit_item(const char *file_path, DelegateEditChange *changes, size_t change_count) {
    DelegateEditItem *item = calloc(1, sizeof(DelegateEditItem));
    if (!item) return NULL;
    
    item->file_path = strdup(file_path ? file_path : "");
    item->change_count = change_count;
    
    if (change_count > 0) {
        item->changes = calloc(change_count, sizeof(DelegateEditChange));
        if (!item->changes) {
            free(item->file_path);
            free(item);
            return NULL;
        }
        
        /* Deep copy each change - don't use memcpy for structures with pointers */
        for (size_t i = 0; i < change_count; i++) {
            item->changes[i].description = strdup(changes[i].description ? changes[i].description : "");
            item->changes[i].code_snippet = strdup(changes[i].code_snippet ? changes[i].code_snippet : "");
            item->changes[i].complexity = changes[i].complexity;
        }
    }
    
    return item;
}

static void free_delegate_edit_item(DelegateEditItem *item) {
    if (!item) return;
    
    free(item->file_path);
    
    if (item->changes) {
        for (size_t i = 0; i < item->change_count; i++) {
            free(item->changes[i].description);
            free(item->changes[i].code_snippet);
        }
        free(item->changes);
    }
    
    free(item);
}

/* MARK: - CDATA Stripping */

char* repo_strip_cdata(const char *content) {
    if (!content) return NULL;
    
    char *result = strdup(content);
    if (!result) return NULL;
    
    char *read = result;
    char *write = result;
    
    while (*read) {
        if (strncmp(read, "<![CDATA[", 9) == 0) {
            /* Skip CDATA opening */
            read += 9;
            
            /* Copy content until closing ]]> */
            while (*read && strncmp(read, "]]>", 3) != 0) {
                *write++ = *read++;
            }
            
            /* Skip closing ]]> if found */
            if (*read) read += 3;
        } else {
            *write++ = *read++;
        }
    }
    
    *write = '\0';
    return result;
}

/* MARK: - XML Content Extraction */

char* repo_extract_content(const char *content, const char *tag, bool flexible) {
    if (!content || !tag) return NULL;
    
    /* Build opening tag pattern */
    char open_tag[256];
    snprintf(open_tag, sizeof(open_tag), "<%s>", tag);
    
    /* Build closing tag pattern */
    char close_tag[256];
    snprintf(close_tag, sizeof(close_tag), "</%s>", tag);
    
    /* Find opening tag */
    const char *start = strstr(content, open_tag);
    if (!start) return NULL;
    
    /* Move past opening tag */
    start += strlen(open_tag);
    
    /* Find closing tag */
    const char *end = strstr(start, close_tag);
    if (!end) return NULL;
    
    /* Extract content */
    size_t len = end - start;
    char *result = malloc(len + 1);
    if (!result) return NULL;
    
    memcpy(result, start, len);
    result[len] = '\0';
    
    return result;
}

/* MARK: - Line Splitting */

char* repo_split_content_to_lines(const char *content, bool preserve_empty, 
                                 char ***out_lines, size_t *out_count) {
    if (!out_lines || !out_count) {
        return NULL;
    }
    
    *out_lines = NULL;
    *out_count = 0;
    
    if (!content) {
        return strdup("\n");  /* Return default line ending for NULL content */
    }
    
    /* Count lines */
    size_t line_count = 0;
    const char *p = content;
    const char *line_start = content;
    size_t content_len = strlen(content);
    
    /* Sanity check - prevent extremely large allocations */
    if (content_len > 10 * 1024 * 1024) { /* 10MB limit */
        return strdup("\n");  /* Return default line ending */
    }
    
    while (*p) {
        if (*p == '\n' || *p == '\r') {
            if (preserve_empty || p > line_start) {
                line_count++;
            }
            
            /* Handle \r\n */
            if (*p == '\r' && *(p + 1) == '\n') {
                p++;
            }
            
            p++;
            line_start = p;
        } else {
            p++;
        }
    }
    
    /* Last line */
    if (*line_start || preserve_empty) {
        line_count++;
    }
    
    /* Another sanity check */
    if (line_count > 100000) { /* 100k lines max */
        return strdup("\n");  /* Return default line ending */
    }
    
    /* Allocate lines array */
    char **lines = calloc(line_count + 1, sizeof(char*));
    if (!lines) {
        return strdup("\n");  /* Return default line ending */
    }
    
    /* Fill lines */
    size_t idx = 0;
    p = content;
    line_start = content;
    
    while (*p) {
        if (*p == '\n' || *p == '\r') {
            if ((preserve_empty || p > line_start) && idx < line_count) {
                size_t line_len = (p >= line_start) ? (p - line_start) : 0;
                lines[idx++] = str_substring(line_start, 0, line_len);
            }
            
            /* Handle \r\n */
            if (*p == '\r' && *(p + 1) == '\n') {
                p++;
            }
            
            p++;
            line_start = p;
        } else {
            p++;
        }
    }
    
    /* Last line */
    if ((*line_start || preserve_empty) && idx < line_count) {
        lines[idx++] = strdup(line_start);
    }
    
    *out_lines = lines;
    *out_count = idx;
    
    /* Detect line ending */
    if (g_enable_debug_logging) {
        printf("[DEBUG] repo_split_content_to_lines: Detecting line ending, content=%p, content_len=%zu\n", 
               (void*)content, content_len);
    }
    
    if (!content) {
        if (g_enable_debug_logging) {
            printf("[DEBUG] repo_split_content_to_lines: content is NULL, returning default\n");
        }
        return strdup("\n");
    }
    
    /* Check if content pointer is still valid by trying to read first byte */
    volatile char first_char = content[0];
    if (g_enable_debug_logging) {
        printf("[DEBUG] repo_split_content_to_lines: First char = %d\n", (int)first_char);
    }
    
    /* Now do the actual line ending detection */
    if (strstr(content, "\r\n")) {
        if (g_enable_debug_logging) {
            printf("[DEBUG] repo_split_content_to_lines: Found CRLF\n");
        }
        return strdup("\r\n");
    }
    
    if (strchr(content, '\n')) {
        if (g_enable_debug_logging) {
            printf("[DEBUG] repo_split_content_to_lines: Found LF\n");
        }
        return strdup("\n");
    }
    
    if (strchr(content, '\r')) {
        if (g_enable_debug_logging) {
            printf("[DEBUG] repo_split_content_to_lines: Found CR\n");
        }
        return strdup("\r");
    }
    
    if (g_enable_debug_logging) {
        printf("[DEBUG] repo_split_content_to_lines: No line ending found, returning default\n");
    }
    return strdup("\n");
}

/* MARK: - Chat Name Parsing */

char* repo_parse_and_remove_chat_name(char **content) {
    if (!content || !*content || !g_regexes) return NULL;
    
    regmatch_t matches[4];
    if (regexec(&g_regexes->chat_name_regex, *content, 4, matches, 0) != 0) {
        return NULL;
    }
    
    char *name = NULL;
    
    /* Extract name from either quoted or unquoted group */
    if (matches[1].rm_so != -1) {
        /* Quoted name */
        size_t len = matches[1].rm_eo - matches[1].rm_so;
        name = str_substring(*content, matches[1].rm_so, len);
    } else if (matches[2].rm_so != -1) {
        /* Unquoted name */
        size_t len = matches[2].rm_eo - matches[2].rm_so;
        name = str_substring(*content, matches[2].rm_so, len);
    }
    
    /* Remove the chat name tag from content */
    if (name && matches[0].rm_so != -1) {
        size_t content_len = strlen(*content);
        
        /* Shift content to remove tag */
        memmove(*content + matches[0].rm_so, 
                *content + matches[0].rm_eo,
                content_len - matches[0].rm_eo + 1);
    }
    
    return name;
}

/* MARK: - Scope Description Extraction */

char* repo_extract_scope_description(const char *snippet) {
    if (!snippet || !g_regexes) return strdup("");
    
    regmatch_t matches[3];
    if (regexec(&g_regexes->scope_marker_regex, snippet, 3, matches, 0) != 0) {
        return strdup("");
    }
    
    /* Extract description from capture group 2 */
    if (matches[2].rm_so != -1) {
        size_t len = matches[2].rm_eo - matches[2].rm_so;
        char *desc = str_substring(snippet, matches[2].rm_so, len);
        char *trimmed = str_trim(desc);
        free(desc);
        return trimmed;
    }
    
    return strdup("");
}

/* MARK: - Code Block Indentation Decoding */

char* repo_decode_indentation_in_code_block(const char *code_block) {
    if (!code_block) return NULL;
    
    char **lines;
    size_t line_count;
    char *line_ending = repo_split_content_to_lines(code_block, true, &lines, &line_count);
    
    if (!lines) return strdup(code_block);
    
    /* Decode each line */
    for (size_t i = 0; i < line_count; i++) {
        char *decoded = repo_decode_indentation(lines[i]);
        if (decoded) {
            free(lines[i]);
            lines[i] = decoded;
        }
    }
    
    /* Join lines back together */
    size_t total_len = 0;
    for (size_t i = 0; i < line_count; i++) {
        total_len += strlen(lines[i]);
        if (i < line_count - 1) {
            total_len += strlen(line_ending);
        }
    }
    
    char *result = malloc(total_len + 1);
    if (!result) {
        for (size_t i = 0; i < line_count; i++) free(lines[i]);
        free(lines);
        free(line_ending);
        return strdup(code_block);
    }
    
    char *p = result;
    for (size_t i = 0; i < line_count; i++) {
        strcpy(p, lines[i]);
        p += strlen(lines[i]);
        if (i < line_count - 1) {
            strcpy(p, line_ending);
            p += strlen(line_ending);
        }
    }
    *p = '\0';
    
    /* Cleanup */
    for (size_t i = 0; i < line_count; i++) free(lines[i]);
    free(lines);
    free(line_ending);
    
    return result;
}

/* MARK: - Delegate Edit Hashing */

int64_t repo_hash_delegate_edit_item(const DelegateEditItem *item) {
    if (!item) return 0;
    
    /* Build a string representation for hashing */
    size_t buf_size = strlen(item->file_path) + 100;
    for (size_t i = 0; i < item->change_count; i++) {
        buf_size += strlen(item->changes[i].description) + 
                   strlen(item->changes[i].code_snippet) + 50;
    }
    
    char *buffer = malloc(buf_size);
    if (!buffer) return 0;
    
    char *p = buffer;
    p += sprintf(p, "File: %s\n", item->file_path);
    
    for (size_t i = 0; i < item->change_count; i++) {
        p += sprintf(p, "Change %zu:\n", i + 1);
        p += sprintf(p, "Description: %s\n", item->changes[i].description);
        p += sprintf(p, "Complexity: %d\n", item->changes[i].complexity);
        p += sprintf(p, "Code:\n%s\n", item->changes[i].code_snippet);
    }
    
    /* Use FNV-1a hash from string_extensions_wrapper */
    int64_t hash = (int64_t)repo_fnv1a64(buffer);
    free(buffer);
    
    return hash;
}

/* MARK: - Helper Functions for Parsing */

static bool is_delegate_edit_complete(const char *body) {
    if (!body || !g_regexes) return false;
    
    /* Count opening and closing change tags */
    int open_count = 0;
    int close_count = 0;
    const char *p = body;
    regmatch_t match;
    
    /* Count opening tags */
    while (regexec(&g_regexes->change_regex, p, 1, &match, 0) == 0) {
        open_count++;
        p += match.rm_eo;
    }
    
    /* Count closing tags */
    p = body;
    while (regexec(&g_regexes->change_end_regex, p, 1, &match, 0) == 0) {
        close_count++;
        p += match.rm_eo;
    }
    
    return open_count > 0 && open_count == close_count;
}

static char* extract_code_content(const char *content, bool is_final) {
    if (!content) return strdup("");
    
    char *code = repo_extract_content(content, "content", true);
    if (!code) return strdup("");
    
    /* Trim the content */
    char **lines;
    size_t line_count;
    char *line_ending = repo_split_content_to_lines(code, true, &lines, &line_count);
    free(code);
    
    if (!lines) return strdup("");
    
    /* Trim leading whitespace */
    repo_trim_leading_whitespace(lines, line_count);
    
    /* Skip leading empty lines */
    size_t start = 0;
    while (start < line_count && strlen(lines[start]) == 0) {
        start++;
    }
    
    /* Skip trailing empty lines */
    size_t end = line_count;
    while (end > start && strlen(lines[end - 1]) == 0) {
        end--;
    }
    
    /* Join lines back */
    size_t total_len = 0;
    for (size_t i = start; i < end; i++) {
        total_len += strlen(lines[i]);
        if (i < end - 1) total_len += strlen(line_ending);
    }
    
    char *result = malloc(total_len + 1);
    if (!result) {
        for (size_t i = 0; i < line_count; i++) free(lines[i]);
        free(lines);
        free(line_ending);
        return strdup("");
    }
    
    char *p = result;
    for (size_t i = start; i < end; i++) {
        strcpy(p, lines[i]);
        p += strlen(lines[i]);
        if (i < end - 1) {
            strcpy(p, line_ending);
            p += strlen(line_ending);
        }
    }
    *p = '\0';
    
    /* Cleanup */
    for (size_t i = 0; i < line_count; i++) free(lines[i]);
    free(lines);
    free(line_ending);
    
    return result;
}

/* MARK: - Change Extraction Helpers */

static char** extract_change_descriptions(const char *content) {
    if (!content || !g_regexes) return calloc(1, sizeof(char*));
    
    /* Count matches first */
    size_t count = 0;
    const char *p = content;
    regmatch_t match;
    while (regexec(&g_regexes->description_regex, p, 1, &match, 0) == 0) {
        count++;
        p += match.rm_eo;
    }
    
    /* Allocate array */
    char **descriptions = calloc(count + 1, sizeof(char*));
    if (!descriptions) return calloc(1, sizeof(char*));
    
    /* Extract descriptions */
    p = content;
    size_t idx = 0;
    regmatch_t matches[2];
    while (idx < count && regexec(&g_regexes->description_regex, p, 2, matches, 0) == 0) {
        if (matches[1].rm_so != -1) {
            size_t len = matches[1].rm_eo - matches[1].rm_so;
            char *desc = str_substring(p, matches[1].rm_so, len);
            descriptions[idx++] = str_trim(desc);
            free(desc);
        }
        p += matches[0].rm_eo;
    }
    
    return descriptions;
}

static char** extract_multiple_changes(const char *content, bool is_final) {
    if (!content || !g_regexes) return calloc(1, sizeof(char*));
    
    /* Check if there are any <change> tags */
    if (!str_contains(content, "<change>")) {
        /* No change tags - check for single content tag */
        char *single_content = extract_code_content(content, is_final);
        if (single_content && *single_content) {
            char **changes = calloc(2, sizeof(char*));
            changes[0] = single_content;
            return changes;
        }
        free(single_content);
        
        /* No tags at all - use the whole content */
        char **changes = calloc(2, sizeof(char*));
        changes[0] = strdup(content);
        return changes;
    }
    
    /* Count change blocks */
    size_t count = 0;
    const char *p = content;
    regmatch_t match;
    while (regexec(&g_regexes->change_regex, p, 1, &match, 0) == 0) {
        count++;
        p += match.rm_eo;
    }
    
    /* Allocate array */
    char **changes = calloc(count + 1, sizeof(char*));
    if (!changes) return calloc(1, sizeof(char*));
    
    /* Extract each change block */
    p = content;
    size_t idx = 0;
    while (idx < count && regexec(&g_regexes->change_regex, p, 1, &match, 0) == 0) {
        /* Move to content after <change> */
        p += match.rm_eo;
        
        /* Find closing tag */
        regmatch_t end_match;
        if (regexec(&g_regexes->change_end_regex, p, 1, &end_match, 0) == 0) {
            char *change_content = str_substring(p, 0, end_match.rm_so);
            changes[idx++] = extract_code_content(change_content, is_final);
            free(change_content);
            p += end_match.rm_eo;
        } else {
            /* No closing tag - take rest */
            changes[idx++] = extract_code_content(p, is_final);
            break;
        }
    }
    
    return changes;
}

/* MARK: - Scope Splitting for Delegate Edits */

typedef struct {
    char *description;
    char *content;
} ScopeInfo;

static char* get_comment_prefix(const char *file_path) {
    if (!file_path) return "//";
    
    const char *ext = strrchr(file_path, '.');
    if (!ext) return "//";
    ext++; /* Skip the dot */
    
    /* Python, Ruby, Shell */
    if (strcmp(ext, "py") == 0 || strcmp(ext, "rb") == 0 || 
        strcmp(ext, "sh") == 0 || strcmp(ext, "bash") == 0) {
        return "#";
    }
    /* SQL */
    else if (strcmp(ext, "sql") == 0 || strcmp(ext, "sqlite") == 0) {
        return "--";
    }
    /* HTML, XML */
    else if (strcmp(ext, "html") == 0 || strcmp(ext, "htm") == 0 || 
             strcmp(ext, "xml") == 0 || strcmp(ext, "xhtml") == 0) {
        return "<!--";
    }
    
    /* Default to C-style */
    return "//";
}

static regex_t* create_placeholder_regex(const char *file_path) {
    const char *prefix = get_comment_prefix(file_path);
    char pattern[512];
    
    if (strcmp(prefix, "<!--") == 0) {
        snprintf(pattern, sizeof(pattern),
                "^[[:space:]]*<!--[[:space:]]*\\.\\.\\.[[:space:]]*existing[[:space:]]+code[[:space:]]*\\.\\.\\.[[:space:]]*-->[[:space:]]*$");
    } else if (strcmp(prefix, "//") == 0) {
        /* Support both // and /* style block comments - simpler pattern */
        snprintf(pattern, sizeof(pattern),
                "^[[:space:]]*(//[[:space:]]*\\.\\.\\.[[:space:]]*existing[[:space:]]+code[[:space:]]*\\.\\.\\.[[:space:]]*|"
                "/\\*[[:space:]]*\\.\\.\\.[[:space:]]*existing[[:space:]]+code[[:space:]]*\\.\\.\\.[[:space:]]*\\*/)[[:space:]]*$");
    } else {
        /* Simple prefix */
        snprintf(pattern, sizeof(pattern),
                "^[[:space:]]*%s[[:space:]]*\\.\\.\\.[[:space:]]*existing[[:space:]]+code[[:space:]]*\\.\\.\\.[[:space:]]*$",
                prefix);
    }
    
    regex_t *regex = malloc(sizeof(regex_t));
    if (!regex) {
        return NULL;
    }
    
    int ret = regcomp(regex, pattern, REG_EXTENDED | REG_ICASE);
    if (ret != 0) {
        if (g_enable_debug_logging) {
            char errbuf[256];
            regerror(ret, regex, errbuf, sizeof(errbuf));
            printf("[DEBUG] Failed to compile regex pattern: %s\n", pattern);
            printf("[DEBUG] Error: %s\n", errbuf);
        }
        free(regex);
        return NULL;
    }
    
    return regex;
}

static ScopeInfo* split_into_scopes(const char *code_snippet, const char *file_path, 
                                   size_t context_lines, size_t *out_count) {
    if (!code_snippet || !out_count || !g_regexes) {
        *out_count = 0;
        return NULL;
    }
    
    /* Split into lines */
    char **lines;
    size_t line_count;
    char *line_ending = repo_split_content_to_lines(code_snippet, true, &lines, &line_count);
    if (!lines) {
        *out_count = 0;
        return NULL;
    }
    
    regex_t *placeholder_regex = create_placeholder_regex(file_path);
    
    /* Allocate scope array */
    size_t scope_capacity = 8;
    ScopeInfo *scopes = calloc(scope_capacity, sizeof(ScopeInfo));
    size_t scope_count = 0;
    
    /* Current scope state */
    char *current_desc = NULL;
    char **buffer = NULL;
    size_t buffer_count = 0;
    size_t buffer_capacity = 0;
    
    /* Look-behind buffer */
    char **look_behind = calloc(context_lines + 1, sizeof(char*));
    size_t look_behind_count = 0;
    
    /* Carried placeholders */
    char **carry_placeholders = NULL;
    size_t carry_count = 0;
    size_t carry_capacity = 0;
    
    /* Process each line */
    for (size_t i = 0; i < line_count; i++) {
        const char *line = lines[i];
        regmatch_t matches[3];
        
        /* Check for scope marker */
        if (regexec(&g_regexes->scope_marker_regex, line, 3, matches, 0) == 0 && matches[2].rm_so != -1) {
            /* Flush current scope if any */
            if (current_desc && buffer_count > 0) {
                /* Join buffer lines */
                size_t total_len = 0;
                for (size_t j = 0; j < buffer_count; j++) {
                    total_len += strlen(buffer[j]);
                    if (j < buffer_count - 1) total_len += strlen(line_ending);
                }
                
                char *content = malloc(total_len + 1);
                char *p = content;
                for (size_t j = 0; j < buffer_count; j++) {
                    strcpy(p, buffer[j]);
                    p += strlen(buffer[j]);
                    if (j < buffer_count - 1) {
                        strcpy(p, line_ending);
                        p += strlen(line_ending);
                    }
                }
                *p = '\0';
                
                /* Add scope */
                if (scope_count >= scope_capacity) {
                    scope_capacity *= 2;
                    scopes = realloc(scopes, scope_capacity * sizeof(ScopeInfo));
                }
                scopes[scope_count].description = current_desc;
                scopes[scope_count].content = content;
                scope_count++;
                
                /* Clear buffer */
                for (size_t j = 0; j < buffer_count; j++) free(buffer[j]);
                buffer_count = 0;
                current_desc = NULL;
            }
            
            /* Extract new description */
            size_t desc_len = matches[2].rm_eo - matches[2].rm_so;
            char *desc = str_substring(line, matches[2].rm_so, desc_len);
            current_desc = str_trim(desc);
            free(desc);
            
            /* Seed buffer with look-behind context */
            for (size_t j = 0; j < look_behind_count; j++) {
                if (buffer_count >= buffer_capacity) {
                    buffer_capacity = buffer_capacity ? buffer_capacity * 2 : 16;
                    buffer = realloc(buffer, buffer_capacity * sizeof(char*));
                }
                buffer[buffer_count++] = strdup(look_behind[j]);
            }
            
            /* Add carried placeholders */
            for (size_t j = 0; j < carry_count; j++) {
                if (buffer_count >= buffer_capacity) {
                    buffer_capacity = buffer_capacity ? buffer_capacity * 2 : 16;
                    buffer = realloc(buffer, buffer_capacity * sizeof(char*));
                }
                buffer[buffer_count++] = strdup(carry_placeholders[j]);
            }
            
            /* Clear carry */
            for (size_t j = 0; j < carry_count; j++) free(carry_placeholders[j]);
            carry_count = 0;
            
            /* Clear look-behind */
            for (size_t j = 0; j < look_behind_count; j++) free(look_behind[j]);
            look_behind_count = 0;
            
            continue;
        }
        
        /* Check for placeholder line */
        if (placeholder_regex && regexec(placeholder_regex, line, 0, NULL, 0) == 0) {
            if (current_desc) {
                /* Add to current buffer */
                if (buffer_count >= buffer_capacity) {
                    buffer_capacity = buffer_capacity ? buffer_capacity * 2 : 16;
                    buffer = realloc(buffer, buffer_capacity * sizeof(char*));
                }
                buffer[buffer_count++] = strdup(line);
            }
            
            /* Add to carry */
            if (carry_count >= carry_capacity) {
                carry_capacity = carry_capacity ? carry_capacity * 2 : 8;
                carry_placeholders = realloc(carry_placeholders, carry_capacity * sizeof(char*));
            }
            carry_placeholders[carry_count++] = strdup(line);
            
            continue;
        }
        
        /* Regular line */
        if (current_desc) {
            /* Add to buffer */
            if (buffer_count >= buffer_capacity) {
                buffer_capacity = buffer_capacity ? buffer_capacity * 2 : 16;
                buffer = realloc(buffer, buffer_capacity * sizeof(char*));
            }
            buffer[buffer_count++] = strdup(line);
        }
        
        /* Maintain look-behind */
        if (context_lines > 0) {
            if (look_behind_count >= context_lines) {
                /* Remove oldest */
                free(look_behind[0]);
                memmove(look_behind, look_behind + 1, (context_lines - 1) * sizeof(char*));
                look_behind_count--;
            }
            look_behind[look_behind_count++] = strdup(line);
        }
    }
    
    /* Flush final scope */
    if (current_desc && buffer_count > 0) {
        /* Append any remaining carry placeholders */
        for (size_t j = 0; j < carry_count; j++) {
            if (buffer_count >= buffer_capacity) {
                buffer_capacity = buffer_capacity ? buffer_capacity * 2 : 16;
                buffer = realloc(buffer, buffer_capacity * sizeof(char*));
            }
            buffer[buffer_count++] = carry_placeholders[j];
            carry_placeholders[j] = NULL;
        }
        
        /* Join buffer lines */
        size_t total_len = 0;
        for (size_t j = 0; j < buffer_count; j++) {
            total_len += strlen(buffer[j]);
            if (j < buffer_count - 1) total_len += strlen(line_ending);
        }
        
        char *content = malloc(total_len + 1);
        char *p = content;
        for (size_t j = 0; j < buffer_count; j++) {
            strcpy(p, buffer[j]);
            p += strlen(buffer[j]);
            if (j < buffer_count - 1) {
                strcpy(p, line_ending);
                p += strlen(line_ending);
            }
        }
        *p = '\0';
        
        /* Add scope */
        if (scope_count >= scope_capacity) {
            scope_capacity *= 2;
            scopes = realloc(scopes, scope_capacity * sizeof(ScopeInfo));
        }
        scopes[scope_count].description = current_desc;
        scopes[scope_count].content = content;
        scope_count++;
    }
    
    /* Cleanup */
    for (size_t i = 0; i < line_count; i++) free(lines[i]);
    free(lines);
    free(line_ending);
    
    for (size_t i = 0; i < buffer_count; i++) free(buffer[i]);
    free(buffer);
    
    for (size_t i = 0; i < look_behind_count; i++) free(look_behind[i]);
    free(look_behind);
    
    for (size_t i = 0; i < carry_count; i++) free(carry_placeholders[i]);
    free(carry_placeholders);
    
    if (placeholder_regex) {
        regfree(placeholder_regex);
        free(placeholder_regex);
    }
    
    *out_count = scope_count;
    return scopes;
}

/* MARK: - Delegate Edit Parsing */

static void parse_delegate_edit(const char *file_content, bool is_final, const char *file_path,
                              char ***out_code_changes, size_t *out_code_count,
                              DelegateEditChange **out_changes, size_t *out_change_count) {
    *out_code_changes = calloc(1, sizeof(char*));
    *out_code_count = 0;
    *out_changes = NULL;
    *out_change_count = 0;
    
    if (!file_content || !g_regexes) return;
    
    /* Count change blocks */
    size_t change_count = 0;
    const char *p = file_content;
    regmatch_t match;
    while (regexec(&g_regexes->change_regex, p, 1, &match, 0) == 0) {
        change_count++;
        p += match.rm_eo;
    }
    
    if (change_count == 1) {
        /* Single change block - check for scope-based parsing */
        regmatch_t open_match, close_match;
        if (regexec(&g_regexes->change_regex, file_content, 1, &open_match, 0) == 0 &&
            regexec(&g_regexes->change_end_regex, file_content + open_match.rm_eo, 1, &close_match, 0) == 0) {
            
            /* Extract change body */
            char *change_body = str_substring(file_content + open_match.rm_eo, 0, close_match.rm_so);
            
            /* Get XML description and complexity */
            size_t desc_buffer_size = strlen(change_body) + 1;
            char *desc_buffer = malloc(desc_buffer_size);
            char *xml_desc = NULL;
            if (desc_buffer && repo_extract_description(desc_buffer, change_body, desc_buffer_size)) {
                xml_desc = strdup(desc_buffer);
            }
            free(desc_buffer);
            if (!xml_desc) xml_desc = strdup("");
            
            int complexity = repo_extract_complexity(change_body);
            if (complexity < 0) complexity = 3;
            
            /* Get code snippet */
            char *code_snippet = extract_code_content(change_body, is_final);
            
            /* Try scope splitting */
            size_t scope_count;
            ScopeInfo *scopes = split_into_scopes(code_snippet, file_path, 2, &scope_count);
            
            if (scopes && scope_count > 0) {
                /* Use scopes */
                *out_code_changes = calloc(scope_count + 1, sizeof(char*));
                *out_changes = calloc(scope_count, sizeof(DelegateEditChange));
                
                for (size_t i = 0; i < scope_count; i++) {
                    (*out_code_changes)[i] = strdup(scopes[i].content);
                    
                    /* Use scope description, fall back to XML or extract from content */
                    char *desc = scopes[i].description;
                    if (!desc || *desc == '\0') desc = xml_desc;
                    if (!desc || *desc == '\0') desc = repo_extract_scope_description(scopes[i].content);
                    
                    (*out_changes)[i].description = strdup(desc ? desc : "");
                    (*out_changes)[i].code_snippet = strdup(scopes[i].content);
                    (*out_changes)[i].complexity = complexity;
                    
                    free(scopes[i].description);
                    free(scopes[i].content);
                }
                
                *out_code_count = scope_count;
                *out_change_count = scope_count;
                free(scopes);
            } else {
                /* No scopes - treat as single change */
                *out_code_changes = calloc(2, sizeof(char*));
                *out_changes = calloc(1, sizeof(DelegateEditChange));
                
                (*out_code_changes)[0] = code_snippet;
                
                char *desc = xml_desc;
                if (!desc || *desc == '\0') desc = repo_extract_scope_description(code_snippet);
                
                (*out_changes)[0].description = strdup(desc ? desc : "");
                (*out_changes)[0].code_snippet = strdup(code_snippet);
                (*out_changes)[0].complexity = complexity;
                
                *out_code_count = 1;
                *out_change_count = 1;
            }
            
            free(xml_desc);
            free(change_body);
        }
    } else {
        /* Multiple change blocks - process each separately */
        *out_code_changes = calloc(change_count + 1, sizeof(char*));
        *out_changes = calloc(change_count, sizeof(DelegateEditChange));
        
        p = file_content;
        size_t idx = 0;
        
        while (idx < change_count && regexec(&g_regexes->change_regex, p, 1, &match, 0) == 0) {
            p += match.rm_eo;
            
            regmatch_t end_match;
            if (regexec(&g_regexes->change_end_regex, p, 1, &end_match, 0) == 0) {
                char *change_body = str_substring(p, 0, end_match.rm_so);
                
                size_t desc_buf_size = strlen(change_body) + 1;
                char *desc_buf = malloc(desc_buf_size);
                char *desc = NULL;
                if (desc_buf && repo_extract_description(desc_buf, change_body, desc_buf_size)) {
                    desc = strdup(desc_buf);
                }
                free(desc_buf);
                if (!desc) desc = strdup("");
                
                char *snippet = extract_code_content(change_body, is_final);
                int complexity = repo_extract_complexity(change_body);
                if (complexity < 0) complexity = 1;
                
                if (!desc || *desc == '\0') {
                    free(desc);
                    desc = repo_extract_scope_description(snippet);
                }
                
                (*out_code_changes)[idx] = snippet;
                (*out_changes)[idx].description = desc;
                (*out_changes)[idx].code_snippet = strdup(snippet);
                (*out_changes)[idx].complexity = complexity;
                
                idx++;
                free(change_body);
                p += end_match.rm_eo;
            } else {
                break;
            }
        }
        
        *out_code_count = idx;
        *out_change_count = idx;
    }
}

/* MARK: - Text Processing Helpers */

static char* maybe_truncate_last_line(const char *text, bool is_final) {
    if (is_final || !text || *text == '\0') return strdup(text);
    
    /* If text ends with newline, keep it all */
    size_t len = strlen(text);
    if (text[len - 1] == '\n') return strdup(text);
    
    /* Split into lines and drop the last one */
    char **lines;
    size_t line_count;
    char *line_ending = repo_split_content_to_lines(text, true, &lines, &line_count);
    
    if (line_count > 0) {
        /* Remove last line */
        free(lines[line_count - 1]);
        line_count--;
    }
    
    /* Join remaining lines */
    size_t total_len = 0;
    for (size_t i = 0; i < line_count; i++) {
        total_len += strlen(lines[i]);
        if (i < line_count - 1) total_len += strlen(line_ending);
    }
    
    char *result = malloc(total_len + 1);
    if (!result) {
        for (size_t i = 0; i < line_count; i++) free(lines[i]);
        free(lines);
        free(line_ending);
        return strdup(text);
    }
    
    char *p = result;
    for (size_t i = 0; i < line_count; i++) {
        strcpy(p, lines[i]);
        p += strlen(lines[i]);
        if (i < line_count - 1) {
            strcpy(p, line_ending);
            p += strlen(line_ending);
        }
    }
    *p = '\0';
    
    /* Cleanup */
    for (size_t i = 0; i < line_count; i++) free(lines[i]);
    free(lines);
    free(line_ending);
    
    return result;
}

static void process_text_content(const char *content, bool is_final, int *item_index,
                                ContentItem ***items, size_t *item_count, size_t *items_capacity,
                                char **core_content, size_t *core_len, size_t *core_capacity) {
    if (!content || *content == '\0') return;
    
    /* Accumulator for all text fragments to join with single newlines */
    size_t relevant_capacity = 256;
    char *relevant_text = malloc(relevant_capacity);
    if (!relevant_text) return;
    relevant_text[0] = '\0';
    size_t relevant_len = 0;
    
    /* Use strstr to find code blocks instead of regex for reliability */
    const char *p = content;
    const char *code_start;
    
    /* Check if there are any code blocks */
    if (strstr(p, "```") == NULL) {
        /* No code blocks - treat everything as text */
        char *trimmed = str_trim(content);
        char *final_text = maybe_truncate_last_line(trimmed, is_final);
        free(trimmed);
        
        if (final_text && *final_text) {
            ContentItem *item = create_content_item(*item_index, CONTENT_TYPE_TEXT, final_text);
            if (item) {
                /* Grow array if needed */
                if (*item_count >= *items_capacity) {
                    *items_capacity *= 2;
                    *items = realloc(*items, *items_capacity * sizeof(ContentItem*));
                }
                (*items)[(*item_count)++] = item;
                *item_index += item->line_segment_count;
                
                /* Add to relevant_text accumulator */
                size_t text_len = strlen(final_text);
                size_t needed = relevant_len + (relevant_len > 0 ? 1 : 0) + text_len + 1;
                
                if (needed > relevant_capacity) {
                    while (relevant_capacity < needed) {
                        relevant_capacity *= 2;
                    }
                    char *new_text = realloc(relevant_text, relevant_capacity);
                    if (!new_text) {
                        free(relevant_text);
                        free(final_text);
                        return;
                    }
                    relevant_text = new_text;
                }
                
                if (relevant_len > 0) {
                    relevant_text[relevant_len++] = '\n';
                }
                memcpy(relevant_text + relevant_len, final_text, text_len);
                relevant_len += text_len;
                relevant_text[relevant_len] = '\0';
            }
        }
        free(final_text);
        goto finish_text_section;
    }
    
    /* Process code blocks using strstr */
    while ((code_start = strstr(p, "```")) != NULL) {
        /* Text before code block */
        if (code_start > p) {
            size_t text_len = code_start - p;
            char *text_before = str_substring(p, 0, text_len);
            char *trimmed = str_trim(text_before);
            char *final_text = maybe_truncate_last_line(trimmed, is_final);
            free(text_before);
            free(trimmed);
            
            if (final_text && *final_text) {
                ContentItem *item = create_content_item(*item_index, CONTENT_TYPE_TEXT, final_text);
                if (item) {
                    if (*item_count >= *items_capacity) {
                        *items_capacity *= 2;
                        *items = realloc(*items, *items_capacity * sizeof(ContentItem*));
                    }
                    (*items)[(*item_count)++] = item;
                    *item_index += item->line_segment_count;
                    
                    /* Add to relevant_text accumulator */
                    size_t text_len = strlen(final_text);
                    size_t needed = relevant_len + (relevant_len > 0 ? 1 : 0) + text_len + 1;
                    
                    if (needed > relevant_capacity) {
                        while (relevant_capacity < needed) {
                            relevant_capacity *= 2;
                        }
                        char *new_text = realloc(relevant_text, relevant_capacity);
                        if (!new_text) {
                            free(relevant_text);
                            free(final_text);
                            return;
                        }
                        relevant_text = new_text;
                    }
                    
                    if (relevant_len > 0) {
                        relevant_text[relevant_len++] = '\n';
                    }
                    memcpy(relevant_text + relevant_len, final_text, text_len);
                    relevant_len += text_len;
                    relevant_text[relevant_len] = '\0';
                }
            }
            free(final_text);
        }
        
        /* Skip past opening ``` and any language identifier */
        const char *code_content_start = code_start + 3;
        
        /* Skip language identifier if present */
        while (*code_content_start && *code_content_start != '\n' && *code_content_start != '\r') {
            code_content_start++;
        }
        /* Skip newline after language identifier */
        if (*code_content_start == '\r') code_content_start++;
        if (*code_content_start == '\n') code_content_start++;
        
        /* Find the closing ``` */
        const char *code_end = strstr(code_content_start, "```");
        
        if (code_end) {
            /* Extract code content */
            size_t code_len = code_end - code_content_start;
            char *code = str_substring(code_content_start, 0, code_len);
            
            /* Remove trailing newline before closing ``` if present */
            if (code_len > 0 && code[code_len - 1] == '\n') {
                code[code_len - 1] = '\0';
                if (code_len > 1 && code[code_len - 2] == '\r') {
                    code[code_len - 2] = '\0';
                }
            }
            
            /* Trim and decode indentation in code block */
            char *trimmed = str_trim(code);
            free(code);
            char *decoded = repo_decode_indentation_in_code_block(trimmed);
            free(trimmed);
            
            if (decoded && *decoded) {
                ContentItem *item = create_content_item(*item_index, CONTENT_TYPE_CODE, decoded);
                if (item) {
                    if (*item_count >= *items_capacity) {
                        *items_capacity *= 2;
                        *items = realloc(*items, *items_capacity * sizeof(ContentItem*));
                    }
                    (*items)[(*item_count)++] = item;
                    *item_index += item->line_segment_count;
                }
            }
            free(decoded);
            
            /* Move past the closing ``` */
            p = code_end + 3;
        } else {
            /* No closing ``` - treat rest as text */
            break;
        }
    }
    
    /* Remaining text after last code block */
    if (*p) {
        char *trimmed = str_trim(p);
        char *final_text = maybe_truncate_last_line(trimmed, is_final);
        free(trimmed);
        
        if (final_text && *final_text) {
            ContentItem *item = create_content_item(*item_index, CONTENT_TYPE_TEXT, final_text);
            if (item) {
                if (*item_count >= *items_capacity) {
                    *items_capacity *= 2;
                    *items = realloc(*items, *items_capacity * sizeof(ContentItem*));
                }
                (*items)[(*item_count)++] = item;
                *item_index += item->line_segment_count;
                
                /* Add to relevant_text accumulator */
                size_t text_len = strlen(final_text);
                size_t needed = relevant_len + (relevant_len > 0 ? 1 : 0) + text_len + 1;
                
                if (needed > relevant_capacity) {
                    while (relevant_capacity < needed) {
                        relevant_capacity *= 2;
                    }
                    char *new_text = realloc(relevant_text, relevant_capacity);
                    if (!new_text) {
                        free(relevant_text);
                        free(final_text);
                        return;
                    }
                    relevant_text = new_text;
                }
                
                if (relevant_len > 0) {
                    relevant_text[relevant_len++] = '\n';
                }
                memcpy(relevant_text + relevant_len, final_text, text_len);
                relevant_len += text_len;
                relevant_text[relevant_len] = '\0';
            }
        }
        free(final_text);
    }
    
finish_text_section:
    /* If we accumulated any text, add it to core content with single Text: header */
    if (relevant_len > 0) {
        const char *header = "Text:\n";
        const char *footer = "\n\n";
        size_t header_len = strlen(header);
        size_t footer_len = strlen(footer);
        size_t needed = *core_len + header_len + relevant_len + footer_len + 1;
        
        if (needed > *core_capacity) {
            while (*core_capacity < needed) {
                *core_capacity *= 2;
            }
            char *new_core = realloc(*core_content, *core_capacity);
            if (!new_core) {
                free(relevant_text);
                return;
            }
            *core_content = new_core;
        }
        
        memcpy(*core_content + *core_len, header, header_len);
        *core_len += header_len;
        memcpy(*core_content + *core_len, relevant_text, relevant_len);
        *core_len += relevant_len;
        memcpy(*core_content + *core_len, footer, footer_len);
        *core_len += footer_len;
        (*core_content)[*core_len] = '\0';
    }
    
    free(relevant_text);
}

static void process_and_add_text_content(char *content, bool is_final, int *item_index,
                                       ContentItem ***items, size_t *item_count, size_t *items_capacity,
                                       char **core_content, size_t *core_len, size_t *core_capacity) {
    if (!content) return;
    
    /* Extract and remove chat name if present */
    char *content_copy = strdup(content);
    char *chat_name = repo_parse_and_remove_chat_name(&content_copy);
    free(chat_name); /* We're not using it, just removing it */
    
    /* Process the text content */
    process_text_content(content_copy, is_final, item_index, items, item_count, items_capacity,
                        core_content, core_len, core_capacity);
    
    free(content_copy);
}

/* MARK: - String Buffer Helper */

static bool append_to_buffer(char **buffer, size_t *len, size_t *capacity, const char *text) {
    if (!buffer || !*buffer || !len || !capacity || !text) return false;
    
    size_t text_len = strlen(text);
    size_t needed = *len + text_len + 1;
    
    if (needed > *capacity) {
        while (*capacity < needed) {
            *capacity *= 2;
        }
        char *new_buffer = realloc(*buffer, *capacity);
        if (!new_buffer) {
            return false;
        }
        *buffer = new_buffer;
    }
    
    memcpy(*buffer + *len, text, text_len);
    *len += text_len;
    (*buffer)[*len] = '\0';
    
    return true;
}

/* MARK: - Main Parse Function */

ParseResult* repo_parse_content(
    const char *content,
    int64_t *processed_hashes,
    size_t hash_count,
    bool is_final,
    bool enable_debug
) {
    if (!content) return NULL;
    
    /* Initialize regexes if needed */
    if (!init_regexes()) {
        DEBUG_LOG("Failed to initialize regex patterns");
        return NULL;
    }
    
    /* Verify regexes are initialized */
    if (!g_regexes) {
        DEBUG_LOG("Regexes not properly initialized");
        return NULL;
    }
    
    /* Set debug mode */
    g_enable_debug_logging = enable_debug;
    
    /* Create result structure */
    ParseResult *result = calloc(1, sizeof(ParseResult));
    if (!result) return NULL;
    
    /* Strip CDATA */
    char *cdata_stripped = repo_strip_cdata(content);
    if (!cdata_stripped) {
        free(result);
        return NULL;
    }
    
    /* Remove outer backticks */
    size_t buf_size = strlen(cdata_stripped) + 1;
    char *cleaned = malloc(buf_size);
    if (!cleaned || !repo_remove_outer_backticks(cleaned, cdata_stripped, buf_size)) {
        free(cdata_stripped);
        free(cleaned);
        free(result);
        return NULL;
    }
    free(cdata_stripped);
    
    /* Initialize dynamic arrays for items */
    size_t items_capacity = 16;
    ContentItem **items = calloc(items_capacity, sizeof(ContentItem*));
    size_t item_count = 0;
    
    size_t core_capacity = 1024;
    size_t core_len = 0;
    char *core_content = malloc(core_capacity);
    core_content[0] = '\0';
    
    size_t delegate_capacity = 8;
    DelegateEditItem **delegate_edits = calloc(delegate_capacity, sizeof(DelegateEditItem*));
    size_t delegate_count = 0;
    
    /* Track current position and item index */
    const char *p = cleaned;
    int item_index = 0;
    
    /* Main parsing loop */
    while (*p) {
        /* Find next plan or file tag */
        regmatch_t plan_match, file_match;
        int plan_found = regexec(&g_regexes->plan_regex, p, 1, &plan_match, 0) == 0;
        int file_found = regexec(&g_regexes->file_regex, p, 1, &file_match, 0) == 0;
        
        if (!plan_found && !file_found) {
            /* No more tags - process remaining as text */
            process_and_add_text_content((char*)p, is_final, &item_index, 
                                       &items, &item_count, &items_capacity,
                                       &core_content, &core_len, &core_capacity);
            break;
        }
        
        /* Determine which tag comes first */
        int next_tag_pos;
        bool is_plan;
        if (!file_found || (plan_found && plan_match.rm_so < file_match.rm_so)) {
            next_tag_pos = (int)plan_match.rm_so;
            is_plan = true;
        } else {
            next_tag_pos = (int)file_match.rm_so;
            is_plan = false;
        }
        
        /* Process text before the tag */
        if (next_tag_pos > 0) {
            char *text_before = str_substring(p, 0, next_tag_pos);
            process_and_add_text_content(text_before, is_final, &item_index,
                                       &items, &item_count, &items_capacity,
                                       &core_content, &core_len, &core_capacity);
            free(text_before);
        }
        
        if (is_plan) {
            /* Process plan block */
            p += plan_match.rm_eo;
            regmatch_t plan_end_match;
            
            if (regexec(&g_regexes->plan_end_regex, p, 1, &plan_end_match, 0) == 0) {
                /* Extract plan content */
                char *plan_content = str_substring(p, 0, plan_end_match.rm_so);
                char *trimmed = str_trim(plan_content);
                free(plan_content);
                
                if (trimmed && *trimmed) {
                    ContentItem *item = create_content_item(item_index, CONTENT_TYPE_TEXT, trimmed);
                    if (item) {
                        if (item_count >= items_capacity) {
                            items_capacity *= 2;
                            items = realloc(items, items_capacity * sizeof(ContentItem*));
                        }
                        items[item_count++] = item;
                        item_index += item->line_segment_count;
                        
                        /* Add to core */
                        append_to_buffer(&core_content, &core_len, &core_capacity, "Plan:\n");
                        append_to_buffer(&core_content, &core_len, &core_capacity, trimmed);
                        append_to_buffer(&core_content, &core_len, &core_capacity, "\n\n");
                    }
                }
                free(trimmed);
                
                p += plan_end_match.rm_eo;
            } else {
                /* No closing tag - treat rest as plan content */
                char *trimmed = str_trim(p);
                if (trimmed && *trimmed) {
                    ContentItem *item = create_content_item(item_index, CONTENT_TYPE_TEXT, trimmed);
                    if (item) {
                        if (item_count >= items_capacity) {
                            items_capacity *= 2;
                            items = realloc(items, items_capacity * sizeof(ContentItem*));
                        }
                        items[item_count++] = item;
                        item_index += item->line_segment_count;
                        
                        /* Add to core */
                        append_to_buffer(&core_content, &core_len, &core_capacity, "Plan:\n");
                        append_to_buffer(&core_content, &core_len, &core_capacity, trimmed);
                        append_to_buffer(&core_content, &core_len, &core_capacity, "\n\n");
                    }
                }
                free(trimmed);
                break;
            }
        } else {
            /* Process file block */
            
            /* Extract file path and action from the original match */
            regmatch_t file_full_match[3];
            if (regexec(&g_regexes->file_regex, p, 3, file_full_match, 0) == 0) {
                /* Get file path (group 1) */
                char *file_path = NULL;
                if (file_full_match[1].rm_so != -1) {
                    size_t path_len = file_full_match[1].rm_eo - file_full_match[1].rm_so;
                    file_path = str_substring(p, file_full_match[1].rm_so, path_len);
                }
                
                /* Get action (group 2) */
                char *action = NULL;
                if (file_full_match[2].rm_so != -1) {
                    size_t action_len = file_full_match[2].rm_eo - file_full_match[2].rm_so;
                    action = str_substring(p, file_full_match[2].rm_so, action_len);
                }
                
                /* Move past opening tag */
                p += file_full_match[0].rm_eo;
                
                /* Find closing tag */
                regmatch_t file_end_match;
                if (regexec(&g_regexes->file_end_regex, p, 1, &file_end_match, 0) == 0) {
                    /* Extract file content */
                    char *file_content = str_substring(p, 0, file_end_match.rm_so);
                    
                    /* Check if this is a delegate edit */
                    bool is_delegate = action && str_contains(action, "delegate");
                    
                    char **code_changes = NULL;
                    char **descriptions = NULL;
                    size_t change_count = 0;
                    
                    if (is_delegate && (!is_final || is_delegate_edit_complete(file_content))) {
                        /* Process delegate edit */
                        DelegateEditChange *changes = NULL;
                        size_t code_count = 0;
                        parse_delegate_edit(file_content, is_final, file_path,
                                          &code_changes, &code_count,
                                          &changes, &change_count);
                        
                        /* Extract descriptions from DelegateEditChange array */
                        if (change_count > 0) {
                            descriptions = calloc(change_count + 1, sizeof(char*));
                            for (size_t i = 0; i < change_count; i++) {
                                descriptions[i] = strdup(changes[i].description);
                            }
                            
                            /* Create delegate edit item */
                            DelegateEditItem *del_item = create_delegate_edit_item(file_path, changes, change_count);
                            if (del_item) {
                                int64_t hash = repo_hash_delegate_edit_item(del_item);
                                bool already_processed = false;
                                for (size_t i = 0; i < hash_count; i++) {
                                    if (processed_hashes[i] == hash) {
                                        already_processed = true;
                                        break;
                                    }
                                }
                                
                                if (!already_processed) {
                                    if (delegate_count >= delegate_capacity) {
                                        delegate_capacity *= 2;
                                        delegate_edits = realloc(delegate_edits, delegate_capacity * sizeof(DelegateEditItem*));
                                    }
                                    delegate_edits[delegate_count++] = del_item;
                                } else {
                                    free_delegate_edit_item(del_item);
                                }
                            }
                            
                            /* Free the changes array since we've copied what we need */
                            for (size_t i = 0; i < change_count; i++) {
                                free(changes[i].description);
                                free(changes[i].code_snippet);
                            }
                            free(changes);
                        }
                    } else {
                        /* Process regular file */
                        code_changes = extract_multiple_changes(file_content, is_final);
                        descriptions = extract_change_descriptions(file_content);
                        
                        /* Count changes */
                        if (code_changes) {
                            for (char **p = code_changes; *p; p++) {
                                change_count++;
                            }
                        }
                    }
                    
                    /* Create file content item */
                    ContentItem *item = create_content_item(item_index, CONTENT_TYPE_FILE, file_content);
                    if (item) {
                        item->file_path = file_path ? strdup(file_path) : NULL;
                        item->action = action ? strdup(action) : NULL;
                        item->changes = code_changes;
                        item->descriptions = descriptions;
                        item->change_count = change_count;
                        
                        /* Create line segments for each change */
                        if (change_count > 0 && code_changes) {
                            item->change_line_segments = calloc(change_count, sizeof(LineSegment*));
                            item->change_line_segment_counts = calloc(change_count, sizeof(size_t));
                            
                            if (item->change_line_segments && item->change_line_segment_counts) {
                                for (size_t i = 0; i < change_count; i++) {
                                    if (code_changes[i]) {
                                        item->change_line_segments[i] = create_line_segments(
                                            code_changes[i],
                                            CONTENT_TYPE_CODE,
                                            0,  // base index for individual changes can start at 0
                                            &item->change_line_segment_counts[i]
                                        );
                                    }
                                }
                            }
                        }
                        
                        if (item_count >= items_capacity) {
                            items_capacity *= 2;
                            items = realloc(items, items_capacity * sizeof(ContentItem*));
                        }
                        items[item_count++] = item;
                        item_index += item->line_segment_count;
                        
                        /* Add to core */
                        append_to_buffer(&core_content, &core_len, &core_capacity, "File: ");
                        if (file_path) {
                            append_to_buffer(&core_content, &core_len, &core_capacity, file_path);
                        }
                        append_to_buffer(&core_content, &core_len, &core_capacity, "\n");
                        append_to_buffer(&core_content, &core_len, &core_capacity, "Changes:\n");
                        
                        /* Add change details to core */
                        for (size_t i = 0; i < change_count; i++) {
                            char change_header[256];
                            snprintf(change_header, sizeof(change_header), "Change #%zu:\n", i + 1);
                            append_to_buffer(&core_content, &core_len, &core_capacity, change_header);
                            
                            if (descriptions && descriptions[i] && *descriptions[i]) {
                                append_to_buffer(&core_content, &core_len, &core_capacity, "Description: ");
                                append_to_buffer(&core_content, &core_len, &core_capacity, descriptions[i]);
                                append_to_buffer(&core_content, &core_len, &core_capacity, "\n");
                            }
                            
                            if (code_changes && code_changes[i]) {
                                append_to_buffer(&core_content, &core_len, &core_capacity, "Content:\n");
                                append_to_buffer(&core_content, &core_len, &core_capacity, code_changes[i]);
                                append_to_buffer(&core_content, &core_len, &core_capacity, "\n\n");
                            }
                        }
                        
                        append_to_buffer(&core_content, &core_len, &core_capacity, "\n");
                    }
                    
                    free(file_content);
                    p += file_end_match.rm_eo;
                } else {
                    /* No closing tag - treat rest as file content */
                    char *file_content = strdup(p);
                    
                    ContentItem *item = create_content_item(item_index, CONTENT_TYPE_FILE, file_content);
                    if (item) {
                        item->file_path = file_path ? strdup(file_path) : NULL;
                        item->action = action ? strdup(action) : NULL;
                        
                        if (item_count >= items_capacity) {
                            items_capacity *= 2;
                            items = realloc(items, items_capacity * sizeof(ContentItem*));
                        }
                        items[item_count++] = item;
                        item_index += item->line_segment_count;
                    }
                    
                    free(file_content);
                    break;
                }
                
                free(file_path);
                free(action);
            } else {
                /* Couldn't parse file tag properly, skip it */
                p += file_match.rm_eo;
            }
        }
    }
    
    /* Copy results to final structure */
    result->items = calloc(item_count, sizeof(ContentItem));
    if (!result->items && item_count > 0) {
        /* Cleanup on allocation failure */
        for (size_t i = 0; i < item_count; i++) {
            free_content_item(items[i]);
        }
        for (size_t i = 0; i < delegate_count; i++) {
            free_delegate_edit_item(delegate_edits[i]);
        }
        free(items);
        free(core_content);
        free(delegate_edits);
        free(cleaned);
        free(result);
        return NULL;
    }
    
    for (size_t i = 0; i < item_count; i++) {
        /* Transfer ownership by copying struct and nulling source pointers */
        result->items[i] = *items[i];
        /* Clear the source to prevent double-free */
        memset(items[i], 0, sizeof(ContentItem));
        free(items[i]);
    }
    result->item_count = item_count;
    
    /* Trim core content to match Swift behavior */
    result->core_content = str_trim(core_content);
    free(core_content);  /* Free the original after trimming */
    
    result->delegate_edits = calloc(delegate_count, sizeof(DelegateEditItem));
    if (!result->delegate_edits && delegate_count > 0) {
        /* Cleanup on allocation failure */
        free(result->items);
        free(result->core_content);
        for (size_t i = 0; i < delegate_count; i++) {
            free_delegate_edit_item(delegate_edits[i]);
        }
        free(items);
        free(delegate_edits);
        free(cleaned);
        free(result);
        return NULL;
    }
    
    for (size_t i = 0; i < delegate_count; i++) {
        /* Transfer ownership by copying struct and nulling source pointers */
        result->delegate_edits[i] = *delegate_edits[i];
        /* Clear the source to prevent double-free */
        memset(delegate_edits[i], 0, sizeof(DelegateEditItem));
        free(delegate_edits[i]);
    }
    result->delegate_edit_count = delegate_count;
    
    /* Cleanup - arrays only, contents have been transferred */
    free(items);
    free(delegate_edits);
    free(cleaned);
    
    return result;
}

/* MARK: - Memory Management */

void repo_free_parse_result(ParseResult *result) {
    if (!result) return;
    
    /* Free content items */
    for (size_t i = 0; i < result->item_count; i++) {
        free(result->items[i].content);
        free(result->items[i].file_path);
        free(result->items[i].action);
        
        if (result->items[i].changes) {
            for (char **p = result->items[i].changes; *p; p++) {
                free(*p);
            }
            free(result->items[i].changes);
        }
        
        if (result->items[i].descriptions) {
            for (char **p = result->items[i].descriptions; *p; p++) {
                free(*p);
            }
            free(result->items[i].descriptions);
        }
        
        free_line_segments(result->items[i].line_segments, result->items[i].line_segment_count);
    }
    free(result->items);
    
    /* Free core content */
    free(result->core_content);
    
    /* Free delegate edits */
    if (result->delegate_edits) {
        for (size_t i = 0; i < result->delegate_edit_count; i++) {
            if (result->delegate_edits[i].file_path) {
                free(result->delegate_edits[i].file_path);
            }
            if (result->delegate_edits[i].changes) {
                for (size_t j = 0; j < result->delegate_edits[i].change_count; j++) {
                    if (result->delegate_edits[i].changes[j].description) {
                        free(result->delegate_edits[i].changes[j].description);
                    }
                    if (result->delegate_edits[i].changes[j].code_snippet) {
                        free(result->delegate_edits[i].changes[j].code_snippet);
                    }
                }
                free(result->delegate_edits[i].changes);
            }
        }
        free(result->delegate_edits);
    }
    
    free(result);
}

