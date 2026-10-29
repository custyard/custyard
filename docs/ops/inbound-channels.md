# Connecting a support address

A channel connects one public address, such as `support@companyname.com`, to
Custyard. Open **Email setup** at `/app/settings/email` on the tenant's host
to connect its provider project, receiving route and signed webhooks, then
choose **Add support address**. Channels belong to the tenant; customer pages
have no channel or provider configuration. The
wizard has four steps, and each one picks up where the channel left off. The
design is in [spec-inbound-channels](../design/spec-inbound-channels.md).

S󠄁e󠄁e󠄁 [L󠄁e󠄁t󠄁t󠄁e󠄁r󠄁m󠄁i󠄁n󠄁t󠄁 e󠄁m󠄁a󠄁i󠄁l󠄁 s󠄁e󠄁t󠄁u󠄁p󠄁](lettermint-email-setup.md) f󠄁o󠄁r󠄁 c󠄁r󠄁e󠄁d󠄁e󠄁n󠄁t󠄁i󠄁a󠄁l󠄁s󠄁,󠄁 m󠄁a󠄁n󠄁u󠄁a󠄁l󠄁
p󠄁r󠄁o󠄁v󠄁i󠄁d󠄁e󠄁r󠄁 s󠄁t󠄁e󠄁p󠄁s󠄁,󠄁 a󠄁n󠄁d󠄁 t󠄁h󠄁e󠄁 c󠄁o󠄁m󠄁p󠄁l󠄁e󠄁t󠄁e󠄁 r󠄁e󠄁c󠄁e󠄁i󠄁v󠄁e󠄁/󠄁r󠄁e󠄁p󠄁l󠄁y󠄁 t󠄁e󠄁s󠄁t󠄁.󠄁

Pick how mail arrives:

| Kind | Use it when | DNS change | Mailbox keeps the mail |
| --- | --- | --- | --- |
| Forward from an existing mailbox | The address lives at Proton, Gmail, Google Workspace or another provider that can forward | None for receiving | Yes |
| Direct MX on a dedicated subdomain | You can give support its own subdomain, such as `help.companyname.com` | One MX record on that subdomain | No mailbox is involved |
| Read a mailbox over IMAP | Forwarding is not available, and the provider allows IMAP with an app password | None | Yes; Custyard only reads |

Every channel replies from its public address. Replies authenticate only when
the public address domain is a verified sending domain in Lettermint. The last
wizard step checks that.

## Multiple addresses, routes and defaults

A󠄁 r󠄁e󠄁c󠄁e󠄁i󠄁v󠄁i󠄁n󠄁g󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁 b󠄁e󠄁l󠄁o󠄁n󠄁g󠄁s󠄁 t󠄁o󠄁 t󠄁h󠄁e󠄁 t󠄁e󠄁n󠄁a󠄁n󠄁t󠄁 a󠄁n󠄁d󠄁 c󠄁a󠄁n󠄁 c󠄁a󠄁r󠄁r󠄁y󠄁 s󠄁e󠄁v󠄁e󠄁r󠄁a󠄁l󠄁 e󠄁m󠄁a󠄁i󠄁l󠄁 c󠄁h󠄁a󠄁n󠄁n󠄁e󠄁l󠄁s󠄁.󠄁
R󠄁e󠄁u󠄁s󠄁e󠄁 i󠄁t󠄁 f󠄁o󠄁r󠄁 a󠄁d󠄁d󠄁r󠄁e󠄁s󠄁s󠄁e󠄁s󠄁 s󠄁u󠄁c󠄁h󠄁 a󠄁s󠄁 `support@`,󠄁 `billing@` a󠄁n󠄁d󠄁 `payments@`;󠄁 n󠄁e󠄁i󠄁t󠄁h󠄁e󠄁r󠄁 a󠄁
n󠄁e󠄁w󠄁 a󠄁d󠄁d󠄁r󠄁e󠄁s󠄁s󠄁 n󠄁o󠄁r󠄁 a󠄁 C󠄁u󠄁s󠄁t󠄁y󠄁a󠄁r󠄁d󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁 r󠄁e󠄁q󠄁u󠄁i󠄁r󠄁e󠄁s󠄁 i󠄁t󠄁s󠄁 o󠄁w󠄁n󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁.󠄁 U󠄁s󠄁e󠄁 a󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁
w󠄁h󠄁e󠄁n󠄁 y󠄁o󠄁u󠄁 n󠄁e󠄁e󠄁d󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁 p󠄁r󠄁o󠄁v󠄁i󠄁d󠄁e󠄁r󠄁 r󠄁e󠄁c󠄁e󠄁i󠄁v󠄁i󠄁n󠄁g󠄁 c󠄁o󠄁n󠄁f󠄁i󠄁g󠄁u󠄁r󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 o󠄁r󠄁 a󠄁n󠄁o󠄁t󠄁h󠄁e󠄁r󠄁 d󠄁i󠄁r󠄁e󠄁c󠄁t󠄁-󠄁M󠄁X󠄁
d󠄁o󠄁m󠄁a󠄁i󠄁n󠄁.󠄁 A󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁 h󠄁a󠄁s󠄁 o󠄁n󠄁e󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁 r󠄁e󠄁c󠄁e󠄁i󠄁v󠄁i󠄁n󠄁g󠄁 d󠄁o󠄁m󠄁a󠄁i󠄁n󠄁.󠄁

I󠄁n󠄁 **E󠄁m󠄁a󠄁i󠄁l󠄁 s󠄁e󠄁t󠄁u󠄁p󠄁**,󠄁 c󠄁h󠄁o󠄁o󠄁s󠄁e󠄁 **A󠄁d󠄁d󠄁 s󠄁u󠄁p󠄁p󠄁o󠄁r󠄁t󠄁 a󠄁d󠄁d󠄁r󠄁e󠄁s󠄁s󠄁** f󠄁o󠄁r󠄁 e󠄁a󠄁c󠄁h󠄁 p󠄁u󠄁b󠄁l󠄁i󠄁c󠄁 a󠄁d󠄁d󠄁r󠄁e󠄁s󠄁s󠄁.󠄁
F󠄁o󠄁r󠄁w󠄁a󠄁r󠄁d󠄁 e󠄁a󠄁c󠄁h󠄁 m󠄁a󠄁i󠄁l󠄁b󠄁o󠄁x󠄁 t󠄁o󠄁 t󠄁h󠄁e󠄁 c󠄁o󠄁m󠄁p󠄁l󠄁e󠄁t󠄁e󠄁 i󠄁n󠄁g󠄁r󠄁e󠄁s󠄁s󠄁 a󠄁d󠄁d󠄁r󠄁e󠄁s󠄁s󠄁 g󠄁e󠄁n󠄁e󠄁r󠄁a󠄁t󠄁e󠄁d󠄁 f󠄁o󠄁r󠄁 i󠄁t󠄁s󠄁 c󠄁h󠄁a󠄁n󠄁n󠄁e󠄁l󠄁,󠄁
i󠄁n󠄁c󠄁l󠄁u󠄁d󠄁i󠄁n󠄁g󠄁 i󠄁t󠄁s󠄁 o󠄁w󠄁n󠄁 `+token`,󠄁 e󠄁v󠄁e󠄁n󠄁 w󠄁h󠄁e󠄁n󠄁 t󠄁h󠄁e󠄁 c󠄁h󠄁a󠄁n󠄁n󠄁e󠄁l󠄁s󠄁 s󠄁h󠄁a󠄁r󠄁e󠄁 a󠄁 r󠄁e󠄁c󠄁e󠄁i󠄁v󠄁i󠄁n󠄁g󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁.󠄁

E󠄁a󠄁c󠄁h󠄁 a󠄁d󠄁d󠄁r󠄁e󠄁s󠄁s󠄁'󠄁s󠄁 c󠄁a󠄁r󠄁d󠄁 h󠄁a󠄁s󠄁 **D󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁**,󠄁 **D󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁** a󠄁n󠄁d󠄁
**D󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁 l󠄁a󠄁b󠄁e󠄁l󠄁** s󠄁e󠄁t󠄁t󠄁i󠄁n󠄁g󠄁s󠄁.󠄁 F󠄁o󠄁r󠄁 s󠄁h󠄁a󠄁r󠄁e󠄁d󠄁 m󠄁a󠄁i󠄁l󠄁b󠄁o󠄁x󠄁e󠄁s󠄁,󠄁 l󠄁e󠄁a󠄁v󠄁e󠄁 t󠄁h󠄁e󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁 a󠄁s󠄁
**R󠄁e󠄁s󠄁o󠄁l󠄁v󠄁e󠄁 f󠄁r󠄁o󠄁m󠄁 s󠄁e󠄁n󠄁d󠄁e󠄁r󠄁**.󠄁 F󠄁o󠄁r󠄁 e󠄁x󠄁a󠄁m󠄁p󠄁l󠄁e󠄁,󠄁 g󠄁i󠄁v󠄁e󠄁 `billing@` t󠄁h󠄁e󠄁 **B󠄁i󠄁l󠄁l󠄁i󠄁n󠄁g󠄁** l󠄁a󠄁b󠄁e󠄁l󠄁 a󠄁n󠄁d󠄁
`payments@` t󠄁h󠄁e󠄁 **P󠄁a󠄁y󠄁m󠄁e󠄁n󠄁t󠄁s󠄁** l󠄁a󠄁b󠄁e󠄁l󠄁.󠄁 T󠄁h󠄁e󠄁 a󠄁d󠄁d󠄁r󠄁e󠄁s󠄁s󠄁 s󠄁u󠄁p󠄁p󠄁o󠄁r󠄁t󠄁s󠄁 o󠄁n󠄁e󠄁 d󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁 l󠄁a󠄁b󠄁e󠄁l󠄁;󠄁
i󠄁n󠄁d󠄁i󠄁v󠄁i󠄁d󠄁u󠄁a󠄁l󠄁 t󠄁h󠄁r󠄁e󠄁a󠄁d󠄁s󠄁 c󠄁a󠄁n󠄁 h󠄁a󠄁v󠄁e󠄁 a󠄁d󠄁d󠄁i󠄁t󠄁i󠄁o󠄁n󠄁a󠄁l󠄁 l󠄁a󠄁b󠄁e󠄁l󠄁s󠄁.󠄁

D󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁s󠄁 a󠄁p󠄁p󠄁l󠄁y󠄁 t󠄁o󠄁 n󠄁e󠄁w󠄁 t󠄁h󠄁r󠄁e󠄁a󠄁d󠄁s󠄁.󠄁 K󠄁n󠄁o󠄁w󠄁n󠄁 s󠄁e󠄁n󠄁d󠄁e󠄁r󠄁 i󠄁d󠄁e󠄁n󠄁t󠄁i󠄁t󠄁y󠄁 t󠄁a󠄁k󠄁e󠄁s󠄁 p󠄁r󠄁e󠄁c󠄁e󠄁d󠄁e󠄁n󠄁c󠄁e󠄁 o󠄁v󠄁e󠄁r󠄁 t󠄁h󠄁e󠄁
c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁 d󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁,󠄁 a󠄁n󠄁d󠄁 a󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁 d󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁 m󠄁u󠄁s󠄁t󠄁 b󠄁e󠄁l󠄁o󠄁n󠄁g󠄁 t󠄁o󠄁 t󠄁h󠄁e󠄁 r󠄁e󠄁s󠄁o󠄁l󠄁v󠄁e󠄁d󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁.󠄁
R󠄁e󠄁p󠄁l󠄁i󠄁e󠄁s󠄁 t󠄁o󠄁 e󠄁x󠄁i󠄁s󠄁t󠄁i󠄁n󠄁g󠄁 t󠄁h󠄁r󠄁e󠄁a󠄁d󠄁s󠄁 d󠄁o󠄁 n󠄁o󠄁t󠄁 c󠄁h󠄁a󠄁n󠄁g󠄁e󠄁 t󠄁h󠄁e󠄁i󠄁r󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁,󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁 o󠄁r󠄁 l󠄁a󠄁b󠄁e󠄁l󠄁s󠄁.󠄁
E󠄁m󠄁a󠄁i󠄁l󠄁 t󠄁h󠄁r󠄁e󠄁a󠄁d󠄁s󠄁 r󠄁e󠄁t󠄁a󠄁i󠄁n󠄁 t󠄁h󠄁e󠄁i󠄁r󠄁 r󠄁e󠄁c󠄁e󠄁i󠄁v󠄁i󠄁n󠄁g󠄁 c󠄁h󠄁a󠄁n󠄁n󠄁e󠄁l󠄁 f󠄁o󠄁r󠄁 r󠄁e󠄁p󠄁l󠄁i󠄁e󠄁s󠄁.󠄁 S󠄁e󠄁l󠄁e󠄁c󠄁t󠄁 t󠄁h󠄁e󠄁 t󠄁e󠄁n󠄁a󠄁n󠄁t󠄁'󠄁s󠄁
d󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁 r󠄁e󠄁p󠄁l󠄁y󠄁 a󠄁d󠄁d󠄁r󠄁e󠄁s󠄁s󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁l󠄁y󠄁 f󠄁o󠄁r󠄁 r󠄁e󠄁q󠄁u󠄁e󠄁s󠄁t󠄁s󠄁 s󠄁t󠄁a󠄁r󠄁t󠄁e󠄁d󠄁 t󠄁h󠄁r󠄁o󠄁u󠄁g󠄁h󠄁 a󠄁 p󠄁o󠄁r󠄁t󠄁a󠄁l󠄁 o󠄁r󠄁 f󠄁o󠄁r󠄁m󠄁.󠄁

## Forwarding

The wizard shows a secret ingress address,
`support+<token>@<route-id>.lettermint.app`. Your provider forwards to it. The
address never changes when a custom domain is added to the route later. Rotate
the token from the channel card if it leaks: the old token keeps working for 7
days, so there is time to update the forwarding rule.

- **Proton Mail** (paid plans): Settings, Auto forward, Add forwarding rule.
  Proton sends an "Accept forwarding" email to the ingress address, and the
  wizard shows its link. Forwarding outside Proton turns off end-to-end
  encryption for that address.
- **Gmail, or Google Workspace per user**: Settings, See all settings,
  Forwarding and POP/IMAP. Google sends a confirmation code to the ingress
  address; the wizard shows it, and you enter it back in Gmail.
- **Other providers**: create a rule that forwards a copy and keeps the
  original. If the provider sends a confirmation email, the wizard shows it.

### Google Workspace admin routing

Workspace admins can block per-user forwarding. A Gmail settings administrator
can route a copy of the support address's mail instead. Choose the provider
"Google Workspace (admin routing)" in the wizard, then do the following in the
Admin console:

1. Open Apps, Google Workspace, Gmail, Default routing, and choose Configure.
2. Under "Specify envelope recipients to match", choose Single recipient and
   enter the public address.
3. Choose Modify message, then Add more recipients, then Add. Enter the full
   ingress address from the wizard, including the part after the `+`.
4. Do not choose Change envelope recipient: it takes the message out of the
   mailbox.
5. Choose "Perform this action on non-recognized and recognized addresses" and
   save. Google says changes can take up to 24 hours.

Admin routing sends no confirmation email. Confirm the step in the wizard, or
send a test message: the first message completes the step. If the test message
never arrives, open the rejection log on the Channels tab. A copy delivered
without the `+token` part of the address is listed there as "no matching
channel".

## Direct MX

Customers write to an address on a subdomain whose MX record points at
Lettermint. Use a subdomain that no mailbox uses, because every message to that
domain arrives in Custyard. The wizard refuses a domain that one of the
organization's forwarding channels already uses.

1. Create the channel with the public address, for example
   `support@help.companyname.com`. Custyard sets that domain as the route's
   custom domain in Lettermint. The address cannot contain a `+`.
2. Publish the record the wizard shows: `MX 10 lettermint.mx` for the
   subdomain, and no other MX records for it. Some DNS providers want only the
   host part.
3. Choose Check MX record. Lettermint looks up the record, and the wizard lists
   what it found when the check fails. The first message to the address also
   completes the step.
4. Add the subdomain to Lettermint as a sending domain, with its DKIM CNAME
   records and SPF include, then choose Check domain on the last step.

A route receives direct mail for one domain. Every direct-MX channel on the
route uses that domain, for example `support@` and `sales@` on
`help.companyname.com`. A `+tag` on the address still reaches the channel.
Direct-MX channels have no ingress address, token rotation, reply fallback or
archive copy.

## IMAP

Custyard reads one folder over implicit TLS (port 993 by default). It opens the
folder read-only and never marks, moves or deletes a message. When the channel
first connects, it records the newest message, so only mail that arrives after
that is imported. Reconnecting later keeps its place, so nothing that arrived
during an outage is skipped. It checks for new mail every minute.

- **Works with an app password**: Fastmail, iCloud Mail, Zoho Mail, most hosted
  and self-hosted servers. Gmail and Google Workspace also work if the account
  has 2-Step Verification and the admin allows app passwords.
- **Does not work**: Microsoft 365 and Outlook.com, which allow only OAuth, and
  Proton, which offers IMAP only through the local Bridge. Use forwarding for
  those.

Creating the channel connects immediately. The connect step shows the last
error in plain words. Change the settings and choose Save and connect; an empty
password field keeps the stored password. Changing the server, username or
folder starts again from the newest message.

After three rejected logins without a successful check in between, polling
stops until the password is entered again; the mail that arrived in the
meantime is then imported. Providers lock accounts that keep failing to log
in. Messages over 25 MB, and messages that cannot be read, appear in the
rejection log, and polling moves past them. A connection or database failure
retries on the next poll with backoff, up to 15 minutes. So does a message
whose attachments could not be saved, for five attempts; after that the
message is imported with its attachments marked failed. The channel card shows
when the mailbox was last checked and any error.

IMAP mail carries no authentication results that Custyard trusts. The suspect
badge and the operator-sent and forwarded-by-operator detection therefore never
apply to it.

### Credential encryption key

IMAP passwords are stored encrypted with a dedicated key. Without the key,
Custyard refuses to save a password, and nothing is stored in plaintext. Set it
once per deployment:

```sh
fly secrets set CREDENTIAL_ENCRYPTION_KEY="$(openssl rand -base64 32)"
```

Keep the key independent of `SECRET_KEY_BASE`: rotating session secrets must
not destroy stored credentials. To rotate it, follow these steps:

1. Set the new key as `CREDENTIAL_ENCRYPTION_KEY`.
2. Set the old key as `CREDENTIAL_ENCRYPTION_KEY_PREVIOUS`.
3. Wait until each IMAP channel has polled once. Each poll re-encrypts the
   channel's password with the new key.
4. Remove the previous key.

A malformed key stops the application at boot.

### Moving from IMAP_ENABLED

The single global IMAP poller, which was configured through `IMAP_ENABLED` and
`IMAP_*`, has been removed. A deployment that still sets `IMAP_ENABLED` to
anything but `false` refuses to start. To move the mailbox to a channel:

1. Create an IMAP channel for the mailbox on its organization.
2. Remove `IMAP_ENABLED`, `IMAP_ORGANIZATION_ID`, `IMAP_HOST`, `IMAP_PORT`,
   `IMAP_USERNAME`, `IMAP_PASSWORD`, `IMAP_FOLDER`, `IMAP_POLL_INTERVAL` and
   `IMAP_SSL`.

The old poller marked messages as read. The channel does not, and it starts
from the newest message.

## Rejection log

The Channels tab lists the last 14 days of mail that reached a route but did
not become a thread:

| Label | Meaning |
| --- | --- |
| no matching channel | The recipient matched no channel: a wrong or expired token, or an unknown local part on a direct-MX domain |
| channel paused / channel revoked | The channel was not accepting mail |
| auto-reply, no thread | An auto-response or bounce that answered no thread |
| provider notice | A provider forwarding notification outside setup |
| copy of your own reply | The archive copy of a reply, recognised and dropped |
| too large to import | IMAP: a message over 25 MB |
| could not be read | IMAP: a message the MIME parser could not read |
