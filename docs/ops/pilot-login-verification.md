# Pilot login verification

Verification date: 2026-10-28 (America/Vancouver). Live application: Fly release
87, source `4a94fb7`. This record contains no login tokens, links containing
tokens, session cookies or mail-provider credentials.

## DNS and TLS

Public DNS over HTTPS resolves `onetimesecret.custyard.com` to IPv4
`66.241.125.114` and IPv6 `2a09:8280:1::ea:321e:0`. Fly reports the tenant
certificate issued, verified and active through Let's Encrypt.

An HTTPS request to the tenant login, using the published IP and preserving the
original hostname, returned HTTP 200 with certificate verification result zero.
No certificate bypass was used. HTTP redirects to the same hostname over HTTPS.
The installation login also returns HTTP 200 with certificate verification zero.

The local recursive resolver initially retained the earlier negative answer,
preventing browser tenant access even after public DNS and TLS were ready.

## Installation administrator

Requested the login email from the production browser form for
`delano@custyard.com`. Provider acceptance was logged against the request ID,
without recording the login token. The user opened the delivered link in the
Codex browser. The resulting view is `https://custyard.com/admin`, titled
`Instance admin · Custyard`, with identity `Instance admin · delano@custyard.com`
and the tenant provisioning/lifecycle console. A full page refresh retains this
session and realm.

The live instance-admin account store contains this operator identity; the
tenant identity exists separately as `delano@onetimesecret.com`, role `admin`,
in OneTimeSecret. Submitting the tenant email to installation sign-in returns
the generic sent response without creating an installation account.

## Tenant administrator

Browser DNS now resolves the tenant host and its HTTPS login page renders
OneTimeSecret branding without a certificate warning. The existing operator
session does not sign into the tenant workspace. Submitting the operator email
to this form logs `unknown_account` and sends no tenant login link.

The production form sent a timestamped login email to
`delano@onetimesecret.com`; provider acceptance was logged with request ID
`GOLXYvwsjCfzDwEAAA0h`. The user will open the delivered link in the Codex
browser to complete the final dashboard verification.

## Login email subjects

Both login realms append a UTC timestamp in `YYYY-MMDD-HH:mm:ss` format.
For example: `Your Custyard login link | 2026-1029-00:07:01`.
The timestamp has second precision; requests sent within the same second share
the same subject. Message bodies and login-token semantics are unchanged.

Change: `6900667`. Full CI passes 2,640 tests with zero failures or skips,
including broker integration tests, formatting, compilation and strict Credo.

The timestamp change is deployed in healthy Fly release **88**. The operator
session remains valid after deployment and page refresh. The installation
workspace finder was also exercised in the browser: `onetimesecret` redirects
to the tenant's own HTTPS login page. Recent production logs contain no raw
magic-link token paths. Final tenant dashboard confirmation is pending the
user opening the delivered tenant login link.
