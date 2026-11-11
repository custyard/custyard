defmodule Custyard.Lettermint.HttpClient do
  @moduledoc """
  Production HTTP client for the Lettermint API.

  Uses Finch to make HTTP requests. Requires `LETTERMINT_API_URL` and
  a tenant connection with a management token.

  Routes and sending domains are both read from the Team API at the
  configured base URL with the same bearer token; `list_domains/0` pages
  through `GET /domains` (`page[size]=100`, `page[cursor]=`) for at most five
  pages.
  """

  alias Custyard.Lettermint.Client
  @behaviour Client

  @impl true
  def create_route(params, opts \\ [])

  def create_route(%{lettermint_project_id: project_id}, _opts) when project_id in [nil, ""],
    do: {:error, :project_required}

  def create_route(params, opts) do
    project_id = Map.fetch!(params, :lettermint_project_id)
    url = api_url("/projects/#{URI.encode_www_form(to_string(project_id))}/routes", opts)

    # attachment_delivery "url": signed URLs rather than inline Base64
    # (docs/design/spec-inbound-channels.md, D9).
    body =
      Jason.encode!(%{
        name: Map.fetch!(params, :name),
        route_type: Map.fetch!(params, :route_type),
        attachment_delivery: "url"
      })

    case request(:post, url, body, opts) do
      {:ok, %Finch.Response{status: status, body: response_body}}
      when status in [200, 201] ->
        decode_route(response_body)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:api_error, status, response_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def get_route(lettermint_route_id, opts \\ []) do
    url = api_url("/routes/#{URI.encode_www_form(lettermint_route_id)}", opts)

    case request(:get, url, nil, opts) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        decode_route(response_body)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:api_error, status, response_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def delete_route(lettermint_route_id, opts \\ []) do
    url = api_url("/routes/#{URI.encode_www_form(lettermint_route_id)}", opts)

    case request(:delete, url, nil, opts) do
      {:ok, %Finch.Response{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %Finch.Response{status: 404}} ->
        :ok

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:api_error, status, response_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def set_inbound_domain(lettermint_route_id, domain, opts \\ []) do
    url = api_url("/routes/#{URI.encode_www_form(lettermint_route_id)}", opts)
    body = Jason.encode!(%{inbound_settings: %{inbound_domain: domain}})

    case request(:put, url, body, opts) do
      {:ok, %Finch.Response{status: 200, body: response_body}} ->
        decode_route(response_body)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:api_error, status, response_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def verify_inbound_domain(lettermint_route_id, opts \\ []) do
    url =
      api_url("/routes/#{URI.encode_www_form(lettermint_route_id)}/verify-inbound-domain", opts)

    case request(:post, url, nil, opts) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        decode_verification(response_body)

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:api_error, status, response_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc false
  # `{"data": {"verified": bool, "message": ..., "expected_mx_records": [...],
  # "found_mx_records": [...]}}`; accepts the bare object as well.
  def decode_verification(response_body) when is_binary(response_body) do
    case Jason.decode(response_body) do
      {:ok, %{"data" => %{"verified" => verified} = result}} when is_boolean(verified) ->
        {:ok, result}

      {:ok, %{"verified" => verified} = result} when is_boolean(verified) ->
        {:ok, result}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, decode_error} ->
        {:error, {:decode_failed, decode_error, response_body}}
    end
  end

  @impl true
  def get_webhook_delivery(webhook_id, delivery_id, opts \\ []) do
    # Provider IDs are opaque path segments, never URLs supplied by a message.
    path =
      "/webhooks/#{URI.encode_www_form(webhook_id)}/deliveries/#{URI.encode_www_form(delivery_id)}"

    case request(:get, api_url(path, opts), nil, opts) do
      {:ok, %Finch.Response{status: 200, body: body}} -> decode_delivery(body)
      {:ok, %Finch.Response{status: status}} -> {:error, {:provider_status, status}}
      {:error, _reason} -> {:error, :provider_unavailable}
    end
  rescue
    _error -> {:error, :provider_unavailable}
  end

  @doc false
  def decode_delivery(body) do
    with {:ok, %{} = response} <- Jason.decode(body),
         %{} = delivery <- Map.get(response, "data", response),
         %{} = payload <- delivery["payload"] do
      {:ok, Map.put(delivery, "payload", payload)}
    else
      _ -> {:error, :delivery_content_unavailable}
    end
  end

  @domains_per_page 100
  @domains_max_pages 5

  @impl true
  def list_domains(opts \\ []) do
    list_domains_page(nil, [], @domains_max_pages, opts)
  end

  @impl true
  # The project-filtered list omits unrestricted domains. Look up the exact
  # team domain and inspect its project limits: an empty list allows every
  # project, while explicit assignments must include the selected project.
  def get_sending_domain(domain, opts \\ []) do
    opts = config(opts)
    project_id = opts[:project_id]

    if is_binary(project_id) and project_id != "" do
      lookup_opts = opts |> Keyword.delete(:project_id) |> Keyword.put(:domain_filter, domain)

      with {:ok, domains} <- list_domains(lookup_opts),
           %{"id" => id} = found when is_binary(id) <-
             Client.find_domain(domains, domain),
           {:ok, details} <-
             get_resource("/domains/#{URI.encode_www_form(id)}?include%5B%5D=projects", opts) do
        case details["projects"] do
          [] ->
            {:ok, found}

          projects when is_list(projects) ->
            if Enum.any?(projects, &(is_map(&1) and &1["id"] == project_id)),
              do: {:ok, found},
              else: {:ok, nil}

          _ ->
            {:error, :domain_access_unknown}
        end
      else
        nil -> {:ok, nil}
        {:error, _} = error -> error
        _ -> {:error, :domain_access_unknown}
      end
    else
      {:error, :project_required}
    end
  end

  # Cursor pagination over GET /domains, bounded so a misbehaving cursor can
  # never loop. Pages are concatenated in API order.
  defp list_domains_page(_cursor, acc, 0, _opts), do: {:ok, acc}

  defp list_domains_page(cursor, acc, pages_left, opts) do
    url =
      api_url(
        "/domains?" <>
          URI.encode_query(domains_query(cursor) ++ project_filter(opts) ++ domain_filter(opts)),
        opts
      )

    case request(:get, url, nil, opts) do
      {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
        with {:ok, {domains, next_cursor}} <- decode_domains_page(response_body) do
          acc = acc ++ domains

          if is_binary(next_cursor) and next_cursor != "" do
            list_domains_page(next_cursor, acc, pages_left - 1, opts)
          else
            {:ok, acc}
          end
        end

      {:ok, %Finch.Response{status: status, body: response_body}} ->
        {:error, {:api_error, status, response_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # The Team API takes JSON:API-style page parameters; `per_page` and
  # `cursor` are ignored, which would return the first page every time.
  defp domains_query(nil), do: [{"page[size]", @domains_per_page}]

  defp domains_query(cursor),
    do: [{"page[size]", @domains_per_page}, {"page[cursor]", cursor}]

  @doc false
  # One page of GET /domains: `{"data": [domain, ...], "next_cursor": ...}`.
  # The cursor may be absent or null on the last page, or live under "meta".
  def decode_domains_page(response_body) when is_binary(response_body) do
    case Jason.decode(response_body) do
      {:ok, %{"data" => domains} = page} when is_list(domains) ->
        {:ok, {domains, next_cursor(page)}}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, decode_error} ->
        {:error, {:decode_failed, decode_error, response_body}}
    end
  end

  defp next_cursor(%{"next_cursor" => cursor}), do: cursor
  defp next_cursor(%{"meta" => %{"next_cursor" => cursor}}), do: cursor
  defp next_cursor(_page), do: nil

  @doc false
  # Lettermint wraps the route in `{"data": route, "message": ...}` on create
  # (201) but returns it bare on GET. Accept both so callers see one shape.
  def normalize_route_response(%{"data" => %{} = route}), do: route
  def normalize_route_response(%{} = route), do: route

  defp decode_route(response_body) do
    case Jason.decode(response_body) do
      {:ok, %{} = decoded} ->
        {:ok, normalize_route_response(decoded)}

      {:ok, other} ->
        {:error, {:unexpected_response, other}}

      {:error, decode_error} ->
        {:error, {:decode_failed, decode_error, response_body}}
    end
  end

  @doc "Fetch a provider project without modifying it."
  def get_project(project_id, opts \\ []),
    do: get_resource("/projects/#{URI.encode_www_form(project_id)}", opts)

  @doc "Fetch a webhook so a manually created endpoint can be bound safely."
  def get_webhook(webhook_id, opts \\ []),
    do: get_resource("/webhooks/#{URI.encode_www_form(webhook_id)}", opts)

  def ping_sending(token, opts \\ []) do
    Finch.build(:get, api_url("/ping", opts), [{"x-lettermint-token", token}])
    |> Finch.request(Custyard.Finch, receive_timeout: 10_000)
    |> case do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:provider_status, status}}
      {:error, _} -> {:error, :provider_unavailable}
    end
  end

  defp get_resource(path, opts) do
    case request(:get, api_url(path, opts), nil, opts) do
      {:ok, %{status: 200, body: body}} -> decode_route(body)
      {:ok, %{status: status}} -> {:error, {:provider_status, status}}
      {:error, _} -> {:error, :provider_unavailable}
    end
  end

  defp project_filter(opts) do
    case Keyword.get(opts, :project_id) do
      nil -> []
      id -> [{"filter[project]", id}]
    end
  end

  defp domain_filter(opts) do
    case Keyword.get(opts, :domain_filter) do
      nil -> []
      domain -> [{"filter[domain]", domain}]
    end
  end

  defp request(method, url, body, opts) do
    headers = [
      {"authorization", "Bearer #{api_key(opts)}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    Finch.build(method, url, headers, body)
    |> Finch.request(Custyard.Finch, receive_timeout: 10_000)
  end

  defp config(opts),
    do: if(opts == [], do: Application.get_env(:custyard, :lettermint, []), else: opts)

  defp api_url(path, opts) do
    base = config(opts)[:api_url] || "https://api.lettermint.co/v1"
    String.trim_trailing(base, "/") <> path
  end

  defp api_key(opts) do
    config(opts)[:team_token] || raise "tenant management credential not configured"
  end
end
