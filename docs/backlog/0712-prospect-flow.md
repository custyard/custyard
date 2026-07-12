# docs/backlog/0712-prospect-flow.md
---
# Prospect-Flow Backlog — 2026-07-12

Findings from prod prospect-flow testing on custyard.fly.dev (intake `eu-otshosted`).
9 issues found + 2 still-open items from earlier turns = 11 total.

**Status: all 11 items RESOLVED** on `fix/prospect-flow-ui` (2026-07-12, multi-agent
implementation pass; full suite 1803 tests green). Item details kept below for reference.
Notable decisions: error flashes auto-dismiss at 10s (info stays 5s); source links render
even for disabled sources (provenance, not availability); message delete is soft-only
(tombstone keeps thread position); claim shape-validation runs before rate-limit but
existence checks stay behind it (no enumeration oracle).

**Previously fixed** (commit `1f7bea1`): per-source intake URLs + copy button,
reply-gating, textarea-clear-after-send. Not in this backlog.

---

## 1. Flash toasts — icons, close affordance, auto-dismiss

Root cause: no heroicons Tailwind plugin, and the installed `{:heroicons, "~> 0.5"}` is the
component library (no SVG files), while `.icon/1` uses the mask-image approach. So all
`hero-*` icons render invisible app-wide — invisible close button, missing title icon,
orphaned `pl-[22px]`. Also error flashes never auto-dismiss (only `:info` gets the
AutoDismiss hook). Icons used: 14 distinct names enumerated.

## 2. Per-source branding links on prospect pages

Prospects have no visual/link connection back to the operator's product. Plan: titled
links per intake source. Confirmed intake sources are not associated with projects (only
transitively via `conversations.intake_source_key` + optional `project_id`).

## 3. Root → dashboard redirect for authed operators

`HomeLive.mount` ignores session.

## 4. Obscured prospect email in operator thread

`conversation_live.ex:1100` shows bare "via prospect"; want "via prospect abc***@company.com".

## 5. Suppress duplicate identical messages

Screenshot showed 4 identical "d" messages; suppress reply identical to most recent.

## 6. "Waiting on customer" as a toggle

Clicking again should undo the waiting state.

## 7. Operator delete message → tombstone

GitHub-style "this comment was deleted" marker; needs soft-delete column + rendering in
operator + resume views.

## 8. White-on-white select in dark mode

Native `<select>` ("All organizations") on Projects; likely app-wide. Related to the
earlier dark-mode checkbox/input contrast findings.

## 9. Branding: image upload + color picker

Instance branding uses plain text; want a real logo upload widget + native color picker.
Distinct from #2.

## 10. Claim rate-limit ordering

Rate-limit check happens before validation, so a validation-failed submit still burns one
of the 3/hr IP-keyed attempts. (Earlier-turn item.)

## 11. Dark-mode checkbox check contrast

Hand-rolled checkboxes in `resume_live.ex` diverge from the core component; check-mark
legibility is browser-dependent. Distinct from #8 (that's the native `<select>`).
