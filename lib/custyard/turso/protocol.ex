defmodule Custyard.Turso.Protocol do
  @moduledoc """
  Hrana 3 over HTTP, the JSON protocol Turso and libSQL servers speak.

  A client POSTs a pipeline to `/v3/pipeline`: a list of stream requests and
  an optional baton. Without a baton the server opens a new stream, which is
  one SQLite connection on its side; the response returns a baton that names
  the stream for the next pipeline, until a `close` request ends it. Every
  request in a pipeline gets its own result, so a failed statement does not
  stop the ones after it.

  This module only builds and reads the JSON. `Custyard.Turso.Connection`
  decides which requests to send.
  """

  @pipeline_path "/v3/pipeline"

  # sqld prefixes SQLite's own message. Ecto.Adapters.SQLite3 recognises
  # constraint violations by matching that message from its first character,
  # so the prefix comes off.
  @sqlite_prefixes ["SQLite error: ", "SQLite failure: "]

  @type endpoint :: %{
          scheme: :http | :https,
          host: String.t(),
          port: :inet.port_number(),
          path: String.t()
        }

  def pipeline_path(%{path: path}), do: path <> @pipeline_path

  @doc """
  Parses a database URL into the endpoint the HTTP client connects to.

  `libsql://` is Turso's scheme and means HTTPS; add `?tls=0` for a libSQL
  server on plain HTTP. `https://` and `http://` URLs are taken as they are.
  """
  @spec parse_url(String.t()) :: {:ok, endpoint} | {:error, String.t()}
  def parse_url(url) when is_binary(url) do
    uri = URI.parse(url)

    with {:ok, scheme} <- scheme(uri),
         {:ok, host} <- host(uri) do
      {:ok,
       %{
         scheme: scheme,
         host: host,
         port: uri.port || default_port(scheme),
         path: String.trim_trailing(uri.path || "", "/")
       }}
    end
  end

  def parse_url(other), do: {:error, "expected a database URL, got #{inspect(other)}"}

  defp scheme(%URI{scheme: "libsql", query: query}) do
    tls = query |> to_string() |> URI.decode_query() |> Map.get("tls")
    if tls == "0", do: {:ok, :http}, else: {:ok, :https}
  end

  defp scheme(%URI{scheme: "https"}), do: {:ok, :https}
  defp scheme(%URI{scheme: "http"}), do: {:ok, :http}

  defp scheme(%URI{scheme: scheme}),
    do: {:error, "unsupported database URL scheme #{inspect(scheme)}; use libsql://"}

  defp host(%URI{host: host}) when is_binary(host) and host != "", do: {:ok, host}
  defp host(_uri), do: {:error, "database URL has no host"}

  defp default_port(:https), do: 443
  defp default_port(:http), do: 80

  ## Requests

  def execute(sql, args), do: %{"type" => "execute", "stmt" => stmt(sql, args)}

  def get_autocommit, do: %{"type" => "get_autocommit"}

  def close, do: %{"type" => "close"}

  defp stmt(sql, args), do: %{"sql" => sql, "args" => args, "want_rows" => true}

  @spec encode_pipeline(String.t() | nil, [map]) :: iodata
  def encode_pipeline(baton, requests) do
    Jason.encode_to_iodata!(%{"baton" => baton, "requests" => requests})
  end

  ## Values

  @doc """
  Encodes positional parameters the way Exqlite binds them, so a query sees
  the same SQLite values over HTTP as it does against a local file.
  """
  @spec encode_args(list | nil) :: {:ok, [map]} | {:error, String.t()}
  def encode_args(nil), do: {:ok, []}

  def encode_args(params) when is_list(params) do
    params
    |> Enum.reduce_while([], fn param, acc ->
      case encode_value(param) do
        {:ok, value} -> {:cont, [value | acc]}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      values -> {:ok, Enum.reverse(values)}
    end
  end

  def encode_args(params), do: {:error, "unsupported parameters: #{inspect(params)}"}

  def encode_value(nil), do: {:ok, %{"type" => "null"}}
  def encode_value(:undefined), do: {:ok, %{"type" => "null"}}

  def encode_value(int) when is_integer(int),
    do: {:ok, %{"type" => "integer", "value" => Integer.to_string(int)}}

  def encode_value(float) when is_float(float), do: {:ok, %{"type" => "float", "value" => float}}
  def encode_value({:blob, data}), do: {:ok, blob(IO.iodata_to_binary(data))}
  def encode_value(atom) when is_atom(atom), do: text(Atom.to_string(atom))
  def encode_value(%Date{} = date), do: text(Date.to_iso8601(date))
  def encode_value(%Time{} = time), do: text(Time.to_iso8601(time))
  def encode_value(%NaiveDateTime{} = naive), do: text(NaiveDateTime.to_iso8601(naive))

  def encode_value(%DateTime{time_zone: "Etc/UTC"} = datetime),
    do: text(NaiveDateTime.to_iso8601(datetime))

  def encode_value(%DateTime{} = datetime), do: {:error, "#{inspect(datetime)} is not in UTC"}

  def encode_value(data) when is_binary(data) or is_list(data),
    do: text(IO.iodata_to_binary(data))

  def encode_value(other), do: {:error, "unsupported type: #{inspect(other)}"}

  # JSON strings must be valid UTF-8. A local SQLite file stores any bytes
  # bound as text; over HTTP they travel as a blob, so reading the row back
  # still returns the same binary.
  defp text(data) do
    if String.valid?(data),
      do: {:ok, %{"type" => "text", "value" => data}},
      else: {:ok, blob(data)}
  end

  defp blob(data), do: %{"type" => "blob", "base64" => Base.encode64(data, padding: false)}

  def decode_value(%{"type" => "null"}), do: nil
  def decode_value(%{"type" => "integer", "value" => value}), do: String.to_integer(value)
  def decode_value(%{"type" => "float", "value" => value}) when is_number(value), do: value / 1
  def decode_value(%{"type" => "text", "value" => value}), do: value

  def decode_value(%{"type" => "blob", "base64" => data}),
    do: Base.decode64!(data, padding: false)

  ## Responses

  @spec decode_pipeline(binary) ::
          {:ok, %{baton: String.t() | nil, base_url: String.t() | nil, results: [result]}}
          | {:error, String.t()}
        when result: {:ok, map} | {:error, map}
  def decode_pipeline(body) do
    case Jason.decode(body) do
      {:ok, %{"results" => results} = decoded} when is_list(results) ->
        {:ok,
         %{
           baton: decoded["baton"],
           base_url: decoded["base_url"],
           results: Enum.map(results, &result/1)
         }}

      {:ok, _} ->
        {:error, "pipeline response has no results"}

      {:error, error} ->
        {:error, "pipeline response is not JSON: #{Exception.message(error)}"}
    end
  end

  defp result(%{"type" => "ok", "response" => response}), do: {:ok, response}
  defp result(%{"type" => "error", "error" => error}), do: {:error, error}
  defp result(other), do: {:error, %{"message" => "unexpected result #{inspect(other)}"}}

  @doc """
  Reads an execute result into columns, rows and the affected row count.
  """
  def statement_result(%{"type" => "execute", "result" => result}) do
    columns = Enum.map(result["cols"] || [], &(&1["name"] || ""))
    rows = Enum.map(result["rows"] || [], fn row -> Enum.map(row, &decode_value/1) end)
    {:ok, columns, rows, result["affected_row_count"] || 0}
  end

  def statement_result(other), do: {:error, "unexpected response #{inspect(other)}"}

  @doc """
  The message of an error a statement or pipeline returned, in the form
  SQLite itself reports it.
  """
  def error_message(%{"message" => message}) when is_binary(message) do
    Enum.reduce(@sqlite_prefixes, message, fn prefix, acc ->
      String.replace_prefix(acc, prefix, "")
    end)
  end

  def error_message(error), do: inspect(error)

  @doc """
  The error a server returned as a whole, for a non-200 response.
  """
  def http_error(status, body) do
    case Jason.decode(body) do
      {:ok, %{"message" => message} = error} when is_binary(message) ->
        code = if error["code"], do: " (#{error["code"]})", else: ""
        "HTTP #{status}: #{message}#{code}"

      _ ->
        "HTTP #{status}: #{String.slice(body, 0, 200)}"
    end
  end
end
