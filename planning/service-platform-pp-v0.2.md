# Product Principles: Relationship-Driven Service Platform

**Version:** 0.2 — Aligned with SDD v0.2
**Date:** 2026-03-24

---

## Document Purpose

This document captures durable product guidance that emerged from implementation decisions. It bridges the SDD's specification of *what* with guidance on *how to think about edge cases* during implementation.

**Maintenance guidance:** Do not paraphrase or editorialize when adding entries. Shortening and condensing is encouraged but not at the loss of nuance. Fewer items captured at high fidelity is preferable to more items with diluted precision.

---

## 1. Platform Posture: Net Model, Not Filter

The platform sits on the open-vs-gated spectrum toward open. The intake channel that distinguishes this from pure onboarding platforms is email, and email is inherently open. Anyone can send to a monitored address.

**Auto-creating contacts and orgs for unknown senders makes the platform a net. Rejecting or gating makes it a filter.** The net model fits the problem statement because one of the explicit failure modes being solved is things getting lost during the lateral thinking phase. If an unknown sender hits a gate, and the operator is deep in a TLS incident for Acme Corp, that gate becomes a place where requests die silently. The whole point of the attention queue is that nothing requires the operator to remember to check something.

The risk of the net model is garbage: spam, vendor outreach, automated notifications all become conversations. **The mitigation isn't gating; it's making the unmatched queue cheap to triage.** A quick-dismiss action ("not a customer request") that archives without creating a real contact. The system is open on intake, cheap on rejection, and nothing blocks on operator action to enter the system.

---

## 2. Identity Model: Ambient, Not Re-Collected

Portal users authenticate with email/password (SSO in v2). If the customer is logged in, forms should not re-ask for information the system already has.

**Identity is ambient via session.** This is onboarding-platform behavior: once you're in the shared workspace, you're a known participant. Adding name/email fields to the portal request form would feel like a support ticket system, which is exactly the model being moved away from.

---

## 3. The `/` Route: Infrastructure, Not Storefront

The platform has two authentication domains (operator and portal), so `/` needs to bifurcate:

- Redirect to `/operator/attention` if there's an active operator session
- Redirect to the portal login if accessed via a customer-facing domain (custom CNAME)
- Show a minimal login chooser if neither condition is met

**No marketing page.** This isn't a product you're selling from its own UI; it's infrastructure you've deployed. The login screen is the front door, not a storefront.

---

## 4. Operator Friction: Reversibility Beats Confirmation

### 4.1 View = Claim (Single-Operator MVP)

For a single-operator system (which the MVP is), auto-transition from New to Active on view is correct. There's no "someone else might be working on this" ambiguity. The operator viewed it, the operator is the only operator, therefore it's active.

This reduces one more manual status update the operator has to remember. The platform being the sequencer means the platform decides when something is active, and "the operator looked at it" is a strong signal.

**Revisit for multi-operator v2**, where "view" and "claim" diverge (an operator might open a conversation to read context for a different conversation, not to work on it).

### 4.2 No Confirmation on Resolve

**Confirmation dialogs are a linear-thinker safety net:** "are you sure you want to complete this sequential step?" For someone who's bouncing between five conversations, a modal that interrupts the flow of "done, done, come back to this, done" adds friction at exactly the wrong moment.

The cost of accidental resolution is low because:
1. Any inbound message on a Resolved conversation transitions it back to Active (per SDD)
2. An explicit Reopen action exists for operator-initiated correction

**State transitions are fluid, not ceremonial.**

---

## 5. Scoring Transparency: Effects, Not Inputs

The scoring weights are the platform's judgment parameters — the knobs that tune how the linear thinker thinks. The operator needs to understand what they're changing and see the effect.

Text inputs vs. sliders for weight configuration is a cosmetic question. **The real question is whether the input method communicates the effect of the change.** What the operator actually wants to know is: "if I increase the tier weight, what happens to my current queue?"

A live preview of the attention queue re-ordering as weights are adjusted is more valuable than the input mechanism itself. Without preview, sliders and text inputs are equally opaque. With preview, sliders win because they invite exploration (drag and see what happens) in a way text inputs don't.

**The investment is slider-with-live-queue-preview vs. any static input method.** The preview is what makes the scoring algorithm trustworthy, which the SDD calls out as an acceptance criterion ("the scoring algorithm is transparent").

---

## Appendix: Open Questions for Future Versions

These items were identified during implementation review but deferred as v2 concerns:

- **Multi-operator claim semantics**: When view ≠ claim, what's the explicit claim action?
- **Unmatched queue triage UX**: Quick-dismiss action design, bulk operations
- **Custom domain deployment model**: Host header validation depends on reverse proxy configuration
