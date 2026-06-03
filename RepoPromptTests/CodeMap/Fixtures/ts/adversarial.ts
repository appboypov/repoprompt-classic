// adversarial.ts - Stress test for TS CodeMap extraction.
// Intentionally includes "weird but parseable" constructs to expose capture/routing gaps.

// ---------- Module patterns / imports ----------
import type { User as UserType } from "./types";

// TS-specific import alias (CommonJS style)
import Bar = require("bar");

// Dynamic import expression (NOT an import_statement)
export const dynImportResult = import("./dyn");

// ---------- Export edge cases ----------
export {}; // "empty export" marks a module

// Default export that is NOT a named declaration
export default function () {
    return 42;
}

// ---------- Unicode / special identifiers ----------
export const café = 1;
export function naïve<T extends { ü: string }>(arg: T): T {
    return arg;
}

// ---------- Multiline arrow exports ----------
export const multiLineArrow =
    <T extends string | number>(
        x: T,
        y: T,
    ): T =>
        x;

// Async arrow assigned to const
export const asyncArrow = async (x: number): Promise<number> => {
    return x + 1;
};

// Wrapped arrow: value is a parenthesized_expression, not a direct arrow_function
export const wrappedArrow = ((x: number): number => x + 1);

// Function expression assigned to const
export const functionExpr = function named(x: number): number {
    return x;
};

// Parenthesized non-function value
export const PAREN_EXPR = (1 + 2) * 3;

// ---------- "Generics gone wild" type alias ----------
export type ComplexUnion<T> =
    | { kind: "a"; value: T }
    | { kind: "b"; value: { nested: T } }
    | (T extends string ? { kind: "s"; s: T } : never);

// ---------- Declaration merging ----------
export interface MergeMe {
    a: string;
}

// Same name again (declaration merging)
export interface MergeMe {
    b: number;
}

// Namespace augmentation with exports nested inside
export namespace MergeMe {
    export const augmented = true;
}

// ---------- Interface with multiline call signature ----------
export interface OverloadedCallable {
    foo(x: string): string;
    foo(x: number): number;

    (
        x: string,
        y: number,
    ): Promise<string>;
}

// ---------- Decorators + computed member names ----------
export class DecoratedAndComputed {
    @sealed
    readonly field: number = 1;

    // Method overloads
    overloaded(x: string): string;
    overloaded(x: number): number;
    overloaded(x: any): any {
        return x;
    }

    // Computed member names
    ["computed-method"](x: number): number {
        return x;
    }

    [Symbol.iterator](): Iterator<number> {
        return [][Symbol.iterator]();
    }

    // Nested local class inside method
    nestedFactory() {
        class LocalClass {
            localMethod(): number {
                return 1;
            }
        }
        return new LocalClass();
    }
}

// ---------- Containers inside exported function (should stay local) ----------
export function containerNesting() {
    // These should be "local-only" but may leak into top-level
    class Local {
        m(): number {
            return 1;
        }
    }

    interface LocalI {
        x: string;
        y(): void;
    }

    enum LocalE {
        A = 1,
        B = 2,
    }

    type LocalT =
        | { tag: "x"; v: number }
        | { tag: "y"; v: string };

    const localArrow = (z: number) => z * 2;
    function inner() {
        return localArrow(2);
    }

    return { Local, inner };
}

// Dummy decorator identifier
declare const sealed: any;
