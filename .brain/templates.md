# Templates

Last reviewed: 2026-08-25
Source of truth: this file

Copy/paste formats so entries added later match the house style. Route each new fact to its owner
page first — see `owner-page-taxonomy.md`.

## Page header

Every page opens with exactly this, on the first three lines:

```
# <Topic>

Last reviewed: YYYY-MM-DD
Source of truth: `<primary code path>`
```

`Last reviewed:` must start the line — automated preflights grep for `^Last reviewed`, and a page
missing it reads as unmaintained.

## Gotcha entry (`gotchas.md`)

The highest-value format in the brain. Keep every entry; never summarise them away.

```
## <Gotcha title>

Symptom: <what fails or surprises — be concrete, quote the error>
Evidence: `<path>` or `<path>:<line>` or a commit hash
Impact: <why it matters / what breaks downstream>
Do: <the safe pattern>
Avoid: <the pattern that caused it>
```

Append ` — **Safeguard**` to the title when the rule is a merge blocker rather than advice.

## Code-map row (`code-maps.md`)

```
| Feature | Key files | Tests | Notes |
|---|---|---|---|
| <feature> | `Sources/ApusKitTools/Tool.swift` | `Tests/ApusKitToolsTests/ToolsTests.swift` | <constraint or trap> |
```

## Open question (`open-questions.md`)

```
- [ ] **<the question>** <what is undecided, what depends on it, and what would settle it>
```

## Backtick rule — mind the dead-path check

Automated runs extract every backticked token containing `/` and assert the path exists; anything
missing marks its subsystem stale and re-triggers the expensive code-reading the brain exists to
avoid.

- **Backtick only paths that exist today.**
- Name planned paths in plain prose with the milestone that creates them — e.g. "ApusKitSessions
  (M2)" — never in backticks.
- `path:line` references are fine: the check skips them.

## Validation

```bash
grep -L '^Last reviewed:' .brain/*.md          # must print nothing
grep -oh '`[a-zA-Z0-9_][a-zA-Z0-9_./-]*`' .brain/*.md | tr -d '`' | grep '/' | sort -u \
  | while read -r p; do [ -e "$p" ] || echo "DEAD: $p"; done   # must print nothing
```

## Open questions

None.
