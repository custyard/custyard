# PR 59 review follow-up

Review baseline: `63d1935`. This ledger covers the initial 17 inline review findings, three additional automated findings, conversation feedback, the missing review label and the failed CI formatting check. Each disposition was validated against the implementation. These review changes are not deployed by this task.

## Findings

| Comment | Finding | Disposition |
| --- | --- | --- |
| 4415345663 | Research prose changed from conversational to threadal | Addressed in b8e1db2; ordinary discussion wording restored |
| 4415346155 | Repeated thread thread wording in routing and related specifications | Addressed in b8e1db2; repeated thread wording removed |
| 4415346514 | Circular definition of Thread | Addressed in b8e1db2; correspondence definition clarified |
| 4415346900 | Repeated Thread thread in inbound UI specification | Addressed in b8e1db2; thread view wording corrected |
| 4415352721 | Public-intake acceptance wording | Addressed in b8e1db2; acceptance wording corrected |
| 4415353049 | Thread-loop acceptance wording and thread threading | Addressed in b8e1db2; acceptance and threading wording corrected |
| 4415358862 | Installation hostname incorrectly described as available to tenants | Addressed in b8e1db2; installation host is reserved and tenant workspaces are distinct |
| 4415374403 | Invalid or repeatedly crashing tenant acknowledgment consumer affects other tenants | Addressed in 4d20027; invalid configuration and restart exhaustion are tenant-local |
| 4415385808 | LMTP accepts distinct channels but dispatches only the first | Addressed in c79f8d0; a distinct second channel receives 451 for separate delivery |
| 4415395568 | Public intake and prospect writes do not consistently enforce active tenant ownership | Addressed in 73da7b7; public writes lock and recheck active tenant and current ownership |
| 4415418044 | Instance-admin CLI prints escaped usage and starts the database for invalid argv | Addressed in 4b363c3; malformed argv is handled before database startup |
| 4415423634 | Last tenant host can be removed, breaking URL generation | Addressed in f361f92; last usable host is protected under a tenant lock and removal is audited |
| 4415478054 | User-visible thread threads help text | Addressed in b8e1db2; user-visible help text corrected |
| 4415479978 | Default-contact event lacks an explicit admin guard | Existing context already blocked the reported escalation; df6d939 adds an explicit LiveView guard and forged-event/demotion tests |
| 4415532398 | Required staff tenant FK uses SET NULL deletion behavior | Addressed in 345bc50; fresh RESTRICT FK and safe forward restriction preserve existing records |
| 4415585426 | Missing SQLite export and instance-admin bootstrap/argv tests | Addressed in 4b363c3; SQLite export and bootstrap/argv coverage restored |
| 4415623962 | Missing highest-privilege admin login regression tests | Addressed in df6d939; privileged login security coverage restored |

## Additional automated review

Enabling the configured reviewer added three findings on the same original head:

| Comment | Finding | Disposition |
| --- | --- | --- |
| 4416116215 | Orphan cleanup deletes customer defaults and portal contact attribution | Addressed in dfee22a; live references are excluded from both dry-run and deletion |
| 4416116231 | Broker credentials are not migrated before retiring the previous encryption key | Addressed in e45eebb; lazy re-encryption uses a tenant-scoped ciphertext compare-and-swap, including disabled integrations |
| 4416116236 | A crash after message commit restores an already-submitted draft | Addressed in 96481f6; message/note creation and submitted-mode retirement are atomic, with explicit CC intent and forward migration 25000 |

## Final local validation

Code validation at `96481f6` passed `mix ci`: **2,781 tests, zero failures**, warnings-as-errors compilation, formatting and strict Credo. The Elixir 1.18.3 formatter separately checked 469 files. Sobelow, dependency vulnerability and Hex advisory/retirement audits passed. The production release built and its local smoke test passed.

Migration tests cover fresh and legacy SQLite plus local Turso, including upgrade/rollback for the tenant-staff deletion guard (24000) and explicit draft CC intent (25000). Deployed draft migration 22000 is unchanged. Independent final reviews cover acknowledgment credential rotation and atomic draft submission.

No deployment, production migration, database reset or customer email was performed by this review-follow-up task.

## Conversation and CI checks

- The summarized review also identifies a stale research fixture, an obsolete inbound-channel PubSub topic, and rename artifacts in module documentation. These are included in the documentation pass.
- The original test job stopped at formatting before tests ran. Commit 0149627 uses explicit guarded definitions stable under both Elixir 1.18.3 and 1.19.2; the final formatter check passes all 469 source/template files.
- Applied the configured `greptile-review` label, inspected its additional findings and addressed all three above.
- Final local validation covers the review fixes independently of the earlier 2,731-test run and production release 91. GitHub checks are tracked on the pushed PR head.
