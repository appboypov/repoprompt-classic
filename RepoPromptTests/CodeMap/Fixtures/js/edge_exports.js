export const VERSION = "1.0.0";

export function createUser(id, name) {
  return { id, name };
}

export class UserService {
  constructor(prefix) {
    this.prefix = prefix;
  }

  format(user) {
    return `${this.prefix}:${user.id}`;
  }
}

export default function makeService(prefix) {
  return new UserService(prefix);
}
