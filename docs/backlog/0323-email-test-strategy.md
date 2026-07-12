# Email Infrastructure Test Strategy

**Context:** GitHub Issue #10 - Email Infrastructure with Lettermint integration
**Date:** 2026-03-23
**Status:** Research and Design

## Executive Summary

This document outlines a comprehensive testing strategy for Custyard's email infrastructure, covering inbound email processing via webhooks (Lettermint) and outbound notifications via Swoosh. The strategy emphasizes test isolation, realistic fixtures, and layered testing from unit through end-to-end.

---

## 1. Current State Assessment

### Existing Email Components

| Component | Location | Purpose |
|-----------|----------|---------|
| `Custyard.Mailer` | `lib/custyard/mailer.ex` | Swoosh mailer (outbound) |
| `Custyard.Notifications.Email` | `lib/custyard/notifications/email.ex` | Alert composition |
| `Custyard.Email.Processor` | `lib/custyard/email/processor.ex` | Inbound webhook handler |
| `Custyard.Email.SenderMatcher` | `lib/custyard/email/sender_matcher.ex` | Contact/Org resolution |
| `Custyard.Email.ThreadMatcher` | `lib/custyard/email/thread_matcher.ex` | Conversation threading |
| `Custyard.Email.SieveHeaderMapper` | `lib/custyard/email/sieve_header_mapper.ex` | MTA metadata extraction |
| `CustyardWeb.WebhookController` | `lib/custyard_web/controllers/webhook_controller.ex` | HTTP endpoint |

### Existing Test Coverage

- `test/custyard/email/processor_test.exs` - 14 test cases for email processing
- `test/custyard/notifications/email_test.exs` - 6 test cases for outbound alerts
- Test configuration uses `Swoosh.Adapters.Test` for email capture

### Gaps Identified

1. No controller-level tests for `/api/webhook/inbound`
2. No tests for `SenderMatcher` or `ThreadMatcher` modules directly
3. No tests for `SieveHeaderMapper` module
4. No webhook authentication/verification tests
5. No property-based tests for email parsing edge cases
6. No integration tests with realistic email payloads

---

## 2. Unit Test Strategy

### 2.1 Email Parsing and Composition

**Target modules:** `Processor`, `SieveHeaderMapper`

**Test categories:**

1. **Payload parsing**
   - Standard JSON payload from Lettermint
   - Missing optional fields (subject, text body, headers)
   - HTML-only emails (strip HTML to text)
   - Various `from` formats: bare email, "Name <email>", RFC 2822 compliant
   - Unicode in subject/body
   - Large payloads (attachment references)

2. **Header extraction**
   - Case-insensitive header lookup
   - Missing headers return nil
   - Sieve-injected custom headers (X-Priority, X-Customer-Tier)
   - Multiple header values (References chain)

3. **Urgency detection**
   - Keyword matching in subject
   - Keyword matching in body
   - Case insensitivity
   - No false positives (e.g., "download" should not match "down")

**Fixture strategy:**
```elixir
# test/support/fixtures/email_payloads.ex
defmodule Custyard.Fixtures.EmailPayloads do
  def standard_payload(overrides \\ %{}) do
    Map.merge(%{
      "from" => "alice@acme.com",
      "to" => "support@custyard.test",
      "subject" => "Test subject",
      "text" => "Test body",
      "html" => nil,
      "headers" => %{
        "message-id" => "<msg-#{:rand.uniform(10000)}@acme.com>",
        "date" => "Mon, 23 Mar 2026 10:00:00 +0000"
      }
    }, overrides)
  end

  def reply_payload(in_reply_to, overrides \\ %{}) do
    standard_payload(overrides)
    |> Map.put("headers", %{
      "in-reply-to" => in_reply_to,
      "references" => in_reply_to
    })
  end

  def urgent_payload(overrides \\ %{}) do
    standard_payload(Map.merge(%{"subject" => "URGENT: System down"}, overrides))
  end
end
```

### 2.2 Sender Matching

**Target module:** `SenderMatcher`

**Test categories:**

1. **Email address extraction**
   - Bare email: `alice@acme.com`
   - Name format: `Alice Smith <alice@acme.com>`
   - Quoted names: `"Smith, Alice" <alice@acme.com>`
   - Missing angle brackets

2. **Domain extraction**
   - Standard domain: `alice@acme.com` -> `acme.com`
   - Subdomain: `alice@support.acme.com` -> `support.acme.com`
   - Invalid format: `invalid-email` -> nil

3. **Contact lookup**
   - Existing contact matched by email
   - Case-insensitive email matching
   - Contact not found -> domain lookup

4. **Organization lookup**
   - Match by domain
   - No match -> create unmatched org placeholder
   - Unmatched org singleton pattern

5. **Contact creation**
   - Extract name from From header
   - Associate with matched/created org

### 2.3 Thread Matching

**Target module:** `ThreadMatcher`

**Test categories:**

1. **In-Reply-To matching**
   - Exact message-id match
   - No match returns `:not_found`
   - Nil In-Reply-To skipped

2. **References header matching**
   - Single reference
   - Multiple references (space-separated)
   - Match any reference in chain
   - Empty references skipped

3. **Threading edge cases**
   - Cross-conversation message-id collision (should not happen, but handle)
   - Malformed message-ids

---

## 3. Integration Test Strategy

### 3.1 Webhook Controller Tests

**File:** `test/custyard_web/controllers/webhook_controller_test.exs`

**Test categories:**

1. **Happy path**
   - POST valid payload -> 200 with conversation_id
   - New conversation created
   - Message created
   - PubSub events broadcast

2. **Threading**
   - Reply to existing conversation
   - Conversation state transitions (dormant -> active)

3. **Error handling**
   - Invalid payload structure -> 422
   - Missing required fields -> 422
   - Database errors -> 500 with error details

4. **Authentication (future)**
   - Missing webhook signature -> 401
   - Invalid signature -> 401
   - Expired timestamp -> 401

**Example test structure:**
```elixir
defmodule CustyardWeb.WebhookControllerTest do
  use CustyardWeb.ConnCase, async: true

  import Custyard.Factory
  import Custyard.Fixtures.EmailPayloads

  describe "POST /api/webhook/inbound" do
    test "creates conversation from valid email", %{conn: conn} do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      conn = post(conn, ~p"/api/webhook/inbound", standard_payload(%{
        "from" => "alice@acme.example.com"
      }))

      assert %{"status" => "ok", "conversation_id" => conv_id} = json_response(conn, 200)
      assert is_integer(conv_id)
    end

    test "returns 422 for processing errors", %{conn: conn} do
      # Trigger an error condition
      conn = post(conn, ~p"/api/webhook/inbound", %{"invalid" => "payload"})

      assert %{"status" => "error"} = json_response(conn, 422)
    end
  end
end
```

### 3.2 Outbound Email Tests

**Existing coverage is adequate.** Enhance with:

1. **Delivery failure handling**
   - Mock Swoosh adapter failure
   - Verify error logging
   - Verify return value

2. **Template rendering**
   - Verify HTML structure
   - Verify text fallback
   - Verify dynamic content insertion

---

## 4. End-to-End Test Strategy

### 4.1 Full Email Flow Tests

**File:** `test/integration/email_flow_test.exs`

**Scenarios:**

1. **New customer email creates conversation**
   - HTTP POST to webhook
   - Conversation appears in Attention Queue (LiveView)
   - Operator can view message

2. **Customer reply threads to existing conversation**
   - Create initial conversation
   - POST reply with In-Reply-To header
   - Message appends to existing conversation
   - Conversation bumped in queue

3. **Operator reply triggers outbound email**
   - Operator sends reply via LiveView
   - Outbound email composed
   - Email captured by Swoosh.TestAssertions

4. **Neglect alert email flow**
   - Create old conversation
   - Trigger neglect check
   - Alert email sent
   - Verify recipient and content

### 4.2 PubSub Event Verification

```elixir
test "broadcasts conversation_created on new email", %{conn: conn} do
  Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")

  org = insert_organization(domain: "acme.example.com")
  insert_contact(organization_id: org.id, email: "alice@acme.example.com")

  post(conn, ~p"/api/webhook/inbound", standard_payload(%{
    "from" => "alice@acme.example.com"
  }))

  assert_receive {:conversation_created, _conv_id}, 1000
end
```

---

## 5. Test Fixtures and Factories

### 5.1 Email Payload Fixtures

Create `test/support/fixtures/email_payloads.ex` with:

- `standard_payload/1` - Basic email
- `reply_payload/2` - Threaded reply
- `urgent_payload/1` - Urgent keywords
- `html_only_payload/1` - No text body
- `with_sieve_headers/2` - Custom MTA headers
- `malformed_payload/0` - For error testing

### 5.2 Factory Enhancements

Add to `test/support/factory.ex`:

```elixir
def build_email_payload(overrides \\ []) do
  id = unique_id()
  %{
    "from" => overrides[:from] || "sender-#{id}@example.com",
    "to" => overrides[:to] || "support@custyard.test",
    "subject" => overrides[:subject] || "Test subject #{id}",
    "text" => overrides[:text] || "Test body #{id}",
    "headers" => overrides[:headers] || %{
      "message-id" => "<msg-#{id}@example.com>"
    }
  }
end
```

---

## 6. Mocking Strategies

### 6.1 Swoosh Test Adapter (Current)

Already configured in `config/test.exs`:
```elixir
config :custyard, Custyard.Mailer, adapter: Swoosh.Adapters.Test
```

Use `Swoosh.TestAssertions` for verification:
- `assert_email_sent/0` - Any email sent
- `assert_email_sent/1` - Email matching function
- `assert_no_email_sent/0` - No emails sent

### 6.2 Mox for External Services

Define behaviours for external email services:

```elixir
# lib/custyard/email/mailer_behaviour.ex
defmodule Custyard.Email.MailerBehaviour do
  @callback deliver(Swoosh.Email.t()) :: {:ok, term()} | {:error, term()}
end
```

Mock in tests:
```elixir
# test/test_helper.exs
Mox.defmock(Custyard.MockMailer, for: Custyard.Email.MailerBehaviour)

# test case
import Mox

test "handles delivery failure" do
  Custyard.MockMailer
  |> expect(:deliver, fn _email -> {:error, :connection_refused} end)

  # Test error handling
end
```

### 6.3 Bypass for Webhook Authentication

For future webhook signature verification:

```elixir
setup do
  bypass = Bypass.open()
  {:ok, bypass: bypass}
end

test "verifies webhook signature", %{bypass: bypass} do
  Bypass.expect(bypass, fn conn ->
    # Simulate Lettermint signature verification endpoint
    Plug.Conn.resp(conn, 200, ~s({"valid": true}))
  end)
end
```

---

## 7. Alternative Approaches

### 7.1 Testing Framework Comparison

| Approach | Pros | Cons | Recommendation |
|----------|------|------|----------------|
| **ExUnit + Swoosh.Test** | Built-in, simple, fast | No real SMTP | Use for unit/integration |
| **Mailpit** | Real SMTP, API, web UI | External dependency | Use for E2E/staging |
| **Bamboo.Test** | Similar to Swoosh | Would require migration | Skip (already on Swoosh) |
| **gen_smtp** | Full SMTP server | Complex setup | Overkill for testing |

### 7.2 Local Mail Server vs Mocked Services

**Mocked Services (Current Approach)**
- Pros: Fast, no external deps, CI-friendly
- Cons: May miss real protocol issues

**Mailpit (Docker)**
```yaml
# docker-compose.test.yml
services:
  mailpit:
    image: axllent/mailpit
    ports:
      - "1025:1025"  # SMTP
      - "8025:8025"  # Web UI
```

```elixir
# config/test.exs (optional Mailpit mode)
if System.get_env("USE_MAILPIT") do
  config :custyard, Custyard.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: "localhost",
    port: 1025
end
```

**Recommendation:** Use mocked services for CI, Mailpit for local development and manual testing.

### 7.3 Property-Based Testing for Email Validation

Use StreamData for fuzzing email parsing:

```elixir
# test/custyard/email/parser_property_test.exs
defmodule Custyard.Email.ParserPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  property "handles any valid email address format" do
    check all local_part <- string(:alphanumeric, min_length: 1, max_length: 64),
              domain <- string(:alphanumeric, min_length: 1, max_length: 64) do
      email = "#{local_part}@#{domain}.com"
      result = Custyard.Email.SenderMatcher.extract_email(email)
      assert is_binary(result)
    end
  end

  property "never crashes on malformed input" do
    check all input <- string(:printable) do
      # Should not raise
      _ = Custyard.Email.Processor.parse_payload(%{"from" => input})
    end
  end

  property "thread matching is idempotent" do
    check all message_id <- string(:alphanumeric, min_length: 10) do
      full_id = "<#{message_id}@test.com>"
      result1 = ThreadMatcher.find_thread(%{in_reply_to: full_id, references: nil})
      result2 = ThreadMatcher.find_thread(%{in_reply_to: full_id, references: nil})
      assert result1 == result2
    end
  end
end
```

**Add dependency:**
```elixir
{:stream_data, "~> 0.6", only: [:dev, :test]}
```

---

## 8. Related Opportunities

### 8.1 Playwright Tests for Email-Triggered UI Flows

**Scenarios:**

1. **Real-time conversation updates**
   - POST webhook while viewing Attention Queue
   - Verify new conversation appears without refresh
   - Verify LiveView receives PubSub update

2. **Email notification preferences**
   - Operator enables/disables email alerts
   - Trigger alert condition
   - Verify email sent/not sent

**Implementation approach:**
- Use Playwright's `request` API to POST webhook payloads
- Verify UI state changes via page assertions
- Coordinate with Swoosh.TestAssertions or Mailpit API

### 8.2 Performance Testing for High-Volume Email Processing

**Metrics to track:**
- Webhook throughput (requests/second)
- Database write latency
- PubSub broadcast latency
- Memory usage under load

**Tools:**
- `benchee` for micro-benchmarks
- `k6` or `vegeta` for load testing webhook endpoint
- `telemetry` for production monitoring

**Example benchmark:**
```elixir
# bench/email_processor_bench.exs
Benchee.run(%{
  "process single email" => fn ->
    Processor.process(standard_payload())
  end,
  "process 100 emails" => fn ->
    Enum.each(1..100, fn _ -> Processor.process(standard_payload()) end)
  end
})
```

### 8.3 Monitoring and Alerting for Email Delivery Issues

**Telemetry events to emit:**
```elixir
:telemetry.execute(
  [:custyard, :email, :inbound, :processed],
  %{duration: duration_ms},
  %{organization_id: org.id, is_new_conversation: is_new}
)

:telemetry.execute(
  [:custyard, :email, :outbound, :sent],
  %{},
  %{type: :neglect_alert, level: level}
)

:telemetry.execute(
  [:custyard, :email, :outbound, :failed],
  %{},
  %{type: :neglect_alert, reason: reason}
)
```

**Dashboard metrics:**
- Inbound email processing rate
- Thread match rate (new vs. threaded)
- Outbound delivery success rate
- Sender match rate (known vs. unmatched)

### 8.4 Qase Test Case Organization

**Test Suite Structure:**

```
Email Infrastructure (Suite)
├── Inbound Email Processing (Section)
│   ├── TC-001: New email creates conversation
│   ├── TC-002: Reply threads to existing conversation
│   ├── TC-003: Dormant conversation reactivated
│   ├── TC-004: Unknown sender creates placeholder org
│   ├── TC-005: Urgency detected from keywords
│   └── TC-006: Sieve headers override urgency
├── Outbound Notifications (Section)
│   ├── TC-101: Neglect alert sent at warning level
│   ├── TC-102: Neglect alert sent at critical level
│   ├── TC-103: Email disabled suppresses delivery
│   └── TC-104: Delivery failure handled gracefully
├── Webhook Security (Section)
│   ├── TC-201: Valid signature accepted
│   ├── TC-202: Invalid signature rejected
│   └── TC-203: Expired timestamp rejected
└── Edge Cases (Section)
    ├── TC-301: HTML-only email body
    ├── TC-302: Missing subject defaults
    ├── TC-303: Unicode in subject/body
    └── TC-304: Large attachment references
```

**Automation linking:**
- Each test file includes Qase case ID in docstring
- Reporter configured to update Qase on test run
- CI pipeline publishes results to Qase automatically

---

## 9. Implementation Roadmap

### Phase 1: Foundation (Week 1)
- [ ] Create `test/support/fixtures/email_payloads.ex`
- [ ] Add `WebhookControllerTest` with basic happy path
- [ ] Add unit tests for `SenderMatcher`
- [ ] Add unit tests for `ThreadMatcher`
- [ ] Add unit tests for `SieveHeaderMapper`

### Phase 2: Edge Cases (Week 2)
- [ ] Add property-based tests with StreamData
- [ ] Expand processor tests for malformed input
- [ ] Add integration tests for full email flow
- [ ] Set up Mailpit for local development

### Phase 3: Security and Performance (Week 3)
- [ ] Implement webhook signature verification
- [ ] Add security tests for webhook auth
- [ ] Add performance benchmarks
- [ ] Add telemetry instrumentation

### Phase 4: CI/CD Integration (Week 4)
- [ ] Configure Qase reporter
- [ ] Create test cases in Qase
- [ ] Add Playwright tests for UI flows
- [ ] Document test coverage requirements

---

## 10. Dependencies to Add

```elixir
# mix.exs deps (test only)
{:stream_data, "~> 0.6", only: [:dev, :test]},
{:mox, "~> 1.1", only: :test},
{:bypass, "~> 2.1", only: :test},
{:benchee, "~> 1.3", only: :dev}
```

---

## Appendix A: Lettermint Webhook Payload Reference

Based on common email webhook patterns (Postmark, SendGrid), expected Lettermint payload:

```json
{
  "from": "sender@example.com",
  "to": "support@custyard.test",
  "subject": "Email subject",
  "text": "Plain text body",
  "html": "<html>HTML body</html>",
  "headers": {
    "message-id": "<unique-id@example.com>",
    "in-reply-to": "<previous-id@example.com>",
    "references": "<id1@example.com> <id2@example.com>",
    "date": "Mon, 23 Mar 2026 10:00:00 +0000",
    "x-priority": "high"
  },
  "attachments": [
    {
      "filename": "document.pdf",
      "content_type": "application/pdf",
      "size": 12345
    }
  ]
}
```

**Note:** Actual Lettermint payload structure should be verified against their documentation when available.

---

## Appendix B: Related Files

| File | Purpose |
|------|---------|
| `/Users/d/Projects/experiments/custyard/lib/custyard/email/processor.ex` | Inbound processing logic |
| `/Users/d/Projects/experiments/custyard/lib/custyard/email/sender_matcher.ex` | Contact/org resolution |
| `/Users/d/Projects/experiments/custyard/lib/custyard/email/thread_matcher.ex` | Conversation threading |
| `/Users/d/Projects/experiments/custyard/lib/custyard/email/sieve_header_mapper.ex` | MTA header extraction |
| `/Users/d/Projects/experiments/custyard/lib/custyard_web/controllers/webhook_controller.ex` | HTTP endpoint |
| `/Users/d/Projects/experiments/custyard/lib/custyard/notifications/email.ex` | Outbound composition |
| `/Users/d/Projects/experiments/custyard/test/custyard/email/processor_test.exs` | Existing processor tests |
| `/Users/d/Projects/experiments/custyard/test/custyard/notifications/email_test.exs` | Existing notification tests |
| `/Users/d/Projects/experiments/custyard/test/support/factory.ex` | Test data factories |
| `/Users/d/Projects/experiments/custyard/config/test.exs` | Test environment config |
