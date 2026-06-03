//  RepoPrompt-Bridging-Header.h
//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//

#ifndef RepoPrompt_Bridging_Header_h
#define RepoPrompt_Bridging_Header_h

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/ptrace.h>
#include <unistd.h>
#include <stdbool.h>

// Define PT_DENY_ATTACH if not already defined
#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif


// Forward declare TSLanguage so the compiler knows it's a struct.
typedef struct TSLanguage TSLanguage;

const TSLanguage * tree_sitter_javascript(void);
const TSLanguage * tree_sitter_python(void);
const TSLanguage * tree_sitter_c_sharp(void);
const TSLanguage * tree_sitter_swift(void);
const TSLanguage * tree_sitter_c(void);
const TSLanguage * tree_sitter_cpp(void);
const TSLanguage * tree_sitter_rust(void);
const TSLanguage * tree_sitter_go(void);
const TSLanguage * tree_sitter_java(void);    // Java support added
const TSLanguage * tree_sitter_dart(void);    // Dart support added
const TSLanguage * tree_sitter_php(void);    // Dart support added
const TSLanguage * tree_sitter_ruby(void);   // Ruby support added

// Bundled wildmatch matcher for gitignore-compatible pattern matching
int repo_wildmatch(const char *pattern, const char *text, unsigned int flags);

// Gitignore-specific matching functions
int repo_gitignore_match_anchored(const char *pattern, const char *path);
int repo_gitignore_match_anywhere(const char *pattern, const char *path);
void repo_normalize_pattern(char *dest, const char *src, size_t dest_size);

// Pattern parsing structure
typedef struct {
    char pattern[1024];
    bool is_negation;
    bool directory_only;
    bool absolute;
} repo_gitignore_pattern;

// Parse a gitignore line
bool repo_parse_gitignore_line(const char *line, repo_gitignore_pattern *result);

// String extensions from string_extensions_wrapper.h
#include "Support/C/Utils/string_extensions_wrapper.h"

// Chat content parser functions
#include "Support/C/Utils/chat_content_parser.h"

// Search scoring functions
#include "Support/C/Utils/search_scoring.h"

// Path search functions
#include "Support/C/Utils/path_search.h"

// Monotonic clock helper
#include "Infrastructure/Security/MonotonicClock.h"

// PCRE2 regex (vendored from SwiftPCRE2)
#include "Infrastructure/Regex/CSwiftPCRE2/include/CSwiftPCRE2.h"

#endif /* RepoPrompt_Bridging_Header_h */
