// Smoke test fixture for Go codemap extraction
package user

import (
	"context"
	"errors"
	"sync"
	"time"
)

// UserRole represents the role of a user
type UserRole string

const (
	RoleAdmin  UserRole = "admin"
	RoleEditor UserRole = "editor"
	RoleViewer UserRole = "viewer"
	RoleGuest  UserRole = "guest"
)

// MaxUsers is the maximum number of users allowed
const MaxUsers = 1000

// DefaultTimeout for operations
var DefaultTimeout = 30 * time.Second

// User represents a user in the system
type User struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Email     string    `json:"email"`
	Role      UserRole  `json:"role"`
	CreatedAt time.Time `json:"created_at"`
}

// DisplayName returns the formatted display name
func (u *User) DisplayName() string {
	return u.Name + " (" + string(u.Role) + ")"
}

// Validate checks if the user data is valid
func (u *User) Validate() error {
	if u.ID == "" {
		return errors.New("user ID cannot be empty")
	}
	if u.Name == "" {
		return errors.New("user name cannot be empty")
	}
	return nil
}

// DataProvider defines the interface for data access
type DataProvider[T any] interface {
	Fetch(ctx context.Context) ([]T, error)
	Save(ctx context.Context, item T) error
	Delete(ctx context.Context, id string) error
}

// UserService manages user operations
type UserService struct {
	mu     sync.RWMutex
	users  map[string]*User
	config Config
}

// Config holds service configuration
type Config struct {
	MaxUsers int
	Timeout  time.Duration
}

// NewUserService creates a new UserService instance
func NewUserService(cfg Config) *UserService {
	return &UserService{
		users:  make(map[string]*User),
		config: cfg,
	}
}

// Fetch retrieves all users
func (s *UserService) Fetch(ctx context.Context) ([]*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	users := make([]*User, 0, len(s.users))
	for _, u := range s.users {
		users = append(users, u)
	}
	return users, nil
}

// Save stores a user
func (s *UserService) Save(ctx context.Context, user *User) error {
	if err := user.Validate(); err != nil {
		return err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if len(s.users) >= s.config.MaxUsers {
		return errors.New("max users reached")
	}

	s.users[user.ID] = user
	return nil
}

// Delete removes a user by ID
func (s *UserService) Delete(ctx context.Context, id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, exists := s.users[id]; !exists {
		return errors.New("user not found")
	}

	delete(s.users, id)
	return nil
}

// GetByRole returns users with the specified role
func (s *UserService) GetByRole(role UserRole) []*User {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var result []*User
	for _, u := range s.users {
		if u.Role == role {
			result = append(result, u)
		}
	}
	return result
}

// CreateUser is a factory function for creating users
func CreateUser(name, email string, role UserRole) *User {
	return &User{
		ID:        generateID(),
		Name:      name,
		Email:     email,
		Role:      role,
		CreatedAt: time.Now(),
	}
}

// generateID creates a unique identifier
func generateID() string {
	return "user_" + time.Now().Format("20060102150405")
}
