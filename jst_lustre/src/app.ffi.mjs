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
    if (!value) {
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
    return JSON.parse(value)
}

/**
 * Copies text to the clipboard using the browser's clipboard API.
 * Shows temporary "Copied!" feedback on the element containing the short_code.
 *
 * @param {string} text - The text to copy to clipboard.
 * @param {string} short_code - The short code to identify which element to show feedback on.
 */
export function clipboard_copy(text, short_code) {
    navigator.clipboard.writeText(text).then(() => {
        // Find the element containing the short code
        const elements = document.querySelectorAll('[title="Copy short URL to clipboard"]');
        let targetElement = null;
        
        elements.forEach(el => {
            if (el.textContent.trim() === short_code) {
                targetElement = el;
            }
        });
        
        if (targetElement) {
            const originalText = targetElement.textContent;
            const originalColor = targetElement.style.color;
            
            // Show feedback
            targetElement.textContent = "Copied!";
            targetElement.style.color = "#10b981"; // green-500
            
            // Restore original text after 1 second
            setTimeout(() => {
                targetElement.textContent = originalText;
                targetElement.style.color = originalColor;
            }, 1000);
        }
    }).catch(err => {
        console.error('Failed to copy to clipboard:', err);
    });
}
