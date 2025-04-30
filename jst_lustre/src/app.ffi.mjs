import { Ok, Error } from "./gleam.mjs";
import { marked } from 'marked';
import DOMPurify from 'dompurify';
import { kv } from '@nats-io/kv';
import { connect, deferred, nuid } from "@nats-io/transport-node";



// parses and injects markdown into the element with the given id
export function inject_markdown(element_id, markdown) {
    console.debug("inject_markdown", element_id, markdown.slice(0, 100));
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
            let content = markdown.trim();
            content = content.replace(/^[\u200B\u200C\u200D\u200E\u200F\uFEFF]/, "");
            content = DOMPurify.sanitize(markdown, { USE_PROFILES: { html: true } });
            content = marked(content, { async: false });
            if (document.startViewTransition) {
                document.startViewTransition(() => {
                    element.innerHTML = content;
                });
            } else {
                element.innerHTML = content;
            }
            return new Ok(undefined);
        } catch (error) {
            console.error("ffi: inject_markdown: Error", error);
            return new Error(undefined);
        }
    }, 50);
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

export async function nats_init(on_unhandled) {
    const nc = await connect({ servers: "localhost:4222" });
    nc.subscribe('>', (msg) => {
        console.log("ffi: nats_init: Message received", msg);
        on_unhandled(msg);
    });
}
