// class_fields_and_accessors.ts - Edge case fixture for class member variations
// Tests field modifiers, accessors, and constructor parameter properties

// Class with all field modifier combinations
export class ModifierShowcase {
    // Access modifiers
    public publicField: string = 'public';
    private privateField: number = 42;
    protected protectedField: boolean = true;
    
    // Static fields
    static staticField: string = 'static';
    private static privateStaticField = 100;
    
    // Readonly fields
    readonly readonlyField: string = 'readonly';
    private readonly privateReadonlyField = 'secret';
    static readonly CONSTANT = 'CONST';
    
    // Optional and definite assignment
    optionalField?: string;
    definiteField!: number;
    
    // Typed without initializer
    declaredField: Date;
    
    // Arrow function as field
    arrowMethod = (x: number): number => x * 2;
    private privateArrow = () => this.privateField;
    
    // Computed property name (rare)
    ['computed']: string = 'computed-value';
    
    constructor() {
        this.declaredField = new Date();
    }
}

// Class with constructor parameter properties
export class ParameterProperties {
    // These create and initialize class properties
    constructor(
        public name: string,
        private secret: string,
        protected level: number,
        readonly id: string,
        private readonly createdAt: Date = new Date()
    ) {}
    
    getName(): string {
        return this.name;
    }
}

// Class with getters and setters
export class AccessorClass {
    private _value: number = 0;
    private _name: string = '';
    
    // Getter only
    get value(): number {
        return this._value;
    }
    
    // Setter only
    set name(n: string) {
        this._name = n.trim();
    }
    
    // Both getter and setter
    get fullName(): string {
        return this._name;
    }
    
    set fullName(n: string) {
        this._name = n;
    }
    
    // Static accessors
    private static _instance: AccessorClass | null = null;
    
    static get instance(): AccessorClass {
        if (!this._instance) {
            this._instance = new AccessorClass();
        }
        return this._instance;
    }
}

// Abstract class with abstract members
export abstract class AbstractBase {
    abstract abstractField: string;
    
    abstract process(): void;
    abstract get data(): unknown;
    
    concreteMethod(): void {
        console.log('concrete');
    }
}

// Decorated class (if decorators are enabled)
// @decorator
// export class DecoratedClass {
//     @fieldDecorator
//     decoratedField: string = '';
// }

// Private identifier fields (ES2022+)
export class PrivateIdentifiers {
    #truePrivate: number = 0;
    #privateMethod(): void {}
    
    getPrivate(): number {
        return this.#truePrivate;
    }
}
