// adversarial.tsx - Stress test for TSX CodeMap extraction.
// Focus: TSX-only parsing ambiguities + JSX-embedded functions that must NOT be treated as top-level.

// ---------- Imports (TSX grammar differences vs TS) ----------
import React, { forwardRef, memo, useCallback, useMemo } from "react";
import type { ReactNode } from "react";

// ---------- Types used by components ----------
export type RenderProp<T> = (value: T) => ReactNode;

export interface BoxProps<T> {
    value: T;
    label?: string;
    render?: RenderProp<T>;
    onValue?: (v: T) => void;
}

// ---------- Generic components (TSX ambiguity: <T> can look like JSX) ----------
// NOTE: In TSX, arrow generics should use `<T,>` to avoid parsing as JSX.
export const GenericArrowComponent = <T,>(props: BoxProps<T>) => {
    return (
        <div data-label={props.label}>
            {props.render ? props.render(props.value) : String(props.value)}
        </div>
    );
};

// Generic function component (named, should be captured as a function)
export function GenericFunctionComponent<T>(props: BoxProps<T>) {
    return <div>{props.render?.(props.value)}</div>;
}

// ---------- JSX expressions with embedded functions (must NOT be captured as globals) ----------
export const InlineHandlers = (props: { text: string; extra?: Record<string, unknown> }) => {
    const localHelper = (s: string) => s.trim(); // local var: must not be captured

    return (
        <section
            // arrow inside JSX attribute
            onClick={(e) => {
                const inner = localHelper(props.text); // local var: must not be captured
                console.log(e.type, inner);
            }}
            // function expression inside JSX attribute
            onKeyDown={function onKeyDown(e) {
                console.log("key", e.key);
            }}
            // spread attributes
            {...props.extra}
        >
            {props.text}
        </section>
    );
};

// ---------- Fragment syntax ----------
export const WithFragments = () => {
    const ok = Math.random() > 0.5;
    return (
        <>
            <div>head</div>
            {ok ? <span data-ok /> : null}
            <React.Fragment>
                <div>tail</div>
            </React.Fragment>
        </>
    );
};

// ---------- Render props / HOCs / memo / forwardRef ----------
export const MemoWrapped = memo(function MemoWrapped(props: { n: number }) {
    return <div>{props.n}</div>;
});

export const Forwarded = forwardRef<HTMLDivElement, { id: string }>(function Forwarded(props, ref) {
    return (
        <div ref={ref} data-id={props.id}>
            forwarded
        </div>
    );
});

// Render-prop component usage with generic type args in JSX
export const GenericUsage = () => {
    return (
        <GenericArrowComponent<number>
            value={123}
            label="n"
            render={(x) => <span>{x + 1}</span>}
            onValue={(x) => {
                // nested arrow in prop (must NOT be captured)
                console.log("value", x);
            }}
        />
    );
};

// ---------- Hooks (nested functions returning JSX) ----------
export const Hooky = () => {
    const cb = useCallback((x: number) => <span>{x}</span>, []);
    const memoed = useMemo(() => <div>{cb(1)}</div>, [cb]);

    return <div>{memoed}</div>;
};

// ---------- Class components + decorators + class fields ----------
export class ClassComponent extends React.Component<{ title: string }> {
    // class field (public_field_definition)
    state = { count: 0 };

    @sealed
    decoratedField: number = 1;

    // overload-like signatures
    overloaded(x: string): string;
    overloaded(x: number): number;
    overloaded(x: any): any {
        return x;
    }

    // computed names
    ["computed-method"](x: number) {
        return x + 1;
    }

    render() {
        return (
            <div>
                <h1>{this.props.title}</h1>
                <button onClick={() => this.setState({ count: this.state.count + 1 })}>
                    {this.state.count}
                </button>
            </div>
        );
    }
}

// Dummy decorator identifier
declare const sealed: any;

// ---------- Pathological nesting inside a component ----------
export function ContainerNestingTSX() {
    class LocalClass {
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

    return (
        <div data-local={new LocalClass().m()}>
            {LocalE.A}
            {inner()}
            <pre>{JSON.stringify({ LocalI: "type-only", LocalT: "type-only" })}</pre>
        </div>
    );
}

// ---------- Default exports ----------
export default function App() {
    return <div>default export</div>;
}

// Anonymous default-like export
export const AnonymousDefault = () => (
    <div>anonymous default-like</div>
);
