# docs/backlog/0712-intake-prs-feedback.md
---
# Intake Stack — PR Review Feedback (verbatim)

Consolidated review feedback for the public-intake PR stack, merged to `main` (tip 703189b).
Source PRs: #59, #60, #61, #62, #63, #64, #65, #66, #68 (docs PR #67 and draft #69 excluded).

Channels and reviewer identities:
- `Copilot` / `copilot-pull-request-reviewer[bot]` — GitHub Copilot inline comments + PR overview
- `greptile-apps[bot]` — Greptile inline findings (severity badges `[P1]`/`[P2]`) + confidence score
- `claude[bot]` — Claude review bot (top-level review comment)
- `delano` — human author/maintainer

Content is verbatim from the GitHub API. Removed as non-information: HTML markup, badge images,
"Fix in Claude" base64 tracking links, `[View job]` CI links, checkbox progress lists, and the
duplicate "Fix the following N issues" reprint that restates the inline comments. No finding text is paraphrased.


---

## PR #59 — Unify scoring formula and score unlinked conversations (intake stack 1/9)

Merged: 2026-07-06T02:58:15Z

### Inline comments

#### [Copilot] `lib/custyard/scoring.ex:7`

The module doc’s formula omits the neglect weight, but the implementation multiplies `neglect_bonus/1` by `weights.neglect` (see `components/2`). This makes the documented scoring formula inaccurate for anyone reading/debugging the scoring system.

#### [Copilot] `lib/custyard/scoring.ex:325`

`@default_unlinked_tier_score` is hard-coded to 10, duplicating the standard tier score already defined in `@tier_scores`. Since the intent is for the default to match the standard tier, deriving it from `@tier_scores` prevents drift if the standard tier score changes.

#### [Copilot] `lib/custyard/settings.ex:203`

`update_intake_config/1` overwrites the entire `intake_config` map with only the provided keys. Since `validate_intake_config/1` does not require all known keys, callers can pass a partial map and unintentionally reset omitted keys back to defaults on the next read. Either require all keys or merge over existing/default values before persisting.

### Copilot PR overview

## Pull request overview

This PR is the first in the public-intake stack, aligning all scoring entrypoints to a single unified formula while changing semantics so nil-organization (“unlinked”) conversations can be scored and accrue neglect (with crash guards in reporting/notification surfaces).

**Changes:**
- Unifies the attention-score calculation paths behind a shared internal component function and adds equivalence tests across paths.
- Introduces `settings.intake_config` (with validation/defaults) to drive unlinked-tier scoring and future slug-claim TTL configuration.
- Hardens neglect email and neglect report rendering for nil-organization conversations and adds operator settings UI + tests.

### Reviewed changes

Copilot reviewed 14 out of 14 changed files in this pull request and generated 3 comments.

Show a summary per file

| File | Description |
| ---- | ----------- |
| test/custyard/settings_test.exs | Adds coverage for intake config defaults, validation, and update behavior. |
| test/custyard/scoring/recalculator_test.exs | Adds recalculation coverage for org-linked vs unlinked conversations. |
| test/custyard/scoring_test.exs | Updates nil-org scoring semantics and adds path-equivalence + unlinked scoring/neglect tests. |
| test/custyard/notifications/neglect_checker_test.exs | Pins current behavior that nil-org conversations don’t enter notification sweep (join boundary) and don’t crash. |
| test/custyard/notifications/email_test.exs | Verifies email rendering/logging doesn’t crash for nil-org conversations and uses a neutral label. |
| test/custyard_web/live/operator/settings_live_test.exs | Adds LiveView tests for viewing/editing intake config and authorization handling. |
| test/custyard_web/live/operator/neglect_report_live_test.exs | Ensures neglect report renders nil-org conversations safely and labels them appropriately. |
| priv/repo/migrations/20260705131000_add_intake_config_to_settings.exs | Adds `intake_config` map column to settings. |
| lib/custyard/settings.ex | Implements intake config defaults, parsing, validation, and update API. |
| lib/custyard/scoring.ex | Removes nil-org=0 behavior, unifies calculation via shared components, and applies standard-tier thresholds for nil-org neglect. |
| lib/custyard/notifications/email.ex | Uses safe organization display helper to avoid nil dereferences. |
| lib/custyard_web/live/operator/settings_live.ex | Adds Intake settings card with edit/save flow and numeric parsing/validation. |
| lib/custyard_web/live/operator/neglect_report_live.ex | Renders and sorts nil-org groups safely and hides tier badge when org is nil. |

---

💡 Add Copilot custom instructions for smarter, more guided reviews. Learn how to get started.

### Claude review bot

**Claude encountered an error** ——

---
I'll analyze this and get back to you.


---

## PR #60 — Render, authorize, and broadcast unlinked conversations (intake stack 2/9)

Merged: 2026-07-07T04:39:39Z

### Inline comments

#### [Copilot] `test/custyard/conversations_test.exs:943`

This test subscribes to both "conversations" and the malformed "conversations:org:" topic, but PubSub delivers the same message shape regardless of topic. That means `assert_received {:conversation_updated, ^conv_id}` does not prove the event came from the global topic; it could be coming solely from the malformed org topic and the test would still pass. Split this into two tests: one that subscribes only to the expected topics ("conversation:{id}" + "conversations") and asserts the events arrive, and another that subscribes only to "conversations:org:" and refutes receiving the update.

#### [Copilot] `test/custyard/conversations_test.exs:9`

The describe block is labeled `list_neglected/1`, but most tests in this block call `Conversations.list_neglected()` with no args (arity 0 via default). Renaming the describe string avoids confusion when scanning test output.

### Copilot PR overview

## Pull request overview

This PR is the second in the public-intake stack, extending operator-facing queue and conversation LiveViews to safely handle and surface “unlinked” (nil-organization) conversations, while updating authorization and PubSub broadcasting to avoid malformed org-scoped topics.

**Changes:**
- Allow org-scoped operators to *see and open* nil-org conversations (while still excluding other organizations’ conversations).
- Add human-labeled `source_badge` rendering across the operator queue card and conversation header, with a safe fallback for new/unknown sources.
- Centralize org-topic broadcasting via `Conversations.broadcast_to_org/2`, skipping nil org IDs to prevent publishing to `"conversations:org:"`.

### Reviewed changes

Copilot reviewed 12 out of 12 changed files in this pull request and generated 2 comments.

Show a summary per file

| File | Description |
| ---- | ----------- |
| `lib/custyard/conversations.ex` | Expands org scoping to include nil-org conversations and adds `broadcast_to_org/2` to prevent malformed org-topic broadcasts. |
| `lib/custyard/authorization.ex` | Updates access policy so all operator roles can access nil-org conversations. |
| `lib/custyard_web/live/operator/conversation_live.ex` | Subscribes nil-org conversations to the global topic, renders “Unlinked prospect” safely, and shows the source badge. |
| `lib/custyard_web/live/operator/attention_queue_live.ex` | Renders nil-org rows safely (no org/tier deref) and shows source badges on queue cards. |
| `lib/custyard_web/components/operator_components.ex` | Enhances `source_badge/1` with curated labels/colors and a humanized fallback label. |
| `lib/custyard/webhooks/purposes/sender_matching.ex` | Routes org-topic publishes through `Conversations.broadcast_to_org/2` to skip nil org IDs. |
| `lib/custyard/conversations/dormancy_checker.ex` | Routes org-topic publishes through `Conversations.broadcast_to_org/2` to skip nil org IDs. |
| `test/custyard/conversations_test.exs` | Adds coverage for nil-org inclusion in scoped queries and for org-topic broadcast skipping. |
| `test/custyard/authorization_test.exs` | Updates expectations for nil-org access across operator roles and adds a non-operator denial test. |
| `test/custyard_web/live/operator/conversation_live_test.exs` | Adds nil-org rendering/access/reply tests and source badge assertions. |
| `test/custyard_web/live/operator/attention_queue_live_test.exs` | Adds nil-org queue visibility and source badge rendering tests. |
| `test/custyard_web/components/operator_components_test.exs` | Adds focused tests for source badge labels and fallback behavior. |

---

💡 Add Copilot custom instructions for smarter, more guided reviews. Learn how to get started.

### Greptile review

Confidence Score: 3/5

The broadcast hygiene, render guards, and auth changes are solid, but one gap in conversation_live.ex can crash the LiveView process under normal traffic conditions.

When a nil-org conversation is open, conversation_live.ex subscribes to the global "conversations" topic. sender_matching.ex broadcasts {:conversation_created, id} on that topic every time a new inbound email creates a conversation — which is routine. conversation_live.ex has no handle_info clause for :conversation_created, and no catch-all. attention_queue_live.ex has an explicit catch-all with the comment "to prevent LiveView crashes," which is direct evidence that the missing guard causes real crashes. Any new inbound email while an operator is viewing an unlinked conversation will disconnect that LiveView session.

lib/custyard_web/live/operator/conversation_live.ex — needs a catch-all handle_info (or an explicit {:conversation_created, _id} clause) to match what attention_queue_live.ex already does.

Important Files Changed

| Filename | Overview |
|----------|----------|
| lib/custyard_web/live/operator/conversation_live.ex | Adds nil-org rendering, global topic fallback subscription, and broadcast_to_org migration — but the global topic subscription introduces a crash risk from unhandled {:conversation_created, id} messages |
| lib/custyard/authorization.ex | Adds nil-org conversation access for all OperatorAccount roles; clause ordering is correct (super_admin first, nil-org second, org-match last, catch-all deny at bottom); documented and tested |
| lib/custyard/conversations.ex | Adds broadcast_to_org/2 with nil guard, updates apply_organization_filter to OR-include nil-org rows for org-scoped queries; logic is sound and the new nil-org skip in broadcast is a strict improvement over interpolating a bare topic |
| lib/custyard/conversations/dormancy_checker.ex | Migrates to broadcast_to_org; the inner join on organization in stale_conversations/0 already excludes nil-org conversations so the nil guard in broadcast_to_org is unreachable here but harmlessly defensive |
| lib/custyard_web/components/operator_components.ex | Adds human labels for source atoms and a humanized fallback; String.capitalize gives "Public intake" for :public_intake as expected; unknown sources render neutrally without requiring a code change |
| lib/custyard_web/live/operator/attention_queue_live.ex | Migrates raw broadcasts to broadcast_to_org, adds source_badge to queue card, and guards org-name/tier display for nil-org conversations; has a catch-all handle_info that conversation_live.ex is missing |

Comments Outside Diff (1)

1. `lib/custyard_web/live/operator/conversation_live.ex`, line 361-377 ([link](https://github.com/onetimesecret/custyard/blob/06ec6a19edec3a60ea1f7826dda57fd67f96d14c/lib/custyard_web/live/operator/conversation_live.ex#L361-L377))

   [P1]  **Missing catch-all causes crashes when viewing nil-org conversations**

   `conversation_live.ex` now subscribes to the global `"conversations"` topic (not just the org-scoped one) when `organization_id` is nil. That global topic receives `{:conversation_created, id}` whenever `SenderMatching.broadcast_updates/2` fires for a new inbound email. There is no `handle_info` clause for `{:conversation_created, _id}` in this module, so any new conversation arriving while an operator has a nil-org conversation open will crash the LiveView process.

   `attention_queue_live.ex` has an explicit `def handle_info(_msg, socket)` with the comment *"Catch-all for unexpected PubSub messages to prevent LiveView crashes"* — the same guard is needed here.

### Claude review bot

**Claude finished @delano's task** ——

---
### PR #60 Review Complete

**Summary**: This is a well-structured PR that safely extends the operator queue and conversation views to handle nil-organization ("unlinked prospect") conversations. The implementation follows good Elixir/Phoenix patterns and addresses the critical concerns raised by previous reviewers.

---

### Strengths

**Broadcast hygiene** (`lib/custyard/conversations.ex:335-343`): The new `broadcast_to_org/2` function elegantly solves the malformed topic problem with a simple pattern match guard. This is applied consistently across all broadcast sites.

**Authorization changes** (`lib/custyard/authorization.ex:74-88`): The clause ordering is correct - super_admin first, nil-org second, org-match third, catch-all deny last. The docstring clearly explains the rationale.

**LiveView crash prevention** (`lib/custyard_web/live/operator/conversation_live.ex:361-367`): The explicit `handle_info({:conversation_created, _id}, socket)` clause plus catch-all addresses the Greptile finding. Both LiveViews now have matching defensive patterns.

**Test coverage**: 22 new tests with good coverage of edge cases - org scoping, nil-org visibility, broadcast isolation, and the malformed topic refutation test.

---

### Minor Observations

1. **DormancyChecker excludes nil-org conversations by design** (`lib/custyard/conversations/dormancy_checker.ex:49-61`): The `join: o in assoc(c, :organization)` (inner join) inherently excludes nil-org conversations from dormancy transitions. This appears intentional since unlinked conversations have no tier-based thresholds, but it's worth noting in case future behavior changes are needed.

2. **Source badge fallback** (`lib/custyard_web/components/operator_components.ex:217-219`): The `String.capitalize/1` fallback produces "Public intake" from `:public_intake` which is good. Just confirming this matches expectations for the upcoming PR #3.

3. **Test describes** (`test/custyard/conversations_test.exs:9`): The `describe "list_neglected"` block was renamed per Copilot feedback - good fix.

---

### Security Considerations

- **Nil-org access is intentionally permissive**: All operator roles can view unlinked conversations. The PR description notes this as "adopted-default #1, pending ratification." If the security-lens dissent prevails, the change is isolated to two clauses: `Authorization.can_access_conversation?/2:84` and `Conversations.apply_organization_filter/2:64-66`.

- **No IDOR concerns**: The org filter applies at query time, and authorization is checked at mount time. Scoped operators cannot access other organizations' conversations even if they manipulate IDs.

---

### Verdict

Looks good to merge. The previous reviewer findings have been addressed, the implementation is clean, and the test coverage is thorough.

### Human comments

@delano:
Addressed all outstanding review feedback in 33c1727:

- **greptile** (critical): `conversation_live.ex` had no `handle_info` clause for `{:conversation_created, _id}` and no catch-all, so any inbound email would crash the LiveView process while an operator had a nil-org conversation open (subscribed to the global `"conversations"` topic). Added the missing clause plus a catch-all, mirroring `attention_queue_live.ex`.
- **Copilot**: split the nil-org broadcast test into two — one asserting delivery on the legitimate topics, one subscribed *only* to the malformed `"conversations:org:"` topic to refute delivery there. The combined test previously couldn't distinguish which topic a message arrived from.
- **Copilot**: renamed `describe "list_neglected/1"` to `describe "list_neglected"` since the block exercises both the 0- and 1-arg forms.

Full suite: 1347 tests, 0 failures, 1 skipped.


---

## PR #61 — Add the intake domain model: prospects, intake sources, hashed tokens (intake stack 3/9)

Merged: 2026-07-07T04:40:09Z

### Inline comments

#### [Copilot] `lib/custyard/prospect.ex:61`

capture_email_changeset/2 normalizes email via update_change/3 before validate_required/2. If attrs includes email: nil (or any non-binary that still casts to nil), EmailAddress.normalize/1 will raise due to its is_binary guard, crashing instead of returning an invalid changeset.

#### [Copilot] `lib/custyard/intake_source.ex:80`

validate_questions/1 assumes questions is a list and calls length/1 and Enum.all?/2. If attrs (or an existing row) has questions: nil, this will raise at runtime while building the changeset.

#### [greptile-apps[bot]] `lib/custyard/intake.ex:252`

[P1]  **`rotate_resume_token` doesn't check revocation**

Every other write operation in `Intake` that touches a prospect explicitly blocks on `revoked_at`: `capture_email` rollbacks with `:no_prospect`, and `set_notification` does the same — the docstring even calls it out: "revocation removes write access entirely." `rotate_resume_token` has no such guard. If called on a revoked prospect it returns `{:ok, %{resume_token: token}}` with a token that `get_conversation_by_resume_token/1` will immediately reject (it checks `is_nil(p.revoked_at)`), leaving the caller holding a dead credential with a success tuple. There's no test covering this path, so the omission is invisible today but will confuse the PR-6 author wiring up the operator UI.

#### [greptile-apps[bot]] `lib/custyard/intake.ex:220`

[P2]  `Repo.get!` raises an unhandled `Ecto.NoResultsError` if the conversation is deleted in the narrow window between the prospect lookup and this fetch. The `on_delete: :delete_all` FK makes the race very unlikely, but a non-raising `Repo.get` with an explicit nil branch would be safer and keeps the function's contract to structured error tuples.

```suggestion
  def get_conversation_by_resume_token(token) when is_binary(token) do
    hash = Token.hash(token)

    prospect =
      Repo.one(
        from p in Prospect,
          where: p.resume_token_hash == ^hash and is_nil(p.revoked_at)
      )

    case prospect do
      nil ->
        {:error, :not_found}

      %Prospect{} = prospect ->
        conversation =
          Conversation
          |> Repo.get(prospect.conversation_id)
          |> case do
            nil -> {:error, :not_found}
            conv -> conv
          end
          |> Repo.preload([
```

### Copilot PR overview

## Pull request overview

This PR adds the core “public intake” domain substrate: new Prospect + IntakeSource models, hashed-at-rest resume tokens, lookup-only sender resolution for linking, and derived reply-channel/badging support for the operator attention queue.

**Changes:**
- Introduces `Custyard.Prospect` and `Custyard.Auth.Token` for hashed resume-token identity + lifecycle (rotate/revoke) and email capture.
- Introduces `Custyard.IntakeSource` + `Custyard.Intake` context to support intake CTA configuration and atomic intake conversation creation + linking flow.
- Extends Conversation/Message/source handling and operator UI components to support `:public_intake` / `:prospect`, plus queue badges and derived `reply_channel/1`.

### Reviewed changes

Copilot reviewed 28 out of 28 changed files in this pull request and generated 2 comments.

Show a summary per file

| File | Description |
| ---- | ----------- |
| test/support/factory.ex | Adds factories/helpers for org-exempt conversations, prospects, and intake sources. |
| test/custyard/prospect_test.exs | Adds unit tests for Prospect changesets and token rotation/revocation behavior. |
| test/custyard/message_test.exs | Adds tests for new `:prospect` message source and `:public_intake` origin. |
| test/custyard/intake_test.exs | Adds extensive tests for Intake context: creation, resume access, email capture/linking, CRUD. |
| test/custyard/intake_source_test.exs | Adds IntakeSource changeset validation tests (key format, caps, Q&A validation). |
| test/custyard/email/sender_matcher_test.exs | Adds tests for new lookup-only `SenderMatcher.resolve/1` behavior. |
| test/custyard/email_address_test.exs | Adds tests for extracted shared email validation and normalization. |
| test/custyard/conversations_test.exs | Adds tests for derived `reply_channel/1` and queue preloads. |
| test/custyard/conversation_test.exs | Adds tests for org requirement exemptions + creation-only intake_source_key behavior. |
| test/custyard/auth/token_test.exs | Adds tests for token generation + SHA-256 hashing primitive. |
| test/custyard_web/live/operator/attention_queue_live_test.exs | Adds LiveView tests for intake badges (source tag + no-reply-channel). |
| test/custyard_web/components/operator_components_test.exs | Adds component tests for public-intake styling and new badges/tags. |
| priv/repo/migrations/20260705150002_create_intake_sources.exs | Creates `intake_sources` table + unique key index. |
| priv/repo/migrations/20260705150001_create_prospects.exs | Creates `prospects` table + unique constraints for 1:1 conversation + token hash. |
| priv/repo/migrations/20260705150000_add_intake_source_key_to_conversations.exs | Adds `conversations.intake_source_key` provenance column + index. |
| lib/custyard/webhooks/purposes/sender_matching.ex | Routes `:public_intake` conversation source to `:prospect` message source. |
| lib/custyard/prospect.ex | Implements Prospect schema + changesets (create, capture email, notify, rotate, revoke). |
| lib/custyard/message.ex | Extends message sources/origins enums to include intake values. |
| lib/custyard/intake.ex | Adds Intake context: source CRUD, atomic intake creation, resume access, email capture/linking. |
| lib/custyard/intake_source.ex | Implements IntakeSource schema + key/Q&A validation rules. |
| lib/custyard/email/sender_matcher.ex | Adds `resolve/1` (lookup-only) and sentinel-org exclusions for intake linking. |
| lib/custyard/email_address.ex | Extracts shared email validation and normalization logic from Contact. |
| lib/custyard/conversations.ex | Preloads prospect for queue and adds derived `reply_channel/1`. |
| lib/custyard/conversation.ex | Adds `:public_intake` source, org-exempt validation, intake_source_key, and `intake_changeset/2`. |
| lib/custyard/contact.ex | Switches Contact email validation to delegate to `Custyard.EmailAddress`. |
| lib/custyard/auth/token.ex | Adds shared token generation + SHA-256 hash primitive for hashed-at-rest bearer tokens. |
| lib/custyard_web/live/operator/attention_queue_live.ex | Wires reply-channel derivation and renders intake-related badges/tags. |
| lib/custyard_web/components/operator_components.ex | Refactors source badge styling and adds intake tag + no-reply-channel badge components. |

---

💡 Add Copilot custom instructions for smarter, more guided reviews. Learn how to get started.

### Greptile review

Confidence Score: 3/5

Safe to merge for the pure domain layer; the rotation gap is a behavioral inconsistency, not a security hole, but it needs a decision before PR 6 wires up the operator UI.

Almost all of the domain substrate is carefully implemented — the hash-at-rest discipline, sentinel-org exclusion, write-once email, and the `capture_email` revocation gate are all correct. The one gap is `rotate_resume_token`: it succeeds on a revoked prospect and returns a live-looking token that immediately cannot be used. Every other write path in the module explicitly blocks on `revoked_at`; this one doesn't, and there is no test covering the case. Before PR 6 adds operator UI for token rotation, the domain contract needs to be explicit about whether revoked prospects are writable here.

`lib/custyard/intake.ex` — specifically `rotate_resume_token/1` (revocation policy) and the `Repo.get!` in `get_conversation_by_resume_token/1`.

Important Files Changed

| Filename | Overview |
|----------|----------|
| lib/custyard/intake.ex | Core intake context: atomic conversation creation, resume token lifecycle, and email capture with lookup-only resolution. `rotate_resume_token` lacks the revocation guard present in every other write operation, and `get_conversation_by_resume_token` uses `Repo.get!` in a spot that should never raise. |
| lib/custyard/auth/token.ex | New SHA-256 hash-at-rest primitive. Correct: 256-bit entropy, url-safe base64, deterministic hash for indexed lookup, plaintext never persisted. |
| lib/custyard/prospect.ex | New Prospect schema with well-scoped changesets: create (token hash + FK only), capture_email (write-once, normalizes before validation), rotate, revoke. Cast lists and field guards are tight. |
| lib/custyard/intake_source.ex | New IntakeSource schema. Key regex uses `\A`/`\z` anchors (not `^`/`$`) to block trailing-newline bypass. Q&A validation rejects unknown keys, enforces entry and field-length caps. |
| lib/custyard/email/sender_matcher.ex | New `resolve/1` (lookup-only): sentinel org excluded on both the contact and domain paths, oldest-contact tie-break logged. Doesn't create rows; webhook `match/1` is untouched. |
| lib/custyard/conversation.ex | Adds `:public_intake` source, `intake_source_key` (creation-only via `intake_changeset/2`), `has_one :prospect`, and extends `@org_exempt_sources` to cover `:public_intake`. Key format re-validated on intake changeset. |
| lib/custyard/conversations.ex | Adds `reply_channel/1` (derived, never stored) and preloads prospect in `list_for_attention_queue/0`. Preload-guard logic is correct. |
| priv/repo/migrations/20260705150001_create_prospects.exs | Prospects table: unique index on both `conversation_id` (1:1) and `resume_token_hash` (indexed lookup). `on_delete: :delete_all` FK to conversations. Correct. |
| priv/repo/migrations/20260705150002_create_intake_sources.exs | Intake sources table: `questions` stored as `:text` with `"[]"` default, matching the `{:array, :map}` Ecto type's JSON serialization on SQLite (consistent with `projects.tags` precedent). |
| lib/custyard_web/components/operator_components.ex | Refactors `source_badge` color logic into private `source_colors/1` clauses; adds `intake_source_tag` and `no_reply_channel_badge` components. Both are badges only, never filters. |
| test/custyard/intake_test.exs | 446-line test suite covering the full intake lifecycle including hash-at-rest pin, enumeration neutrality, write-once email, sentinel exclusion, and operator-linkage-wins behavior. |

### Claude review bot

**Claude encountered an error** ——

---
I'll analyze this and get back to you.


---

## PR #62 — Add generic rate limiting: sliding-window limiter, public plug, client IP (intake stack 4/9)

Merged: 2026-07-07T04:48:41Z

### Inline comments

#### [Copilot] `lib/custyard_web/client_ip.ex:127`

`address_to_string/1` can raise if `conn.remote_ip` / `peer_data.address` is nil or not a valid inet tuple. This contradicts the module docs (“extraction never raises…”, fallback to "unknown") and would turn malformed/missing peer data into a 500.

#### [Copilot] `test/custyard_web/client_ip_test.exs:24`

This setup mutates global application env but doesn’t restore the previous value on exit. That can make unrelated tests order-dependent/flaky if they rely on a non-default `:trust_proxy_headers` value.

#### [Copilot] `test/custyard_web/client_ip_test.exs:61`

This setup deletes the env key on exit instead of restoring the prior value. If another test configured `:trust_proxy_headers` (or future test config does), this can leak state across tests.

#### [Copilot] `test/custyard/rate_limit_test.exs:119`

If `:rate_limit_buckets` was previously unset, `original` will be `nil` and the on_exit hook will set the env key to `nil` (not delete it). That can cause `bucket_config!/1` to crash later because it expects a keyword list.

#### [greptile-apps[bot]] `lib/custyard_web/plugs/public_rate_limit.ex:36`

[P2]  Bucket config is not validated at startup. `PublicRateLimit.init/1` only checks that `:bucket` is present in opts; a typo like `bucket: :intake_pst` compiles and starts cleanly, but the first real request to that route raises `ArgumentError` and serves a 500. Since `bucket_config!/1` is a pure `Application.get_env` call (no GenServer, no ETS), it's safe to call from `init/1` — which in Phoenix runs at compile time for router-defined plugs. The test suite would need one adjustment: the "unconfigured bucket" test would move from asserting on `call/2` to asserting on `init/1`.

```suggestion
  @impl true
  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    # Validate at compile/startup time so a typo in a router plug fails
    # loudly before any request is served (bucket_config! is config-only,
    # no GenServer or ETS involved).
    RateLimit.bucket_config!(bucket)
    %{bucket: bucket}
  end
```

#### [greptile-apps[bot]] `lib/custyard/rate_limit.ex:160`

[P2]  **`:public` table weakens the serialization guarantee**

The moduledoc's core correctness claim — "count-then-insert is atomic" — is enforced by convention rather than the ETS access mode. Because the table is `:public`, any process can write to it; `sweep/1` and `reset/0` already do. If a future contributor calls `sweep/1` from a non-GenServer context in production code (not tests), concurrent `handle_call({:check_rate, ...})` messages could race the `select_delete` against the window read, causing a false deny without a corresponding insert. A `:protected` table would make the invariant enforceable by the runtime instead of the code review. The trade-off is that `reset/0` and the public `sweep/1` would need to become `GenServer.call` wrappers — a small cost in test convenience for a long-term correctness signal.

### Copilot PR overview

## Pull request overview

Introduces a generic, ETS-backed sliding-window rate limiter intended for anonymous “public intake” surfaces, plus a shared client-IP extraction module (for both Plug and LiveView paths) and associated configuration/templates/tests.

**Changes:**
- Adds `Custyard.RateLimit` GenServer owning a named ETS table with serialized `check_rate/2` checks and periodic sweeping.
- Adds `CustyardWeb.ClientIP` (HTTP + LiveView connect_info) and a new `CustyardWeb.Plugs.PublicRateLimit` that returns a structured 429 with `Retry-After`.
- Updates `LoginRateLimit` to delegate client-IP extraction (including rightmost-XFF behavior) and expands regression coverage.

### Reviewed changes

Copilot reviewed 12 out of 13 changed files in this pull request and generated 4 comments.

Show a summary per file

| File | Description |
| ---- | ----------- |
| test/custyard/rate_limit_test.exs | New tests for sliding-window semantics, sweep/reset, config resolution, and serialization. |
| test/custyard_web/plugs/login_rate_limit_test.exs | Updates/extends tests to reflect `ClientIP` extraction behavior (rightmost XFF, garbage fallback). |
| test/custyard_web/client_ip_test.exs | New test coverage for HTTP + LiveView client IP extraction and trust gating. |
| lib/custyard/rate_limit.ex | New generic sliding-window limiter with ETS storage, GenServer serialization, and sweep/reset utilities. |
| lib/custyard/application.ex | Supervises the new `Custyard.RateLimit` process. |
| lib/custyard_web/plugs/public_rate_limit.ex | New plug enforcing configured buckets and rendering standard 429 + `Retry-After`. |
| lib/custyard_web/plugs/login_rate_limit.ex | Delegates IP extraction to `CustyardWeb.ClientIP` and documents behavior deltas. |
| lib/custyard_web/endpoint.ex | Adds `:peer_data` / `:x_headers` connect_info for LiveView IP-based limiting. |
| lib/custyard_web/controllers/error_html/429.html.heex | Adds a standard 429 error page template. |
| lib/custyard_web/client_ip.ex | New shared IP extraction module for Plug + LiveView with proxy-header trust boundary. |
| config/runtime.exs | Enables `:trust_proxy_headers` in prod when `FLY_APP_NAME` is present. |
| config/config.exs | Adds default `:rate_limit_buckets` app configuration. |

---

💡 Add Copilot custom instructions for smarter, more guided reviews. Learn how to get started.

### Greptile review

Confidence Score: 4/5

Safe to merge for the substrate layer it introduces; no router consumer is wired until 6/9, so the only live risk is the LoginRateLimit XFF change which is intentional, tested, and documented.

The concurrency model is solid, the security fixes in ClientIP are correct, and the test coverage is thorough. The one actionable gap is that PublicRateLimit.init/1 doesn't validate the bucket name at startup — a typo in a future router plug would silently pass startup and then 500 on first request rather than crashing at boot. Everything else checks out.

lib/custyard_web/plugs/public_rate_limit.ex — the init/1 bucket validation gap; lib/custyard/rate_limit.ex — the :public ETS table vs. the serialisation claim in the moduledoc.

Important Files Changed

| Filename | Overview |
|----------|----------|
| lib/custyard/rate_limit.ex | New GenServer-owned ETS sliding-window limiter. Serialization model is sound; retry_after math is correct. Minor tension between :public table access and the "all writes serialize through GenServer" claim. |
| lib/custyard_web/client_ip.ex | Clean extraction of proxy-trust discipline. rightmost-XFF logic is correct, fallback chain handles malformed input, LiveView variant documented and tested. |
| lib/custyard_web/plugs/public_rate_limit.ex | Plug is thin and correct; Retry-After ceiling-division is right. init/1 does not validate the bucket name against app config, so a typo surfaces as a 500 on first request rather than a startup failure. |
| lib/custyard_web/plugs/login_rate_limit.ex | IP extraction delegated to ClientIP; leftmost→rightmost XFF change and garbage-header fallthrough documented and pinned by regression tests. |
| config/runtime.exs | trust_proxy_headers gated on FLY_APP_NAME; secure default (off) outside Fly. PR calls out the one-time env verify needed. |
| lib/custyard_web/endpoint.ex | Added :peer_data and :x_headers to both websocket and longpoll connect_info for LiveView rate limiting; no other changes. |
| test/custyard/rate_limit_test.exs | Comprehensive coverage: sliding-window semantics, serialization under 50 concurrent tasks, sweep correctness, config resolution, and bucket isolation all pinned. |
| test/custyard_web/client_ip_test.exs | Tests cover rightmost-XFF, spoofed-leftmost regression, malformed header fallback, IPv6, and LiveView peer_data paths. |
| test/custyard_web/plugs/public_rate_limit_test.exs | Tests cover allow/deny lifecycle, Retry-After header, per-bucket isolation, distinct-client isolation, and malformed-header fallback. |
| test/custyard_web/plugs/login_rate_limit_test.exs | Regression tests updated to reflect rightmost-XFF change; garbage-header-falls-to-peer test is new and correctly pins the security fix. |
| config/config.exs | Eight bucket configs added; limits and windows look reasonable for their stated purposes. |
| lib/custyard/application.ex | RateLimit GenServer added before TaskSupervisor and Endpoint; correct placement in supervision tree. |
| lib/custyard_web/controllers/error_html/429.html.heex | Minimal 429 template with data-testid for test assertions; consistent with the existing error view pattern. |

### Claude review bot

**Claude finished @delano's task** ——

---
### PR #62 Review: Rate Limiting Implementation

**Overall Assessment: Approve with minor suggestions**

This is a well-designed rate limiting implementation with solid security properties. The code demonstrates good understanding of concurrency concerns (GenServer serialization) and proxy header security (rightmost XFF). The PR addresses previously identified issues - I can confirm that both Greptile findings have already been resolved.

---

### Resolved Review Comments

**Issue 1: Bucket validation at startup** - **Already fixed**

The current `init/1` at `lib/custyard_web/plugs/public_rate_limit.ex:31-35` validates the bucket config at boot time:
```elixir
def init(opts) do
  bucket = Keyword.fetch!(opts, :bucket)
  RateLimit.bucket_config!(bucket)  # Validates at startup
  %{bucket: bucket}
end
```
This correctly fails loudly on a typo like `:intake_pst` before any request is served.

**Issue 2: `:protected` ETS table** - **Already fixed**

At `lib/custyard/rate_limit.ex:154-156`, the table is `:protected`:
```elixir
:ets.new(@table, [
  :duplicate_bag,
  :protected,  # Not :public
  ...
])
```
Both `sweep/1` and `reset/0` route through `GenServer.call/2` (lines 137-147), preserving the serialization guarantee.

---

### Strengths

1. **Sound concurrency model** (`rate_limit.ex:6-15`): The GenServer serialization for `check_rate` prevents the race condition where concurrent requests at `limit - 1` could all observe an under-limit count. The moduledoc clearly documents why this differs from `LoginRateLimit`.

2. **Correct X-Forwarded-For handling** (`client_ip.ex:98-110`): The rightmost entry selection is the correct approach - proxies append, so only the rightmost is authoritative. Well-documented and tested.

3. **Comprehensive test coverage**:
   - Sliding window semantics pinned (not fixed-window reset) in `rate_limit_test.exs:26-40`
   - Concurrency test with 50 parallel tasks (`rate_limit_test.exs:89-100`)
   - XFF spoofing regression tests (`client_ip_test.exs:79-87`, `login_rate_limit_test.exs:224-245`)

4. **Clean separation of concerns**: `ClientIP` extracted for reuse across HTTP plugs and LiveView sockets.

5. **Proper LiveView support** (`endpoint.ex:36-47`): `:peer_data` and `:x_headers` in `connect_info` enable rate limiting on websocket connections.

---

### Minor Suggestions

**1. Copilot's concern about `address_to_string/1` potentially raising** (`client_ip.ex:122-127`)

The current implementation:
```elixir
defp address_to_string(address) do
  case :inet.ntoa(address) do
    {:error, _reason} -> "unknown"
    chars -> to_string(chars)
  end
end
```

`:inet.ntoa/1` can raise `ArgumentError` if `address` is `nil` or not a valid inet tuple. While `conn.remote_ip` should always be a valid tuple in normal operation, consider adding a guard:

```elixir
defp address_to_string(address) when is_tuple(address) do
  case :inet.ntoa(address) do
    {:error, _reason} -> "unknown"
    chars -> to_string(chars)
  end
end
defp address_to_string(_other), do: "unknown"
```

This ensures the moduledoc promise of "extraction never raises on malformed input" holds under all edge cases.

**2. Test env restoration** (`client_ip_test.exs`, `rate_limit_test.exs`)

Copilot flagged that some test setups don't properly restore the original env value when it was `nil`. The pattern used in most places is correct:
```elixir
if original do
  Application.put_env(...)
else
  Application.delete_env(...)
end
```

This is fine, but consider using a helper to ensure consistency. The `rate_limit_test.exs:111-117` pattern is correct.

**3. Consider documenting the trust boundary assumption**

The rightmost-XFF logic assumes exactly one trusted appending edge (Fly). The moduledoc at `client_ip.ex:17-23` mentions this, but consider adding a runtime warning or config option if a CDN is fronted later. This is mentioned in the PR description - just noting it for the record.

---

### Security Analysis

- **Rate limit bypass via header spoofing**: Mitigated by rightmost-XFF selection and `trust_proxy_headers` gating
- **Resource exhaustion**: Bounded by periodic sweep (`rate_limit.ex:28-34`)
- **Denial of service on legitimate users**: Denied requests don't extend the window (`rate_limit.ex:24`)
- **Frame-a-victim attack**: Blocked by rightmost-XFF (attacker-supplied entries are left of the authoritative one)

The `FLY_APP_NAME` gating in `runtime.exs:167-169` is a good security default - proxy headers are only trusted when deployed on Fly.

---

### Summary

Solid implementation with proper security considerations. The existing review comments from Greptile have been addressed. The only actionable suggestion is the defensive guard on `address_to_string/1` to match the "never raises" documentation claim.


---

## PR #63 — Add operator config: intake sources UI and instance branding (intake stack 5/9)

Merged: 2026-07-12T02:09:16Z

### Inline comments

#### [Copilot] `lib/custyard_web/live/operator/intake_sources_live.ex:71`

`id` arrives from the client as a string and is passed directly into `Intake.get_source/1`. Other operator LiveViews defensively `Integer.parse/1` IDs to avoid crashes on forged/non-integer params; this should do the same to prevent an `Ecto.Query.CastError` from taking down the LiveView.

#### [Copilot] `lib/custyard_web/live/operator/intake_sources_live.ex:125`

`toggle_enabled` forwards the raw string `id` into `toggle_enabled/2`, which then calls `Intake.get_source/1`. For consistency with other operator LiveViews and to avoid crashes on forged/non-integer IDs, parse/validate the id before calling into the context.

#### [Copilot] `lib/custyard_web/live/operator/intake_sources_live.ex:137`

`delete` forwards the raw string `id` into `delete_source/2`, which then calls `Intake.get_source/1`. A forged non-integer id can raise and crash the LiveView; parse/validate the id first (matching the defensive pattern used elsewhere in operator LiveViews).

#### [greptile-apps[bot]] `lib/custyard_web/live/operator/intake_sources_live.ex:236`

[P2]  The edit path in `rebuild_form` calls `IntakeSource.changeset/2` (the creation changeset) rather than `update_changeset/2`. Today this is harmless — `maybe_strip_key` strips `:key` from attrs before either changeset runs, and the struct's stored key is always valid — but it means the form's live-validation profile includes `validate_required(:key)`, `validate_format(:key, …)`, and `unique_constraint(:key)` that `update_changeset/2` deliberately omits. Any future divergence between the two changesets (e.g. adding a field only valid at creation) would silently show phantom errors in the edit form without affecting the save path, which would be confusing to debug.

```suggestion
  defp rebuild_form(socket, questions) do
    base = socket.assigns.editing_source || %IntakeSource{}

    attrs =
      socket.assigns.form_params
      |> Map.put("questions", questions)
      |> maybe_strip_key(socket.assigns.editing_source)

    changeset_fn =
      if socket.assigns.editing_source, do: &IntakeSource.update_changeset/2, else: &IntakeSource.changeset/2

    changeset =
      base
      |> changeset_fn.(attrs)
      |> Map.put(:action, :validate)
```

### Copilot PR overview

## Pull request overview

This PR adds operator-facing configuration surfaces for the public-intake stack: a super-admin LiveView to manage `intake_sources` (CTA provenance + copy), and a new `settings.branding` map column with validation + an operator UI card for instance branding (name/logo/color).

**Changes:**
- Add `/operator/intake-sources` (`IntakeSourcesLive`) for CRUD on intake sources, including capped Q&A rows and enabled toggling, with key immutability enforced at the schema/context layer.
- Add `settings.branding` (JSON map) plus `Settings.get_branding/0` + `Settings.update_branding/1`, and a new Branding card in `SettingsLive`.
- Extract shared `/uploads/` path validation into `Custyard.UploadPath` and delegate organization logo validation to it.

### Reviewed changes

Copilot reviewed 16 out of 16 changed files in this pull request and generated 3 comments.

Show a summary per file

| File | Description |
| ---- | ----------- |
| test/custyard/upload_path_test.exs | Adds unit coverage for `Custyard.UploadPath` validation rules. |
| test/custyard/settings_test.exs | Adds branding read/update/validation tests, including key dropping and format enforcement. |
| test/custyard/intake_test.exs | Verifies `Intake.update_source/2` ignores attempted key changes. |
| test/custyard/intake_source_test.exs | Tests `IntakeSource.update_changeset/2` never casts `:key` and still validates content. |
| test/custyard_web/live/operator/settings_live_test.exs | Exercises Branding card UX and the settings double-gate behavior. |
| test/custyard_web/live/operator/intake_sources_live_test.exs | Adds end-to-end tests for intake source listing/create/edit/questions/toggle/delete + auth gates. |
| priv/repo/migrations/20260705160000_add_branding_to_settings.exs | Adds `branding` map column to `settings`. |
| lib/custyard/upload_path.ex | Introduces shared uploads-only path validator to prevent traversal/null-byte/external URL usage. |
| lib/custyard/settings.ex | Implements branding storage/validation and exposes `get_branding/0` + `update_branding/1`. |
| lib/custyard/organization.ex | Delegates organization `logo_url` validation to `Custyard.UploadPath`. |
| lib/custyard/intake.ex | Adds `get_source/1` and switches updates to use `IntakeSource.update_changeset/2`. |
| lib/custyard/intake_source.ex | Adds `max_questions/0`, splits create vs update changesets, and enforces key immutability on update. |
| lib/custyard_web/router.ex | Registers `/operator/intake-sources` under the super-admin live_session. |
| lib/custyard_web/live/operator/settings_live.ex | Adds Branding card UI and save handler wired to `Settings.update_branding/1`. |
| lib/custyard_web/live/operator/intake_sources_live.ex | Adds super-admin LiveView CRUD for intake sources with Q&A row management. |
| lib/custyard_web/components/layouts/operator.html.heex | Adds “Intake Sources” navigation entry. |

---

💡 Add Copilot custom instructions for smarter, more guided reviews. Learn how to get started.

### Greptile review

Confidence Score: 4/5

Safe to merge. All security-relevant paths (key immutability, upload path traversal, auth gate) have correct two-layer enforcement and are directly tested. The one finding is a design inconsistency in the edit-form validation changeset that causes no wrong behavior today.

The edit form rebuilds its changeset with `IntakeSource.changeset/2` (creation changeset) instead of `update_changeset/2`, so the live validation profile in edit mode includes key-format and key-required rules that the actual save path does not enforce. `maybe_strip_key` keeps this from surfacing now, but the two code paths are out of sync. Everything else — branding validation, upload-path extraction, auth gating, key immutability — is correct and thoroughly tested.

`lib/custyard_web/live/operator/intake_sources_live.ex` — the `rebuild_form` changeset choice for edit mode.

Important Files Changed

| Filename | Overview |
|----------|----------|
| lib/custyard_web/live/operator/intake_sources_live.ex | 596-line CRUD LiveView for intake sources; double-gate auth, two-layer key-immutability enforcement, and question-row management are all correct. One minor design mismatch: `rebuild_form` uses the creation changeset for edit-mode validation (see comment). |
| lib/custyard/settings.ex | Adds `branding` map field with whitelist validation matching the intake_config pattern. `get_branding/0` silently drops malformed DB entries before `String.to_existing_atom` — safe because the whitelist guarantees only the three known atoms reach that call. |
| lib/custyard/upload_path.ex | New shared module for upload-path validation; covers external URLs, `..`, `%2e`-encoded traversal, and null bytes. Organization.logo_url now delegates here, ensuring the two callers can't drift. |
| lib/custyard/intake_source.ex | Adds `update_changeset/2` that intentionally omits `:key` cast (immutability enforcement at the schema layer), and extracts shared content validations into `validate_content/1`. Clean and correct. |
| lib/custyard/intake.ex | Adds `get_source/1` for operator lookup and switches `update_source/2` to `update_changeset/2`. Minimal and correct. |
| lib/custyard/organization.ex | Logo URL validation refactored to delegate to `UploadPath.validate/1`; behavior is identical to the inline logic it replaces. |
| lib/custyard_web/live/operator/settings_live.ex | Adds branding card with edit/save/cancel flow matching the existing intake_config card pattern. Blank-field filtering before save correctly implements the whole-map-replace clear semantics. |
| lib/custyard_web/router.ex | Single new route inside the existing `operator_super_admin` live_session — correctly scoped. |
| priv/repo/migrations/20260705160000_add_branding_to_settings.exs | Additive migration; adds `:map` (jsonb) column with `%{}` default. Consistent with `intake_config` treatment. |
| test/custyard_web/live/operator/intake_sources_live_test.exs | 374-line test file covering listing, create, edit (including forged-key direct invocation), Q&A row management, toggle, delete, and auth double-gate. Comprehensive. |
| test/custyard/upload_path_test.exs | Covers valid paths, all traversal/encoding variants, external URLs, and non-binary inputs. |
| test/custyard/settings_test.exs | Tests cover get_branding defaults, malformed-entry filtering, round-trips, clear-on-omit semantics, traversal paths, hex format, length bounds, and blank-name rejection. |
| test/custyard/intake_source_test.exs | Adds tests for `update_changeset/2`: key is never cast (both atom and string key shapes), and content validations still fire. |
| test/custyard/intake_test.exs | Adds context-layer proof that `update_source/2` ignores `:key` in both atom and string param shapes, and verifies via `Repo.reload!`. |
| test/custyard_web/live/operator/settings_live_test.exs | Adds branding card tests: defaults render, valid save round-trips, blank/whitespace fields clear values, traversal and bad-color paths show flash errors, non-super-admin double-gate verified by direct invocation. |
| lib/custyard_web/components/layouts/operator.html.heex | Adds "Intake Sources" nav entry in both desktop and mobile sections, matching the existing Projects/Settings pattern including active-class logic and data-testid on desktop only. |

### Claude review bot

**Claude encountered an error** ——

---
I'll analyze this and get back to you.


---

## PR #64 — Add the public intake surface: intake pages and resume thread (intake stack 6/9)

Merged: 2026-07-12T02:10:45Z

### Inline comments

#### [Copilot] `lib/custyard_web/live/resume_auth.ex:42`

`RateLimit.check_rate/2` uses `client_ip || "unknown"` from `ClientIP.from_socket/1`, while the cookie-refresh plug keys `RateLimit.peek/2` by `ClientIP.from_conn/1`. When `from_socket/1` returns `nil` (e.g. connect_info missing / disconnected mount), the mount budget is enforced under the shared "unknown" key but the cookie refresh still runs under the per-IP key, which can reintroduce the deny-window Set-Cookie oracle the PR is trying to close.

Consider ensuring the HTTP request and LiveView mount use the same key (e.g. pass the HTTP-derived client IP into the LiveView via session/assigns for the disconnected mount, or split the budget into explicit HTTP+WS buckets and have the cookie plug honor the HTTP bucket).

#### [Copilot] `lib/custyard/intake.ex:318`

`add_prospect_reply/3` validates revocation and `:token_hash` against a prospect struct loaded before `do_add_prospect_reply/2` runs its transaction. If an operator revokes or rotates the token concurrently between the pre-check and the DB write, a stale handle can still insert a message and reactivate the conversation, despite the intention that rotation/revocation immediately strips access.

To make rotation/revocation cut off writes atomically, move the prospect lookup + token-hash/revocation checks into the same transaction as the message insert (ideally locking the prospect row with `FOR UPDATE`, or using a conditional update/locking strategy) so there’s no time-of-check/time-of-use window.

#### [Copilot] `lib/custyard_web/plugs/resume_cookie.ex:76`

This cookie is only *signed* (`sign: true`), which provides integrity but not confidentiality: the raw token is still present in the cookie payload (just encoded + signed). The docstring claims the token is “never readable client side without the signature”, which isn’t accurate for signed-only cookies.

If the intent is to avoid the resume bearer token appearing in logs / client-visible storage, set `encrypt: true` (and adjust the wording accordingly).

#### [Copilot] `lib/custyard/intake.ex:491`

`set_notification/3` enforces `:token_hash` by comparing against the prospect struct fetched before the write. If the token rotates between that read and `Repo.update/1`, a stale handle can still toggle notifications (TOCTOU race), which undermines the “rotation cuts off live sockets” guarantee.

Consider performing the prospect read + token-hash/revocation check under a row lock inside a transaction (or otherwise making the check part of the same atomic DB operation as the update).

#### [greptile-apps[bot]] `lib/custyard_web/plugs/resume_cookie.ex:77`

[P1]  **Nil IP key diverges from ResumeAuth's `"unknown"` fallback**

`ResumeAuth` explicitly uses `client_ip || "unknown"` when the IP is undetectable, so all nil-IP clients share one ETS key and their mount budget is bounded. `ResumeCookie` passes `ClientIP.from_conn(conn)` directly to `RateLimit.peek`, so when that returns `nil` the peek reads the `{:resume_mount, nil}` ETS slot — which is always empty — and returns `{:allow, 0}`. A client whose IP cannot be detected will exceed the `"unknown"` mount budget (in `ResumeAuth`) and get redirected, yet the `ResumeCookie` plug will still issue a cookie refresh for a valid token in that same request, because its peek sees no events. That Set-Cookie presence is exactly the validity oracle the `peek`/`ResumeAuth` split was designed to prevent.

```suggestion
         {:allow, _count} <- RateLimit.peek(:resume_mount, ClientIP.from_conn(conn) || "unknown"),
```

### Copilot PR overview

## Pull request overview

Adds the first anonymous/public-facing “public intake” web surfaces to Custyard: dead-view intake pages at `/i/:source_key` and a token-authenticated LiveView resume thread at `/r/:token`, with uniform “unavailable” handling, rate limiting, and a long-lived resume convenience cookie.

**Changes:**
- Introduces `/i/:source_key` controller-rendered intake pages (active/passive modes) plus POST submission flow that redirects to `/r/:token`.
- Adds `/r/:token` ResumeLive with mount-time token auth, mutation rate limiting, and revocation/rotation shutdown via PubSub broadcast.
- Extends the rate limiter with a non-counting `RateLimit.peek/3` and adds plugs/layouts supporting the public surfaces (no-referrer policy, resume cookie refresh, intake layouts).

### Reviewed changes

Copilot reviewed 22 out of 22 changed files in this pull request and generated 4 comments.

Show a summary per file

| File | Description |
| ---- | ----------- |
| test/custyard/rate_limit_test.exs | Adds coverage for new `RateLimit.peek/3` semantics. |
| test/custyard/intake_test.exs | Adds tests for token validity checks, rotation/revocation broadcasts, and stale-hash refusal behavior. |
| test/custyard_web/live/resume_live_test.exs | Adds end-to-end tests for ResumeLive rendering, rate limiting, mutation semantics, and enumeration neutrality. |
| test/custyard_web/controllers/intake_controller_test.exs | Adds end-to-end tests for `/i` and `/r` HTTP behavior, CSP/referrer policy, cookie behavior, and custom-domain rewriting. |
| lib/custyard/rate_limit.ex | Implements `RateLimit.peek/3` for non-counting reads of the sliding window. |
| lib/custyard/intake.ex | Adds resume token validity predicate, passive→active pairing helper, and extends resume-surface mutation guards + broadcasts. |
| lib/custyard_web/router.ex | Wires new `/i` and `/r` routes and adds dedicated public pipelines/layouts/plugs. |
| lib/custyard_web/plugs/resume_cookie.ex | Adds resume-cookie refresh plug for valid `/r/:token` HTTP GETs. |
| lib/custyard_web/plugs/no_referrer.ex | Adds `Referrer-Policy: no-referrer` plug for bearer-token-in-path surfaces. |
| lib/custyard_web/live/resume_live.ex | Implements prospect-facing resume thread UI and websocket mutation handling with rate limiting. |
| lib/custyard_web/live/resume_auth.ex | Implements on-mount token authentication + mount rate limiting for resume LiveView. |
| lib/custyard_web/controllers/resume_html/unavailable.html.heex | Adds static uniform “conversation unavailable” page template. |
| lib/custyard_web/controllers/resume_html.ex | Adds HTML template module for resume dead views. |
| lib/custyard_web/controllers/resume_controller.ex | Adds dead-view controller endpoint for uniform unavailable rendering. |
| lib/custyard_web/controllers/intake_html/resume_banner.html.heex | Adds shared “resume your conversation” banner component. |
| lib/custyard_web/controllers/intake_html/passive.html.heex | Adds passive-mode intake page template. |
| lib/custyard_web/controllers/intake_html/message_form.html.heex | Adds shared intake message form component for active/passive pages. |
| lib/custyard_web/controllers/intake_html/active.html.heex | Adds active-mode intake page template. |
| lib/custyard_web/controllers/intake_html.ex | Adds template module for intake pages/components. |
| lib/custyard_web/controllers/intake_controller.ex | Implements intake GET/POST controller with shape validation, rate limiting, cookie set, and redirect to resume. |
| lib/custyard_web/components/layouts/intake.html.heex | Adds sparse intake layout for public surfaces. |
| lib/custyard_web/components/layouts/intake_root.html.heex | Adds minimal root layout for public intake surfaces. |

---

💡 Add Copilot custom instructions for smarter, more guided reviews. Learn how to get started.

### Greptile review

Confidence Score: 3/5

One focused fix needed in ResumeCookie before merging; everything else is solid.

The overall design is careful and well-tested — token rotation cuts off live sockets, enumeration neutrality is byte-identical and directly verified, and the peek/ResumeAuth split is the right approach. The one concrete gap is in ResumeCookie.call/2: it passes the raw result of ClientIP.from_conn to RateLimit.peek while ResumeAuth applies || "unknown" for the same bucket. For any client where IP detection returns nil, the cookie plug reads a perpetually-empty ETS slot and will refresh the cookie even when that client's mount budget is exhausted — breaking the oracle prevention the moduledoc explicitly guarantees. The fix is a one-liner.

lib/custyard_web/plugs/resume_cookie.ex — the RateLimit.peek call needs `|| "unknown"` to match ResumeAuth's fallback key.

Important Files Changed

| Filename | Overview |
|----------|----------|
| lib/custyard_web/plugs/resume_cookie.ex | New plug that refreshes the signed resume cookie on valid /r GETs; the nil-IP case passes nil directly to RateLimit.peek instead of the "unknown" fallback used by ResumeAuth, breaking the oracle-prevention guarantee for clients with undetectable IPs. |
| lib/custyard/intake.ex | Adds resume_token_valid?/1, add_prospect_reply/3, first_enabled_active_source/0, and token_hash_current?/2; makes get_prospect/1 public; extends set_notification and capture_email with token_hash rotation guard; rotation/revocation now broadcast resume_access_changed. |
| lib/custyard/rate_limit.ex | Adds peek/3 — a non-counting ETS-direct read that lets ResumeCookie honor the resume_mount budget without double-billing. Implementation is clean; the nil-key issue is in the caller, not here. |
| lib/custyard_web/live/resume_auth.ex | on_mount hook that authenticates the URL token on every mount, rate-limits per client IP with correct "unknown" fallback, and redirects invalid/revoked/rate-limited requests to the uniform unavailable page. |
| lib/custyard_web/live/resume_live.ex | Prospect-facing LiveView; every mutation checks its rate bucket, passes mount-time token_hash to context, and resume_access_changed handler correctly closes sockets on rotation/revocation. Enumeration neutrality upheld. |
| lib/custyard_web/controllers/intake_controller.ex | Dead-view controller for /i/:source_key; validates body before any context call, captures optional email fire-and-forget, sets resume cookie, renders structured 422s. |
| lib/custyard_web/router.ex | Adds public_intake and resume_cookie pipelines and /i, /r scopes; /r/unavailable declared before the live route; custom-domain exclusion covered by existing rewrite. |
| lib/custyard_web/plugs/no_referrer.ex | Minimal plug setting Referrer-Policy: no-referrer to prevent bearer tokens in /r paths from leaking via the Referer header. |

### Claude review bot

**Claude finished @delano's task** ——

---
### Reviewing PR #64

---

### Summary

This is a well-designed PR that adds anonymous-facing intake surfaces with careful attention to security. The code demonstrates strong Elixir/Phoenix patterns, comprehensive test coverage (~60 new tests), and thoughtful security considerations around enumeration neutrality and rate limiting.

---

### Previously Identified Issue (Already Fixed)

The Greptile review identified a nil-IP key divergence in `ResumeCookie` (line 52). I can confirm this has already been fixed in the current code:

```elixir
{:allow, _count} <- RateLimit.peek(:resume_mount, ClientIP.from_conn(conn) || "unknown"),
```

The `|| "unknown"` fallback is now present, matching `ResumeAuth`'s behavior.

---

### Positive Highlights

1. **Enumeration neutrality**: Byte-identical responses for contact/domain/no-match cases, verified by test (`resume_live_test.exs:277-308`)

2. **Rate limiting architecture**: Clean separation with `peek/3` for non-counting reads, preventing double-billing while still honoring budgets

3. **Token rotation/revocation**: The `{:resume_access_changed, id}` broadcast properly shuts down mounted sockets - a solid solution for invalidating leaked tokens

4. **Dead views for hammerable surfaces**: Correct decision to use controller-rendered pages for `/i` instead of LiveView

5. **Security headers**: `Referrer-Policy: no-referrer` properly prevents bearer token leakage via `Referer` header

---

### Minor Observations

**1. `ClientIP.from_conn/1` never returns nil** (`lib/custyard_web/client_ip.ex:46-52`)

The function always returns a string (falls back to `"unknown"`), so the `|| "unknown"` fallback in `ResumeCookie` line 52 is technically redundant. However, keeping it is defensive programming and documents intent - not a bug.

**2. Transaction scope in `add_prospect_reply/3`** (`lib/custyard/intake.ex:334-349`)

The `authorized_prospect/2` check runs inside the transaction (`Multi.run/3`), which correctly prevents TOCTOU races for revocation/rotation. The Copilot review concern about this appears to be a misread - the code is correct.

**3. Consider extracting rate limit key building**

The `socket.assigns.client_ip || "unknown"` pattern appears in multiple places (`resume_live.ex:72,84`). A small helper could centralize this, though it's not blocking.

---

### Test Coverage

The test coverage is thorough:
- Enumeration neutrality byte-identical comparison test
- Rate limiting for all surfaces (mount, reply, email capture)
- Token rotation/revocation mid-session shutdown
- IDOR prevention (conversation ID guessing)
- Malformed input handling (non-binary, oversized)
- Custom domain exclusion regression test
- Cookie attribute verification

---

### Conclusion

This PR is ready to merge. The code quality is high, security considerations are well-addressed, and test coverage is comprehensive. The one issue identified by other reviewers (nil-IP key) has already been fixed.


---

## PR #65 — Add the slug claim: registry, confirmation, expiry, release (intake stack 7/9)

Merged: 2026-07-12T02:12:14Z

### Inline comments

#### [Copilot] `lib/custyard/slug.ex:92`

`claim_changeset/2` normalizes email via `update_change(:email, &EmailAddress.normalize/1)`, but `EmailAddress.normalize/1` only matches binaries. If `email` is nil or a non-binary (e.g., forged params / missing form field), this will raise instead of returning a changeset error, which is risky on the public surface and undermines the "invalid input returns a changeset error" contract.

#### [Copilot] `lib/custyard/intake/claim_email.ex:78`

When async delivery is enabled, `deliver/2` always returns `{:ok, :queued}` even if `Task.Supervisor.start_child/2` fails (e.g., supervisor down / max_children reached). That can cause the UI to claim an email was queued when it wasn't. Consider checking the return and falling back to synchronous delivery (or returning an error) when the task can't be started.

#### [greptile-apps[bot]] `lib/custyard_web/live/resume_live.ex:316`

[P1]  The result of `send_confirmation_email/3` is discarded here, so the flash always says "Confirmation email sent." even when `ClaimEmail.send_confirmation/2` returns `{:error, :rate_limited}` (the rate limit was hit between the advisory peek and the actual counting check) or any other mailer error. The PR description calls out exactly this class of bug as a fix applied to the initial claim path — the resend path missed it. Capture the result and branch on it the same way `put_claim_flash/2` does for the claim path. You'll need a `put_resend_flash/2` companion with resend-appropriate messages (omit "Name claimed" from the success copy).

```suggestion
          {:ok, slug, confirmation_token} ->
            send_result = send_confirmation_email(socket, slug, confirmation_token)

            {:noreply,
             socket
             |> assign(:slug_claim, slug)
             |> put_resend_flash(send_result)}
```

#### [greptile-apps[bot]] `lib/custyard/slugs.ex:185`

[P2]  `Repo.get!` will raise `Ecto.NoResultsError` if the now-confirmed row is deleted between the `update_all` returning count=1 and this read — e.g., an operator races to release the slug in that microsecond window. The same pattern appears in `rotate_confirmation_token/1`. Both callers surface this as an unhandled exception (500) rather than a graceful `{:error, :invalid}`. Using `Repo.get` with an explicit nil branch is the safer shape.

```suggestion
        if count == 1 do
          case Repo.get(Slug, id) do
            %Slug{} = slug -> {:ok, slug}
            nil -> {:error, :invalid}
          end
        else
          {:error, :invalid}
        end
    end
  end

  def confirm(_token), do: {:error, :invalid}
```

### Copilot PR overview

## Pull request overview

This PR introduces the “slug claim” subsystem for the public-intake stack: a single-table slug registry with claim/confirm/expiry/release mechanics, scanner-safe confirmation via `/c`, confirmation email delivery, and an operator UI to inspect/release slugs.

**Changes:**
- Adds the `slugs` registry (migration + `Custyard.Slug` schema + `Custyard.Slugs` context) including expiry sweep and DB-enforced invariants.
- Implements slug claim UX on `ResumeLive`, confirmation dead-views under `/c`, and confirmation email composition/delivery with shared header sanitization.
- Adds operator-facing `/operator/slugs` view + release flow with `:slug_released` audit events and extensive tests.

### Reviewed changes

Copilot reviewed 32 out of 32 changed files in this pull request and generated 2 comments.

Show a summary per file

| File | Description |
| ---- | ----------- |
| test/support/failing_mailer_adapter.ex | Test-only Swoosh adapter to simulate delivery failure paths. |
| test/support/factory.ex | Factory helpers for building/inserting slug registry rows. |
| test/custyard/slugs/claim_expiry_test.exs | Tests for expiry sweep behavior and injected clock semantics. |
| test/custyard/slugs_test.exs | End-to-end tests for claim/confirm/rotate/release/availability/DB CHECK constraints. |
| test/custyard/slug_test.exs | Unit tests for slug changeset normalization/format/reserved words/email validation. |
| test/custyard/intake/claim_email_test.exs | Tests for claim confirmation email composition, rate limits, and failure behavior. |
| test/custyard/email/headers_test.exs | Tests for shared email header sanitization/quoting helpers. |
| test/custyard/audit_event_test.exs | Extends event type coverage to include `:slug_released`. |
| test/custyard_web/live/resume_live_test.exs | LiveView tests for the Resume slug-claim panel behavior and rate limiting. |
| test/custyard_web/live/operator/slugs_live_test.exs | Tests for operator listing/release and authorization double-gate. |
| test/custyard_web/controllers/claim_confirmation_controller_test.exs | Tests for scanner-safe `/c` GET peek, POST consume, oracle neutrality, and rate limiting. |
| priv/repo/migrations/20260705170000_create_slugs.exs | Raw-SQL CREATE TABLE with CHECK constraints + indexes for registry invariants. |
| lib/custyard/slugs/claim_expiry.ex | Hourly GenServer sweep to delete expired claimed rows. |
| lib/custyard/slugs.ex | Core registry API: claim/peek/confirm/rotate/release/availability/listing/expiry deletion. |
| lib/custyard/slug.ex | Slug schema + claim changeset validation/normalization and reserved list. |
| lib/custyard/intake/claim_email.ex | Claim confirmation email composition/delivery with rate limiting and header discipline. |
| lib/custyard/email/outbound.ex | Delegates header sanitization/quoting to shared `Custyard.Email.Headers`. |
| lib/custyard/email/headers.ex | New shared helper module for header sanitization and display-name quoting. |
| lib/custyard/audit_event.ex | Expands audit event types and updates moduledoc scope. |
| lib/custyard/application.ex | Supervises intake sweep process behind `:start_intake_sweeps` flag. |
| lib/custyard_web/router.ex | Adds `/c/:token` routes and operator `/operator/slugs` LiveView route. |
| lib/custyard_web/plugs/no_referrer.ex | Updates docs and scope listing to include `/c`. |
| lib/custyard_web/live/resume_live.ex | Adds claim form/panel, claim+email capture sequencing, resend flow, and UI. |
| lib/custyard_web/live/resume_auth.ex | Updates docs around plaintext token handling vs hash-based auth. |
| lib/custyard_web/live/operator/slugs_live.ex | New operator LiveView to list/release slugs with audit logging. |
| lib/custyard_web/controllers/claim_confirmation_html/unavailable.html.heex | Unavailable confirmation template (uniform failure page). |
| lib/custyard_web/controllers/claim_confirmation_html/show.html.heex | GET peek template with confirm form. |
| lib/custyard_web/controllers/claim_confirmation_html/confirmed.html.heex | POST success template (no resume URL leakage). |
| lib/custyard_web/controllers/claim_confirmation_html.ex | HTML template module for claim confirmation pages. |
| lib/custyard_web/controllers/claim_confirmation_controller.ex | `/c` controller: GET peek, POST confirm, rate limit, uniform failure rendering. |
| lib/custyard_web/components/layouts/operator.html.heex | Adds operator nav link to the Slugs page. |
| config/test.exs | Disables intake sweeps in test to avoid sandbox conflicts and enable deterministic testing. |

---

💡 Add Copilot custom instructions for smarter, more guided reviews. Learn how to get started.

### Greptile review

Confidence Score: 3/5

The slug registry, migration, confirmation controller, and operator surface are solid; one correctness gap in the resend path means the panel lies to the prospect when a confirmation email is not actually sent.

The resend confirmation path discards the delivery result and unconditionally tells the prospect to check their email, even when the rate limit was exhausted between the advisory peek and the actual send, or when the mailer fails. This is the exact honesty issue the PR author caught and fixed in the initial claim path — it was missed on the resend branch. That gap, combined with the theoretical Repo.get! raise on a post-update concurrent delete, leaves the live panel with incorrect user-facing feedback in reachable conditions.

lib/custyard_web/live/resume_live.ex — resend_confirmation/2 needs the same send-result branching as the initial claim path. lib/custyard/slugs.ex — confirm/1 and rotate_confirmation_token/1 use Repo.get! after update_all where Repo.get with nil handling would be safer.

Important Files Changed

| Filename | Overview |
|----------|----------|
| lib/custyard_web/live/resume_live.ex | Claim panel logic is well-structured; `resend_confirmation/2` discards the `send_confirmation_email/3` result and unconditionally flashes success — the same honesty fix applied to the initial claim path was missed here. |
| lib/custyard/slugs.ex | Core slug registry context: claim/confirm/rotate/release/expiry all correct; lazy-expiry inside the claim transaction is well-designed; `Repo.get!` after `update_all` in `confirm/1` and `rotate_confirmation_token/1` can raise on a concurrent operator delete in the tiny window after the update. |
| lib/custyard/slug.ex | Schema and changeset for slug registry: validation, normalization, reserved-word enforcement, and punycode guard all look correct and well-tested. |
| priv/repo/migrations/20260705170000_create_slugs.exs | Raw-SQL CREATE TABLE with both DB CHECK constraints (status enum + provisioned↔org_id pairing), partial unique indexes on conversation_id/org_id/token_hash, and supporting indexes — all appropriate for SQLite's constraint model. |
| lib/custyard/intake/claim_email.ex | Confirmation email composer: follows the LoginEmail pattern, applies Headers discipline, body contains only server-controlled values (slug, platform URLs) with no prospect content — XSS and spam-relay risks correctly mitigated. |
| lib/custyard_web/controllers/claim_confirmation_controller.ex | Scanner-safe GET peek / POST confirm controller; all four failure classes (invalid/expired/used/purged) render one identical page with no validity oracle — correct. |
| lib/custyard_web/live/operator/slugs_live.ex | Operator slug list + release: double-gated (live_session + event re-check), conditional delete prevents stale-click promotion races, audit event on release — all correct. |
| lib/custyard/slugs/claim_expiry.ex | Hourly sweep GenServer with injectable clock, rescue-wrapped sweep, off in test — follows the existing scheduler pattern correctly. |
| lib/custyard_web/router.ex | Adds `/c/:token` (GET peek) and `/c/:token/confirm` (POST consume) under `:public_intake` pipeline, and `/operator/slugs` live view — all under correct pipe_through and auth gates. |
| lib/custyard/email/headers.ex | Extracted shared header-discipline helpers (sanitize_header_text, quote_display_name); behavior is byte-identical to the Outbound privates it replaces. |

### Claude review bot

**Claude finished @delano's task** ——

---
### PR #65 Review: Slug Claim Registry

---

### Summary

This is a well-architected implementation of the slug registry with strong defensive design. The scanner-safe confirmation pattern (GET peek, POST consume), the race-safe conditional updates, and the unified failure rendering are all solid. The code follows established codebase patterns and maintains consistency with existing modules like `LoginEmail`.

### Previously Identified Issues (Already Fixed)

I reviewed the two issues flagged by Greptile, and I can confirm **both have already been addressed**:

1. **Resend flash issue** (`resume_live.ex:310-316`): The `resend_confirmation/2` function now properly captures `send_result` and passes it to `put_resend_flash/2` at line 316. The `put_resend_flash/2` helper exists at lines 333-342 with appropriate messages for success and failure cases.

2. **Repo.get! race condition** (`slugs.ex:181-185`): The code uses in-memory struct patching after `update_all` instead of re-fetching via `Repo.get!`. Lines 181-196 in `confirm/1` and lines 221-229 in `rotate_confirmation_token/1` both patch the already-held struct directly, avoiding any potential race with concurrent deletes.

### Code Quality Observations

**Strengths:**

- **Security**: Scanner-safe confirmation (zero state change on GET), single-use tokens with hash-only storage, rate limiting at multiple layers (IP, email, token)
- **Race safety**: Conditional updates via `update_all` with count checks, unique indexes as the arbiters
- **Enumeration neutrality**: All failure classes render identically, no validity oracle exposed
- **Clean architecture**: Proper separation between `Slug` (schema/validation), `Slugs` (context/business logic), and `ClaimEmail` (delivery)

**Minor Considerations (not blockers):**

1. **`lib/custyard/intake/claim_email.ex:70-74`** - The Copilot comment about `Task.Supervisor.start_child` failure is addressed by returning `{:error, :queue_failed}`, which would propagate to the flash. This is acceptable.

2. **`lib/custyard/slug.ex:91`** - The `EmailAddress.normalize/1` call on line 91 handles non-binary input safely (returns it unchanged per `email_address.ex:64`), allowing the subsequent `validate_required` to surface the error properly.

3. **Migration constraints** - The raw SQL `CREATE TABLE` with CHECK constraints is the correct approach for SQLite's constraint model. Both the status enum and the `provisioned ↔ organization_id` pairing invariant are properly enforced.

### Test Coverage

The test suite appears comprehensive with ~85 new tests covering:
- Claim/confirm/rotate/release flows
- Rate limiting edge cases
- Scanner-safe peek behavior
- Expiry sweep mechanics
- Reserved word enforcement

### Verdict

This PR is well-implemented and ready. The issues flagged by previous reviewers have already been resolved in the current code.

---


---

## PR #66 — Consent-gated outbound to prospects: :withheld status, From identity, retention split (intake stack 8/9)

Merged: 2026-07-12T02:19:25Z

### Inline comments

#### [Copilot] `lib/custyard_web/live/operator/conversation_live.ex:138`

This branch checks `conversation.source` from the pre-reload snapshot, but the socket has just been reloaded. Using the stale local `conversation` can lead to inconsistent behavior if the conversation source ever changes (or if this pattern is copied to other fields). Prefer reading from `socket.assigns.conversation` after `reload_conversation/1`.

#### [Copilot] `lib/custyard/conversations.ex:888`

The retention split query doesn't account for `conversations.source` being NULL. In SQL, `NULL != :public_intake` evaluates to NULL (not true), so resolved conversations with a NULL source would never be purged. Since the column was added without `null: false` (migration 20260325060001), it’s safer to treat NULL as non-intake here.

#### [greptile-apps[bot]] `lib/custyard/conversations.ex:412`

[P2]  **`reply_delivery/1` can silently return stale results when called with a preloaded struct**

`preload_reply_channel_assocs/1` skips the DB read when both `:contact` and `:prospect` are already loaded — it checks `Ecto.assoc_loaded?` but never forces a re-read. Every call site in this PR is correct: `send_reply/3` force-preloads before calling `reply_deliverable?/1`, `Outbound.deliver/1` force-preloads before calling `reply_channel/1`, and `assign_reply_delivery/2` receives a freshly loaded struct from `get_with_messages/1`. But the public API has no contract on freshness. A future caller who passes a socket-snapshot conversation (both assocs loaded, ages old) will get a stale consent decision with no warning. Worth adding a freshness note to the docstring — something like "callers must ensure associations reflect committed DB state; force-preload before calling when in doubt."

#### [greptile-apps[bot]] `lib/custyard/email/outbound.ex:170`

[P2]  **`branding_name()` now runs a DB read for all nil-org mail, not just public-intake**

Before this PR, the nil-org fallback in `from_name/1` returned `"Custyard"` — a constant. Now it calls `branding_name()` → `Settings.get_branding()`, which is a DB round-trip on every email composition. The public-intake clause (`defp from_name(%{source: :public_intake})`) is intentional. The catch-all clause is the unintended wider scope. If `Settings.get_branding/0` is uncached this adds a query per outbound email for every non-intake conversation that lacks an organization. The PR description acknowledges the scope creep ("unpinned in the non-intake direction") but the code has no comment to that effect, so the next developer won't know this is a carry-forward rather than deliberate design.

#### [greptile-apps[bot]] `lib/custyard_web/live/operator/conversation_live.ex:143`

[P2]  **Flash suppression uses current deliverability, not the delivery status of the message just sent**

`reply_will_email?` is recomputed by `reload_conversation()` before the `cond` runs. It reflects the prospect's consent state at reload time, not at send time. If the prospect toggles consent in the window between `send_reply/3` (which withheld the message) and `reload_conversation()`, `reply_will_email?` can be `true` even though the message was inserted as `:withheld` — the flash is suppressed and no advisory explains what happened. The withheld indicator on the message itself is authoritative, so there is no data loss, but the operator sees a confusing silent state. This could be made accurate by checking the returned message's `delivery_status` directly rather than the recomputed socket assign.

### Copilot PR overview

## Pull request overview

This PR extends the public-intake “prospect channel” flow to be consent-gated end-to-end, introducing a `:withheld` delivery status for replies that are recorded but deliberately not emailed, while also hardening outbound From-identity and improving email threading and retention behavior.

**Changes:**
- Add `:withheld` delivery status and enforce a two-layer consent gate (primary in `Conversations.send_reply/3`, secondary in `Email.Outbound.deliver/1`).
- Ensure public-intake outbound mail uses platform From-address + instance branding display name (preventing operator/org From leaks) and improve prospect threading via synthetic Message-IDs for web replies.
- Split retention: non-intake resolved conversations purge at the existing bound; `:public_intake` retains longer and purges cascade to prospect resume tokens; operator UI reflects `:withheld` state and consent advisories.

### Reviewed changes

Copilot reviewed 10 out of 10 changed files in this pull request and generated 2 comments.

Show a summary per file

| File | Description |
| ---- | ----------- |
| test/custyard/message_test.exs | Extends delivery status coverage to include `:withheld`. |
| test/custyard/email/outbound_test.exs | Adds public-intake prospect delivery matrix tests (consent, From identity, threading, header discipline). |
| test/custyard/conversations_test.exs | Adds send-reply consent-gate tests and retention split tests (including purge cascade to prospect). |
| test/custyard_web/live/resume_live_test.exs | Verifies purged resume tokens land on the uniform unavailable page. |
| test/custyard_web/live/operator/conversation_live_test.exs | Validates operator UI behavior for `:withheld` and consent advisory visibility. |
| lib/custyard/message.ex | Introduces `:withheld` and documents its intent vs provider-side suppression. |
| lib/custyard/intake.ex | Generates synthetic RFC 5322 Message-IDs for prospect web messages and broadcasts on consent flips. |
| lib/custyard/email/outbound.ex | Adds defense-in-depth consent re-check, recipient fallback to prospect email, and From-name branding behavior. |
| lib/custyard/conversations.ex | Implements reply deliverability classification, primary consent gate, and retention split for `:public_intake`. |
| lib/custyard_web/live/operator/conversation_live.ex | Adds consent advisory, `:withheld` delivery indicator, and deliverability assigns used by the UI. |

---

💡 Add Copilot custom instructions for smarter, more guided reviews. Learn how to get started.

### Greptile review

Confidence Score: 4/5

Safe to merge. The consent gate is correct at both layers, the force-preload discipline is sound across every call site, and the test coverage is thorough. Nothing sends to a non-consenting prospect; the worst observable behavior under a consent-toggle race is a misleading or absent operator flash — the delivery indicator in the thread is always authoritative.

Three non-blocking findings: the public reply_delivery/1 API has no freshness contract in its docstring (a footgun for future callers), branding_name() quietly added a DB read to all nil-org email composition (not just intake, as intended), and the post-send flash uses recomputed deliverability rather than the actual delivery status of the message just sent. None of these affect correctness of the consent gate or data integrity.

lib/custyard/conversations.ex (reply_delivery/1 docstring), lib/custyard/email/outbound.ex (from_name fallback scope), and lib/custyard_web/live/operator/conversation_live.ex (flash suppression logic) are the three spots worth a second look before the next developer touches them.

Important Files Changed

| Filename | Overview |
|----------|----------|
| lib/custyard/conversations.ex | Adds reply_delivery/1, reply_deliverable?/1, and the consent gate in send_reply/3. Force preload before calling reply_deliverable? is correct. The cleanup_resolved_conversations query silently drops NULL-source rows (acknowledged carry-forward, schema default prevents it in practice). Logic is sound. |
| lib/custyard/email/outbound.ex | Secondary consent gate via resolve_recipient, from_name public-intake clause, and branding_name fallback. The from_name non-intake fallback now calls branding_name() (DB read) for all nil-org mail, broadening scope beyond intake. Current behavior is reasonable, but the change is undocumented in the code. |
| lib/custyard/intake.ex | Adds synthetic Message-IDs to prospect web messages and broadcasts {:conversation_updated} on set_notification. Both changes are correct and well-scoped. broadcast_notification_change correctly gates on {:ok, _}. |
| lib/custyard/message.ex | Adds :withheld to @delivery_statuses. No migration needed (Ecto.Enum stored as string in SQLite). Change is minimal and correct. |
| lib/custyard_web/live/operator/conversation_live.ex | Adds assign_reply_delivery, the :withheld delivery indicator, and the consent advisory. The post-send flash logic uses reply_will_email? (current consent state after reload, not delivery status of the just-sent message) — a minor category mismatch, but the withheld delivery indicator in the thread is authoritative. |
| test/custyard/conversations_test.exs | New describe blocks cover both consent gate layers, delivery matrix, retention split, cascade, and From-identity leak. The fresh/1 helper correctly re-reads from DB. Coverage is thorough. |
| test/custyard/email/outbound_test.exs | Adds prospect-channel, From-identity leak regression, and header-discipline tests. intake_message_fixture correctly bypasses send_reply/3 to exercise the secondary gate directly. |
| test/custyard_web/live/resume_live_test.exs | Adds retention purge test: verifies prospect cascade, token resolution failure, and uniform unavailable page. Correct end-to-end coverage. |

### Claude review bot

**Claude finished @delano's task** ——

---
### Review of PR #66: Consent-gated outbound to prospects

---

**Overall Assessment: Well-designed and thoroughly tested implementation**

This PR implements a robust two-layer consent gate for public-intake conversations with excellent test coverage (1712 tests). The architecture is sound, the code follows Elixir/Phoenix best practices, and the security considerations are well-handled.

---

### Strengths

**1. Defense-in-depth consent architecture**
The two-layer consent gate is well-designed:
- Primary: `send_reply/3` force-preloads prospect and computes deliverability
- Secondary: `Outbound.deliver/1` independently re-checks with fresh DB state

**2. Comprehensive test coverage**
- Tests for every consent state (opted-in, no-consent, revoked, no-email)
- Delivery matrix tests exercise both layers
- Edge cases like consent toggles between replies are covered
- Header injection tests pin security properties

**3. Clean separation of concerns**
- `:withheld` is deliberately distinct from `:suppressed` (per issue #25)
- Source-keyed From-identity rule is explicit and well-documented
- Synthetic Message-IDs enable proper email threading

---

### Issues Identified

**Issue 1: Stale association risk in `reply_delivery/1` (P2)**
`lib/custyard/conversations.ex:391-412`

The docstring now correctly documents the freshness contract (lines 391-396), but future callers who don't read it could pass stale associations. The current implementation relies on documentation rather than enforcement.

*Current state:* Acceptable given all call sites are correct, and the docstring now explicitly warns callers.

**Issue 2: `branding_name()` scope creep (P2)**
`lib/custyard/email/outbound.ex:162-170`

The catch-all `from_name/1` clause now calls `branding_name()` for all nil-org conversations, not just `public_intake`. This adds a DB read per email for non-intake nil-org mail. The PR description acknowledges this as a carry-forward, but no code comment documents it.

*Recommendation:* Add a comment at line 162 explaining the scope creep is known and deferred.

**Issue 3: Flash uses recomputed deliverability (P3)**
`lib/custyard_web/live/operator/conversation_live.ex:121-143`

The `cond` at line 121 now correctly checks `message.delivery_status == :withheld` first (line 125), which is ground truth. This addresses the race condition concern. The remaining branches that check `socket.assigns.reply_will_email?` are secondary fallbacks.

*Current state:* Fixed — the message's actual delivery status takes precedence.

---

### Copilot's Issue: Pre-reload snapshot concern

The Copilot comment about using `conversation.source` from a pre-reload snapshot at line 133 is technically valid but not a bug:
- `conversation.source` is immutable after creation
- The check is gating flash suppression, not security-critical logic
- The subsequent `reload_conversation()` ensures the full socket state is fresh

---

### Minor Observations

1. **Retention query NULL handling** (`conversations.ex:887-889`): The `is_nil(c.source) or c.source != :public_intake` clause correctly handles NULL sources, matching the schema default behavior.

2. **Synthetic Message-IDs** (`intake.ex:367-376`): Good practice — enables proper In-Reply-To/References threading even for web-originated prospect messages.

3. **Header sanitization**: The `sanitize_header_text` and `quote_display_name` pipeline properly neutralizes CRLF injection in From names and subjects.

---

### Security Assessment

- **From-identity leak prevention**: Correctly enforced via source-keyed rule in `resolve_sender_email/2` (line 670)
- **Header injection defense**: Comprehensive sanitization in `Headers` module
- **Consent gates**: Two independent layers with force-preload discipline
- **Rate limiting**: Not in scope for this PR but likely handled elsewhere

---

### Test Coverage Highlights

| Area | Coverage |
|------|----------|
| Consent gate (both layers) | ✓ Comprehensive |
| Delivery status transitions | ✓ Complete |
| From-identity leak regression | ✓ Pinned |
| Retention split | ✓ With cascade |
| Header injection | ✓ Neutralized |
| UI indicators (`:withheld`) | ✓ Present |

---

### Verdict

**Safe to merge.** The implementation is solid, well-tested, and the reviewer findings from Greptile/Copilot have either been addressed or are acceptable carry-forwards with proper documentation in the PR description.

The three documented carry-forwards (race window taxonomy, NULL-source edge case, branding_name scope) are correctly identified as out-of-scope for this PR.

---


---

## PR #68 — Add prospect-to-organization conversion (intake stack 9/9)

Merged: 2026-07-12T02:22:31Z

### Inline comments

#### [Copilot] `lib/custyard/slugs.ex:22`

The module docs reference `Custyard.Organizations.convert_prospect/2`, but the conversion function in this PR is `convert_prospect/3`. This makes the docs misleading and harder to grep/trace.

#### [Copilot] `lib/custyard/slugs.ex:255`

This `@doc` references `Custyard.Organizations.convert_prospect/2`, but the conversion entrypoint is `convert_prospect/3` in this PR. Updating the arity in the docs will keep cross-references accurate.

#### [Copilot] `lib/custyard/organizations.ex:314`

The docs claim that reading the prospect inside the transaction means a concurrent email capture "can't race the read". Under the default READ COMMITTED semantics this reduces TOCTOU (vs reading before the transaction), but it doesn't prevent another transaction from committing an email capture after this read unless you also take a lock or otherwise coordinate.

#### [Copilot] `lib/custyard/organizations.ex:371`

convert_prospect/3 makes its own link race-safe via `UPDATE ... WHERE organization_id IS NULL`, but other code paths can still overwrite `conversation.organization_id` after conversion if they run with a stale in-memory `%Conversation{organization_id: nil}`. For example, `Intake.capture_email/3` (used from ResumeLive with `socket.assigns.conversation`) updates `organization_id` via a plain `Repo.update()` without a DB-side guard (see lib/custyard/intake.ex link_conversation and lib/custyard_web/live/resume_live.ex do_capture_email). That can clobber a just-converted link and leave the newly created organization orphaned.

#### [greptile-apps[bot]] `lib/custyard/slugs.ex:280`

[P2]  **Non-exhaustive `case count`**

The `case count do 1 -> ...; 0 -> ...` only handles two values. If a conversation ever has more than one confirmed slug claim (no unique index on `(conversation_id, status = confirmed)` is visible in this diff), `update_all` returns `count > 1`, hits no branch, and raises `CaseClauseError` inside the transaction. The error would bubble out as an uncaught exception rather than `{:error, reason}`, bypassing the compensation path in `handle_convert_result`. Adding `_ -> {:ok, :provisioned}` or a DB-level constraint would make this safe.

#### [greptile-apps[bot]] `lib/custyard/slugs.ex:254`

[P2]  **Doc arity mismatch**

Line 230 says `convert_prospect/2` but the actual function is `convert_prospect/3` — the third argument is `%OperatorAccount{}`. Easy to confuse when someone later searches for callers.

### Copilot PR overview

## Pull request overview

Implements the final step of the public-intake stack by adding prospect-to-organization conversion, including a transactional backend conversion path, a slug-claim promotion mechanism, and operator UI support to trigger conversion with safe prefills and auditing.

**Changes:**
- Add `Organizations.convert_prospect/3` to convert an unlinked `:public_intake` conversation into a newly created organization with transactional linking, optional contact creation, and post-commit side effects.
- Add `Slugs.promote/2` to conditionally promote a confirmed slug claim to `:provisioned` and attach it to the new organization.
- Add operator LiveView controls/tests for “Convert to organization”, plus audit event support for `:prospect_converted` and shared form helper (`empty_to_nil/1`).

### Reviewed changes

Copilot reviewed 10 out of 10 changed files in this pull request and generated 4 comments.

Show a summary per file

| File | Description |
| ---- | ----------- |
| test/custyard/slugs_test.exs | Adds coverage for `Slugs.promote/2` behavior across confirmed/unconfirmed/absent/already-provisioned cases. |
| test/custyard/organizations_test.exs | Adds coverage for `Organizations.convert_prospect/3` happy path, contact creation, slug promotion, compensation paths, and concurrency race outcome. |
| test/custyard/audit_event_test.exs | Extends audit event type coverage to include `:prospect_converted`. |
| test/custyard_web/live/operator/conversation_live_test.exs | Adds LiveView coverage for convert UI visibility, prefill, authorization gating, and refusal messaging. |
| lib/custyard/slugs.ex | Adds `promote/2` implementation and documents slug promotion semantics. |
| lib/custyard/organizations.ex | Adds `convert_prospect/3` implementation, including transactional linking and audit recording. |
| lib/custyard/audit_event.ex | Adds `:prospect_converted` to allowed `AuditEvent` enum values. |
| lib/custyard_web/live/operator/organizations_live.ex | Removes local `empty_to_nil/1` in favor of shared helper import. |
| lib/custyard_web/live/operator/conversation_live.ex | Adds convert UI, prefill logic, and event handling to invoke conversion. |
| lib/custyard_web/form_helpers.ex | Adds shared `empty_to_nil/1` helper for optional text inputs. |

---

💡 Add Copilot custom instructions for smarter, more guided reviews. Learn how to get started.

### Greptile review

Confidence Score: 3/5

The core conversion logic and compensation path are correct, but the LiveView stays subscribed to the wrong PubSub topic after a conversion completes, meaning the operator's page will silently go stale for org-scoped broadcasts on the newly-linked conversation.

The transaction logic, race guards, and test coverage are thorough. The subscription issue in ConversationLive is a present behavioral gap — after conversion the socket is subscribed to `"conversations"` (global) while the conversation is now linked and will receive state-change broadcasts on `"conversations:org:{id}"`. The operator who just converted a prospect won't see subsequent real-time updates without a page refresh. The non-exhaustive `case count` in `Slugs.promote/2` is a latent crash path if the one-confirmed-slug-per-conversation invariant is ever violated.

lib/custyard_web/live/operator/conversation_live.ex (subscription not re-established after conversion), lib/custyard/slugs.ex (non-exhaustive case count)

Important Files Changed

| Filename | Overview |
|----------|----------|
| lib/custyard_web/live/operator/conversation_live.ex | Adds convert prospect UI with double authorization checks and correct error handling, but PubSub subscription is not updated after conversion leaves the socket subscribed to the wrong topic. |
| lib/custyard/organizations.ex | Adds `convert_prospect/3`: two-step flow (create org, then a single transaction for slug promotion, contact creation, and conditional link). Race and compensation logic is correct; post-commit broadcasts and audit trail look solid. |
| lib/custyard/slugs.ex | Adds `promote/2`: race-safe conditional UPDATE (WHERE status = confirmed). Non-exhaustive `case count` and doc arity mismatch noted. |
| lib/custyard_web/form_helpers.ex | Extracts `empty_to_nil/2` from `OrganizationsLive` into shared helper; straightforward deduplication. |
| lib/custyard/audit_event.ex | Adds `:prospect_converted` to the `@event_types` enum list; minimal, correct change. |
| test/custyard/organizations_test.exs | Comprehensive tests for `convert_prospect/3`: happy path, contact creation, slug promotion states, resume-token untouched, audit event attribution, not-convertible guards, step-2 compensation, concurrent-conversion race, and Lettermint failure. |
| test/custyard_web/live/operator/conversation_live_test.exs | LiveView tests cover happy path, hidden button for already-linked conversations, role gating for admin operators, and direct unauthorized event submission. |
| test/custyard/slugs_test.exs | Tests for `promote/2` cover confirmed, unconfirmed, no-claim, and already-provisioned cases — all expected states. |
| lib/custyard_web/live/operator/organizations_live.ex | Removes now-duplicated `empty_to_nil/2` private function; no other changes. |
| test/custyard/audit_event_test.exs | Adds `:prospect_converted` to the expected event types assertion; correct. |

Comments Outside Diff (1)

1. `lib/custyard_web/live/operator/conversation_live.ex`, line 49-66 ([link](https://github.com/onetimesecret/custyard/blob/3f1d6e169b984479982d352243fb48aebb0b7976/lib/custyard_web/live/operator/conversation_live.ex#L49-L66))

   [P1]  **PubSub subscription not updated after conversion**

   `mount_conversation` subscribes to the global `"conversations"` topic when `conversation.organization_id` is nil, with the comment that "state changes are only published on the global topic" for unlinked conversations. The implication is that org-linked conversations publish state changes to the org-scoped topic (`"conversations:org:{id}"`) instead. After conversion succeeds and `reload_conversation` runs, the conversation now has an `organization_id`, but the socket is still subscribed to the global topic — not to `"conversations:org:{new_org_id}"`. Any subsequent state-change broadcast that only goes to the org-scoped topic won't reach this LiveView until a manual page refresh.

### Claude review bot

**Claude finished @delano's task** ——

---
### PR Review: Add prospect-to-organization conversion (intake stack 9/9)

---

### Summary

This is a well-structured PR that implements the final piece of the public-intake stack. The code demonstrates strong defensive patterns with race-safe database operations, proper compensation logic, and good separation of concerns. Test coverage is comprehensive. However, I've identified a few issues that align with the existing review comments plus some additional observations.

---

### Issues Requiring Attention

#### 1. PubSub Subscription Not Updated After Conversion (P1)
**File:** `lib/custyard_web/live/operator/conversation_live.ex:49-66`

The `mount_conversation/3` subscribes to topics based on `organization_id`:
- Nil-org conversations subscribe to global `"conversations"` topic
- Org-linked conversations subscribe to `"conversations:org:{id}"`

After a successful conversion, `reload_conversation/1` is called but the PubSub subscription remains on the global topic. The newly-linked conversation will now receive broadcasts on `"conversations:org:{new_org_id}"`, which the LiveView won't receive.

**Suggested fix:** After successful conversion in `handle_convert_result/2`, unsubscribe from the global topic and subscribe to the org-scoped topic:

```elixir
defp handle_convert_result({:ok, conversation}, socket) do
  if connected?(socket) do
    Phoenix.PubSub.unsubscribe(Custyard.PubSub, "conversations")
    Phoenix.PubSub.subscribe(
      Custyard.PubSub,
      "conversations:org:#{conversation.organization_id}"
    )
  end

  {:noreply,
   socket
   |> assign(:show_convert_form, false)
   |> put_flash(:info, "Converted to a new organization")
   |> reload_conversation()}
end
```

#### 2. Non-Exhaustive Case in `Slugs.promote/2` (P2)
**File:** `lib/custyard/slugs.ex:276-279`

```elixir
case count do
  1 -> {:ok, :provisioned}
  0 -> {:error, :not_found}
end
```

If `update_all` ever returns `count > 1` (e.g., if the one-confirmed-slug-per-conversation invariant is violated), this raises `CaseClauseError` inside the transaction, bypassing the compensation path.

**Suggested fix:**
```elixir
case count do
  1 -> {:ok, :provisioned}
  0 -> {:error, :not_found}
  _ -> {:ok, :provisioned}  # Multiple confirmed slugs promoted (shouldn't happen, but safe)
end
```

Alternatively, add a database constraint to enforce the invariant.

#### 3. Doc Arity Mismatch (P2)
**File:** `lib/custyard/slugs.ex:21-22, 253`

The moduledoc at line 21 and the `@doc` at line 253 reference `convert_prospect/2`, but the actual function is `Organizations.convert_prospect/3` (the third argument is `%OperatorAccount{}`).

---

### Additional Observations

#### Race Condition Comment (lib/custyard/organizations.ex:313-314)

The comment states reading the prospect inside the transaction prevents a concurrent email capture from racing the read. This is partially true under READ COMMITTED — it reduces TOCTOU vs. reading before the transaction. However, it doesn't completely prevent a concurrent transaction from committing an email capture after this read completes. This is likely acceptable given the business logic (a just-captured email would still be valid for contact creation), but the comment could be more precise.

#### Good Patterns Observed

1. **Race-safe conditional updates** - The use of `UPDATE ... WHERE organization_id IS NULL` in `do_convert/2` (line 369) properly handles concurrent conversion attempts.

2. **Compensation pattern** - The `handle_convert_result/3` correctly compensates by deleting the organization on step-2 failures (line 416-418).

3. **Audit trail** - The `:prospect_converted` event properly includes operator attribution and is resilient to logging failures (line 426-447).

4. **Authorization double-check** - The `convert_prospect` event handler checks authorization again (line 254), not just relying on UI gating.

5. **Preload safety** - The returned conversation in `do_convert/2` preloads `:organization` and `:contact` (line 375), preventing N+1 queries downstream.

---

### Test Coverage

Test coverage is thorough:
- Happy path conversion with all variations
- Contact creation from captured email
- Slug promotion (confirmed/unconfirmed/none/already-provisioned)
- Resume token untouched
- Audit event with operator attribution
- Not-convertible guards (already linked, non-public-intake)
- Step-2 failure compensation
- Concurrent conversion race handling
- Lettermint failure compensation
- LiveView authorization gating

---

### Minor Suggestions

1. **Consider extracting subscription logic** - The PubSub subscription pattern in `mount_conversation/3` could be extracted to a helper that's reusable after conversion.

2. **Form helper import** - Good deduplication moving `empty_to_nil/1` to `FormHelpers`. The import pattern is clean.

---

### Verdict

The implementation is solid with good defensive programming patterns. The main issues are the PubSub subscription gap (which causes stale UI after conversion) and the non-exhaustive case clause (latent crash path). Both are fixable with minimal changes.
