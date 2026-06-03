// interface_members.ts - Edge case fixture for TypeScript interface signatures
// Tests all interface member types and range-based containment (>30 lines)
// EXPECT_REFERENCED_TYPES: Config, Date
// FORBID_REFERENCED_TYPES: string, number, boolean, Promise, object, any

// Simple interface with method signatures
interface Readable {
    read(): string;
    readAsync(): Promise<string>;
}

// Interface with property signatures
interface Config {
    host: string;
    port: number;
    secure?: boolean;
    readonly version: string;
}

// Interface with call signature
interface Callable {
    (input: string): number;
    description: string;
}

// Interface with construct signature
interface Constructable {
    new (name: string): object;
    prototype: object;
}

// Interface with index signature
interface Dictionary<T> {
    [key: string]: T;
    length: number;
}

// Large interface (>30 lines) to test range-based containment
interface CompleteDataProvider<T, K extends string> {
    // Property signatures
    readonly name: string;
    version: number;
    config?: Config;
    
    // Method signatures
    fetch(): Promise<T[]>;
    fetchOne(id: K): Promise<T | null>;
    save(item: T): Promise<void>;
    update(id: K, changes: Partial<T>): Promise<T>;
    delete(id: K): Promise<boolean>;
    
    // More properties
    lastUpdated: Date;
    isConnected: boolean;
    
    // More methods
    connect(): Promise<void>;
    disconnect(): Promise<void>;
    
    // Complex method signatures
    query(
        filter: (item: T) => boolean,
        options?: { limit?: number; offset?: number }
    ): Promise<T[]>;
    
    aggregate<R>(
        reducer: (acc: R, item: T) => R,
        initial: R
    ): Promise<R>;
    
    // Event handlers
    onConnect(handler: () => void): void;
    onDisconnect(handler: (reason: string) => void): void;
    onError(handler: (error: Error) => void): void;
    
    // Final properties to extend beyond 30 lines
    errorCount: number;
    retryPolicy: 'none' | 'linear' | 'exponential';
}

// Multiple interfaces in same file
interface Serializable {
    serialize(): string;
    deserialize(data: string): void;
}

interface Cloneable<T> {
    clone(): T;
    deepClone(): T;
}
