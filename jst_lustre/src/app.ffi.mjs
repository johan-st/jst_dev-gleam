import { Ok, Error } from "./gleam.mjs";

// LOCAL STORAGE ------------------------------------------------------

export function localstorage_set(key, value) {
    console.log("localstorage_set", key, value)
    localStorage.setItem(key, value)
}

export function localstorage_get(key) {
    console.log("localstorage_get", key)
    const value = localStorage.getItem(key)
    console.log("localstorage_get", value)
    if (!value) {
        console.log("localstorage_get", "no value")
        return new Error(undefined)
    }
    console.log("localstorage_get", "value")
    return new Ok(JSON.parse(value))
}

