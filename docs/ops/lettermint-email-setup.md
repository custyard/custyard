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

## Add more addresses

Reuse the tenant's inbound route for additional addresses such as `billing@`
and `payments@`. Choose **Add support address** for each one and complete its
channel wizard. Each forwarding channel has its own ingress address and token.
A Custyard project does not require a separate route; create another route for
separate provider receiving configuration or another direct-MX domain.

Set **Default customer**, **Default project** and **Default label** on each
address's card. Shared addresses normally use **Resolve from sender** for the
customer; `billing@` can apply the **Billing** label to new threads. Each address
supports one default label, and individual threads can have additional labels.
See [Connecting a support address](inbound-channels.md#multiple-addresses-routes-and-defaults)
for routing defaults and precedence.

For inquiries started through a public form or portal, select the default
reply channel. Exactly one active support channel is used automatically;
multiple active channels require an explicit choice.

The thread composer also has a **From** selector for active tenant addresses.
Selecting an address applies to that reply; it does not change the tenant's
default or the thread's receiving channel. When the public mailbox and sending
domain differ, the selector shows the actual sending address. The installation's
authentication-mail sender is never offered as a tenant support address.

For shared customer portal links, choose **Default contact for shared portal
requests** on the customer page. Personal-email customers created from inbound
mail get their matching contact as the default automatically. A portal link
issued for a specific contact uses that contact instead. Business customers
require an explicit choice; Custyard does not guess from a list of contacts.
Existing portal requests without contact attribution can use this default too.

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

- Status webhooks must target the selected **project**. A webhook created for
  an outbound route can have **Route** scope even when every event is selected.
  Edit its scope in Dashboard → Webhooks; the signing secret stays the same.
  Custyard does not save the supplied secret until the binding checks pass,
  so deliveries return `401` while the binding is incomplete. Basic Auth and
  webhook signatures are separate checks.
- Lettermint replaces a submitted `Message-ID` by default. Custyard requests
  preservation with `X-LM-Preserve-Message-ID: true` so customer replies and
  forwarded archive copies match the stored outbound message. This control is
  included before recording the retry fingerprint. A previously prepared
  request with different headers requires reconciliation; do not bypass
  `envelope_changed` to resend it.
- Delivery events are per recipient. A delivered event for the support mailbox
  may describe the BCC archive copy; only the customer's delivery event proves
  acceptance by that customer's mail server. Confirm inbox receipt separately.
- The project-filtered domain list can omit domains with unrestricted project
  access. Custyard looks up the exact team domain with its project relationships;
  an empty project list permits all projects, while missing relationship data
  fails the check.

See the provider's [sending header requirements](https://lettermint.co/docs/api-reference/sending/send),
[webhook scopes](https://lettermint.co/docs/platform/webhooks/introduction),
and [project domain limits](https://lettermint.co/docs/platform/domains/project-limits).

## Suspension

Suspension rejects new inbound work with HTTP 403 and a tenant audit event.
Delivery-status callbacks continue updating messages sent before suspension.
Resuming does not replay rejected mail.
