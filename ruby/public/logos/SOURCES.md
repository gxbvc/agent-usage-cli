# Provider logos

Vendored locally so the dashboard has zero CDN/runtime dependency. Fetched once
and checked into git; nothing here loads over the network at request time.

| File         | Source                                                                     |
| ------------ | --------------------------------------------------------------------------- |
| `claude.svg` | https://cdn.simpleicons.org/claude (Simple Icons' Claude glyph)             |
| `codex.svg`  | https://upload.wikimedia.org/wikipedia/commons/0/04/ChatGPT_logo.svg (OpenAI/ChatGPT mark, used for Codex) |
| `grok.png`   | https://grok.com/images/android-chrome-192x192.png (Grok's own favicon)     |

Both SVGs were inspected before committing: no `<script>`, `<foreignObject>`,
or `on*` event-handler attributes, and no `width`/`height` attributes (only
`viewBox`), so they scale cleanly at any size via CSS.

If a future re-fetch of one of these ever fails, replace it with a plain
local mark instead (solid circle + monogram) rather than leaving a broken
`<img>` — see `bin/*` or the dashboard views for how logos are referenced
(`ruby/views/index.erb`, class `.provider-logo`).
