import { Ok, Error } from "./gleam.mjs";

// LOCAL STORAGE ------------------------------------------------------

export function localstorage_set(key, value) {
    localStorage.setItem(key, value)
}

export function localstorage_get(key) {
    return new Error("not implemented")
    const value = localStorage.getItem(key)
    if (!value) {
        return new Error(undefined)
    }
    return new Ok(value)
}

