// Compound component pattern
// Tests: property assignments on function components, static properties
// EXPECT_REFERENCED_TYPES: TabsProps, TabsListProps, TabsTriggerProps, TabsContentProps, TabsContextValue, AccordionProps, AccordionItemProps, ReactNode, FC
// FORBID_REFERENCED_TYPES: void }>

import React, { FC, ReactNode, createContext, useContext, useState } from "react";

// Context for compound component
interface TabsContextValue {
    activeTab: string;
    setActiveTab: (value: string) => void;
}

const TabsContext = createContext<TabsContextValue | null>(null);

// Sub-component types
interface TabsListProps {
    children: ReactNode;
}

interface TabsTriggerProps {
    value: string;
    children: ReactNode;
}

interface TabsContentProps {
    value: string;
    children: ReactNode;
}

// Main component with sub-components attached
interface TabsProps {
    defaultValue: string;
    children: ReactNode;
}

// The compound component
const Tabs: FC<TabsProps> & {
    List: FC<TabsListProps>;
    Trigger: FC<TabsTriggerProps>;
    Content: FC<TabsContentProps>;
} = ({ defaultValue, children }) => {
    const [activeTab, setActiveTab] = useState(defaultValue);
    
    return (
        <TabsContext.Provider value={{ activeTab, setActiveTab }}>
            <div className="tabs">{children}</div>
        </TabsContext.Provider>
    );
};

// Sub-component assignments
Tabs.List = ({ children }) => (
    <div className="tabs-list" role="tablist">{children}</div>
);

Tabs.Trigger = ({ value, children }) => {
    const context = useContext(TabsContext);
    if (!context) throw new Error("Tabs.Trigger must be within Tabs");
    
    return (
        <button
            role="tab"
            aria-selected={context.activeTab === value}
            onClick={() => context.setActiveTab(value)}
        >
            {children}
        </button>
    );
};

Tabs.Content = ({ value, children }) => {
    const context = useContext(TabsContext);
    if (!context) throw new Error("Tabs.Content must be within Tabs");
    
    if (context.activeTab !== value) return null;
    return <div role="tabpanel">{children}</div>;
};

// Another pattern: using Object.assign
interface AccordionProps {
    children: ReactNode;
}

interface AccordionItemProps {
    value: string;
    children: ReactNode;
}

const AccordionBase: FC<AccordionProps> = ({ children }) => (
    <div className="accordion">{children}</div>
);

const AccordionItem: FC<AccordionItemProps> = ({ value, children }) => (
    <div className="accordion-item" data-value={value}>{children}</div>
);

const AccordionHeader: FC<{ children: ReactNode }> = ({ children }) => (
    <h3 className="accordion-header">{children}</h3>
);

const AccordionContent: FC<{ children: ReactNode }> = ({ children }) => (
    <div className="accordion-content">{children}</div>
);

export const Accordion = Object.assign(AccordionBase, {
    Item: AccordionItem,
    Header: AccordionHeader,
    Content: AccordionContent,
});

// Class component with static sub-components
class Menu extends React.Component<{ children: ReactNode }> {
    static Item: FC<{ label: string; onClick: () => void }> = ({ label, onClick }) => (
        <button onClick={onClick}>{label}</button>
    );
    
    static Separator: FC = () => <hr />;
    
    static SubMenu: FC<{ label: string; children: ReactNode }> = ({ label, children }) => (
        <div className="submenu">
            <span>{label}</span>
            {children}
        </div>
    );
    
    render() {
        return <div className="menu">{this.props.children}</div>;
    }
}

// Export the compound components
export { Tabs, Menu };

// Top-level function to verify separation
export function useTabsContext(): TabsContextValue {
    const context = useContext(TabsContext);
    if (!context) throw new Error("useTabsContext must be within Tabs");
    return context;
}
