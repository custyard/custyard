# Bunny migration documentation validation

Ready for review as a deployment plan. Production runtime readiness is unverified.

Review set: README Docs links, Fly deployment introduction, the complete Bunny
production/Fly staging plan, its GHCR publishing guide, and the root `.codex/`
ignore rule. All changed sections were reread after edits.

| Finding | Material consequence | Disposition | Evidence and verification |
| --- | --- | --- | --- |
| F1 Hosting capability | Selecting the wrong Bunny service | Addressed | Recommendation distinguishes Magic Containers from CDN/Storage; official deployment and endpoint documentation checked |
| F2 Storage and availability | Data loss and outage expectations | Addressed | Storage section documents independent disks, node binding, missing backups and deployment downtime; vendor volume/rolling-update pages checked |
| F3 Portability | Unsafe operation outside Fly | Addressed in plan | Owning code and portability section identify mount validation, proxy trust and client-IP precedence; implementation explicitly future work |
| F4 Environment separation | Staging could affect production | Addressed | Runtime table and steps 2/5 specify independent staging data, encryption, tenant credentials, mail and broker integrations |
| F5 Cutover and rollback | Divergent or stale production data | Addressed | Transfer and rollback procedures preserve one writer and require reverse transfer after new writes |
| F6 Evidence and current state | Unsupported live-state claims | Addressed | Checkout source, live metadata, public DNS and unverified account/runtime details are distinguished; Fly status, volumes, secret names and selected non-secret config checked |
| F7 Image example | Wrong tag or accidental shell interpretation | Addressed | Manual build example replaced with a text-only digest reference matching the merged GHCR guide |
| F8 Bunny Database selection | Wrong deployment destination | Addressed | User selected Bunny Database; target diagram, configuration, staging, transfer and rollback now consistently use it |
| F9 Driver compatibility | Existing release may not connect correctly | Addressed in plan | Existing /v3/pipeline and Ecto baton/get_autocommit behavior compared with documented /v2/pipeline and interactive-session guidance; required service tests are explicit |
| F10 Durability and consistency | Incorrect database recovery guarantees | Addressed in plan | Managed database snapshots/failover distinguished from file-volume limitations; WAL loss window, pooled read consistency and independent exports are documented |
| F11 GHCR integration | Planning guidance could contradict the merged workflow | Addressed | Plan links the publishing guide, uses the `sha-<full-commit-sha>` tag convention and digest promotion, and separates implemented publishing from future deployment |
| F12 Local Codex files | Worktree configuration could enter Git | Addressed | Root `/.codex/` rule checked with `git check-ignore -v` for `environment.toml` and local state; no tracked Codex files found |

Coverage: twelve addressed; none rejected, deferred, out of scope or unresolved
within the documentation review. Implementation and live acceptance remain
future work specified by the plan.

Validation (before the documentation commit):

- `git diff --check` and `git diff --cached --check` passed.
- The two new Markdown documents passed equivalent whitespace checks before
  staging; the final staged diff includes those files.
- An ad hoc Python check resolved all 36 local links/anchors across the five
  Markdown files in the review set and checked code-fence balance. Whitespace
  checks covered the new documents and changed lines; pre-existing README
  whitespace was left unchanged.
- The image reference is a text-only digest example; no shell/deployment example
  was executed during finalization.
- All 24 unique external references in the migration plan were read through web
  tools during the original research in this conversation. They are official
  Bunny documentation and were unchanged during this finalization pass. They
  were not fetched again for the worktree transfer. GitHub references in the
  existing GHCR guide were checked when that guide was written. Pre-existing
  external links elsewhere in README/Fly guidance were outside this scope.
- Diagnostic discovery inspected Markdown/remark/prettier/Makefile candidates,
  `.formatter.exs`, and CI configuration. No dedicated repository Markdown
  diagnostic was found; vendored Catalyst examples have unrelated tooling.
- `git check-ignore -v --no-index` confirmed the root `.codex/` rule covers
  `environment.toml` and local state, and the existing environment file in 9c2e
  was checked in place. No Codex configuration is tracked or included in the PR.

Limits: no rendered Markdown/Mermaid verification, Bunny account inspection,
email sending, infrastructure changes, data transfer, or runtime acceptance
checks. Application CI was not run locally for these documentation/ignore-only
changes. The GHCR implementation and Bandit fix have their own validation in
PR #60. This report records documentation readiness, not migration completion.
