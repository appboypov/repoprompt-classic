//
//  ChatContentParserBridge.swift
//  RepoPrompt
//
//  A very small Swift → C bridge that exposes the same "extract + clean"
//  pipeline used in the Swift-only parser.  C code can now obtain a
//  fully-processed `<content>` payload (diff fences removed, indentation
//  normalised, leading whitespace trimmed) with one call.
//
//  Memory contract:
//  • The returned pointer is allocated with `strdup`, therefore the C side
//    MUST `free()` it when done.
//

import Foundation

/// C-callable helper that mimics
///   ChatContentParser.extractCodeContent(…)
///
/// - Parameter rawContent: A NUL-terminated C string that contains the raw
///                         `<change>` or `<file>` body.
/// - Returns: A newly-allocated C string with the cleaned code snippet
///            (caller owns / must `free()`), or `NULL` on allocation failure.
///
/// Usage from C:
///     char *clean = repo_extract_clean_content(raw_body);
///     …
///     free(clean);
@_cdecl("repo_extract_clean_content")
public func repo_extract_clean_content(
    _ rawContent: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>? {
    
    // ------------------------------------------------------------------
    // 1. Defensive checks + turn C string into Swift String
    // ------------------------------------------------------------------
    guard let rawCStr = rawContent else {
        return strdup("")
    }
    let input = String(cString: rawCStr)
    
    // ------------------------------------------------------------------
    // 2. Extract inner payload of the <content> tag using the exact same
    //    helper the Swift pipeline relies on (handles === fences).
    // ------------------------------------------------------------------
    guard let extracted = DiffParserUtils
            .extractContent(from: input, tag: "content", flexible: true)
    else {
        return strdup("")
    }
    
    // ------------------------------------------------------------------
    // 3. Re-use trim pipeline from ChatContentParser
    // ------------------------------------------------------------------
    let cleanedSnippet = ChatContentParser.trimContent(extracted)
    
    // ------------------------------------------------------------------
    // 4. Return as malloc'ed C string  (caller is responsible for free())
    // ------------------------------------------------------------------
    return strdup(cleanedSnippet)
}
