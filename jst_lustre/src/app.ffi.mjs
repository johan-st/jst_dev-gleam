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
