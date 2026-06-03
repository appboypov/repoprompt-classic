// Smoke test fixture for TypeScript codemap extraction
// EXPECT_FUNCTION_TYPES_FOR: createUser => UserRole, User
// EXPECT_FUNCTION_TYPES_FOR: formatUserName => User
// EXPECT_FUNCTION_TYPES_FOR: getInstance => Config, UserService
// EXPECT_PROPERTY_TYPES_FOR: users => UserMap
import { EventEmitter } from 'events';
import type { User, Config } from './types';

// Type alias
type UserID = string | number;
type UserMap = Map<UserID, User>;

// Interface definition
interface DataProvider<T> {
    fetch(): Promise<T[]>;
    save(item: T): Promise<void>;
    delete(id: string): Promise<boolean>;
}

// Literal union type
type Status = 'pending' | 'active' | 'completed' | 'failed';
type LogLevel = 'debug' | 'info' | 'warn' | 'error';

// Class with inheritance
export class UserService extends EventEmitter implements DataProvider<User> {
    private users: UserMap = new Map();
    readonly serviceName = 'UserService';
    static instance: UserService | null = null;
    
    constructor(private config: Config) {
        super();
    }
    
    static getInstance(config: Config): UserService {
        if (!UserService.instance) {
            UserService.instance = new UserService(config);
        }
        return UserService.instance;
    }
    
    async fetch(): Promise<User[]> {
        return Array.from(this.users.values());
    }
    
    async save(user: User): Promise<void> {
        this.users.set(user.id, user);
        this.emit('userSaved', user);
    }
    
    async delete(id: string): Promise<boolean> {
        return this.users.delete(id);
    }
    
    private validateUser(user: User): boolean {
        return !!user.id && !!user.name;
    }
}

// Enum definition
export enum UserRole {
    Admin = 'admin',
    Editor = 'editor',
    Viewer = 'viewer',
    Guest = 'guest'
}

// Standalone function
export function createUser(name: string, role: UserRole = UserRole.Guest): User {
    return {
        id: crypto.randomUUID(),
        name,
        role,
        createdAt: new Date()
    };
}

// Arrow function export
export const formatUserName = (user: User): string => {
    return `${user.name} (${user.role})`;
};

// Global constant
export const MAX_USERS = 1000;
const DEFAULT_TIMEOUT = 5000;
