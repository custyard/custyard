# Lettermint support email integration gaps

Custyard is an open-source customer onboarding platform. Its email integration already has much of the machinery needed for a tenant's small support inbox, but the current setup path does not connect that machinery into a verifiable service. Separate sending and management credentials, tenant-scoped provider project binding, actual webhook registration, and a successful reply exchange are prerequisites for forwarding real support mail. The code also conflates tenants with customer organizations and has a confirmed recipient-selection bug.

The intended workload is one or more existing `support@` addresses receiving roughly 1–3 messages a day for a tenant. Forward a copy into Custyard, preserve the original mailbox, answer from the tenant's public support address, and group threads by customer organization/sender and subject. Tenant staff manage their customers together; personal email senders have individual customer organizations named after the sender. Keep customer context and follow-up work beside each thread. Extend the existing wizard with a persistent setup checklist and concise help.

Audit date: 2026-10-27. Original code baseline: `54d4bff8c2065d71ec3c6ae54085dd45c2119af7` in the `dda5` worktree. This document preserves the initial findings; the [implementation ledger](../design/tenant-support-workflow.md) records subsequent changes, validation and deliberate later scope. Production configuration and real mailbox delivery remain separate acceptance checks.

## Confirmed product and tenant model

Custyard is an open-source customer onboarding platform. Email is an intake and communication channel within that product. The deployment operator installs and runs an instance; a tenant uses that instance to manage its own customers.

| Concept | Responsibility |
| --- | --- |
| Deployment operator | Installs, configures and runs the Custyard instance |
| Instance | Hosts tenants and provides shared infrastructure |
| Tenant | Has a subdomain or custom domain, branding, staff, inbound channels and email identities |
| Customer organization | Belongs to a tenant and represents one of that tenant's customers; can represent a company or an individual |
| Contact | A sender/person associated with a customer organization inside a tenant |
| Thread | A conversation within the tenant and customer context, organized by sender/participants and subject; contains messages and follow-up tasks |

The hierarchy is instance → tenant → customer organizations → threads/messages. A tenant's application hostname, its support email domain, and a customer's email domain are distinct. Tenant staff work across that tenant's customers. The same customer domain or sender address can exist independently in different tenants.

Email intake follows ordinary deterministic rules:

1. Resolve the tenant from the configured inbound channel and authenticated delivery context. The sender's address never chooses the tenant.
2. Reuse a known contact/customer association inside that tenant. For a new business sender, use the business-domain customer organization, creating an organization with a domain-derived display name when no name is known; allow staff to correct its name or association.
3. For a personal/public mailbox such as `Alex Kim <alex@gmail.com>`, create or reuse an individual customer organization named **Alex Kim**. Use the email address as the fallback label if no display name is available. The tenant and sender address establish identity; the display name is editable and not a unique key. Do not group unrelated people into a Gmail organization.
4. Preserve reply continuity using Message-ID, In-Reply-To and References. When no usable header relationship exists, match the customer organization/sender and normalized subject within the tenant. Strip conventional reply/forward subject prefixes for matching while preserving the original displayed subject. Never join different customers merely because both write “Help.”
5. Routine first-time senders are filed automatically. Only conflicting or genuinely ambiguous matches need staff review. A headerless message with multiple plausible thread matches starts a new thread rather than silently combining them.

The email-header relationships are defined in [RFC 5322 section 3.6.4](https://www.rfc-editor.org/rfc/rfc5322#section-3.6.4); established subject normalization and threading algorithms are described in [RFC 5256](https://www.rfc-editor.org/rfc/rfc5256#section-2.1). Tenant and customer scoping are Custyard's application requirements around those mechanisms.

“Thread” is the product concept; the existing `Thread` object can implement it. No parallel thread model or broad rename is needed to establish these behaviors.

## Existing capabilities

| Area | Present in this checkout | Remaining boundary |
| --- | --- | --- |
| Receiving | Forwarding, direct MX and IMAP channels; provider confirmation capture; resumable four-step wizard; channel pause, revoke and token rotation | Provider connection prerequisites are outside the usable setup flow |
| Threading | Message-ID, In-Reply-To and References matching; delivery/message deduplication; organization-scoped thread lookup | Sender/subject fallback is absent; tenant scoping and a real forwarding/reply pilot are required |
| Replying | Channel identity, editable CC, Reply-To handling, optional archive BCC and own-echo suppression | A second participant can be omitted; sending readiness is incomplete |
| Delivery | Persisted pending replies, atomic delivery claims, status webhook handler, per-recipient delivery facts | Webhook setup, safe failure diagnosis and uncertain-send recovery need work |
| Content | Sanitized HTML, inbound attachment storage and authorized downloads, suspect-mail handling | Attachment recovery needs provider webhook metadata; outgoing attachments are absent |
| Customer context | Contact and organization sidebar, related conversations, organization-scoped access | Tenant and customer organization are conflated; routes fix the customer organization; personal-address organization creation is absent |
| Tasks | Create, edit, delete, due time and open/in-progress/done states beside a conversation | Due work does not resurface independently; timezone handling and visibility defaults need attention |
| Labels | Project tags exist | Conversation labels, assignment and filtering are absent |

Key implementation references: [channel wizard](../../lib/custyard_web/live/staff/channel_setup_component.ex), [thread matching](../../lib/custyard/email/thread_matcher.ex), [outbound delivery](../../lib/custyard/email/outbound.ex), [delivery queue](../../lib/custyard/email/outbound_queue.ex), [conversation actions](../../lib/custyard_web/live/staff/thread_live.ex).

## Prioritized findings

P1 means address before relying on the affected support workflow. P2 means needed for a complete, maintainable experience. The findings below describe the original audit baseline; use the [implementation ledger](../design/tenant-support-workflow.md) for their current dispositions.

### L01 Separate sending and Team credentials

**P1 — confirmed configuration defect.** The current variable is `LETTERMINT_API_KEY`, rather than the older `LETTERMINT_API_TOKEN` name. It supplies both Swoosh's sending credential and the management client's Bearer credential. Lettermint requires a Project token for sending and a Team token for management. Evidence: [runtime configuration](../../config/runtime.exs), lines 163–168 and 284–313; [HTTP client](../../lib/custyard/lettermint/http_client.ex), lines 237–259; [Lettermint authentication](https://lettermint.co/docs/api-reference/introduction).

Introduce `LETTERMINT_PROJECT_TOKEN` and `LETTERMINT_TEAM_TOKEN`. Retain `LETTERMINT_API_KEY` temporarily as a documented sending-only compatibility alias, with explicit precedence and a warning that never contains the value. Never substitute one token for the other. Default the API URL to the official endpoint while retaining an explicit override for tests.

Acceptance: sending-only configuration cannot masquerade as management readiness; Team-only configuration cannot pass sending readiness; invalid and insufficient-permission credentials produce different actionable states. Grant only the required Team abilities: route read/write and domain read for current management, webhook read for recovery, and project read for selection. Webhook write is needed only if provisioning is automated. Lettermint's [Team token documentation](https://lettermint.co/docs/platform/teams/api-tokens) says write abilities do not imply read abilities.

### L02 Production must not manufacture provider resources

**P1 — confirmed configuration defect.** Missing management configuration selects `MockClient` even in production. That client returns synthetic route IDs and plausible inbound domains, and can report successful MX verification. The banner says provisioning is disabled, but the route creation action is still callable. Evidence: [runtime configuration](../../config/runtime.exs), lines 300–313; [mock client](../../lib/custyard/lettermint/mock_client.ex), lines 25–75; [route creation UI](../../lib/custyard_web/live/staff/organization_detail_live.ex), lines 303–350.

Use an unavailable client outside development/test. Existing conversations should remain usable, while provider mutations fail with a clear setup action. Acceptance: missing credentials can never create a synthetic remote ID or display a receiving address as usable.

### L03 Make provider project binding possible

**P1 — confirmed setup gap.** Organizations store `lettermint_project_id`, but no operator UI sets it. Organization creation skips automatic route provisioning when it is nil; manual route creation still passes it to Lettermint. Evidence: [organization creation](../../lib/custyard/organizations.ex), lines 204–228; [route provisioning](../../lib/custyard/inbound_routes.ex), lines 137–155; [organization form](../../lib/custyard_web/live/staff/organizations_live.ex), lines 90 and 151–161.

Bind the provider connection and project to the tenant's email channels, not to each customer organization. The deployment operator may manage Team credentials centrally; sending credentials must resolve through the intended tenant connection. A shared provider project can be an explicit configuration, but it must not erase tenant ownership or isolation. A single-tenant installation may use an instance default. Validate the binding through the Team API and keep a Custyard onboarding project distinct from a Lettermint infrastructure project.

Acceptance: an administrator can connect an existing provider project, create or import the inbound route, and resume after a failure without a database edit or console command.

### L04 Register and bind the actual inbound webhook

**P1 — confirmed integration gap.** Creating a remote route does not create its Lettermint webhook. `InboundRoutes.create_webhook/1` only inserts a local processing-purpose record. The management client has no webhook creation/import workflow. Evidence: [inbound routes](../../lib/custyard/inbound_routes.ex), lines 137–155 and 414–427; [client interface](../../lib/custyard/lettermint/client.ex). Lettermint documents the required separate [inbound webhook setup](https://lettermint.co/docs/platform/inbound-mail/process-inbound-email).

Support a manual provider step first: show the exact public HTTPS callback URL, identify the selected project and inbound route, link to provider instructions, and capture the provider webhook ID and signing-secret reference. Rename local “Webhook Purposes” to an administrator-facing processing label so toggles do not imply remote registration.

Acceptance: the UI distinguishes route exists, webhook registered, signing secret configured, and signed message received. A missing webhook must lead to a specific next action. A provider's synthetic webhook test must not be presented as proof that mailbox forwarding works.

### L05 Support each webhook's signing secret and recovery metadata

**P1 for multiple routes; P2 for attachment recovery — confirmed gap.** Runtime configuration exposes one inbound signing secret, although the controller can consume a callback-token-to-secret map. No ordinary configuration/UI path creates that map or securely stores per-webhook secrets. Attachment recovery additionally requires `lettermint_webhook_id`, which local purpose creation does not populate. Evidence: [runtime configuration](../../config/runtime.exs), lines 342–350; [webhook controller](../../lib/custyard_web/controllers/webhook_controller.ex), lines 287–293; [webhook schema](../../lib/custyard/inbound_route_webhook.ex), lines 17–25; [attachment recovery](../../lib/custyard/attachments/recovery.ex), lines 50–83.

Introduce an explicit provider-webhook binding with an encrypted secret or secret-manager reference, provider ID, route, endpoint and verification timestamps. Keep processing-purpose toggles separate. Mask secrets, support replacement, and limit binding/rotation actions to the appropriate administrator. Team credentials should not be disclosed to organization agents.

Acceptance: two routes with different secrets both verify correctly; mismatched signatures are rejected; a retained provider delivery can recover an attachment. Provider content retention is bounded: [Lettermint documents 28 days](https://lettermint.co/docs/platform/inbound-mail/attachments-and-raw-email), so preserve needed files locally and report expired recovery honestly.

### L06 Verify sending and delivery events separately

**P1 — confirmed readiness gap.** The sending-domain check looks only for a team domain with `status == "verified"`; it does not establish that the actual sending project may use it. Domain restrictions can prevent sending from an otherwise verified domain. The wizard can finish with a verified domain or ingress fallback without a successful reply. Evidence: [domain check](../../lib/custyard/inbound_channels.ex), lines 548–603; [wizard completion](../../lib/custyard_web/live/staff/channel_setup_component.ex), lines 475–484 and 1146–1166; [provider project restrictions](https://lettermint.co/docs/platform/domains/project-limits).

The separate status endpoint `/api/webhook/email-status/lettermint` and `WEBHOOK_SECRET_LETTERMINT_STATUS` already exist. Setup must explain its own secret and provider scope. Subscribe to the handled events: `message.sent`, `message.delivered`, `message.hard_bounced`, `message.failed`, `message.policy_rejected`, and `message.suppressed`. Other event types are currently ignored; do not promise complaint/open/click workflows. Evidence: [status controller](../../lib/custyard_web/controllers/email_status_controller.ex), lines 22–93; [event mapping](../../lib/custyard/email/delivery_status.ex), lines 56–65.

Acceptance: verify project/domain compatibility, provider production-sending eligibility, and the selected default outgoing route; send an actual reply and correlate its provider ID and delivery event. Provider acceptance, recipient-server delivery, inbox receipt, and a returning reply are distinct observations. An ingress-address fallback must be labeled as a temporary provider-domain identity, not branded sending readiness. See the provider's [production checklist](https://lettermint.co/docs/production-checklist). Also check inbound-plan eligibility: the [current inbound guide](https://lettermint.co/docs/platform/inbound-mail/introduction) requires Starter or higher, regardless of this inbox's low volume.

### L07 Repair setup discovery and recovery

**P1 — observed in the local browser and confirmed in code.** A fresh queue says “Nothing needs attention right now.” Settings offers no email integration section. Organization cards open the edit form rather than the detail screen containing Channels. Navigating directly to that detail screen and choosing New channel produces an empty required Route selector with no connect-project or repair action.

Evidence: [queue blank slate](../../lib/custyard_web/live/staff/attention_queue_live.ex), lines 255–261; [organization card](../../lib/custyard_web/live/staff/organizations_live.ex), lines 633–708; [wizard route selection](../../lib/custyard_web/live/staff/channel_setup_component.ex), lines 550–571 and 733–745. The local fixture had no provider credentials and no bound project; the code also confirms that merely adding credentials does not populate the organization's missing project ID.

Acceptance: a new administrator reaches email setup from the first screen, follows a direct organization-details link, and sees an actionable prerequisite instead of an empty selector. Existing channel setup resumes after refresh. Advanced recovery includes route sync/import and a plain explanation of what is missing.

### L08 Replace configuration banners with verified capability states

**P2 — confirmed misleading status.** The operator layout treats any nonempty global webhook secret as sufficient; a different provider's secret or only the outbound-status secret hides the inbound warning, while a valid per-route map does not satisfy it. It says signature verification is disabled, although production rejects callbacks without a secret. Evidence: [operator layout](../../lib/custyard_web/components/layouts/operator.html.heex), lines 274–297; [verification enforcement](../../lib/custyard_web/controllers/webhook_controller.ex), lines 208–223.

Show sending, management, inbound webhook and status webhook independently, with last-check time and a repair action. Agents should see “Ask your administrator to finish email setup,” while instance administrators can inspect configuration names and safe diagnostics. Never derive readiness solely from an environment variable being present.

### L09 Implement tenants and automatic customer thread grouping

**P1 — confirmed model gaps and required pilot behavior.** The deployment operator runs an instance that hosts tenants; each tenant has many customer organizations. There is no separate tenant schema or `tenant_id` in the audited implementation. `Organization` combines customer relationships with branding, custom domain, Lettermint project, staff accounts and channels. Custom-domain routing resolves directly to one organization's portal, and staff access is either organization-specific or global. Evidence: [organization schema](../../lib/custyard/organization.ex), lines 5–27; [domain routing](../../lib/custyard_web/plugs/custom_domain.ex), lines 66–100; [staff model](../../lib/custyard/staff_account.ex), lines 15–24 and 246–256.

Route-based ingestion treats the route's organization as the customer organization, so unrelated customers contacting one support address are pooled together. The alternate sender matcher sends unknown addresses to a shared Unmatched Senders organization and does not create sender-named organizations for personal mailboxes. Thread matching uses reply/reference headers only; the subject fallback described in the SDD is not implemented. Evidence: [sender matching purpose](../../lib/custyard/webhooks/purposes/sender_matching.ex), lines 77–111; [sender matching](../../lib/custyard/email/sender_matcher.ex), lines 31–60 and 210–283; [thread matching](../../lib/custyard/email/thread_matcher.ex), lines 15–69; [SDD](../design/sdd.md), line 54.

Implement the confirmed hierarchy and intake rules above using the existing Conversation object. Scope application domains, staff membership, channels, provider connections and label definitions to the tenant; retain customer organizations beneath it. Migrate existing organization relationships explicitly, including the currently global customer-domain uniqueness constraint. Reassignment changes customer context within a tenant while preserving the channel's reply identity; it never moves mail to another tenant merely because of sender headers. Ordinary first-time senders should be filed automatically, including a sender-named individual customer organization for a Gmail address.

This decision matters for the portal. The current organization token grants access across that organization; sharing a common support organization's portal with unrelated customers would expose their conversations and portal-visible tasks. This is a confirmed conditional design consequence, not observed production exposure. Evidence: [portal access contract](../../lib/custyard_web/plugs/portal_auth.ex), lines 14–26; [portal request list](../../lib/custyard_web/live/portal/request_list_live.ex), lines 73–88.

Acceptance: tenant Atlas has its own subdomain/custom domain, support address and staff access; its customers Acme, Beta and Alex Kim appear as separate organizations with their own threads. Alex's Gmail address creates or reuses the Alex Kim organization automatically. Replies retain Atlas's support identity. Tenant Beacon can independently have the same customer domain or sender without seeing Atlas's records. Reply headers preserve threads; missing headers use customer/sender plus normalized subject, while unrelated customers with the same subject remain separate. Customer portal access stays within the authorized customer organization. Only actual conflicting matches require review.

### L10 Preserve participants when the latest sender changes

**P1 — reproduced defect.** Alice starts a thread. Bob replies-all to support and CCs Alice without setting Reply-To. Custyard retains Alice as the conversation contact, chooses Alice as the next recipient, and excludes both Alice and Bob from default CC. The resulting selection is `To: Alice; CC: none`, omitting Bob.

Evidence: [reply recipient](../../lib/custyard/email/outbound.ex), lines 206–240; [default CC exclusions](../../lib/custyard/threads.ex), lines 691–738. A temporary test used the actual sender-matching path for both messages and reproduced the omission.

Acceptance: compute the primary recipient and reply-all participants together from the latest eligible customer message, honoring valid Reply-To and excluding the support/ingress addresses. Show the exact intended envelope before send and use that same selection for dispatch. Test changed senders, Reply-To, aliases, CC edits, auto-responses and suspect mail.

### L11 Provide safe delivery recovery and diagnostics

**P1 for reply reliability — confirmed gap.** Pending replies survive restarts, and atomic claims prevent simultaneous sends. Interrupted sends are deliberately marked failed after ten minutes to avoid automatic duplicate delivery. The UI then offers only a failure icon and no reconciliation/retry action. Outbound composition does not set a provider idempotency key, although the locked Swoosh adapter supports one. Evidence: [queue recovery](../../lib/custyard/email/outbound_queue.ex), lines 59–85; [failure UI](../../lib/custyard_web/live/staff/thread_live.ex), lines 1887–1905; [composition](../../lib/custyard/email/outbound.ex), lines 153–169.

Separate confirmed rejection from acceptance unknown. Add safe diagnostic categories, provider-reference lookup where available, and an explicit recovery action. Persist a stable per-message idempotency key for identical retries; Lettermint's documented window is 24 hours, so do not promise indefinite deduplication. Keep the conservative no-blind-resend behavior when acceptance cannot be established.

Outbound and route error paths currently log or display `inspect(reason)`, which can include raw provider responses. Extend the safe logging approach already used by login mail: status, bounded code/field categories and correlation IDs, excluding message bodies, addresses, tokens, headers and signed URLs. Evidence: [outbound error](../../lib/custyard/email/outbound.ex), lines 133–135; [route error](../../lib/custyard_web/live/staff/organization_detail_live.ex), lines 347–349; [login diagnostics](../../lib/custyard/auth/login_email.ex).

### L12 Complete task follow-up behavior

**P2, required if tasks are relied on for promises — partially implemented feature.** Tasks already support editing and three states. An unfinished overdue task on a resolved conversation disappears from the attention queue; a temporary regression check reproduced this. Task due dates do not participate in attention scoring. Evidence: [queue query](../../lib/custyard/threads.ex), lines 52–55; [scoring](../../lib/custyard/scoring.ex), lines 222–243; [task actions](../../lib/custyard_web/live/staff/thread_live.ex), lines 387–529.

The date input is also treated as UTC without conversion from the operator's timezone, and tasks default to portal-visible. Evidence: [date parsing](../../lib/custyard_web/live/staff/thread_live.ex), lines 872–891; [task schema](../../lib/custyard/task.ex), lines 5–15.

Acceptance: a Due tasks view or equivalent queue indicator surfaces unfinished work independently of conversation resolution; a 09:00 America/Vancouver task round-trips correctly, including DST; internal follow-up is the explicit default with a separate “Share in customer portal” choice. For a small team, add assignment only if ownership is needed; a full project-management subsystem is unnecessary for the pilot.

### L13 Add thread labels

**P2 — unimplemented.** Project tags do not supply conversation labels. There is no conversation-label schema, join, assignment UI or queue filter. Evidence: [project schema](../../lib/custyard/project.ex), lines 34–35; [queue filters](../../lib/custyard_web/live/staff/attention_queue_live.ex), lines 243–251; [existing implementation-status document](../design/sdd-status.md), lines 87 and 251.

First slice: tenant-scoped labels with normalized unique names, optional colors, add/remove in the thread header, and queue filtering. Labels such as Billing, Bug and Account access remain independent of state, urgency, customer organization and task completion. Acceptance includes tenant isolation, duplicate names, deletion behavior, and readable text without reliance on color. Keep labels internal to tenant staff by default.

### L14 State the boundaries of a full thread

**P2 — explicit scope decision.** New captured messages can form a complete ongoing thread. Forwarding does not import previous mailbox history, IMAP deliberately starts with newly arriving mail, and manual-forward parsing extracts a forwarded block rather than reconstructing every historic message. Conversation merging and outbound file attachments are also absent. Evidence: [IMAP behavior](../../lib/custyard/email/imap_poll.ex), lines 8–12; [forward parser](../../lib/custyard/email/forward_unwrapper.ex), lines 14–17 and 59–81; [conversation-loop scope](../design/spec-thread-loop.md), lines 99–105; [outbound composition](../../lib/custyard/email/outbound.ex), lines 153–169.

Pilot proposal: start with new conversations after a known cutover time; keep older threads in the existing mailbox. Record historical import/merge and outgoing attachments as deferred work unless they are needed immediately. Preserve inbound attachments and original message ordering in the pilot.

### L15 Finish Phoenix interaction and whitelabel behavior

**P2 — confirmed implementation gaps plus design recommendations.** Domain and MX checks run synchronously in event handlers; IMAP connection testing can block the LiveView for twenty seconds. Raw provider terms can appear in errors. The shell hardcodes “Service Platform,” while the wizard hardcodes Custyard despite configurable branding. Some field errors lack an accessible association with their inputs. Evidence: [wizard handlers](../../lib/custyard_web/live/staff/channel_setup_component.ex), lines 164–223; [field errors](../../lib/custyard_web/live/staff/channel_setup_component.ex), lines 714–729; [operator shell](../../lib/custyard_web/components/layouts/operator.html.heex), lines 34–35.

Use the existing Phoenix 1.8 / LiveView 1.2 foundations: context-owned operations, authenticated scope and event authorization, changesets/forms, verified routes, async capability checks, and explicit loading/failure states. LiveView async tasks end with their owner; provisioning that must survive disconnect belongs in a persisted operation with a supervised worker and reconciliation. Store setup facts in the database and broadcast updates. Do not move provider secrets into browser state. See [LiveView async operations](https://phoenix-live-view.hexdocs.pm/1.2.13/Phoenix.LiveView.html#module-async-operations) and its [security model](https://phoenix-live-view.hexdocs.pm/1.2.13/security-model.html).

Use configured brand names in general product guidance; retain Lettermint where an administrator actually needs to act there. Add associated field errors, visible completion text and announced async results, following [W3C form feedback guidance](https://www.w3.org/WAI/tutorials/forms/notifications/).

### L16 Cover provider-side blind spots and cleanup

**P2 — operational gaps.** Custyard's rejection log cannot show a message that Lettermint quarantined before sending a webhook. A quiet mailbox is also not evidence of failure, especially over a weekend at this volume. Setup troubleshooting should link to provider activity, webhook delivery attempts and quarantine, and show last successful receipt/check. [Lettermint spam filtering](https://lettermint.co/docs/platform/inbound-mail/spam-filtering) describes this pre-webhook boundary. Do not disable spam controls as a substitute for diagnosis.

Route creation can succeed remotely and fail at local insertion, and organization deletion does not clean up remote routes. Add recorded provisioning operations and a reconcile/cleanup action before expanding to many connections. Evidence: [inbound route lifecycle](../../lib/custyard/inbound_routes.ex), lines 9–11 and 147–151. This is a later robustness improvement; it need not become a large orchestration platform for one inbox.

## Proposed setup experience

Use a small persistent checklist on the first-run queue and an Email section in tenant settings, linked from Channels. Shopify's [setup-guide pattern](https://shopify.dev/docs/api/app-home/latest/patterns/compositions/setup-guide) supports actionable steps with progress and resumption. Keep essential prerequisites visible; place provider-specific details behind concise help, consistent with [GOV.UK guidance on details](https://design-system.service.gov.uk/components/details/). Distinguish deployment administration from tenant administration and customer access. Existing code names such as OperatorAccount do not establish that these roles are already separated.

| Step | Owner | Visible result |
| --- | --- | --- |
| Connect email service | Deployment operator | Sending and Team capabilities checked; provider connection available for explicit tenant binding |
| Connect inbound delivery | Deployment operator or delegated tenant administrator | Tenant's route and inbound webhook bound, secret stored, callback publicly reachable |
| Connect support address | Tenant administrator | Tenant's public address and brand identity chosen; full forwarding destination copied; provider confirmation completed |
| Receive a test message | Tenant staff | Receipt time and link to the resulting customer organization's thread |
| Verify replies | Tenant staff with tester | Tenant sending identity verified; reply accepted; delivery event received; returning reply joins the same customer thread |

Manual Lettermint setup is an acceptable first release. The in-app step should identify the chosen project and inbound route, show the callback URL, and instruct the admin to open that route's Webhooks screen and create the webhook. Store its ID and own signing secret. A second step configures the outbound status endpoint and secret with the supported events and sending-project scope. Automation can replace these steps later without changing the user-facing state model. Provider actions are documented in the [webhook API](https://lettermint.co/docs/api-reference/team/webhook).

For forwarding, preserve the existing public mailbox and use the complete channel destination, including its `+token`. Show the real route-domain address produced by setup. A legacy `@inbound.lettermint.co` compatibility address has different addressing constraints and must not be synthesized into a channel destination. Prefer the existing forwarding path for this workload; direct MX and IMAP remain alternatives.

Suggested short help:

| Location | Copy |
| --- | --- |
| First-use queue | **Connect your support address.** Forward mail from your existing mailbox, then reply here with the conversation in view. |
| Team credential | **Team API token.** Used for project access, inbound routes, webhooks and domain checks. |
| Sending credential | **Sending API token.** Used to send replies from the selected Lettermint project. |
| Blocked channel setup | **Email service setup is incomplete.** An instance administrator needs to connect Lettermint before you can add this address. |
| Forwarding step | **Forward a copy to this address.** Keep the original in your mailbox. Your provider may send a confirmation here. |
| First receipt | **Test message received.** Open the conversation and send a reply to finish testing. |
| Team authentication failure | **Couldn't check this domain.** Ask your administrator to check the Team API token. |
| Ongoing status | **Receiving connected** and **Replies verified**, each with the relevant last-check time. |

Persist individual observations rather than one “configured” flag: project validated, route synchronized, signed callback received, provider forwarding confirmed, test message received, domain checked, reply accepted, delivery event received and returning reply matched. Recheck or invalidate affected observations when credentials, route, endpoint, sender identity or forwarding destination changes.

## Implementation sequence and completion criteria

| Slice | Findings | Done when |
| --- | --- | --- |
| 1. Credential and provider foundation | L01–L05 | Separate tokens, no production mocks, selected project, real route/webhook bindings, a secret for each inbound webhook and a separate status-webhook secret work without console/database edits |
| 2. Tenant and customer grouping with correct replies | L09–L10 | Separate tenant ownership and staff access; automatic business/personal customer resolution; header and subject thread matching; cross-tenant/customer checks; correct changed-sender reply-all |
| 3. Guided setup and reliable replies | L06–L08, L11, L15 | First-run entry, resumable manual provider instructions, capability-specific errors, real reply round-trip and safe failure recovery |
| 4. Follow-up work | L12–L13 | Due tasks remain discoverable, timezones round-trip, internal defaults are clear, labels can be applied and filtered |
| 5. Deliberate later scope | L14, remaining L16 | Record decisions for history import, merge, outgoing attachments, automated provisioning and cleanup; none should be implied as already available |

The tenant boundary is a confirmed requirement, not an open product question. Establish tenant ownership and a migration plan before finalizing provider bindings, host routing or staff authorization. Credential separation can proceed in parallel. Slice 3 integrates these foundations into the setup flow. Each tenant's staff must work across its customer organizations while replies retain that tenant's channel identity. Customer grouping cannot be deferred to a single pooled support organization.

Pilot acceptance uses actual provider forwarding, not just mocks:

1. Forward new messages to one tenant's support address from two business customers and a named Gmail sender. Check tenant routing, automatic separate customer organizations, sender-named personal organization, original recipients, subject, body and a small attachment. Repeat a subject across unrelated customers and tenants; it must not merge their threads. Test a headerless follow-up from the same sender with a normalized matching subject.
2. Reply from the branded support address; correlate provider acceptance and delivery status, then confirm receipt with the tester.
3. Reply back from the tester and verify one continuous conversation. Have Bob reply-all to Alice's existing thread without Reply-To, then verify that Custyard replies to Bob with Alice copied, both in the preview and the received headers.
4. Replay a signed delivery and confirm no duplicate conversation/message. Verify invalid signatures fail. Exercise a bounce or suppression using an appropriate provider test address.
5. Resolve the conversation, receive another reply, and confirm expected reactivation. Once slice 4 exists, create an internal due task, resolve the conversation, and confirm the task remains visible; apply and filter a label.
6. Confirm another tenant's staff and another customer's portal scope cannot read the thread, its tasks or its attachments. Confirm tenant staff can manage all customers in their own tenant without instance-wide privileges. Check archive-copy echo suppression if archive copies are enabled.
7. Restart with a pending reply and inspect recovery. Separately test an uncertain send so the UI neither silently drops it nor automatically duplicates it.

## Validation record

The focused existing suite passed **392 tests, zero failures** across Lettermint clients/configuration, channels/routes, outbound composition, threading, task schema, channel setup and conversation LiveViews. This establishes current local behavior, not provider readiness. The fetched dependencies matched the existing lockfile; no dependency manifest was changed.

At the original baseline, both desired-behavior checks failed and confirmed L10 and L12: replies chose Alice instead of Bob with Alice copied, and a resolved conversation's unfinished overdue task was absent from attention. Both [audit reproducers](fixtures/2026-10-27-support-readiness_test.exs) now pass against the implementation. Run them with `MIX_ENV=test mix test docs/research/fixtures/2026-10-27-support-readiness_test.exs`.

The browser walkthrough used a fresh local database, fake Lettermint client and local-only email capture. It covered login, the empty attention queue, organization creation/edit navigation, the organization Channels screen, and the empty-route setup form. It confirms discovery and prerequisite gaps, not live delivery. No production credentials, DNS, forwarding rules or provider resources were inspected or changed. Production account approval, current domains/project restrictions, webhook registrations, storage durability and real inbox receipt remain pilot checks.

Confirmed product model, 2026-10-27: Custyard is an open-source customer onboarding platform. The deployment operator runs an instance; tenants use their own subdomains or custom domains and each have many customer organizations. Email creates or continues threads by customer organization/sender and subject, with reply headers preserving continuity. Personal-address customer organizations use the sender's name. Routine intake is automatic; ambiguous matches alone need review. The remaining work is implementing and migrating this model, not choosing a new product hierarchy. Historical import and outgoing attachments remain explicit later-scope proposals.
