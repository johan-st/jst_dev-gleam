import { Ok, Error } from "./gleam.mjs";

// LOCAL STORAGE ------------------------------------------------------

export function localstorage_set(key, value) {
    localStorage.setItem(key, value)
}

export function localstorage_get(key) {
    const value = localStorage.getItem(key)
    if (!value) {
        return new Error(undefined)
    }
    return new Ok(value)
}

export function string_to_dynamic(value) {
    return JSON.parse(value)
}
