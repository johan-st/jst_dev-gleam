module.exports = {
  content: ["./index.html", "./src/**/*.{gleam,mjs}"],
  // Dynamically constructed classes like "group/<key>" and
  // "group-hover/<key>:border-pink-700" are not discoverable by the
  // Tailwind scanner, so we safelist patterns to ensure the CSS is generated.
  safelist: [
    // Any named group hover that changes border color to pink-700
    { pattern: /group-hover\/[A-Za-z0-9_-]+:border-pink-700/ },
    // Optionally include a general catch-all for any named group utilities you may add later
    // e.g. group-hover/<name>:text-pink-700, etc.
    { pattern: /group-hover\/[A-Za-z0-9_-]+:.+/ },
  ],
  theme: {
    extend: {},
  },
  plugins: [],
};