defmodule Custyard.Fixtures.EmailPayloads do
  @moduledoc """
  Builders for inbound email webhook payloads (Lettermint-style shape).

  Payloads are string-keyed maps matching what `POST /api/webhook/route/:token`
  receives: `from`, `to`, `subject`, `text`, `html`, and a `headers` map.
  Each builder generates a unique `message-id` unless one is provided.
  """

  @doc """
  A standard plain-text email payload. Pass a string-keyed map to override
  any top-level field (overrides replace, not deep-merge).
  """
  def standard_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "from" => "alice@acme.example.com",
        "to" => "support@custyard.test",
        "subject" => "Test subject",
        "text" => "Test body",
        "html" => nil,
        "headers" => %{
          "message-id" => unique_message_id(),
          "date" => "Mon, 23 Mar 2026 10:00:00 +0000"
        }
      },
      overrides
    )
  end

  @doc """
  A reply payload threading onto `in_reply_to` (also placed in References).
  """
  def reply_payload(in_reply_to, overrides \\ %{}) do
    payload = standard_payload(overrides)

    headers =
      payload["headers"]
      |> Map.put("message-id", payload["headers"]["message-id"] || unique_message_id())
      |> Map.put("in-reply-to", in_reply_to)
      |> Map.put("references", in_reply_to)

    Map.put(payload, "headers", headers)
  end

  @doc """
  A payload with urgent keywords in the subject.
  """
  def urgent_payload(overrides \\ %{}) do
    standard_payload(Map.merge(%{"subject" => "URGENT: System down"}, overrides))
  end

  @doc """
  An HTML-only payload (no text body).
  """
  def html_only_payload(overrides \\ %{}) do
    standard_payload(
      Map.merge(
        %{
          "text" => nil,
          "html" => "<html><body><p>HTML only body</p></body></html>"
        },
        overrides
      )
    )
  end

  @doc """
  Merge Sieve-injected custom headers (e.g. `%{"X-Priority" => "high"}`)
  into a payload's headers.
  """
  def with_sieve_headers(payload, sieve_headers) do
    Map.update(payload, "headers", sieve_headers, &Map.merge(&1, sieve_headers))
  end

  @doc """
  A structurally invalid payload for error-path testing: no from/sender,
  no body, no headers.
  """
  def malformed_payload do
    %{"unexpected" => "shape"}
  end

  @doc """
  A unique RFC-style message id, e.g. `"<msg-123@acme.example.com>"`.
  """
  def unique_message_id do
    "<msg-#{System.unique_integer([:positive])}@acme.example.com>"
  end
end
