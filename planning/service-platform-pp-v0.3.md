# Product Principles: Relationship-Driven Service Platform

**Version:** 0.2 — Aligned with SDD v0.2
**Date:** 2026-03-24

---

**Maintenance guidance:** Do not paraphrase, add flourish, or editorialize when adding entries. Shortening and condensing is encouraged but not at the loss of nuance. Fewer items captured at high fidelity is preferable to more items with diluted precision.

---

## 1. Open Intake Model

The platform sits on the open-vs-gated spectrum toward open. The intake channel that distinguishes this from pure onboarding platforms is email, and email is inherently open. Anyone can send to a monitored address.

Auto-creating contacts and orgs for unknown senders makes the platform a net. Rejecting or gating makes it a filter. The net model fits the problem statement because one of the explicit failure modes being solved is things getting lost during the lateral thinking phase. If an unknown sender hits a gate, and the operator is deep in a TLS incident for Acme Corp, that gate becomes a place where requests die silently. The whole point of the attention queue is that nothing requires the operator to remember to check something.

The risk of the net model is garbage: spam, vendor outreach, automated notifications all become conversations. The mitigation isn't gating; it's making the unmatched queue cheap to triage. A quick-dismiss action ("not a customer request") that archives without creating a real contact. The system is open on intake, cheap on rejection, and nothing blocks on operator action to enter the system.

---

## 2. Portal Identity

Portal users authenticate with email/password (SSO in v2). If the customer is logged in, the form doesn't need to collect name/email because the system already knows who they are. The form should not re-ask for information the system has. This is onboarding-platform behavior: once you're in the shared workspace, you're a known participant. Your identity is ambient. Adding name/email fields to the portal form would feel like a support ticket system, which is exactly the model being moved away from.

---

## 3. The `/` Route

The platform has two authentication domains (operator and portal), so `/` needs to bifurcate:

- Redirect to `/operator/attention` if there's an active operator session
- Redirect to the portal login if accessed via a customer-facing domain (custom CNAME)
- Show a minimal login chooser if neither condition is met

No marketing page. This isn't a product you're selling from its own UI; it's infrastructure you've deployed.

---

## 4. Operator Workflow

### 4.1 Auto-Transition on View

For a single-operator system (which the MVP is), auto-transition from New to Active on view is correct. There's no "someone else might be working on this" ambiguity. The operator viewed it, the operator is the only operator, therefore it's active. The SDD already specifies this, and the wireframe reflects it.

Revisit for multi-operator v2. At that point, "view" and "claim" diverge. An operator might open a conversation to read context for a different conversation, not to work on it.

### 4.2 No Confirmation on Resolve

No confirmation on resolve is correct for the lateral thinker profile. Confirmation dialogs are a linear-thinker safety net: "are you sure you want to complete this sequential step?" For someone who's bouncing between five conversations, a modal that interrupts the flow of "done, done, come back to this, done" adds friction at exactly the wrong moment. The cost of accidental resolution is low because of how Reopen works.

### 4.3 Reopen Action

The SDD already specifies that any inbound message on a Resolved conversation transitions it back to Active. So "reopen" already exists as a natural consequence of the customer replying. The missing case is operator-initiated reopen: "I resolved this but I was wrong, there's more work." Adding an explicit Reopen action that transitions Resolved back to Active is the right call. It's cheap (one state transition, no workflow implications), it eliminates the need for a confirmation dialog on resolve (because the mistake is easily reversible), and it matches the onboarding platform pattern where project states are fluid rather than ceremonial.

The resolved state should have a visual "Reopen" affordance on the conversation detail, but it should not appear in the attention queue by default. Resolved means out of queue unless reactivated.

---

## 5. Scoring Weight Configuration

Sliders for scoring weights: the onboarding platform research doesn't directly inform this, but the platform-as-sequencer principle does. The scoring weights are the platform's judgment parameters. The operator needs to understand what they're changing and see the effect.

Text inputs are functional but abstract. Sliders add visual proportionality (you can see that tier weight is "bigger" than velocity weight). But the real question is whether either input method communicates the effect of the change. What the operator actually wants to know is: "if I increase the tier weight, what happens to my current queue?" A live preview of the attention queue re-ordering as you drag the slider would be more valuable than the input mechanism itself. Without that, sliders and text inputs are equally opaque. With that, sliders win because they invite exploration (drag and see what happens) in a way text inputs don't.

If you build the settings screen, the investment isn't slider-vs-text. It's slider-with-live-queue-preview vs. any static input method. The preview is what makes the scoring algorithm trustworthy, which the SDD calls out as an acceptance criterion ("the scoring algorithm is transparent").

---

## References

* Claude Coworker threads
  * "Design customer service platform wireframes"
