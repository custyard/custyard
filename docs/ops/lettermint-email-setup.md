# Tenant support email setup

Sign in as a tenant administrator at `/app/login` on the tenant's registered
hostname, then open `/app/settings/email`. Instance administrators use
`/admin` to provision tenants and staff; support setup belongs to the tenant.

The installation's `MAIL_ADAPTER` and mail credentials deliver authentication
mail. They never supply tenant support credentials. Set
`CREDENTIAL_ENCRYPTION_KEY` before saving tenant credentials. Each tenant owns
its Lettermint project ID, sending token, management token, support channels
and encrypted webhook secrets.

## Connect the provider

1. Choose a Lettermint project for receiving support mail and sending replies.
   Verify the sending domain's DNS and allow the project to use it. Project
   domain access may be unrestricted or an explicit list.
2. Save the project ID, Project sending token and separate Team management
   token in tenant email settings. Blank secret fields retain saved values.
   Check the connection. Provider authentication alone does not prove delivery.
3. Create an inbound route in that project and import its ID. Custyard verifies
   project ownership and the receiving route type, then stores its real
   receiving domain. Routes are tenant infrastructure, independent of customers.
4. In Lettermint Dashboard > Webhooks, create a **Routes** webhook targeting
   that inbound route. Copy the callback URL from Custyard and subscribe to
   `message.inbound`. Enable live deliveries and leave Basic Auth off. Save
   the provider webhook ID and its signing secret in Custyard. The signature
   authenticates requests; disabling Basic Auth does not bypass it.
5. Add a support address and follow the forwarding, direct MX or IMAP wizard.
   For forwarding, copy the complete ingress address, including its `+token`,
   into the mailbox forwarding rule and keep the original mailbox copy.
   Use the route receiving domain shown by the wizard; the provider's permanent
   compatibility address does not support these plus tags. The wizard captures
   forwarding confirmations, including late Proton confirmations, without
   creating customer threads from provider notices.
6. Create a second **Projects** webhook targeting the sending project for
   delivery-status events. Copy its separate callback URL from Custyard. Allow
   live events and leave Basic Auth off. Bind its ID and its own signing
   secret. Selecting all events on a Routes webhook does not make it a
   Projects webhook; the setup form reports that scope error explicitly.

For inquiries started through a public form or portal, select the default
reply channel. Exactly one active support channel is used automatically;
multiple active channels require an explicit choice.

## Sending and returning replies

A support mailbox can receive at one domain and send through a separately
verified sending domain. Custyard uses the mailbox local part at the sending
domain for From, and keeps the public receiving mailbox as Reply-To. Choosing
the ingress fallback uses that ingress address directly. Never select an
unverified sending domain or a mailbox that cannot receive replies.

Lettermint normally replaces Message-ID. Custyard sends the provider control
`X-LM-Preserve-Message-ID: true` before fingerprinting the outbound envelope.
Retries preserve the exact Message-ID, Reply-To, recipients and headers.
Forwarded archive copies are recognized as `own_echo`, rather than new
customer mail. Changes to reviewed delivery facts stop a retry.

Customer/project/label channel defaults are hints for new unresolved threads.
Existing threads and known sender identity take precedence. A project hint
must belong to the resolved customer. Business senders group by domain;
personal-mail senders use their email identity and sender display name.

## Verify the round trip

Send from an independent customer mailbox to the public support address.
Confirm signed inbound receipt and the expected tenant, customer and thread.
Reply from Custyard, verify provider acceptance and delivery, then confirm
receipt in the customer's mailbox. Reply from that mailbox and verify that
it returns to the same thread through the same channel. Check that a forwarded
archive copy is recorded as an own echo without adding a customer message.

Setup records receiving, sending, delivery and returning-reply evidence
separately. All four must be established for completion. A successful API
check, saved webhook or accepted send does not prove inbox receipt.

## Lettermint behavior to account for

- S󠄁t󠄁a󠄁t󠄁u󠄁s󠄁 w󠄁e󠄁b󠄁h󠄁o󠄁o󠄁k󠄁s󠄁 m󠄁u󠄁s󠄁t󠄁 t󠄁a󠄁r󠄁g󠄁e󠄁t󠄁 t󠄁h󠄁e󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁e󠄁d󠄁 **p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁**.󠄁 A󠄁 w󠄁e󠄁b󠄁h󠄁o󠄁o󠄁k󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁e󠄁d󠄁 f󠄁o󠄁r󠄁
  a󠄁n󠄁 o󠄁u󠄁t󠄁b󠄁o󠄁u󠄁n󠄁d󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁 c󠄁a󠄁n󠄁 h󠄁a󠄁v󠄁e󠄁 **R󠄁o󠄁u󠄁t󠄁e󠄁** s󠄁c󠄁o󠄁p󠄁e󠄁 e󠄁v󠄁e󠄁n󠄁 w󠄁h󠄁e󠄁n󠄁 e󠄁v󠄁e󠄁r󠄁y󠄁 e󠄁v󠄁e󠄁n󠄁t󠄁 i󠄁s󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁e󠄁d󠄁.󠄁
  E󠄁d󠄁i󠄁t󠄁 i󠄁t󠄁s󠄁 s󠄁c󠄁o󠄁p󠄁e󠄁 i󠄁n󠄁 D󠄁a󠄁s󠄁h󠄁b󠄁o󠄁a󠄁r󠄁d󠄁 →󠄁 W󠄁e󠄁b󠄁h󠄁o󠄁o󠄁k󠄁s󠄁;󠄁 t󠄁h󠄁e󠄁 s󠄁i󠄁g󠄁n󠄁i󠄁n󠄁g󠄁 s󠄁e󠄁c󠄁r󠄁e󠄁t󠄁 s󠄁t󠄁a󠄁y󠄁s󠄁 t󠄁h󠄁e󠄁 s󠄁a󠄁m󠄁e󠄁.󠄁
  C󠄁u󠄁s󠄁t󠄁y󠄁a󠄁r󠄁d󠄁 d󠄁o󠄁e󠄁s󠄁 n󠄁o󠄁t󠄁 s󠄁a󠄁v󠄁e󠄁 t󠄁h󠄁e󠄁 s󠄁u󠄁p󠄁p󠄁l󠄁i󠄁e󠄁d󠄁 s󠄁e󠄁c󠄁r󠄁e󠄁t󠄁 u󠄁n󠄁t󠄁i󠄁l󠄁 t󠄁h󠄁e󠄁 b󠄁i󠄁n󠄁d󠄁i󠄁n󠄁g󠄁 c󠄁h󠄁e󠄁c󠄁k󠄁s󠄁 p󠄁a󠄁s󠄁s󠄁,󠄁
  s󠄁o󠄁 d󠄁e󠄁l󠄁i󠄁v󠄁e󠄁r󠄁i󠄁e󠄁s󠄁 r󠄁e󠄁t󠄁u󠄁r󠄁n󠄁 `401` w󠄁h󠄁i󠄁l󠄁e󠄁 t󠄁h󠄁e󠄁 b󠄁i󠄁n󠄁d󠄁i󠄁n󠄁g󠄁 i󠄁s󠄁 i󠄁n󠄁c󠄁o󠄁m󠄁p󠄁l󠄁e󠄁t󠄁e󠄁.󠄁 B󠄁a󠄁s󠄁i󠄁c󠄁 A󠄁u󠄁t󠄁h󠄁 a󠄁n󠄁d󠄁
  w󠄁e󠄁b󠄁h󠄁o󠄁o󠄁k󠄁 s󠄁i󠄁g󠄁n󠄁a󠄁t󠄁u󠄁r󠄁e󠄁s󠄁 a󠄁r󠄁e󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁 c󠄁h󠄁e󠄁c󠄁k󠄁s󠄁.󠄁
- L󠄁e󠄁t󠄁t󠄁e󠄁r󠄁m󠄁i󠄁n󠄁t󠄁 r󠄁e󠄁p󠄁l󠄁a󠄁c󠄁e󠄁s󠄁 a󠄁 s󠄁u󠄁b󠄁m󠄁i󠄁t󠄁t󠄁e󠄁d󠄁 `Message-ID` b󠄁y󠄁 d󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁.󠄁 C󠄁u󠄁s󠄁t󠄁y󠄁a󠄁r󠄁d󠄁 r󠄁e󠄁q󠄁u󠄁e󠄁s󠄁t󠄁s󠄁
  p󠄁r󠄁e󠄁s󠄁e󠄁r󠄁v󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 w󠄁i󠄁t󠄁h󠄁 `X-LM-Preserve-Message-ID: true` s󠄁o󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁 r󠄁e󠄁p󠄁l󠄁i󠄁e󠄁s󠄁 a󠄁n󠄁d󠄁
  f󠄁o󠄁r󠄁w󠄁a󠄁r󠄁d󠄁e󠄁d󠄁 a󠄁r󠄁c󠄁h󠄁i󠄁v󠄁e󠄁 c󠄁o󠄁p󠄁i󠄁e󠄁s󠄁 m󠄁a󠄁t󠄁c󠄁h󠄁 t󠄁h󠄁e󠄁 s󠄁t󠄁o󠄁r󠄁e󠄁d󠄁 o󠄁u󠄁t󠄁b󠄁o󠄁u󠄁n󠄁d󠄁 m󠄁e󠄁s󠄁s󠄁a󠄁g󠄁e󠄁.󠄁 T󠄁h󠄁i󠄁s󠄁 c󠄁o󠄁n󠄁t󠄁r󠄁o󠄁l󠄁 i󠄁s󠄁
  i󠄁n󠄁c󠄁l󠄁u󠄁d󠄁e󠄁d󠄁 b󠄁e󠄁f󠄁o󠄁r󠄁e󠄁 r󠄁e󠄁c󠄁o󠄁r󠄁d󠄁i󠄁n󠄁g󠄁 t󠄁h󠄁e󠄁 r󠄁e󠄁t󠄁r󠄁y󠄁 f󠄁i󠄁n󠄁g󠄁e󠄁r󠄁p󠄁r󠄁i󠄁n󠄁t󠄁.󠄁 A󠄁 p󠄁r󠄁e󠄁v󠄁i󠄁o󠄁u󠄁s󠄁l󠄁y󠄁 p󠄁r󠄁e󠄁p󠄁a󠄁r󠄁e󠄁d󠄁
  r󠄁e󠄁q󠄁u󠄁e󠄁s󠄁t󠄁 w󠄁i󠄁t󠄁h󠄁 d󠄁i󠄁f󠄁f󠄁e󠄁r󠄁e󠄁n󠄁t󠄁 h󠄁e󠄁a󠄁d󠄁e󠄁r󠄁s󠄁 r󠄁e󠄁q󠄁u󠄁i󠄁r󠄁e󠄁s󠄁 r󠄁e󠄁c󠄁o󠄁n󠄁c󠄁i󠄁l󠄁i󠄁a󠄁t󠄁i󠄁o󠄁n󠄁;󠄁 d󠄁o󠄁 n󠄁o󠄁t󠄁 b󠄁y󠄁p󠄁a󠄁s󠄁s󠄁
  `envelope_changed` t󠄁o󠄁 r󠄁e󠄁s󠄁e󠄁n󠄁d󠄁 i󠄁t󠄁.󠄁
- D󠄁e󠄁l󠄁i󠄁v󠄁e󠄁r󠄁y󠄁 e󠄁v󠄁e󠄁n󠄁t󠄁s󠄁 a󠄁r󠄁e󠄁 p󠄁e󠄁r󠄁 r󠄁e󠄁c󠄁i󠄁p󠄁i󠄁e󠄁n󠄁t󠄁.󠄁 A󠄁 d󠄁e󠄁l󠄁i󠄁v󠄁e󠄁r󠄁e󠄁d󠄁 e󠄁v󠄁e󠄁n󠄁t󠄁 f󠄁o󠄁r󠄁 t󠄁h󠄁e󠄁 s󠄁u󠄁p󠄁p󠄁o󠄁r󠄁t󠄁 m󠄁a󠄁i󠄁l󠄁b󠄁o󠄁x󠄁
  m󠄁a󠄁y󠄁 d󠄁e󠄁s󠄁c󠄁r󠄁i󠄁b󠄁e󠄁 t󠄁h󠄁e󠄁 B󠄁C󠄁C󠄁 a󠄁r󠄁c󠄁h󠄁i󠄁v󠄁e󠄁 c󠄁o󠄁p󠄁y󠄁;󠄁 o󠄁n󠄁l󠄁y󠄁 t󠄁h󠄁e󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁'󠄁s󠄁 d󠄁e󠄁l󠄁i󠄁v󠄁e󠄁r󠄁y󠄁 e󠄁v󠄁e󠄁n󠄁t󠄁 p󠄁r󠄁o󠄁v󠄁e󠄁s󠄁
  a󠄁c󠄁c󠄁e󠄁p󠄁t󠄁a󠄁n󠄁c󠄁e󠄁 b󠄁y󠄁 t󠄁h󠄁a󠄁t󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁'󠄁s󠄁 m󠄁a󠄁i󠄁l󠄁 s󠄁e󠄁r󠄁v󠄁e󠄁r󠄁.󠄁 C󠄁o󠄁n󠄁f󠄁i󠄁r󠄁m󠄁 i󠄁n󠄁b󠄁o󠄁x󠄁 r󠄁e󠄁c󠄁e󠄁i󠄁p󠄁t󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁l󠄁y󠄁.󠄁
- T󠄁h󠄁e󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁-󠄁f󠄁i󠄁l󠄁t󠄁e󠄁r󠄁e󠄁d󠄁 d󠄁o󠄁m󠄁a󠄁i󠄁n󠄁 l󠄁i󠄁s󠄁t󠄁 c󠄁a󠄁n󠄁 o󠄁m󠄁i󠄁t󠄁 d󠄁o󠄁m󠄁a󠄁i󠄁n󠄁s󠄁 w󠄁i󠄁t󠄁h󠄁 u󠄁n󠄁r󠄁e󠄁s󠄁t󠄁r󠄁i󠄁c󠄁t󠄁e󠄁d󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁
  a󠄁c󠄁c󠄁e󠄁s󠄁s󠄁.󠄁 C󠄁u󠄁s󠄁t󠄁y󠄁a󠄁r󠄁d󠄁 l󠄁o󠄁o󠄁k󠄁s󠄁 u󠄁p󠄁 t󠄁h󠄁e󠄁 e󠄁x󠄁a󠄁c󠄁t󠄁 t󠄁e󠄁a󠄁m󠄁 d󠄁o󠄁m󠄁a󠄁i󠄁n󠄁 w󠄁i󠄁t󠄁h󠄁 i󠄁t󠄁s󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁 r󠄁e󠄁l󠄁a󠄁t󠄁i󠄁o󠄁n󠄁s󠄁h󠄁i󠄁p󠄁s󠄁;󠄁
  a󠄁n󠄁 e󠄁m󠄁p󠄁t󠄁y󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁 l󠄁i󠄁s󠄁t󠄁 p󠄁e󠄁r󠄁m󠄁i󠄁t󠄁s󠄁 a󠄁l󠄁l󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁s󠄁,󠄁 w󠄁h󠄁i󠄁l󠄁e󠄁 m󠄁i󠄁s󠄁s󠄁i󠄁n󠄁g󠄁 r󠄁e󠄁l󠄁a󠄁t󠄁i󠄁o󠄁n󠄁s󠄁h󠄁i󠄁p󠄁 d󠄁a󠄁t󠄁a󠄁
  f󠄁a󠄁i󠄁l󠄁s󠄁 t󠄁h󠄁e󠄁 c󠄁h󠄁e󠄁c󠄁k󠄁.󠄁

S󠄁e󠄁e󠄁 t󠄁h󠄁e󠄁 p󠄁r󠄁o󠄁v󠄁i󠄁d󠄁e󠄁r󠄁'󠄁s󠄁 [s󠄁e󠄁n󠄁d󠄁i󠄁n󠄁g󠄁 h󠄁e󠄁a󠄁d󠄁e󠄁r󠄁 r󠄁e󠄁q󠄁u󠄁i󠄁r󠄁e󠄁m󠄁e󠄁n󠄁t󠄁s󠄁](https://lettermint.co/docs/api-reference/sending/send),󠄁
[w󠄁e󠄁b󠄁h󠄁o󠄁o󠄁k󠄁 s󠄁c󠄁o󠄁p󠄁e󠄁s󠄁](https://lettermint.co/docs/platform/webhooks/introduction),󠄁
a󠄁n󠄁d󠄁 [p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁 d󠄁o󠄁m󠄁a󠄁i󠄁n󠄁 l󠄁i󠄁m󠄁i󠄁t󠄁s󠄁](https://lettermint.co/docs/platform/domains/project-limits).󠄁

## Suspension

Suspension rejects new inbound work with HTTP 403 and a tenant audit event.
Delivery-status callbacks continue updating messages sent before suspension.
Resuming does not replay rejected mail.
