# PR 57 review follow-up

Scope: Proton forwarding setup, resumable setup state, configurable sending domains, and Lettermint domain access checks.

## Finding dispositions

| Finding | Disposition | Evidence |
| --- | --- | --- |
| An outbound retry could lose its public Reply-To after a channel identity change because Swoosh stores that field outside `email.headers`, which was the only header input to the delivery fingerprint. | Fixed. Non-nil Reply-To participates in the fingerprint; nil Reply-To retains the exact legacy representation. Changed return paths fail with `envelope_changed` before another provider call. | `outbound_recovery_test.exs` covers rejected and unattempted configuration retries, domain clearing, ingress fallback selection, and legacy fingerprint compatibility. |
| Tenant receipt and claim emails inherited the custom sending domain without a working public return address. | Fixed. Tenant delivery settings carry the public support Reply-To for custom-domain senders. Platform and ingress senders retain their existing return paths. | `tenant_public_email_test.exs` checks receipt and claim delivery through the actual Swoosh Lettermint adapter, including serialized `reply_to`, plus platform and ingress behavior. |

Both findings came from independent review. The targeted regressions reproduced three failures before the fixes. The expanded focused delivery and intake run passed 116 tests afterward.

The independent provider and tenant-boundary review found no additional material issue. The [initial Claude report](https://github.com/custyard/custyard/pull/57#issuecomment-6461047491) covered all 25 files at `408125e` and reported no additional findings. Updated code requires a fresh current-head Claude report before merge.

Greptile reported that its configured label was missing. This was an informational review-configuration status, without a code finding. The requested merge gates are CI and the complete published Claude review; no label policy was changed.

## Validation boundaries

- Full local `mix ci`: 2,973 tests, zero failures, 48 skips; warnings-as-errors compilation, formatting, and strict Credo passed.
- Sobelow, Hex audit, dependency audit, and whitespace checks passed.
- Changed Elixir sources were checked with the CI-pinned Elixir 1.18.3 formatter.
- Existing populated SQLite and Hrana/Turso-driver upgrade/rollback coverage includes the additive sending-domain migration. Real libSQL CI and release checks remain separate remote gates.
- Automated and static checks do not establish a live email round trip. Production acceptance requires external forwarding, the configured sending identity and public return address, provider delivery, user-confirmed inbox receipt, and a returning reply in the same tenant/customer conversation.
