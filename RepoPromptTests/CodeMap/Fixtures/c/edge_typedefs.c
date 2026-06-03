#include <stdint.h>

#define DEFAULT_TIMEOUT 30

typedef enum {
    ROLE_ADMIN = 1,
    ROLE_EDITOR = 2
} UserRole;

typedef struct User {
    int id;
    const char *name;
} User;

extern int max_users;

static int add(int a, int b) { return a + b; }

int create_user(const User *user) {
    return user->id;
}
