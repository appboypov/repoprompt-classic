// Smoke test fixture for C codemap extraction
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <time.h>

// Constants
#define MAX_USERS 1000
#define MAX_NAME_LENGTH 256
#define DEFAULT_TIMEOUT 30

// User role enumeration
typedef enum {
    ROLE_ADMIN,
    ROLE_EDITOR,
    ROLE_VIEWER,
    ROLE_GUEST
} UserRole;

// Forward declarations
struct User;
struct UserService;

// User structure
typedef struct User {
    char id[64];
    char name[MAX_NAME_LENGTH];
    char email[MAX_NAME_LENGTH];
    UserRole role;
} User;

// Service configuration
typedef struct Config {
    int max_users;
    int timeout_secs;
} Config;

// User service structure
typedef struct UserService {
    User* users[MAX_USERS];
    int user_count;
    Config config;
} UserService;

// Function prototypes
UserService* user_service_create(Config config);
void user_service_destroy(UserService* service);
int user_service_save(UserService* service, User* user);
User* user_service_find(UserService* service, const char* id);
bool user_service_delete(UserService* service, const char* id);
int user_service_get_by_role(UserService* service, UserRole role, User** results, int max_results);

User* user_create(const char* name, const char* email, UserRole role);
void user_destroy(User* user);
bool user_validate(const User* user);
const char* user_display_name(const User* user, char* buffer, size_t size);

// Static helper functions
static void generate_id(char* buffer, size_t size);
static const char* role_to_string(UserRole role);

// Implementation

UserService* user_service_create(Config config) {
    UserService* service = (UserService*)malloc(sizeof(UserService));
    if (!service) return NULL;
    
    memset(service->users, 0, sizeof(service->users));
    service->user_count = 0;
    service->config = config;
    
    return service;
}

void user_service_destroy(UserService* service) {
    if (!service) return;
    
    for (int i = 0; i < service->user_count; i++) {
        user_destroy(service->users[i]);
    }
    free(service);
}

int user_service_save(UserService* service, User* user) {
    if (!service || !user) return -1;
    if (!user_validate(user)) return -2;
    if (service->user_count >= service->config.max_users) return -3;
    
    service->users[service->user_count++] = user;
    return 0;
}

User* user_service_find(UserService* service, const char* id) {
    if (!service || !id) return NULL;
    
    for (int i = 0; i < service->user_count; i++) {
        if (strcmp(service->users[i]->id, id) == 0) {
            return service->users[i];
        }
    }
    return NULL;
}

bool user_service_delete(UserService* service, const char* id) {
    if (!service || !id) return false;
    
    for (int i = 0; i < service->user_count; i++) {
        if (strcmp(service->users[i]->id, id) == 0) {
            user_destroy(service->users[i]);
            // Shift remaining users
            for (int j = i; j < service->user_count - 1; j++) {
                service->users[j] = service->users[j + 1];
            }
            service->user_count--;
            return true;
        }
    }
    return false;
}

int user_service_get_by_role(UserService* service, UserRole role, User** results, int max_results) {
    if (!service || !results) return 0;
    
    int count = 0;
    for (int i = 0; i < service->user_count && count < max_results; i++) {
        if (service->users[i]->role == role) {
            results[count++] = service->users[i];
        }
    }
    return count;
}

User* user_create(const char* name, const char* email, UserRole role) {
    User* user = (User*)malloc(sizeof(User));
    if (!user) return NULL;
    
    generate_id(user->id, sizeof(user->id));
    strncpy(user->name, name, MAX_NAME_LENGTH - 1);
    strncpy(user->email, email, MAX_NAME_LENGTH - 1);
    user->role = role;
    
    return user;
}

void user_destroy(User* user) {
    free(user);
}

bool user_validate(const User* user) {
    if (!user) return false;
    if (strlen(user->id) == 0) return false;
    if (strlen(user->name) == 0) return false;
    return true;
}

const char* user_display_name(const User* user, char* buffer, size_t size) {
    if (!user || !buffer) return NULL;
    snprintf(buffer, size, "%s (%s)", user->name, role_to_string(user->role));
    return buffer;
}

static void generate_id(char* buffer, size_t size) {
    snprintf(buffer, size, "user_%ld", (long)time(NULL));
}

static const char* role_to_string(UserRole role) {
    switch (role) {
        case ROLE_ADMIN: return "Admin";
        case ROLE_EDITOR: return "Editor";
        case ROLE_VIEWER: return "Viewer";
        case ROLE_GUEST: return "Guest";
        default: return "Unknown";
    }
}

// Global configuration
Config default_config = {
    .max_users = MAX_USERS,
    .timeout_secs = DEFAULT_TIMEOUT
};
