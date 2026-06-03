// Module augmentation and declaration merging
// Tests: declare global, declare module, namespace augmentation

// Regular imports
import { EventEmitter } from "events";

// ============================================
// Pattern 1: Augment global Window interface
// ============================================
declare global {
    interface Window {
        __APP_VERSION__: string;
        __DEBUG_MODE__: boolean;
        customLogger: (message: string) => void;
    }
    
    // Add to global namespace
    var globalConfig: {
        apiUrl: string;
        timeout: number;
    };
    
    // Augment Array prototype
    interface Array<T> {
        customFind(predicate: (item: T) => boolean): T | undefined;
    }
}

// ============================================
// Pattern 2: Declare module for untyped package
// ============================================
declare module "untyped-package" {
    export function doSomething(input: string): string;
    export const VERSION: string;
    
    export interface PackageConfig {
        debug?: boolean;
        timeout?: number;
    }
    
    export class PackageClient {
        constructor(config?: PackageConfig);
        connect(): Promise<void>;
        disconnect(): void;
    }
    
    export default function initialize(config: PackageConfig): PackageClient;
}

// ============================================
// Pattern 3: Augment existing module
// ============================================
declare module "express" {
    interface Request {
        user?: {
            id: string;
            email: string;
            roles: string[];
        };
        session?: {
            token: string;
            expiresAt: Date;
        };
    }
    
    interface Response {
        success<T>(data: T): void;
        error(message: string, code?: number): void;
    }
}

// ============================================
// Pattern 4: Namespace augmentation
// ============================================
namespace ExistingNamespace {
    export interface BaseConfig {
        name: string;
    }
}

// Augment the namespace
namespace ExistingNamespace {
    export interface ExtendedConfig extends BaseConfig {
        version: number;
        features: string[];
    }
    
    export function createConfig(name: string): ExtendedConfig {
        return { name, version: 1, features: [] };
    }
}

// ============================================
// Pattern 5: Class + namespace merging
// ============================================
class APIClient {
    private baseUrl: string;
    
    constructor(baseUrl: string) {
        this.baseUrl = baseUrl;
    }
    
    async get<T>(path: string): Promise<T> {
        const response = await fetch(`${this.baseUrl}${path}`);
        return response.json();
    }
}

namespace APIClient {
    export interface RequestOptions {
        headers?: Record<string, string>;
        timeout?: number;
    }
    
    export interface Response<T> {
        data: T;
        status: number;
        headers: Record<string, string>;
    }
    
    export const DEFAULT_TIMEOUT = 30000;
    
    export function create(baseUrl: string, options?: RequestOptions): APIClient {
        return new APIClient(baseUrl);
    }
}

// ============================================
// Pattern 6: Enum + namespace merging
// ============================================
enum LogLevel {
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3,
}

namespace LogLevel {
    export function fromString(level: string): LogLevel {
        switch (level.toLowerCase()) {
            case "debug": return LogLevel.Debug;
            case "info": return LogLevel.Info;
            case "warn": return LogLevel.Warn;
            case "error": return LogLevel.Error;
            default: return LogLevel.Info;
        }
    }
    
    export function toString(level: LogLevel): string {
        return LogLevel[level];
    }
}

// ============================================
// Pattern 7: Interface + namespace merging
// ============================================
interface User {
    id: string;
    name: string;
    email: string;
}

namespace User {
    export interface CreateInput {
        name: string;
        email: string;
    }
    
    export interface UpdateInput {
        name?: string;
        email?: string;
    }
    
    export function create(input: CreateInput): User {
        return { id: crypto.randomUUID(), ...input };
    }
    
    export function validate(user: User): boolean {
        return !!user.id && !!user.name && !!user.email;
    }
}

// ============================================
// Top-level exports to verify separation
// ============================================
export function topLevelFunction(): void {
    const config = ExistingNamespace.createConfig("test");
    console.log(config);
}

export const topLevelConst = APIClient.DEFAULT_TIMEOUT;

export type TopLevelType = User.CreateInput;

export { APIClient, LogLevel, User };
