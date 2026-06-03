// Smoke test fixture for Rust codemap extraction
use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use std::error::Error;

/// User role enumeration
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UserRole {
    Admin,
    Editor,
    Viewer,
    Guest,
}

impl Default for UserRole {
    fn default() -> Self {
        UserRole::Guest
    }
}

/// User data structure
#[derive(Debug, Clone)]
pub struct User {
    pub id: String,
    pub name: String,
    pub email: String,
    pub role: UserRole,
}

impl User {
    /// Creates a new user
    pub fn new(id: String, name: String, email: String) -> Self {
        Self {
            id,
            name,
            email,
            role: UserRole::default(),
        }
    }

    /// Returns the display name
    pub fn display_name(&self) -> String {
        format!("{} ({:?})", self.name, self.role)
    }

    /// Validates the user data
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.id.is_empty() {
            return Err("User ID cannot be empty");
        }
        if self.name.is_empty() {
            return Err("User name cannot be empty");
        }
        Ok(())
    }
}

/// Trait for data providers
pub trait DataProvider<T> {
    fn fetch(&self) -> Result<Vec<T>, Box<dyn Error>>;
    fn save(&mut self, item: T) -> Result<(), Box<dyn Error>>;
    fn delete(&mut self, id: &str) -> Result<bool, Box<dyn Error>>;
}

/// Service configuration
#[derive(Debug, Clone)]
pub struct Config {
    pub max_users: usize,
    pub timeout_secs: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            max_users: MAX_USERS,
            timeout_secs: 30,
        }
    }
}

/// User service for managing users
pub struct UserService {
    users: Arc<RwLock<HashMap<String, User>>>,
    config: Config,
}

impl UserService {
    /// Creates a new UserService
    pub fn new(config: Config) -> Self {
        Self {
            users: Arc::new(RwLock::new(HashMap::new())),
            config,
        }
    }

    /// Gets users by role
    pub fn get_by_role(&self, role: UserRole) -> Vec<User> {
        let users = self.users.read().unwrap();
        users
            .values()
            .filter(|u| u.role == role)
            .cloned()
            .collect()
    }

    /// Returns the number of users
    pub fn count(&self) -> usize {
        self.users.read().unwrap().len()
    }
}

impl DataProvider<User> for UserService {
    fn fetch(&self) -> Result<Vec<User>, Box<dyn Error>> {
        let users = self.users.read().unwrap();
        Ok(users.values().cloned().collect())
    }

    fn save(&mut self, user: User) -> Result<(), Box<dyn Error>> {
        user.validate()?;
        
        let mut users = self.users.write().unwrap();
        if users.len() >= self.config.max_users {
            return Err("Max users reached".into());
        }
        
        users.insert(user.id.clone(), user);
        Ok(())
    }

    fn delete(&mut self, id: &str) -> Result<bool, Box<dyn Error>> {
        let mut users = self.users.write().unwrap();
        Ok(users.remove(id).is_some())
    }
}

/// Maximum number of users
pub const MAX_USERS: usize = 1000;

/// Default timeout in seconds
pub const DEFAULT_TIMEOUT: u64 = 30;

/// Creates a new user with generated ID
pub fn create_user(name: String, email: String, role: UserRole) -> User {
    User {
        id: generate_id(),
        name,
        email,
        role,
    }
}

/// Generates a unique ID
fn generate_id() -> String {
    format!("user_{}", std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_user_creation() {
        let user = User::new("1".into(), "Test".into(), "test@example.com".into());
        assert_eq!(user.role, UserRole::Guest);
    }
}
