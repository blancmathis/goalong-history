# Website-level activity analysis

Goalong History treats a browser as a container, not as the final unit of analysis. A browser row can still appear in application totals, but website activity is attributed separately to the domain, sanitized page URL, page title and observed actions.

## Browser-independent discovery

Website capture does not depend on one product name or bundle identifier. The recorder uses three layers:

1. configured browser bundle identifiers as a fast path;
2. broad compatibility name markers as a fallback;
3. an accessibility capability probe for `AXWebArea`, page URL and address-field semantics.

The capability probe is authoritative for previously unknown browsers, Chromium wrappers and other web containers. No browser-specific rule is required for a newly released browser to expose sites when macOS Accessibility exposes its page URL.

## What a website summary contains

For each normalized host, the analysis can contain:

- estimated foreground time;
- every distinct sanitized page URL and title observed during the day;
- first and last observation time;
- the applications through which the site was observed;
- click targets, accessible roles and occurrence counts;
- unlabelled click coordinates when macOS cannot expose a target label;
- grouped typing activity without decoded characters;
- grouped scrolling and keyboard shortcuts;
- opt-in visible page context and accessible web discussions;
- references to the underlying event chain through the day analysis coverage.

Identical click targets on the same page are grouped with a count to keep the UI and agent context compact. This is a lossless aggregation for the target identity and count, not a claim that every DOM event can be reconstructed. Raw sealed events remain the detailed source of truth.

## Persistent website rules

The Activity screen exposes two independent rule types:

### Sharing rule

A normalized domain can always:

- reveal its name;
- reveal only its local category;
- remain hidden in every selective share.

This does not alter local historical data.

### Future capture rule

A domain can be added to the recorder's excluded-domain configuration directly from its row. From that point forward, Goalong History records only a generic excluded coverage state for the domain and does not retain its URL, title, click target or visible context. Re-enabling the domain affects future capture only; it does not recreate missing details or rewrite existing sealed history.

Subdomains follow the existing domain exclusion semantics. For example, excluding `example.com` also excludes `app.example.com`.

## Visible web discussions

Rich Context remains explicit and local-only. When enabled, Goalong History periodically stores selected and visible text exposed through macOS Accessibility, up to a bounded snapshot size. This can preserve accessible ChatGPT-style discussions and other web content that cannot be inferred from a URL alone.

The collector:

- does not decode keyboard characters;
- does not take screenshots or read the clipboard;
- does not capture private browsing, excluded domains, excluded applications or secure fields;
- redacts common credentials before persistence;
- deduplicates unchanged page snapshots;
- commits the snapshot through `EventRecorder`, so it is included in the normal event hash chain and minute seal.

Some websites expose only part of their content to Accessibility, virtualize older conversation messages, or remove content from the accessibility tree after scrolling. Goalong History can retain only the accessible content it actually observed; it must not claim a complete server-side conversation export when the browser did not expose one.

## Agent context

The deterministic daily Markdown brief prioritizes:

1. coherent focus blocks;
2. user requests and intentions;
3. websites, pages, click counts and meaningful click targets;
4. remembered visible context;
5. application totals and coverage metadata.

The brief respects the selected token budget. The structured JSON cache can contain substantially more site/page/action detail than the Markdown supplied to the daily agent.
