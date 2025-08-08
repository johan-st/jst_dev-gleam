import { Ok, Error } from "./gleam.mjs";

/**
 * Stores a string value in the browser's local storage under the specified key.
 *
 * @param {string} key - The key under which the value will be stored.
 * @param {string} value - The string value to store.
 */
export function localstorage_set(key, value) {
    localStorage.setItem(key, value)
}

/**
 * Retrieves a value from localStorage by key, returning a result object.
 *
 * If the key exists and its value is not null, returns an {@link Ok} containing the value.
 * If the key does not exist or its value is null, returns an {@link Error} with {@link undefined}.
 *
 * @param {string} key - The key to look up in localStorage.
 * @returns {Ok<string> | Error<undefined>} Result object indicating success or failure.
 */
export function localstorage_get(key) {
    const value = localStorage.getItem(key)
    if (value === null) {
        return new Error(undefined)
    }
    return new Ok(value)
}

/**
 * Parses a JSON-formatted string into a JavaScript object.
 *
 * @param {string} value - The JSON string to parse.
 * @returns {any} The resulting JavaScript object.
 *
 * @throws {SyntaxError} If {@link value} is not valid JSON.
 */
export function string_to_dynamic(value) {
    try {
        return JSON.parse(value)
    } catch (_e) {
        return undefined
    }
}

/**
 * Copies text to the clipboard using the browser's clipboard API.
 *
 * @param {string} text - The text to copy to clipboard.
 */
export function clipboard_copy(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).catch(err => {
            console.error('Failed to copy to clipboard:', err);
        });
        return;
    }
    // Fallback for non-secure contexts or unsupported clipboard API
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    try {
        document.execCommand('copy');
    } finally {
        document.body.removeChild(ta);
    }
}

/**
 * Sets a timeout to call the provided callback function after the specified delay.
 *
 * @param {function} callback - The function to call after the delay.
 * @param {number} delay - The delay in milliseconds.
 */
export function set_timeout(callback, delay) {
    setTimeout(callback, delay);
}

/**
 * Focuses and selects an HTML element by its ID.
 *
 * @param {string} elementId - The ID of the element to focus and select.
 */
export function focus_and_select_element(elementId) {
    setTimeout(() => {
        const element = document.getElementById(elementId);
        if (element) {
            element.focus();
            element.select();
        }
    }, 0);
}
