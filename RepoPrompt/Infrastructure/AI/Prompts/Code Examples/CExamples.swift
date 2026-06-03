//
//  CExamples.swift
//  RepoPrompt
//
//  Created by Assistant on 2025-07-14.
//

import Foundation

/**
 * CExamples implements CodeExamples for C-specific snippets.
 */
public struct CExamples: CodeExamples {
	
	// MARK: 1) Search & Replace Lines for "User" struct
	public func userSearchReplaceOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>typedef struct {",
				"<s4>char id[37];",
				"<s4>char name[100];",
				"<s0>} User;"
			]
		} else {
			return [
				"typedef struct {",
				"    char id[37];",
				"    char name[100];",
				"} User;"
			]
		}
	}
	
	public func userSearchReplaceNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>typedef struct {",
				"<s4>char id[37];",
				"<s4>char name[100];",
				"<s4>char email[256];",
				"<s0>} User;"
			]
		} else {
			return [
				"typedef struct {",
				"    char id[37];",
				"    char name[100];",
				"    char email[256];",
				"} User;"
			]
		}
	}
	
	// MARK: 2) Rewrite Entire File with an "email" field
	public func userRewriteAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>#ifndef USER_H",
				"<s0>#define USER_H",
				"<s0>",
				"<s0>#include <string.h>",
				"<s0>#include <stdlib.h>",
				"<s0>",
				"<s0>typedef struct {",
				"<s4>char id[37];",
				"<s4>char name[100];",
				"<s4>char email[256];",
				"<s0>} User;",
				"<s0>",
				"<s0>User* create_user(const char* name, const char* email) {",
				"<s4>User* user = (User*)malloc(sizeof(User));",
				"<s4>if (user) {",
				"<s8>// Simple ID generation (placeholder)",
				"<s8>sprintf(user->id, \"user_%d\", rand());",
				"<s8>strncpy(user->name, name, 99);",
				"<s8>user->name[99] = '\\0';",
				"<s8>strncpy(user->email, email, 255);",
				"<s8>user->email[255] = '\\0';",
				"<s4>}",
				"<s4>return user;",
				"<s0>}",
				"<s0>",
				"<s0>#endif"
			]
		} else {
			return [
				"#ifndef USER_H",
				"#define USER_H",
				"",
				"#include <string.h>",
				"#include <stdlib.h>",
				"",
				"typedef struct {",
				"    char id[37];",
				"    char name[100];",
				"    char email[256];",
				"} User;",
				"",
				"User* create_user(const char* name, const char* email) {",
				"    User* user = (User*)malloc(sizeof(User));",
				"    if (user) {",
				"        // Simple ID generation (placeholder)",
				"        sprintf(user->id, \"user_%d\", rand());",
				"        strncpy(user->name, name, 99);",
				"        user->name[99] = '\\0';",
				"        strncpy(user->email, email, 255);",
				"        user->email[255] = '\\0';",
				"    }",
				"    return user;",
				"}",
				"",
				"#endif"
			]
		}
	}
	
	// MARK: 3) Create a new "rounded_button" file
	public func userCreateAllLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>#ifndef ROUNDED_BUTTON_H",
				"<s0>#define ROUNDED_BUTTON_H",
				"<s0>",
				"<s0>#include <gtk/gtk.h>",
				"<s0>",
				"<s0>typedef struct {",
				"<s4>GtkButton parent;",
				"<s4>gdouble corner_radius;",
				"<s0>} RoundedButton;",
				"<s0>",
				"<s0>typedef struct {",
				"<s4>GtkButtonClass parent_class;",
				"<s0>} RoundedButtonClass;",
				"<s0>",
				"<s0>GType rounded_button_get_type(void);",
				"<s0>GtkWidget* rounded_button_new(void);",
				"<s0>void rounded_button_set_corner_radius(RoundedButton* button, gdouble radius);",
				"<s0>",
				"<s0>#endif"
			]
		} else {
			return [
				"#ifndef ROUNDED_BUTTON_H",
				"#define ROUNDED_BUTTON_H",
				"",
				"#include <gtk/gtk.h>",
				"",
				"typedef struct {",
				"    GtkButton parent;",
				"    gdouble corner_radius;",
				"} RoundedButton;",
				"",
				"typedef struct {",
				"    GtkButtonClass parent_class;",
				"} RoundedButtonClass;",
				"",
				"GType rounded_button_get_type(void);",
				"GtkWidget* rounded_button_new(void);",
				"void rounded_button_set_corner_radius(RoundedButton* button, gdouble radius);",
				"",
				"#endif"
			]
		}
	}
	
	// MARK: 4) NetworkManager async conversion (using callbacks)
	public func networkManagerOldLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>void fetch_data(const char* url, void (*completion)(const char*)) {",
				"<s4>CURL* curl = curl_easy_init();",
				"<s4>if (curl) {",
				"<s8>curl_easy_setopt(curl, CURLOPT_URL, url);",
				"<s8>// Synchronous blocking call",
				"<s8>CURLcode res = curl_easy_perform(curl);",
				"<s8>if (res == CURLE_OK) {",
				"<s12>completion(response_buffer);",
				"<s8>}",
				"<s8>curl_easy_cleanup(curl);",
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"void fetch_data(const char* url, void (*completion)(const char*)) {",
				"    CURL* curl = curl_easy_init();",
				"    if (curl) {",
				"        curl_easy_setopt(curl, CURLOPT_URL, url);",
				"        // Synchronous blocking call",
				"        CURLcode res = curl_easy_perform(curl);",
				"        if (res == CURLE_OK) {",
				"            completion(response_buffer);",
				"        }",
				"        curl_easy_cleanup(curl);",
				"    }",
				"}"
			]
		}
	}
	
	public func networkManagerNewLines(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>typedef struct {",
				"<s4>void (*callback)(const char*);",
				"<s4>char* buffer;",
				"<s0>} FetchContext;",
				"<s0>",
				"<s0>void fetch_data_async(const char* url, void (*completion)(const char*)) {",
				"<s4>pthread_t thread;",
				"<s4>FetchContext* ctx = malloc(sizeof(FetchContext));",
				"<s4>ctx->callback = completion;",
				"<s4>// Launch in background thread",
				"<s4>pthread_create(&thread, NULL, fetch_worker, ctx);",
				"<s4>pthread_detach(thread);",
				"<s0>}"
			]
		} else {
			return [
				"typedef struct {",
				"    void (*callback)(const char*);",
				"    char* buffer;",
				"} FetchContext;",
				"",
				"void fetch_data_async(const char* url, void (*completion)(const char*)) {",
				"    pthread_t thread;",
				"    FetchContext* ctx = malloc(sizeof(FetchContext));",
				"    ctx->callback = completion;",
				"    // Launch in background thread",
				"    pthread_create(&thread, NULL, fetch_worker, ctx);",
				"    pthread_detach(thread);",
				"}"
			]
		}
	}
	
	// MARK: Negative Examples
	public func userSearchReplaceNegativeExampleFileContents(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s0>#include \"user_service.h\"",
				"<s0>#include \"logger.h\"",
				"<s0>",
				"<s0>void process_user(User* user) {",
				"<s4>if (user == NULL) {",
				"<s8>log_error(\"User is NULL\");",
				"<s8>return;",
				"<s4>}",
				"<s4>log_info(\"Processing user: %s\", user->name);",
				"<s0>}"
			]
		} else {
			return [
				"#include \"user_service.h\"",
				"#include \"logger.h\"",
				"",
				"void process_user(User* user) {",
				"    if (user == NULL) {",
				"        log_error(\"User is NULL\");",
				"        return;",
				"    }",
				"    log_info(\"Processing user: %s\", user->name);",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleSearchBlock(includeIndentation: Bool) -> [String] {
		// Intentionally mismatched - missing braces
		if includeIndentation {
			return [
				"<s4>if (user == NULL)",
				"<s8>log_error(\"User is NULL\");"
			]
		} else {
			return [
				"    if (user == NULL)",
				"        log_error(\"User is NULL\");"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>if (user == NULL || strlen(user->name) == 0) {",
				"<s8>log_error(\"User is invalid\");",
				"<s8>return;",
				"<s4>}"
			]
		} else {
			return [
				"    if (user == NULL || strlen(user->name) == 0) {",
				"        log_error(\"User is invalid\");",
				"        return;",
				"    }"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchFileContents(includeIndentation: Bool) -> [String] {
		return userSearchReplaceNegativeExampleFileContents(includeIndentation: includeIndentation)
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>}",
				"<s4>log_info(\"Processing user: %s\", user->name);",
				"<s0>}"
			]
		} else {
			return [
				"    }",
				"    log_info(\"Processing user: %s\", user->name);",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleBraceMismatchNewBlock(includeIndentation: Bool) -> [String] {
		// Extra closing brace added
		if includeIndentation {
			return [
				"<s4>}",
				"<s4>log_info(\"Processing user: %s\", user->name);",
				"<s4>// Additional validation",
				"<s4>validate_user(user);",
				"<s0>}",
				"<s0>}"  // Extra brace
			]
		} else {
			return [
				"    }",
				"    log_info(\"Processing user: %s\", user->name);",
				"    // Additional validation",
				"    validate_user(user);",
				"}",
				"}"  // Extra brace
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineSearchBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s4>log_info(\"Processing user: %s\", user->name);"]
		} else {
			return ["    log_info(\"Processing user: %s\", user->name);"]
		}
	}
	
	public func userSearchReplaceNegativeExampleOneLineNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return ["<s4>log_debug(\"Processing user: %s (ID: %s)\", user->name, user->id);"]
		} else {
			return ["    log_debug(\"Processing user: %s (ID: %s)\", user->name, user->id);"]
		}
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousSearchBlock(includeIndentation: Bool) -> [String] {
		// Just closing braces - ambiguous
		if includeIndentation {
			return [
				"<s4>}",
				"<s0>}"
			]
		} else {
			return [
				"    }",
				"}"
			]
		}
	}
	
	public func userSearchReplaceNegativeExampleAmbiguousNewBlock(includeIndentation: Bool) -> [String] {
		if includeIndentation {
			return [
				"<s4>}",
				"<s4>// TODO: Add more processing",
				"<s0>}"
			]
		} else {
			return [
				"    }",
				"    // TODO: Add more processing",
				"}"
			]
		}
	}
	
	// MARK: Delegate Edit Examples
	public func delegateEditComplexReplaceLines() -> [String] {
		return [
			"int load_user_data(int user_id, User** user_out) {",
			"    // REPOMARK:SCOPE: 1 - Replace blocking call with async operation",
			"    char url[256];",
			"    snprintf(url, sizeof(url), \"/api/users/%d\", user_id);",
			"    ",
			"    FetchRequest* req = create_fetch_request(url);",
			"    req->on_complete = handle_user_response;",
			"    req->user_data = user_out;",
			"    ",
			"    return submit_async_request(req);",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditComplexAddDeleteLines() -> [String] {
		return [
			"void configure_ui(UIConfig* config) {",
			"    // REPOMARK:SCOPE: 1 - Delete hard-coded color and add theme support",
			"    // ... existing code ...",
			"    config->bg_color = get_theme_color(current_theme, COLOR_BACKGROUND);",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditInlineTweakSingleScope() -> [String] {
		return [
			"typedef struct {",
			"    int current_health;",
			"    int max_health;",
			"} Player;",
			"",
			"void heal_player(Player* player, int amount) {",
			"    // REPOMARK:SCOPE: 1 - Cap health at max_health instead of 999",
			"    player->current_health = min(player->current_health + amount, player->max_health);",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditInlineTweaksTwoScopes() -> [String] {
		return [
			"void heal_player(Player* player, int amount) {",
			"    // REPOMARK:SCOPE: 1 - Cap health at max_health",
			"    player->current_health = min(player->current_health + amount, player->max_health);",
			"    // ... existing code ...",
			"}",
			"",
			"void collect_bonus(Player* player, Bonus* bonus) {",
			"    // REPOMARK:SCOPE: 2 - Add +10 bonus to score",
			"    player->score += bonus->value + 10;",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditComplexSingleScope() -> [String] {
		return [
			"void process_order(Order* order) {",
			"    // REPOMARK:SCOPE: 1 - Adjust tax calc, remove legacy discount, add logging",
			"    double subtotal = calculate_subtotal(order);",
			"    double tax = subtotal * get_tax_rate(order->shipping_address);",
			"    // Legacy discount logic removed",
			"    double total = subtotal + tax;",
			"    ",
			"    log_info(\"Order %d: subtotal=%.2f, tax=%.2f, total=%.2f\",",
			"             order->id, subtotal, tax, total);",
			"    order->total = total;",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func delegateEditFullScopeSwap() -> [String] {
		return [
			"// ... existing code ...",
			"// REPOMARK:SCOPE: 1 - Replace generate_structures with randomized algorithm",
			"void generate_structures(World* world) {",
			"    srand(time(NULL));",
			"    int structure_count = 5 + rand() % 10;",
			"    ",
			"    for (int i = 0; i < structure_count; i++) {",
			"        int x = rand() % world->width;",
			"        int z = rand() % world->depth;",
			"        StructureType type = rand() % STRUCTURE_TYPE_COUNT;",
			"        ",
			"        place_structure(world, x, z, type);",
			"    }",
			"}",
			"// ... existing code ..."
		]
	}
	
	public func delegateEditNegativeVerbose() -> [String] {
		return [
			"typedef struct {",
			"    // REPOMARK:SCOPE: 1 - Add on_state_changed callback property",
			"    void (*on_state_changed)(GameState);",
			"    // ... existing code ...",
			"    GameState current_state;",
			"    int player_count;",
			"} GameManager;",
			"",
			"void init_game_manager(GameManager* gm) {",
			"    printf(\"GameManager initializing...\\n\");",
			"    load_game_data(gm);",
			"}",
			"",
			"void update_game_manager(GameManager* gm) {",
			"    handle_input(gm);",
			"    update_game_state(gm);",
			"}",
			"",
			"void load_game_data(GameManager* gm) {",
			"    // Load save data",
			"    SaveData* save = load_save_file();",
			"    if (save != NULL) {",
			"        restore_game_state(gm, save);",
			"    }",
			"}",
			"",
			"void generate_random_layout(GameManager* gm) {",
			"    // Generate world",
			"    for (int x = 0; x < 100; x++) {",
			"        for (int y = 0; y < 100; y++) {",
			"            gm->tiles[x][y] = get_random_tile();",
			"        }",
			"    }",
			"}"
		]
	}
	
	public func commentSyntax() -> String {
		return "//"
	}
	
	// File editor examples use default implementation from protocol extension
	
	// MARK: - Rewrite-Only File Editor Example Methods
	
	public func fileEditorRewriteExampleFileContents() -> [String] {
		return [
			"#include <stdio.h>",
			"#include <stdlib.h>",
			"#include <string.h>",
			"",
			"typedef struct {",
			"    char* id;",
			"    char* name;",
			"} User;",
			"",
			"typedef struct {",
			"    User* users;",
			"    int count;",
			"    int capacity;",
			"} UserService;",
			"",
			"UserService* create_user_service() {",
			"    UserService* service = malloc(sizeof(UserService));",
			"    service->users = malloc(10 * sizeof(User));",
			"    service->count = 0;",
			"    service->capacity = 10;",
			"    return service;",
			"}",
			"",
			"User process_user(const User* user_data) {",
			"    // Process user data",
			"    User user;",
			"    user.id = strdup(user_data->id);",
			"    user.name = strdup(user_data->name);",
			"    return user;",
			"}",
			"",
			"void save_user(UserService* service, User user) {",
			"    // Save user to database",
			"    if (service->count >= service->capacity) {",
			"        service->capacity *= 2;",
			"        service->users = realloc(service->users, service->capacity * sizeof(User));",
			"    }",
			"    service->users[service->count++] = user;",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleChange1() -> [String] {
		return [
			"User process_user(const User* user_data) {",
			"    // Add validation",
			"    if (user_data == NULL || user_data->id == NULL || user_data->name == NULL) {",
			"        fprintf(stderr, \"Invalid user data\\n\");",
			"        User empty = {NULL, NULL};",
			"        return empty;",
			"    }",
			"    ",
			"    // ... existing code ...",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleChange2() -> [String] {
		return [
			"void save_user(UserService* service, User user) {",
			"    // ... existing code ...",
			"    printf(\"User saved successfully\\n\");",
			"}"
		]
	}
	
	public func fileEditorRewriteExampleCompleteFile() -> [String] {
		return [
			"#include <stdio.h>",
			"#include <stdlib.h>",
			"#include <string.h>",
			"",
			"typedef struct {",
			"    char* id;",
			"    char* name;",
			"} User;",
			"",
			"typedef struct {",
			"    User* users;",
			"    int count;",
			"    int capacity;",
			"} UserService;",
			"",
			"UserService* create_user_service() {",
			"    UserService* service = malloc(sizeof(UserService));",
			"    service->users = malloc(10 * sizeof(User));",
			"    service->count = 0;",
			"    service->capacity = 10;",
			"    return service;",
			"}",
			"",
			"User process_user(const User* user_data) {",
			"    // Add validation",
			"    if (user_data == NULL || user_data->id == NULL || user_data->name == NULL) {",
			"        fprintf(stderr, \"Invalid user data\\n\");",
			"        User empty = {NULL, NULL};",
			"        return empty;",
			"    }",
			"    ",
			"    // Process user data",
			"    User user;",
			"    user.id = strdup(user_data->id);",
			"    user.name = strdup(user_data->name);",
			"    return user;",
			"}",
			"",
			"void save_user(UserService* service, User user) {",
			"    // Save user to database",
			"    if (service->count >= service->capacity) {",
			"        service->capacity *= 2;",
			"        service->users = realloc(service->users, service->capacity * sizeof(User));",
			"    }",
			"    service->users[service->count++] = user;",
			"    printf(\"User saved successfully\\n\");",
			"}"
		]
	}
}