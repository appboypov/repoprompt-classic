package edge;

public enum Status {
    ACTIVE,
    DISABLED;

    public String code() {
        return name().toLowerCase();
    }
}

public interface Store<T> {
    T getById(int id);
    void save(T item);
}

public class User {
    private final int id;

    public User(int id) {
        this.id = id;
    }

    public int getId() {
        return id;
    }
}

public class UserStore implements Store<User> {
    @Override
    public User getById(int id) {
        return new User(id);
    }

    @Override
    public void save(User item) {
    }
}
