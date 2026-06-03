<?php
// Smoke test fixture for PHP codemap extraction

declare(strict_types=1);

namespace App\User;

use DateTime;
use Exception;
use InvalidArgumentException;

/**
 * Maximum number of users allowed
 */
const MAX_USERS = 1000;

/**
 * Default timeout in seconds
 */
define('DEFAULT_TIMEOUT', 30);

/**
 * User role enumeration (PHP 8.1+)
 */
enum UserRole: string
{
    case Admin = 'admin';
    case Editor = 'editor';
    case Viewer = 'viewer';
    case Guest = 'guest';

    public function displayName(): string
    {
        return match($this) {
            self::Admin => 'Administrator',
            self::Editor => 'Editor',
            self::Viewer => 'Viewer',
            self::Guest => 'Guest',
        };
    }
}

/**
 * Data provider interface
 */
interface DataProvider
{
    public function fetch(): array;
    public function save(mixed $item): void;
    public function delete(string $id): bool;
}

/**
 * User data model
 */
class User
{
    public readonly DateTime $createdAt;
    
    public function __construct(
        public readonly string $id,
        public string $name,
        public string $email,
        public UserRole $role = UserRole::Guest
    ) {
        $this->createdAt = new DateTime();
    }

    public function getDisplayName(): string
    {
        return sprintf('%s (%s)', $this->name, $this->role->displayName());
    }

    public function validate(): bool
    {
        return !empty($this->id) && !empty($this->name);
    }

    public function toArray(): array
    {
        return [
            'id' => $this->id,
            'name' => $this->name,
            'email' => $this->email,
            'role' => $this->role->value,
        ];
    }

    public static function fromArray(array $data): self
    {
        return new self(
            id: $data['id'],
            name: $data['name'],
            email: $data['email'],
            role: UserRole::from($data['role'] ?? 'guest')
        );
    }
}

/**
 * Service configuration
 */
class Config
{
    public function __construct(
        public readonly int $maxUsers = MAX_USERS,
        public readonly int $timeoutSeconds = DEFAULT_TIMEOUT
    ) {}
}

/**
 * User service for managing users
 */
class UserService implements DataProvider
{
    private array $users = [];
    private static ?self $instance = null;

    public function __construct(
        private readonly Config $config = new Config()
    ) {}

    public static function getInstance(?Config $config = null): self
    {
        if (self::$instance === null) {
            self::$instance = new self($config ?? new Config());
        }
        return self::$instance;
    }

    public function getCount(): int
    {
        return count($this->users);
    }

    public function fetch(): array
    {
        return array_values($this->users);
    }

    public function save(mixed $user): void
    {
        if (!$user instanceof User) {
            throw new InvalidArgumentException('Expected User instance');
        }
        if (!$user->validate()) {
            throw new InvalidArgumentException('Invalid user data');
        }
        if (count($this->users) >= $this->config->maxUsers) {
            throw new Exception('Max users reached');
        }
        $this->users[$user->id] = $user;
    }

    public function delete(string $id): bool
    {
        if (isset($this->users[$id])) {
            unset($this->users[$id]);
            return true;
        }
        return false;
    }

    public function find(string $id): ?User
    {
        return $this->users[$id] ?? null;
    }

    public function getByRole(UserRole $role): array
    {
        return array_filter(
            $this->users,
            fn(User $u) => $u->role === $role
        );
    }
}

/**
 * User factory trait
 */
trait UserFactoryTrait
{
    private static int $counter = 0;

    public static function createUser(
        string $name,
        string $email,
        UserRole $role = UserRole::Guest
    ): User {
        return new User(
            id: 'user_' . (++self::$counter),
            name: $name,
            email: $email,
            role: $role
        );
    }
}

/**
 * User factory class
 */
class UserFactory
{
    use UserFactoryTrait;

    public static function validateEmail(string $email): bool
    {
        return filter_var($email, FILTER_VALIDATE_EMAIL) !== false;
    }
}

/**
 * Creates a new user
 */
function createUser(string $name, string $email): User
{
    return UserFactory::createUser($name, $email);
}

/**
 * Validates email format
 */
function validateEmail(string $email): bool
{
    return str_contains($email, '@');
}
