// Function overloads - all patterns
// Tests: overload signatures, implementation signature, method overloads
// EXPECT_REFERENCED_TYPES: HTMLDivElement, HTMLSpanElement, HTMLInputElement, HTMLElement, Date, MouseEvent, KeyboardEvent, TouchEvent, Event, OverloadedArrow, DataProcessor
// FORBID_REFERENCED_TYPES: string, number, boolean, Promise, object, any
// EXPECT_FUNCTION_TYPES_FOR: createElement => HTMLDivElement, HTMLSpanElement, HTMLInputElement, HTMLElement
// EXPECT_FUNCTION_TYPES_FOR: processValue => OverloadedArrow

// ============================================
// Pattern 1: Basic function overloads
// ============================================
function greet(name: string): string;
function greet(firstName: string, lastName: string): string;
function greet(nameOrFirst: string, lastName?: string): string {
    if (lastName) {
        return `Hello, ${nameOrFirst} ${lastName}!`;
    }
    return `Hello, ${nameOrFirst}!`;
}

// ============================================
// Pattern 2: Overloads with different return types
// ============================================
function parse(input: string): object;
function parse(input: string, asArray: true): any[];
function parse(input: string, asArray: false): object;
function parse(input: string, asArray?: boolean): object | any[] {
    const parsed = JSON.parse(input);
    if (asArray) {
        return Array.isArray(parsed) ? parsed : [parsed];
    }
    return parsed;
}

// ============================================
// Pattern 3: Generic function overloads
// ============================================
function createElement(tag: "div"): HTMLDivElement;
function createElement(tag: "span"): HTMLSpanElement;
function createElement(tag: "input"): HTMLInputElement;
function createElement<T extends HTMLElement>(tag: string): T;
function createElement(tag: string): HTMLElement {
    return document.createElement(tag);
}

// ============================================
// Pattern 4: Overloads with callback signatures
// ============================================
function fetchData(url: string): Promise<unknown>;
function fetchData(url: string, callback: (data: unknown) => void): void;
function fetchData(
    url: string,
    callback?: (data: unknown) => void
): Promise<unknown> | void {
    const promise = fetch(url).then((r) => r.json());
    if (callback) {
        promise.then(callback);
        return;
    }
    return promise;
}

// ============================================
// Pattern 5: Class method overloads
// ============================================
class DataProcessor {
    // Method overloads
    process(data: string): string;
    process(data: number): number;
    process(data: boolean): boolean;
    process(data: string | number | boolean): string | number | boolean {
        if (typeof data === "string") {
            return data.toUpperCase();
        }
        if (typeof data === "number") {
            return data * 2;
        }
        return !data;
    }
    
    // Async method overloads
    async fetch(id: string): Promise<object>;
    async fetch(ids: string[]): Promise<object[]>;
    async fetch(idOrIds: string | string[]): Promise<object | object[]> {
        if (Array.isArray(idOrIds)) {
            return Promise.all(idOrIds.map((id) => this.fetchOne(id)));
        }
        return this.fetchOne(idOrIds);
    }
    
    private async fetchOne(id: string): Promise<object> {
        return { id };
    }
    
    // Static method overloads
    static create(): DataProcessor;
    static create(config: { strict: boolean }): DataProcessor;
    static create(config?: { strict: boolean }): DataProcessor {
        return new DataProcessor();
    }
}

// ============================================
// Pattern 6: Constructor overloads
// ============================================
class Point {
    x: number;
    y: number;
    
    constructor();
    constructor(x: number, y: number);
    constructor(coords: { x: number; y: number });
    constructor(xOrCoords?: number | { x: number; y: number }, y?: number) {
        if (typeof xOrCoords === "object") {
            this.x = xOrCoords.x;
            this.y = xOrCoords.y;
        } else if (typeof xOrCoords === "number" && typeof y === "number") {
            this.x = xOrCoords;
            this.y = y;
        } else {
            this.x = 0;
            this.y = 0;
        }
    }
}

// ============================================
// Pattern 7: Interface method overloads
// ============================================
interface Formatter {
    format(value: string): string;
    format(value: number): string;
    format(value: Date): string;
    format(value: string | number | Date): string;
}

// ============================================
// Pattern 8: Exported function overloads
// ============================================
export function convert(value: string, to: "number"): number;
export function convert(value: number, to: "string"): string;
export function convert(value: string, to: "boolean"): boolean;
export function convert(
    value: string | number,
    to: "number" | "string" | "boolean"
): number | string | boolean {
    switch (to) {
        case "number":
            return Number(value);
        case "string":
            return String(value);
        case "boolean":
            return Boolean(value);
    }
}

// ============================================
// Pattern 9: Arrow function with overload type
// ============================================
type OverloadedArrow = {
    (x: string): string;
    (x: number): number;
};

const processValue: OverloadedArrow = (x: string | number): any => {
    if (typeof x === "string") return x.toUpperCase();
    return x * 2;
};

// ============================================
// Pattern 10: Call signature overloads in type
// ============================================
type EventHandler = {
    (event: MouseEvent): void;
    (event: KeyboardEvent): void;
    (event: TouchEvent): void;
    (event: Event): void;
};

// ============================================
// Top-level exports
// ============================================
export { greet, parse, createElement, fetchData, DataProcessor, Point };

export type { Formatter, EventHandler };
