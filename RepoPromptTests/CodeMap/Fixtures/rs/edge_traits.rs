use std::fmt::Display;

pub const MAX_USERS: usize = 100;

pub static DEFAULT_TIMEOUT: i32 = 30;

pub enum Status {
    Active,
    Disabled,
}

pub trait Store<T> {
    fn save(&self, item: T);
}

pub struct User {
    pub id: i32,
    pub name: String,
}

impl User {
    pub fn new(id: i32, name: String) -> Self {
        Self { id, name }
    }
}

pub fn format_user(user: &User) -> String {
    format!("{}:{}", user.name, user.id)
}

pub fn id_as_string<T: Display>(value: T) -> String {
    value.to_string()
}
