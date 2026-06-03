// noise_locals.ts - Edge case fixture to ensure local variables aren't captured
// Only top-level exports should appear in globalVars/functions

// Top-level constants (SHOULD be captured)
export const GLOBAL_CONFIG = { debug: true };
export const MAX_RETRIES = 3;

// Top-level function (SHOULD be captured)
export function processItems(items: string[]): string[] {
    // Local variables (should NOT be captured)
    const localFilter = (s: string) => s.length > 0;
    let count = 0;
    var legacy = 'old';
    
    // Nested function (should NOT be captured)
    function innerHelper(x: string): string {
        const innerLocal = x.trim();
        return innerLocal.toUpperCase();
    }
    
    // Arrow in variable (should NOT be captured - it's local)
    const transform = (s: string) => {
        const trimmed = s.trim();
        return trimmed;
    };
    
    // Destructuring (should NOT be captured)
    const { debug } = GLOBAL_CONFIG;
    const [first, ...rest] = items;
    
    // Loop variables (should NOT be captured)
    for (const item of items) {
        const processed = transform(item);
        count++;
    }
    
    // Conditional locals (should NOT be captured)
    if (debug) {
        const debugInfo = 'debugging';
        console.log(debugInfo);
    }
    
    // Try-catch locals (should NOT be captured)
    try {
        const result = items.map(innerHelper);
        return result;
    } catch (error) {
        const errorMsg = String(error);
        return [];
    }
}

// Class with method-local variables
export class Processor {
    private state: number = 0;
    
    process(input: string): string {
        // Method locals (should NOT be captured)
        const temp = input.toLowerCase();
        let buffer = '';
        
        const callback = () => {
            // Nested arrow locals (should NOT be captured)
            const innerTemp = temp + buffer;
            return innerTemp;
        };
        
        return callback();
    }
    
    async asyncProcess(): Promise<void> {
        // Async method locals (should NOT be captured)
        const data = await Promise.resolve('test');
        const { length } = data;
    }
}

// Arrow function assigned to export (SHOULD be captured as function)
export const formatOutput = (value: unknown): string => {
    // Local inside arrow (should NOT be captured)
    const serialized = JSON.stringify(value);
    return serialized;
};

// IIFE result (edge case - the IIFE local should NOT be captured)
export const CONFIG = (() => {
    const secret = 'hidden';
    return { public: true };
})();
