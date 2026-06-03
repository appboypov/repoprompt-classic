package edge

import "context"

type User struct {
    ID int
}

type UserStore struct {
    prefix string
}

func (s *UserStore) Save(ctx context.Context, user *User) error {
    return nil
}

func (s UserStore) Name() string {
    return s.prefix
}

func NewStore(prefix string) *UserStore {
    return &UserStore{prefix: prefix}
}

const MaxUsers = 100

var DefaultTimeout = 30
