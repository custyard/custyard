# Problem Space: Relationship-Driven Service Platform

**Version:** 0.4 — Supplements SDD v0.4 and the email-routing design decisions v0.3
**Date:** 2026-07-05

---

**Maintenance guidance:** Do not paraphrase, add flourish, or editorialize when adding entries. Shortening and condensing is encouraged but not at the loss of nuance. Fewer items captured at high fidelity is preferable to more items with diluted precision.

---

## 1. The Ante-CRM Period

High-touch SaaS tiers — dedicated instances, custom domains, forked codebases — have a buying and onboarding journey that fits neither of the two tool categories that normally bracket it:

- **Before the sale**, the pricing page ends in soft calls-to-action ("Join the Waitlist," "Contact Us for a quote"). Without structured intake, these land in a shared inbox: no queue, no state, no ownership.
- **After the sale but before steady state**, onboarding is a long, stateful, multi-message correspondence: provision the instance, walk through CNAME and TLS setup, iterate on customizations, check in the following week.

This interval is the **ante-CRM period**: too early and too fluid for a CRM (no stable account, high back-and-forth, uncertain conversion), yet too important for a plain support inbox (these are the highest-value prospects, and the white-glove experience is itself the product differentiator).

The platform is a managed front door for this period — analogous to a traffic waiting room, except human-paced and relationship-shaped: it absorbs interest from a page or an inbox and turns it into an orderly, operator-driven pipeline of conversations.

## 2. The Operator Problem

Service delivery in this period generates a continuous stream of heterogeneous requests — questions, investigations, configuration changes, incident response — tied to specific customer relationships and arriving primarily by email.

The operator profile is a lateral thinker: strong at investigating, connecting dots, and solving novel problems; weak at the linear execution a queue demands (process the oldest item, update statuses, scan backlogs). Existing tools force the operator to be the sequencer. **The platform is the sequencer instead.** (SDD §1.)

## 3. Why Existing Tool Categories Do Not Fit

| Category | Examples | Disqualifying property |
|----------|----------|------------------------|
| PSA tools | HaloPSA, Odoo | Surfacing depends on the human diligently maintaining statuses |
| Onboarding platforms | Rocketlane, GuideCX | Model onboarding as a finite project with a completion milestone; the relationship here is indefinite |
| Ticketing systems | Zammad, Jira Service Management | Ticket-centric; the customer is context reached by clicking, not the primary object |

## 4. Product Thesis

1. **The relationship is the primary object.** Every conversation, task, and project is subordinate to a customer context.
2. **Capture has near-zero friction.** Email in, no mandatory fields; a message becomes a conversation becomes a task only when that transition is warranted.
3. **Open intake — a net, not a filter.** Unknown senders auto-create conversations; gates are where requests die silently. The spam cost is paid on the rejection side (cheap dismiss), not the intake side. (PP §1.)
4. **Attention is computed, not remembered.** A transparent, configurable scoring engine (idle time, state, tier, urgency, velocity, neglect) orders the queue; neglect thresholds fire per tier. Nothing depends on the operator remembering to check something.
5. **No hard lifecycle boundary.** A customer's first waitlist inquiry, their onboarding project, and a request two years later live in the same relationship context. Onboarding is a phase, not a separate system.
6. **The customer sees the relationship too.** A white-label-capable portal makes the conversation legible to the customer: file, follow, and reply without email.
7. **Identity is ambient.** A known participant is never re-asked for name or email; re-asking is support-ticket behavior, the model being rejected. (PP §2.)
8. **Self-hosted with data sovereignty.** The operator controls where customer data lives.

## 5. What the Platform Is

A single self-hosted application, route-partitioned into three surfaces:

- **Intake** — routed inbound webhooks (per-organization callback URLs carrying routing context in the channel), plus LMTP delivery and IMAP polling against operator-controlled mail infrastructure. All paths converge on one pipeline: verify, parse, resolve sender, thread, create or append to a conversation.
- **Operator surface** — the attention queue as the landing page; conversation detail with reply, internal notes, tasks, and state control; organization view with relationship context; neglect report; settings for scoring weights and thresholds.
- **Customer portal** — organization-scoped request list, conversation threads, new-request filing, portal-visible tasks and projects; white-label branding and custom domains.

The core object is the **conversation**: a five-state machine (New, Active, Waiting, Dormant, Resolved) with automatic transitions, email threading metadata, an immutable message log, and a cached attention score.

## 6. The MVP Bar

The platform proves its value when one loop works end-to-end: a prospect's pricing-page action or email becomes an identified conversation in an organization's queue; an operator replies from the queue and the reply arrives as a properly threaded email; delivery is tracked so a silent failure cannot burn a high-value prospect; the prospect follows the thread in the portal.

This loop is specified in the [Prospect Conversation Loop feature specification](spec-conversation-loop.md).

## 7. Document Map

All design documents live in `docs/design/`. Filenames are stable; versions are tracked in each document's header. Wireframe prototypes and screenshots remain in `wireframes/`.

| Document | Covers |
|----------|--------|
| [sdd.md](sdd.md) | Full system design: user stories US-1–US-11, architecture, data model, scoring algorithm, activation flow |
| [product-principles.md](product-principles.md) | Product principles: open intake, portal identity, operator workflow, scoring configuration |
| [design-decisions-email-routing.md](design-decisions-email-routing.md) | Design decisions: per-project routes, sender-resolution priority, uniqueness constraints, multi-webhook fan-out, delivery-status tracking |
| [sdd-status.md](sdd-status.md) | Implementation status against the SDD |
| [spec-conversation-loop.md](spec-conversation-loop.md) | Feature specification for the end-to-end MVP loop |
| [spec-public-intake.md](spec-public-intake.md) | Feature specification for pricing-page CTA intake: anonymous-first conversations, slug claim, resume access |
| [design-decisions-public-intake.md](design-decisions-public-intake.md) | Implementation decisions for public intake: slug registry, hashed tokens, prospect record, consent-gated outbound, nine-PR delivery stack |
| This document | Problem framing, product thesis, MVP bar |

**Reconciled in SDD v0.4:** SDD §5.2 (outbound) and §7 (activation flow, definition of done) now describe routed-webhook-first intake and platform-native outbound, matching the design decisions document and the conversation-loop spec; §3.3 and §4.1 were adjusted to match. The deeper architecture and data-model reconciliation — inbound-route entities, multi-webhook fan-out, per-project routes — remains in [design-decisions-email-routing.md](design-decisions-email-routing.md) and is not yet folded into SDD §3–§4.

## References

- Issue dependency graph and phased implementation order: `0326-email-landscape.txt`, `0327-custyard-foundational-status.txt`
- Outbound email and status-webhook recon: `0329-issue-26-outbound-email-replies.txt`, `0329-webhook-status-issue-25.txt`
