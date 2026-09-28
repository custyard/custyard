# Branch & PR Audit — 2026-09-28

Triage of all remote branches, open PRs and open issues after two months
away. Findings verified against `git` (fetched today) and GitHub CI state.
Previous audit: `branch-audit-2026-07-05.md`.

## Key facts

- `main` is at `07e611c` (2026-07-25, PR #13). The whole July MVP push
  landed: PRs #3, #4, #5, #7, #8, #9, #10, #12, #13 are all merged.
- Three remote branches besides `main`. Two carry open PRs; one is a leftover.
- Both open PRs are one commit each, 0 behind `main`, CI fully green (test,
  security, claude-review) on their current heads, no review threads, and
  `git merge-tree` shows **no conflicts** between them (disjoint files).
- Nothing in the repo has moved since 2026-07-26.

## Merge now

| Branch / PR | Verdict |
|---|---|
| `fix/telemetry-orphaned-poller-metric` / **#14** | Declares the poller's `custyard.conversations.active` gauge and adds a per-state `by_state` gauge tagged with `state`, zero-filled from `Conversation.states/0` so a drained state reads 0 instead of a stale `last_value`. Adds `test/custyard_web/telemetry_test.exs` (7 tests) asserting every poller event is declared, tags match emitted metadata, and no duplicate declarations. Diff read in full; the reasoning in the comments matches the code. Issue #11 already describes it as fixed. CI green. **Merge.** |
| `test/lmtp-moduletag` / **#15** | Four lines: `@moduletag :lmtp` on the LMTP server suite so `mix test --exclude lmtp` works in sandboxes that cannot bind sockets. CI does not exclude anything, so production CI behaviour is unchanged. **Merge.** |

Order does not matter; they touch disjoint files.

## Drop / delete

| Branch | Verdict |
|---|---|
| `docs/telemetry-no-consumer-ref` | PR #12 merged from `fa84f19`. The branch then got one more commit (`1693f1d`) which is byte-identical to `0a025e0`, already on `main` via PR #13 (`git diff 0a025e0 1693f1d` is empty). 1 ahead / 3 behind on paper, 0 ahead in substance. **Delete.** |

## Open issues

| Issue | State |
|---|---|
| **#11** telemetry: `metrics/0` has no consumer | Still true after #14: the declarations are now correct but nothing reads them. The issue lists three options and picks none. Recommendation: do option 1 (`ConsoleReporter` child in dev/test) now, since it is a correctness check and costs nothing, and defer the production reporter until there is somewhere to ship metrics. |
| **#6** ops: §1 config pass (prod secrets, super-admin, intake source, Lettermint sender) | Human-only, needs `fly` and prod access. Every `/i/*` URL 404s until it is done. The sequencing note ("check `fly secrets list` after the secret-sync fix lands") is satisfied: `c603e1e` (in #9) uncommented the secrets in the sample, so the check can be run now. **This is the only thing blocking a working production deploy.** |
| **#2** Clearinghouse intake MVP follow-ups | Umbrella. The 2026-07-25 comment carries a residual checklist that has not been touched: real Sentry DSN pasted into `docs/ops/sentry.md`, bare `turso db destroy` commands in `docs/ops/database.md`, attention-queue N+1 over Turso (fix already exists: pass thresholds to `neglect_status/2`), operator state changes bypassing `update_state/2`, unsupervised `Task.start` in `Scoring.Scheduler`, untested `NoReferrer`/`ConversationCookie` plugs, dead `Team` schema, Catalyst UI kit committed. The two docs items are five-minute deletes; the N+1 is the one with production impact. |

## Suggested order

1. Merge #14 and #15, delete `docs/telemetry-no-consumer-ref`.
2. Work #6 by hand (prod config). Nothing else makes the product usable.
3. From #2's checklist: delete the pasted DSN and the `turso db destroy`
   lines, then fix the attention-queue query cost before real traffic hits
   Turso.
4. #11 option 1 whenever convenient.

## Notes / limitations

- No Elixir toolchain in this audit environment, so the two PRs were not run
  locally. Verdicts rest on reading the diffs plus GitHub's green `test`,
  `security` and `claude-review` runs on the exact heads.
- GitHub's list API reports `merged: false` for PRs #3 through #13, but each
  has a `Merge pull request #N` commit on `main`. Treated as merged.
