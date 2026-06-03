// Smoke test fixture for C# codemap extraction
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;

namespace UserManagement
{
    /// <summary>
    /// User role enumeration
    /// </summary>
    public enum UserRole
    {
        Admin,
        Editor,
        Viewer,
        Guest
    }

    /// <summary>
    /// User data model
    /// </summary>
    public class User
    {
        public string Id { get; set; }
        public string Name { get; set; }
        public string Email { get; set; }
        public UserRole Role { get; set; } = UserRole.Guest;
        public DateTime CreatedAt { get; init; }

        public User(string id, string name, string email)
        {
            Id = id;
            Name = name;
            Email = email;
            CreatedAt = DateTime.UtcNow;
        }

        public string DisplayName => $"{Name} ({Role})";

        public bool Validate()
        {
            return !string.IsNullOrEmpty(Id) && !string.IsNullOrEmpty(Name);
        }
    }

    /// <summary>
    /// Data provider interface
    /// </summary>
    public interface IDataProvider<T>
    {
        Task<IEnumerable<T>> FetchAsync();
        Task SaveAsync(T item);
        Task<bool> DeleteAsync(string id);
    }

    /// <summary>
    /// Service configuration
    /// </summary>
    public record Config(int MaxUsers = 1000, int TimeoutSeconds = 30);

    /// <summary>
    /// User service for managing users
    /// </summary>
    public class UserService : IDataProvider<User>, IDisposable
    {
        private readonly Dictionary<string, User> _users = new();
        private readonly Config _config;
        private bool _disposed;

        public static int MaxUsers => 1000;
        public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(30);

        public UserService(Config? config = null)
        {
            _config = config ?? new Config();
        }

        public int Count => _users.Count;

        public async Task<IEnumerable<User>> FetchAsync()
        {
            await Task.Yield();
            return _users.Values.ToList();
        }

        public async Task SaveAsync(User user)
        {
            if (user == null)
                throw new ArgumentNullException(nameof(user));
            
            if (!user.Validate())
                throw new ArgumentException("Invalid user data", nameof(user));
            
            if (_users.Count >= _config.MaxUsers)
                throw new InvalidOperationException("Max users reached");

            await Task.Yield();
            _users[user.Id] = user;
        }

        public async Task<bool> DeleteAsync(string id)
        {
            await Task.Yield();
            return _users.Remove(id);
        }

        public User? Find(string id)
        {
            return _users.GetValueOrDefault(id);
        }

        public IEnumerable<User> GetByRole(UserRole role)
        {
            return _users.Values.Where(u => u.Role == role);
        }

        public void Dispose()
        {
            if (_disposed) return;
            _users.Clear();
            _disposed = true;
            GC.SuppressFinalize(this);
        }
    }

    /// <summary>
    /// User factory with static methods
    /// </summary>
    public static class UserFactory
    {
        private static int _counter;

        public static User Create(string name, string email, UserRole role = UserRole.Guest)
        {
            var user = new User($"user_{++_counter}", name, email)
            {
                Role = role
            };
            return user;
        }

        public static bool ValidateEmail(string email)
        {
            return !string.IsNullOrEmpty(email) && email.Contains('@');
        }
    }

    /// <summary>
    /// Extension methods for User
    /// </summary>
    public static class UserExtensions
    {
        public static bool IsAdmin(this User user)
        {
            return user.Role == UserRole.Admin;
        }

        public static string ToJson(this User user)
        {
            return $"{{\"id\":\"{user.Id}\",\"name\":\"{user.Name}\"}}";
        }
    }
}
