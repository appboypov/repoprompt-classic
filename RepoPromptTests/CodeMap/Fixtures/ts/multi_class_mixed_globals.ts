// multi_class_mixed_globals.ts - Edge case fixture for multiple containers
// Tests that globals aren't absorbed into classes, and methods go to correct class

// Global before any class
export const GLOBAL_VERSION = '1.0.0';

// First class
export class ServiceA {
    private name = 'ServiceA';
    
    process(input: string): string {
        return input.toUpperCase();
    }
    
    validate(data: unknown): boolean {
        return data !== null;
    }
}

// Global between classes
export const SHARED_CONFIG = { timeout: 5000 };

// Top-level function between classes
export function helperFunction(a: number, b: number): number {
    return a + b;
}

// Second class with same method names (should go to correct class)
export class ServiceB {
    private name = 'ServiceB';
    
    // Same method name as ServiceA - should go to ServiceB, not ServiceA
    process(input: string): string {
        return input.toLowerCase();
    }
    
    // Same method name as ServiceA
    validate(data: unknown): boolean {
        return typeof data === 'object';
    }
    
    // Unique method
    transform(items: string[]): string[] {
        return items.map(i => i.trim());
    }
}

// Interface after classes
export interface SharedContract {
    process(input: string): string;
    validate(data: unknown): boolean;
}

// Third class
export class ServiceC implements SharedContract {
    process(input: string): string {
        return input;
    }
    
    validate(data: unknown): boolean {
        return true;
    }
}

// More globals after all classes
export const FINAL_CONSTANT = 42;

export function standaloneProcessor(): void {
    console.log('standalone');
}

export const arrowAfterClasses = (x: number): number => x * 2;

// Type alias after classes
export type ServiceType = ServiceA | ServiceB | ServiceC;

// Enum after classes
export enum ServiceStatus {
    Idle = 'idle',
    Running = 'running',
    Stopped = 'stopped'
}
