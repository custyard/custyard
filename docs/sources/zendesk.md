# Zendesk inbound webhooks

Create an inbound route with `source: :zendesk`, then configure a Zendesk webhook to POST to `/api/webhook/route/:callback_token`. The callback token selects the route and its customer organization. Custyard verifies `X-Zendesk-Webhook-Signature` against the exact request body prefixed by `X-Zendesk-Webhook-Signature-Timestamp`. Zendesk sends that timestamp in ISO 8601 format; requests more than five minutes old are rejected.

The configured payload must include a ticket ID, requester email, subject, and a stable comment ID for each comment. For example:

```json
{
  "ticket": {
    "id": 123,
    "subject": "Account access",
    "requester": {"email": "customer@example.com"},
    "comment": {"id": 456, "body": "I still need help"}
  }
}
```

The ticket ID keeps comments in one Custyard conversation. The comment ID makes retries idempotent without discarding later comments. A payload with comment text but no comment ID receives a processing error; include `comment.id`, top-level `comment_id`, or top-level `event_id` in the template. Ticket-only events without a comment remain supported.

`WEBHOOK_SECRET_ZENDESK` supplies one source-wide signing secret. If multiple Zendesk webhooks use different signing secrets, replace the `if map_size(webhook_secrets) > 0` block in `config/runtime.exs` with a route-keyed map. Keep the existing `webhook_secrets` construction so other sources retain their secrets:

```elixir
zendesk_route_secrets = %{
  System.fetch_env!("ZENDESK_ROUTE_A_TOKEN") => System.fetch_env!("ZENDESK_ROUTE_A_SECRET"),
  System.fetch_env!("ZENDESK_ROUTE_B_TOKEN") => System.fetch_env!("ZENDESK_ROUTE_B_SECRET")
}

config :custyard, :webhook_secrets,
  Map.put(webhook_secrets, :zendesk, zendesk_route_secrets)
```

Each webhook must use its own matching route URL and signing secret. A configured map fails closed when a callback token has no secret.

`InboundRoutes.create_route/1` creates a Zendesk route locally without provisioning a Lettermint mailbox. Its `callback_url/1` result is the URL to configure in Zendesk. Creating an organization still provisions its default Lettermint route separately.

An organization can therefore have both a Lettermint and a Zendesk general route. `get_general_route/1` prefers Lettermint, then a direct email route, so email replies keep using an email address. `find_or_create_general_route/2` selects by requested source; `source: :email` reuses Lettermint when present, while `source: :zendesk` selects the Zendesk route. The callback token always selects the exact route for an incoming webhook.
