// Namespace declarations with nested exports
// Tests: namespace scoping, nested namespace, exported members

import { Something } from "./types";

// Simple namespace with exports
namespace SimpleNamespace {
    export const CONSTANT = 42;
    export let mutableValue = "hello";
    
    export function namespaceFunction(): void {
        console.log("Inside namespace");
    }
    
    export interface NamespaceInterface {
        prop: string;
    }
    
    export class NamespaceClass {
        method(): void {}
    }
    
    export type NamespaceType = string | number;
    
    export enum NamespaceEnum {
        A,
        B,
        C
    }
}

// Nested namespaces
namespace Outer {
    export namespace Inner {
        export const innerConst = "inner";
        
        export namespace Deepest {
            export function deepFunction(): void {}
        }
    }
    
    export function outerFunction(): void {
        Inner.Deepest.deepFunction();
    }
}

// Exported namespace
export namespace ExportedNamespace {
    export interface Config {
        url: string;
        timeout: number;
    }
    
    export function configure(config: Config): void {}
}

// Namespace merging with interface
interface MergedEntity {
    id: string;
}

namespace MergedEntity {
    export function create(id: string): MergedEntity {
        return { id };
    }
    
    export const DEFAULT_ID = "default";
}

// Namespace merging with class
class Service {
    start(): void {}
}

namespace Service {
    export interface Options {
        port: number;
    }
    
    export const DEFAULT_OPTIONS: Options = { port: 3000 };
}

// Ambient namespace (declare)
declare namespace AmbientNamespace {
    function ambientFunction(): void;
    const ambientConst: string;
    interface AmbientInterface {
        value: number;
    }
}

// Top-level function to verify it's separate from namespace contents
export function topLevelFunction(): void {
    SimpleNamespace.namespaceFunction();
}

// Top-level variable
export const topLevelConst = SimpleNamespace.CONSTANT;
