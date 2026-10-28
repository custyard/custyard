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

Suspension rejects new inbound work with HTTP 403 and a tenant audit event.
Delivery-status callbacks continue updating messages sent before suspension.
Resuming does not replay rejected mail.
