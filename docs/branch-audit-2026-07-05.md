# Branch & PR Audit — 2026-07-05

Triage of all remote branches and open PRs after ~3 months away, ahead of the
MVP push. All findings verified against git history and GitHub CI/review state
on this date.

## Key facts

- `main` has not moved since 2026-03-29 (PR #41). **Every live branch is 0
  commits behind main**, so no rebases are needed anywhere.
- All pairwise merges between live branches were checked with
  `git merge-tree`: **no textual conflicts in any combination** (including
  `claude/email-only-auth-VP2JG` × `feature/26-outbound`, which touch the same
  files: `config/runtime.exs`, `router.ex`, `test/mix/tasks/fly_secrets_test.exs`).
- The three `feature/26-*` / `feature/27-*` branches are a clean linear stack:

  ```
  main ──► feature/26-prep (6 commits, PR #42 → main)
              └─► feature/27-routes (+1 commit, PR #43 → 26-prep)
                     └─► feature/26-outbound (+2 commits, no PR)
  ```

## Merge now

| Branch / PR | Verdict |
|---|---|
| `feature/normalizer-improvements` / **#46** | One small, self-contained commit (UTF-8 `truncate/2` fix + regex module attributes). CI green (test + security). Touches only normalizer files; conflicts with nothing. |
| `claude/email-only-auth-VP2JG` / **#45** | Magic-link operator auth. CI green on latest head (2026-04-16). Every substantive review finding was already fixed in follow-up commits: `Repo.update!` (gemini, resolved), Post/Redirect/Get so the rate limiter isn't tripped by 200-renders, a fallback `create/2` clause for missing email param, and a `DateTime` guard in `verify_login_token/2` (all three Copilot comments — threads are unresolved on GitHub but the code is fixed; resolve and merge). Only open judgment call: migration `down()` silently skips accounts with null `password_hash` on rollback — acceptable pre-MVP. |

## Review / continue — the MVP-critical stack

| Branch / PR | Verdict |
|---|---|
| `feature/26-prep` / **#42** | Processor consolidation (Phase 0 of issue #26). Claude review: approve; security check green. The **test job failed**, but logs have expired (>90 days) and the run can no longer be re-run. Delano's own status comment on issue #26 (2026-03-29) notes "2 pre-existing LMTP test failures (unrelated to consolidation)" — likely the same failures. Action: push a trivial commit (or amend) to re-trigger CI; if the LMTP failures reappear, fix or skip them, then merge. |
| `feature/27-routes` / **#43** | Route-management hardening, one commit on top of 26-prep. Claude review green; test/security jobs never ran on it. GitHub will auto-retarget #43 to `main` when #42 merges. Merge after #42 (fresh CI run first). |
| `feature/26-outbound` (no PR) | The actual MVP work: `Conversations.send_reply/3`, `Email.Outbound`, `ThreadHeaders` (In-Reply-To/References), `delivery_status` + `lettermint_message_id` migrations, reply UI in `ConversationLive` — most of issue #26's acceptance criteria are implemented. Open a PR → main after #42/#43 land (it will then show only its 2 unique commits). Review the big commit `c4fef98` properly — it never got CI or review. |

Suggested landing order: **#46 → #45 → #42 → #43 → new PR for 26-outbound.**
After #45 and the stack are both in, run the full suite once — the merges are
textually clean but `fly_secrets_test.exs` and `config/runtime.exs` are edited
by both lines of work, so a semantic double-check is cheap insurance.

## Drop / close

| Branch | Verdict |
|---|---|
| `delano/next2` | 0 commits ahead, 149 behind. Everything in it is already merged. **Delete.** |
| `claude/single-auth-method-config-uEcM4` (PR #44, closed) | The `AUTH_*_ONLY` config approach was explicitly closed as "out of scope" on 2026-03-29 and superseded by #45's email-only auth. The work remains recoverable via the closed PR. **Delete branch.** |

## Related issue state

- **#27** (route management): closed complete — #43 is hardening on top.
- **#26** (outbound replies): open; `feature/26-outbound` implements the bulk
  of it. Remaining after merge: verify acceptance criteria, then #25
  (Lettermint delivery-status webhooks), which #26 unblocks via
  `lettermint_message_id`.

## Notes / limitations

- Local test runs weren't possible in this audit environment (network policy
  blocks `repo.hex.pm`, so `mix deps.get` fails). All CI conclusions come from
  GitHub check runs.
- CI logs for the March runs are expired; the #42 failure diagnosis is inferred
  from timing (job died after 22s — setup/compile-stage fast-fail) and delano's
  contemporaneous notes, not from the log itself.
