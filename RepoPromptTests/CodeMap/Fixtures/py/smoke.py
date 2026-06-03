"""Smoke test fixture for Python codemap extraction."""

from __future__ import annotations
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Optional, List, Dict, TypeVar, Generic
from enum import Enum, auto
import asyncio


# Type variable for generic classes
T = TypeVar('T')


class UserRole(Enum):
    """User role enumeration."""
    ADMIN = auto()
    EDITOR = auto()
    VIEWER = auto()
    GUEST = auto()


@dataclass
class User:
    """User data model."""
    id: str
    name: str
    email: str
    role: UserRole = UserRole.GUEST
    metadata: Dict[str, str] = field(default_factory=dict)
    
    def __post_init__(self):
        if not self.id:
            raise ValueError("User ID cannot be empty")
    
    @property
    def display_name(self) -> str:
        """Returns formatted display name."""
        return f"{self.name} ({self.role.name})"
    
    def to_dict(self) -> Dict[str, any]:
        """Converts user to dictionary."""
        return {
            'id': self.id,
            'name': self.name,
            'email': self.email,
            'role': self.role.value
        }


class DataProvider(ABC, Generic[T]):
    """Abstract base class for data providers."""
    
    @abstractmethod
    async def fetch(self) -> List[T]:
        """Fetches all items."""
        pass
    
    @abstractmethod
    async def save(self, item: T) -> None:
        """Saves an item."""
        pass
    
    @abstractmethod
    async def delete(self, item_id: str) -> bool:
        """Deletes an item by ID."""
        pass


class UserService(DataProvider[User]):
    """Service for managing users."""
    
    _instance: Optional[UserService] = None
    
    def __init__(self, config: Optional[Dict] = None):
        self._users: Dict[str, User] = {}
        self._config = config or {}
        self._initialized = False
    
    @classmethod
    def get_instance(cls, config: Optional[Dict] = None) -> UserService:
        """Returns singleton instance."""
        if cls._instance is None:
            cls._instance = cls(config)
        return cls._instance
    
    async def fetch(self) -> List[User]:
        """Fetches all users."""
        return list(self._users.values())
    
    async def save(self, user: User) -> None:
        """Saves a user."""
        self._users[user.id] = user
    
    async def delete(self, user_id: str) -> bool:
        """Deletes a user."""
        if user_id in self._users:
            del self._users[user_id]
            return True
        return False
    
    def get_by_role(self, role: UserRole) -> List[User]:
        """Gets users by role."""
        return [u for u in self._users.values() if u.role == role]


def create_user(name: str, email: str, role: UserRole = UserRole.GUEST) -> User:
    """Factory function to create a new user."""
    import uuid
    return User(
        id=str(uuid.uuid4()),
        name=name,
        email=email,
        role=role
    )


async def batch_save_users(service: UserService, users: List[User]) -> int:
    """Saves multiple users and returns count."""
    for user in users:
        await service.save(user)
    return len(users)


# Module-level constants
MAX_USERS: int = 1000
DEFAULT_TIMEOUT: float = 30.0
VERSION: str = "1.0.0"


# Private helper
def _validate_email(email: str) -> bool:
    """Validates email format."""
    return '@' in email and '.' in email
