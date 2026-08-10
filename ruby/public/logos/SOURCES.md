# Provider logos

Vendored locally so the dashboard has zero CDN/runtime dependency. Fetched once
and checked into git; nothing here loads over the network at request time.

| File         | Source                                                                     |
| ------------ | --------------------------------------------------------------------------- |
| `claude.svg` | https://cdn.simpleicons.org/claude (Simple Icons' Claude glyph)             |
| `codex.png`  | https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/codex-color.png - retrieved 2026-08-09 from [LobeHub Icons](https://github.com/lobehub/lobe-icons) (MIT licensed), the current Codex mark. Replaces a prior `codex.svg` that was mistakenly the old green OpenAI/ChatGPT logo. |
| `grok.png`   | https://grok.com/images/android-chrome-192x192.png (Grok's own favicon)     |

`claude.svg` was inspected before committing: no `<script>`, `<foreignObject>`,
or `on*` event-handler attributes, and no `width`/`height` attributes (only
`viewBox`), so it scales cleanly at any size via CSS. `codex.png` and
`grok.png` are raster PNGs with transparent backgrounds, sized via CSS/HTML
`width`/`height` like any other `<img>`.

If a future re-fetch of one of these ever fails, replace it with a plain
local mark instead (solid circle + monogram) rather than leaving a broken
`<img>` - see `bin/*` or the dashboard views for how logos are referenced
(`ruby/views/index.erb`, class `.provider-logo`).
