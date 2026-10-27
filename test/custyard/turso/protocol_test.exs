defmodule Custyard.Turso.ProtocolTest do
  use ExUnit.Case, async: true

  alias Custyard.Turso.Protocol

  describe "parse_url/1" do
    test "libsql:// is HTTPS on 443" do
      assert Protocol.parse_url("libsql://custyard-acme.turso.io") ==
               {:ok, %{scheme: :https, host: "custyard-acme.turso.io", port: 443, path: ""}}
    end

    test "tls=0 selects plain HTTP, and an explicit port is kept" do
      assert Protocol.parse_url("libsql://127.0.0.1:8080?tls=0") ==
               {:ok, %{scheme: :http, host: "127.0.0.1", port: 8080, path: ""}}
    end

    test "https:// and http:// are taken as they are" do
      assert {:ok, %{scheme: :https, port: 443, path: "/db"}} =
               Protocol.parse_url("https://example.com/db/")

      assert {:ok, %{scheme: :http, port: 80}} = Protocol.parse_url("http://sqld.internal")
    end

    test "rejects other schemes and a missing host" do
      assert {:error, message} = Protocol.parse_url("postgres://localhost/custyard")
      assert message =~ "libsql://"
      assert {:error, "database URL has no host"} = Protocol.parse_url("libsql://")
    end

    test "the pipeline path follows the URL's path" do
      {:ok, endpoint} = Protocol.parse_url("https://example.com/db")
      assert Protocol.pipeline_path(endpoint) == "/db/v3/pipeline"
    end
  end

  describe "values" do
    test "integers travel as strings so 64-bit values survive JSON" do
      max = 9_223_372_036_854_775_807

      assert Protocol.encode_value(max) ==
               {:ok, %{"type" => "integer", "value" => "9223372036854775807"}}

      assert Protocol.decode_value(%{"type" => "integer", "value" => "9223372036854775807"}) ==
               max
    end

    test "binds like Exqlite" do
      assert Protocol.encode_args([nil, :undefined, 1.5, "text", ["io", "data"], true]) ==
               {:ok,
                [
                  %{"type" => "null"},
                  %{"type" => "null"},
                  %{"type" => "float", "value" => 1.5},
                  %{"type" => "text", "value" => "text"},
                  %{"type" => "text", "value" => "iodata"},
                  %{"type" => "text", "value" => "true"}
                ]}

      assert {:ok, [%{"value" => "2026-10-26"}, %{"value" => "09:30:00"}]} =
               Protocol.encode_args([~D[2026-10-26], ~T[09:30:00]])

      assert {:ok, [%{"value" => "2026-10-26T09:30:00"}, %{"value" => "2026-10-26T09:30:00"}]} =
               Protocol.encode_args([~N[2026-10-26 09:30:00], ~U[2026-10-26 09:30:00Z]])
    end

    test "blobs round-trip through base64, with or without padding" do
      data = <<0, 255, 1, 2>>
      assert {:ok, blob} = Protocol.encode_value({:blob, data})
      assert blob == %{"type" => "blob", "base64" => "AP8BAg"}
      assert Protocol.decode_value(blob) == data
      assert Protocol.decode_value(%{"type" => "blob", "base64" => "AP8BAg=="}) == data
    end

    # JSON cannot send it as text; the bytes still come back unchanged.
    test "text that is not UTF-8 is sent as a blob" do
      bad = <<0xFF>> <> "Bad@Example.com"
      assert {:ok, %{"type" => "blob"} = blob} = Protocol.encode_value(bad)
      assert Protocol.decode_value(blob) == bad
    end

    test "floats decode as floats even when JSON wrote a whole number" do
      assert Protocol.decode_value(%{"type" => "float", "value" => 2}) === 2.0
      assert Protocol.decode_value(%{"type" => "null"}) == nil
      assert Protocol.decode_value(%{"type" => "text", "value" => "x"}) == "x"
    end

    test "refuses what Exqlite refuses" do
      assert {:error, message} = Protocol.encode_args([1, %{a: 1}])
      assert message =~ "unsupported type"

      paris = DateTime.new!(~D[2026-10-26], ~T[09:30:00], "Etc/UTC") |> Map.put(:time_zone, "CET")
      assert {:error, message} = Protocol.encode_value(paris)
      assert message =~ "is not in UTC"
    end
  end

  describe "responses" do
    test "decodes a pipeline and its execute result" do
      body =
        Jason.encode!(%{
          "baton" => "b1",
          "base_url" => nil,
          "results" => [
            %{
              "type" => "ok",
              "response" => %{
                "type" => "execute",
                "result" => %{
                  "cols" => [%{"name" => "id"}, %{"name" => "name"}],
                  "rows" => [[%{"type" => "integer", "value" => "1"}, %{"type" => "null"}]],
                  "affected_row_count" => 0
                }
              }
            },
            %{"type" => "error", "error" => %{"message" => "SQLite error: no such table: x"}}
          ]
        })

      assert {:ok, %{baton: "b1", base_url: nil, results: [{:ok, execute}, {:error, error}]}} =
               Protocol.decode_pipeline(body)

      assert Protocol.statement_result(execute) == {:ok, ["id", "name"], [[1, nil]], 0}
      assert Protocol.error_message(error) == "no such table: x"
    end

    # Ecto.Adapters.SQLite3 matches constraint errors from the first
    # character of SQLite's message.
    test "error messages lose sqld's prefix and nothing else" do
      assert Protocol.error_message(%{
               "message" => "SQLite error: UNIQUE constraint failed: operator_accounts.email",
               "code" => "SQLITE_CONSTRAINT"
             }) == "UNIQUE constraint failed: operator_accounts.email"

      assert Protocol.error_message(%{"message" => "Transaction timed out"}) ==
               "Transaction timed out"
    end

    test "a response that is not a pipeline is an error" do
      assert {:error, "pipeline response has no results"} = Protocol.decode_pipeline("{}")
      assert {:error, "pipeline response is not JSON" <> _} = Protocol.decode_pipeline("<html>")
    end

    test "describes a non-200 response" do
      assert Protocol.http_error(401, ~s({"message":"Unauthorized","code":"AUTH_FAILED"})) ==
               "HTTP 401: Unauthorized (AUTH_FAILED)"

      assert Protocol.http_error(502, "Bad Gateway") == "HTTP 502: Bad Gateway"
    end
  end
end
