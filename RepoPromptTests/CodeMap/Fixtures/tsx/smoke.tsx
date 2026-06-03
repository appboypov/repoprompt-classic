// Smoke test fixture for TSX codemap extraction
// EXPECT_FUNCTION_TYPES_FOR: useUser => User
import React, { useState, useEffect, useCallback } from 'react';
import type { FC, ReactNode } from 'react';

// Type definitions
type Theme = 'light' | 'dark' | 'system';
type ButtonVariant = 'primary' | 'secondary' | 'danger';

interface User {
    id: string;
    name: string;
    email: string;
    avatar?: string;
}

interface ButtonProps {
    variant?: ButtonVariant;
    disabled?: boolean;
    onClick?: () => void;
    children: ReactNode;
}

interface UserCardProps {
    user: User;
    onSelect?: (user: User) => void;
    showEmail?: boolean;
}

// Functional component with props interface
export const Button: FC<ButtonProps> = ({ 
    variant = 'primary', 
    disabled = false, 
    onClick, 
    children 
}) => {
    return (
        <button 
            className={`btn btn-${variant}`}
            disabled={disabled}
            onClick={onClick}
        >
            {children}
        </button>
    );
};

// Class component
export class UserCard extends React.Component<UserCardProps> {
    static defaultProps = {
        showEmail: true
    };
    
    handleClick = () => {
        this.props.onSelect?.(this.props.user);
    };
    
    render() {
        const { user, showEmail } = this.props;
        return (
            <div className="user-card" onClick={this.handleClick}>
                <h3>{user.name}</h3>
                {showEmail && <p>{user.email}</p>}
            </div>
        );
    }
}

// Custom hook
export function useUser(userId: string): { user: User | null; loading: boolean } {
    const [user, setUser] = useState<User | null>(null);
    const [loading, setLoading] = useState(true);
    
    useEffect(() => {
        fetchUser(userId).then(setUser).finally(() => setLoading(false));
    }, [userId]);
    
    return { user, loading };
}

// Utility function
async function fetchUser(id: string): Promise<User> {
    const response = await fetch(`/api/users/${id}`);
    return response.json();
}

// Higher-order component
export function withTheme<P extends object>(
    Component: React.ComponentType<P & { theme: Theme }>
): FC<P> {
    return (props: P) => {
        const theme = useTheme();
        return <Component {...props} theme={theme} />;
    };
}

// Context hook (stub)
function useTheme(): Theme {
    return 'light';
}

// Constants
export const THEME_KEY = 'app-theme';
export const DEFAULT_AVATAR = '/images/default-avatar.png';
