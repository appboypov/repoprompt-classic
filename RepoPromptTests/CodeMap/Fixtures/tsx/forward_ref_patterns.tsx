// forwardRef patterns - named inner functions, generics, memo combinations
// Tests: forwardRef with named function, forwardRef + memo, generic forwardRef

import React, {
    forwardRef,
    memo,
    useImperativeHandle,
    useRef,
    ForwardedRef,
    ComponentPropsWithoutRef,
    ElementRef,
    ReactNode,
} from "react";

// Pattern 1: forwardRef with named inner function
interface InputProps extends ComponentPropsWithoutRef<"input"> {
    label?: string;
    error?: string;
}

export const Input = forwardRef<HTMLInputElement, InputProps>(
    function Input({ label, error, ...props }, ref) {
        return (
            <div className="input-wrapper">
                {label && <label>{label}</label>}
                <input ref={ref} {...props} />
                {error && <span className="error">{error}</span>}
            </div>
        );
    }
);

// Pattern 2: forwardRef with anonymous arrow (common but less ideal)
export const Button = forwardRef<HTMLButtonElement, ComponentPropsWithoutRef<"button">>(
    (props, ref) => <button ref={ref} {...props} />
);

// Pattern 3: forwardRef + memo combination
interface CardProps {
    title: string;
    children: ReactNode;
}

export const Card = memo(
    forwardRef<HTMLDivElement, CardProps>(function Card({ title, children }, ref) {
        return (
            <div ref={ref} className="card">
                <h2>{title}</h2>
                {children}
            </div>
        );
    })
);

// Pattern 4: forwardRef with useImperativeHandle
interface ModalHandle {
    open: () => void;
    close: () => void;
    toggle: () => void;
}

interface ModalProps {
    title: string;
    children: ReactNode;
}

export const Modal = forwardRef<ModalHandle, ModalProps>(
    function Modal({ title, children }, ref) {
        const [isOpen, setIsOpen] = React.useState(false);
        
        useImperativeHandle(ref, () => ({
            open: () => setIsOpen(true),
            close: () => setIsOpen(false),
            toggle: () => setIsOpen((prev) => !prev),
        }));
        
        if (!isOpen) return null;
        
        return (
            <div className="modal">
                <h1>{title}</h1>
                {children}
            </div>
        );
    }
);

// Pattern 5: Generic forwardRef (tricky type inference)
interface ListProps<T> {
    items: T[];
    renderItem: (item: T) => ReactNode;
}

// Type assertion needed for generic forwardRef
export const List = forwardRef(function List<T>(
    { items, renderItem }: ListProps<T>,
    ref: ForwardedRef<HTMLUListElement>
) {
    return (
        <ul ref={ref}>
            {items.map((item, index) => (
                <li key={index}>{renderItem(item)}</li>
            ))}
        </ul>
    );
}) as <T>(props: ListProps<T> & { ref?: ForwardedRef<HTMLUListElement> }) => JSX.Element;

// Pattern 6: Polymorphic forwardRef
type PolymorphicRef<E extends React.ElementType> = React.ComponentPropsWithRef<E>["ref"];

interface BoxProps<E extends React.ElementType = "div"> {
    as?: E;
    children?: ReactNode;
}

type PolymorphicBoxProps<E extends React.ElementType> = BoxProps<E> &
    Omit<React.ComponentPropsWithoutRef<E>, keyof BoxProps<E>>;

export const Box = forwardRef(function Box<E extends React.ElementType = "div">(
    { as, children, ...props }: PolymorphicBoxProps<E>,
    ref: PolymorphicRef<E>
) {
    const Component = as || "div";
    return (
        <Component ref={ref} {...props}>
            {children}
        </Component>
    );
}) as <E extends React.ElementType = "div">(
    props: PolymorphicBoxProps<E> & { ref?: PolymorphicRef<E> }
) => JSX.Element;

// Pattern 7: forwardRef with displayName
const TextAreaBase = forwardRef<HTMLTextAreaElement, ComponentPropsWithoutRef<"textarea">>(
    function TextArea(props, ref) {
        return <textarea ref={ref} {...props} />;
    }
);
TextAreaBase.displayName = "TextArea";
export const TextArea = TextAreaBase;

// Top-level function to test separation
export function createInputRef(): React.RefObject<HTMLInputElement> {
    return useRef<HTMLInputElement>(null);
}

// Top-level type alias
export type InputRef = ElementRef<typeof Input>;
export type ModalRef = ModalHandle;
