# Pilot mail verification

## Setup completion regression after adding a second address

The 2026-10-29 billing-address round trip had a delivered Custyard reply and
a returning customer email, but the attention queue again showed **Finish
email setup**. Saving the portal/form default address cleared accepted,
delivered and returning-reply evidence and advanced the reply evidence boundary,
even when the selected default had not changed. That setting chooses a reply
address for new portal and form requests; it does not change the sending
credentials or invalidate an observed email round trip.

The local fix preserves delivery evidence when choosing or resaving that
default. Resaving the same provider tokens also preserves the evidence and
provider checks; genuinely changed credentials and sending identities still
require fresh observations. The queue subscribes to its tenant's setup updates,
so it removes the banner when the final observation arrives. An incomplete
configured connection lists the specific missing observations instead of asking
the administrator to repeat already completed forwarding steps.

Regression tests cover default changes and repeated saves, unchanged tokens,
actual token rotation, and live queue completion updates. This change has not
been deployed, and the live pilot's evidence has not been rewritten or replayed.

## Forwarding confirmation callback repair

On 2026-10-29, OneTimeSecret's Proton forwarding confirmation reached Lettermint,
but the provider callback returned HTTP 401. The inbound webhook
`01a18047-c876-7248-bef2-7efce4d028a0` had project scope and targeted the tenant's
outbound delivery-status callback. Its URL did not match the saved inbound route.
The tenant's inbound signing secret was present and decryptable; no status
webhook or status signing secret was bound.

Restored this webhook to route scope for inbound route
`01a18046-0e70-70d6-87c6-a33cb68205ca` and its existing Custyard inbound callback
URL, preserving the signing secret. Confirmed live delivery mode, enabled state,
`message.inbound` subscription, and Basic Auth disabled.

Retried delivery `f82abe7c-b72b-53f0-b79f-7cc557df22f0` through Lettermint. Attempt 3
succeeded at 07:29:08 UTC with HTTP 200 and response
`{"reason":"verification_captured","status":"ignored"}`. This confirms signature
acceptance, inbound channel resolution, and capture of the forwarding notice.

The tenant administrator must accept the captured Proton link in the channel's
Forward step and confirm forwarding. A normal external message, outbound reply,
and returning reply remain separate verification steps. This repair changed
provider configuration only; no application code, database reset, secret rotation,
or outbound support email was required.

No callback tokens, provider credentials, confirmation links, or message bodies
are included in this record.

## Outbound status callback repair

The tenant administrator subsequently confirmed inbound mail was working.
The separate `Sending messages events` webhook
`01a1811a-176d-7311-8a94-5bff13d5c373` returned HTTP 401. Live inspection found
the correct project scope and event subscriptions, but an obsolete callback URL.
OneTimeSecret had no saved status-webhook ID or signing secret.

Updated this webhook to the current tenant status callback URL, regenerated its
signing secret, and saved the encrypted secret through the tenant email setup
binding function with the configured tenant administrator's authority checks.
The secret remained inside the remote process and was not printed.

Retried delivery `f97a8842-9315-5b5e-a446-005d0c0020d5`. Attempt 2 succeeded at
07:37:35 UTC on 2026-10-29 with HTTP 200 and response
`{"reason":"unknown_message","status":"ignored"}`. This proves the provider's
signed callback authenticates. The event does not match a recorded tenant support
reply, so no message status was changed. A reply sent from a Custyard tenant thread
is still needed to prove the delivery-status update for an actual support message.

## Completed support round trip

The tenant administrator sent a support reply from Custyard and replied back
from Mail.app. Live records show the original inbound message (1), staff reply
(2), and returning customer message (3) all on tenant 1, thread 1. Sending was
accepted at 07:46:03 UTC and the returning reply was recorded at 07:48:04 UTC
on 2026-10-29.

Lettermint reported the staff reply delivered, but its three recipient delivery
callbacks had received HTTP 401. Replayed only the callbacks whose provider
message ID matched this staff reply. All three retries returned HTTP 200 with
`{"status":"ok"}`; the staff message now has delivery status `delivered`.

At 07:51 UTC, the live setup summary reports receiving, sending, delivered,
returning, and complete all true. The queue banner's completion condition now
hides the setup prompt when the page reloads its data. This is database and
provider evidence; the refreshed browser banner was not visually inspected.
