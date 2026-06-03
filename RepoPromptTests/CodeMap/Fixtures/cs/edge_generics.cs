using System;

namespace Edge {
    public enum Status {
        Active,
        Disabled
    }

    public interface IRepository<T> {
        T GetById(int id);
        void Save(T item);
    }

    public class User {
        public int Id { get; set; }
    }

    public class UserRepository : IRepository<User> {
        public event Action<User>? Saved;
        private static int _count = 0;

        public User GetById(int id) {
            return new User { Id = id };
        }

        public void Save(User item) {
            _count++;
            Saved?.Invoke(item);
        }
    }
}
