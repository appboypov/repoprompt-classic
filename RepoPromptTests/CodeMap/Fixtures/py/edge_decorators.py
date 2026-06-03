from enum import Enum

def slugify(text: str) -> str:
    return text.strip().lower().replace(" ", "-")

class Status(Enum):
    ACTIVE = "active"
    DISABLED = "disabled"

class User:
    def __init__(self, user_id: int, name: str) -> None:
        self.user_id = user_id
        self.name = name

    @property
    def display_name(self) -> str:
        return f"{self.name}#{self.user_id}"

DEFAULT_ROLE = "user"
