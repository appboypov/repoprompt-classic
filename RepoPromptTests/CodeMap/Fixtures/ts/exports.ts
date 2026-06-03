// exports.ts - Edge case fixture for TypeScript export variations
// Tests that exports[] captures all export forms, not just re-exports

// Re-exports (with source)
export * from './types';
export { User, Config } from './models';
export type { UserID } from './types';
export { default as DefaultExport } from './default';

// Named exports (inline)
export const MAX_SIZE = 100;
export let currentUser: string | null = null;
export var legacyFlag = false;

// Type/interface exports
export type Status = 'pending' | 'active' | 'done';
export interface Logger {
    log(message: string): void;
    error(message: string): void;
}

// Class export
export class DataStore {
    private data: Map<string, unknown> = new Map();
    
    get(key: string): unknown {
        return this.data.get(key);
    }
    
    set(key: string, value: unknown): void {
        this.data.set(key, value);
    }
}

// Function export
export function processData(input: string): string {
    return input.toUpperCase();
}

// Arrow function export
export const transformData = (data: unknown[]): unknown[] => {
    return data.filter(Boolean);
};

// Async function export
export async function fetchData(url: string): Promise<unknown> {
    return { url };
}

// Default exports (only one allowed, so comment out alternatives)
export default class MainExport {
    static version = '1.0.0';
}

// export default function defaultFunc() { return 42; }
// export default { key: 'value' };

// Enum export
export enum Color {
    Red = 'red',
    Green = 'green',
    Blue = 'blue'
}

// Namespace export (rare but valid)
export namespace Utils {
    export function helper(): void {}
}
