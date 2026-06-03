// Smoke test fixture for JavaScript codemap extraction
import { EventEmitter } from 'events';
import fs from 'fs/promises';

/**
 * User service for managing user data
 * @extends EventEmitter
 */
export class UserService extends EventEmitter {
    /** @type {Map<string, User>} */
    #users = new Map();
    
    /** Service name constant */
    static serviceName = 'UserService';
    
    /** Singleton instance */
    static #instance = null;
    
    /**
     * Creates a new UserService
     * @param {Object} config - Service configuration
     */
    constructor(config) {
        super();
        this.config = config;
        this.initialized = false;
    }
    
    /**
     * Gets the singleton instance
     * @param {Object} config
     * @returns {UserService}
     */
    static getInstance(config) {
        if (!UserService.#instance) {
            UserService.#instance = new UserService(config);
        }
        return UserService.#instance;
    }
    
    /**
     * Fetches all users
     * @returns {Promise<User[]>}
     */
    async fetchAll() {
        return Array.from(this.#users.values());
    }
    
    /**
     * Saves a user
     * @param {User} user
     */
    async save(user) {
        this.#users.set(user.id, user);
        this.emit('userSaved', user);
    }
    
    /**
     * Deletes a user by ID
     * @param {string} id
     * @returns {boolean}
     */
    delete(id) {
        return this.#users.delete(id);
    }
}

/**
 * Creates a new user object
 * @param {string} name - User's name
 * @param {string} email - User's email
 * @returns {User}
 */
export function createUser(name, email) {
    return {
        id: crypto.randomUUID(),
        name,
        email,
        createdAt: new Date()
    };
}

/**
 * Formats a user's display name
 * @param {User} user
 * @returns {string}
 */
export const formatUserName = (user) => {
    return `${user.name} <${user.email}>`;
};

/**
 * Validates user data
 */
const validateUser = (user) => {
    if (!user.name) throw new Error('Name required');
    if (!user.email) throw new Error('Email required');
    return true;
};

// Constants
export const MAX_USERS = 1000;
export const DEFAULT_ROLE = 'guest';
const INTERNAL_VERSION = '1.0.0';

// User roles enum-like object
export const UserRole = Object.freeze({
    ADMIN: 'admin',
    EDITOR: 'editor', 
    VIEWER: 'viewer',
    GUEST: 'guest'
});
