# Blocage — exceptions et mots-clés (2026-10-08)

Owner request: the last functional gap after #75/#76. Base: `docs/BLOCKING.md` (rules, privacy,
lock semantics). This file only adds to it.

## Model (schema stays version 1, new fields optional)

- `BlockList.exceptions: [BlockSiteRule]?` — same normalized `host[/path]` as `sites`.
- `BlockList.keywords: [String]?` — stored trimmed, lowercased, NFC. 2…40 characters each, at most
  50 per list, no duplicates (after folding), no whitespace-only entries.
- Absent = empty. Old files load unchanged; `validate` checks the new fields.

## Matching (per list; lists still combine with « blocked if any active list blocks »)

Order inside one active list, for a browser target:
1. Browser app listed (block mode) → blocked. Exceptions do not reopen a blocked browser app.
2. Internal page → allowed (unchanged).
3. An exception matches the URL → **this list** does not block it. Exceptions never unblock what
   another active list blocks.
4. A keyword matches → blocked (block and allowOnly modes).
5. Otherwise the existing site rule logic.

Exceptions only make sense in `block` mode; in `allowOnly` mode they are ignored (the allowed sites
already play that role) and the UI hides them.

**Keyword match.** Fold case and diacritics (`é` = `e`). Match whole words: the keyword must start and
end on a word boundary (letters/digits on both sides break the match; `sex` must not match `essex`).
A keyword with several words matches that word sequence. Targets:
- the URL host + path (split on `.`, `/`, `-`, `_`), as observed today (never query/fragment);
- the browser **tab/window title**, read only while an active list has keywords.

Non-browser apps: keywords do not apply (app rules only).

## Privacy (same rules as URLs)

- The title is read by the blocking sink only, never for private windows (private check first, as
  for the address), never recorded, logged, sent to Jev, analytics or diagnostics. Keep it out of
  `BlockingObservation` equality/caching longer than one sample.
- No title read at all when no active list has keywords (cost unchanged when unused).
- A Google search for a keyword is caught by its title (« mot - Recherche Google »), since the query
  string is never read. Document this in BLOCKING.md.

## Locks (stricter-only)

While a list is stricter-only (program lock or locked manual session):
- adding keywords, removing exceptions = stricter → allowed;
- removing keywords, adding or widening exceptions = looser → refused with a French reason, like
  the existing `BlockingEditCheck` messages.
An edited exception counts as remove + add.

## API for the UI (UI is done separately, not in this task)

On the controller, same style as the site/app editing calls: add/remove exception, add/remove
keyword, each returning the existing edit-check result; a pure helper that says why a given
URL/title is blocked or allowed by a list (for tests and a future « Pourquoi ? » line).

## Tests

Matching table (exception beats site rule in the same list; not across lists; browser app block wins;
allowOnly ignores exceptions; keyword word boundaries, diacritics, multi-word, URL tokens, title),
lock checks both ways, `validate` limits, old-file decoding, no title read without keywords, no
title read in private windows.
