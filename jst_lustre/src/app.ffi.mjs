import { Ok, Error } from "./gleam.mjs";
import { marked } from 'marked';
import DOMPurify from 'dompurify';


// parses and injects markdown into the element with the given id
export function inject_markdown(element_id, markdown) {
    window.md = marked;
    if (!element_id || !markdown) {
        console.error("ffi: inject_markdown: Invalid arguments");
        return new Error(undefined);
    }
    // HACK TO RENDER AFTER PAINT
    setTimeout(() => {
        const element = document.getElementById(element_id);
        if (!element) {
            console.error("ffi: inject_markdown: Element not found");
            return new Error(undefined);
        }


        try {
            console.log("ffi: inject_markdown: markdown", markdown);
            let content = markdown;
            console.log("ffi: inject_markdown: content", content);
            // content = DOMPurify.sanitize(markdown, { USE_PROFILES: { html: true } });
            // content = content.replace(/^[\u200B\u200C\u200D\u200E\u200F\uFEFF]/, "");
            content = marked.parse(content);
            console.log("ffi: inject_markdown: content", content);
            content = marked.parse(content);
            console.log("ffi: inject_markdown: content", content);

            element.innerHTML = content;
            return new Ok(undefined);
        } catch (error) {
            console.error("ffi: inject_markdown: Error", error);
            return new Error(undefined);
        }
    }, 0);
}


// set up a websocket connection and the required event handlers
export function setup_websocket(path, on_open, on_message, on_close, on_error) {
    const ws = new WebSocket(path, "jst_dev");
    window.ws = ws;
    ws.onopen = (data) => {
        console.log("ffi: setup_websocket: WebSocket connection opened", data);
        on_open(data);
    };
    ws.onmessage = (data) => {
        console.log("ffi: setup_websocket: Message received", data);
        on_message(data);
    };
    ws.onclose = (data) => {
        console.log("ffi: setup_websocket: WebSocket connection closed", data);
        on_close(data);
    };
    ws.onerror = (data) => {
        console.error("ffi: setup_websocket: Error", data);
        on_error(data);
    };
    return new Ok(undefined);
}
