defmodule Custyard.Email.ImapClient.Plover do
  @moduledoc """
  `Custyard.Email.ImapClient` on the Plover library.

  Plover verifies the server certificate (`verify_peer` with the system
  CA store and HTTPS hostname matching); this module never turns that off.
  Plover's commands run as `GenServer.call/2` with the default five-second
  timeout and its TLS connect has none, so callers run a whole session in a
  task with its own deadline (`Custyard.Email.ImapPoll`).
  """

  @behaviour Custyard.Email.ImapClient

  @impl true
  def connect(address, port, opts) do
    plover_opts =
      case Keyword.get(opts, :server_name) do
        name when is_binary(name) ->
          [ssl_opts: [server_name_indication: String.to_charlist(name)]]

        _ ->
          []
      end

    # :plover passes a test transport through (Plover.Transport.Mock).
    Plover.connect(address, port, Keyword.merge(plover_opts, Keyword.get(opts, :plover, [])))
  end

  @impl true
  def login(conn, username, password) do
    case Plover.login(conn, username, password) do
      {:ok, _response} -> :ok
      {:error, %Plover.Response.Tagged{status: :no}} -> {:error, :auth_failed}
      {:error, %Plover.Response.Tagged{status: :bad}} -> {:error, :auth_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def examine(conn, folder) do
    with {:ok, _response} <- Plover.examine(conn, folder),
         %{uid_validity: validity} = info when is_integer(validity) <-
           Plover.Connection.mailbox_info(conn) do
      {:ok, %{uid_validity: validity, uid_next: Map.get(info, :uid_next)}}
    else
      {:error, %Plover.Response.Tagged{}} -> {:error, :folder_unavailable}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_uid_validity}
    end
  end

  @impl true
  def highest_uid(conn) do
    case Plover.uid_fetch(conn, "*", [:uid]) do
      {:ok, messages} -> {:ok, messages |> uids() |> Enum.max(fn -> nil end)}
      {:error, %Plover.Response.Tagged{}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # `n:*` also returns the highest message when every UID is below n (the
  # range is read as highest:n), so results at or below `after_uid` are
  # dropped here.
  @impl true
  def list_after(conn, after_uid) do
    case Plover.uid_fetch(conn, "#{after_uid + 1}:*", [:uid, :rfc822_size]) do
      {:ok, messages} ->
        listed =
          messages
          |> Enum.map(fn msg -> %{uid: msg.attrs[:uid], size: msg.attrs[:rfc822_size]} end)
          |> Enum.filter(&(is_integer(&1.uid) and &1.uid > after_uid))
          |> Enum.sort_by(& &1.uid)

        {:ok, listed}

      {:error, reason} ->
        {:error, {:list_failed, reason}}
    end
  end

  @impl true
  def fetch_message(conn, uid) do
    case Plover.uid_fetch(conn, "#{uid}", [{:body_peek, ""}]) do
      {:ok, [msg | _]} ->
        case get_in(msg.attrs, [:body, ""]) || msg.attrs["BODY[]"] do
          body when is_binary(body) -> {:ok, body}
          _ -> {:error, :no_body}
        end

      {:ok, []} ->
        {:error, :message_not_found}

      {:error, reason} ->
        {:error, {:fetch_failed, reason}}
    end
  end

  @impl true
  def logout(conn) do
    Plover.logout(conn)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp uids(messages), do: messages |> Enum.map(& &1.attrs[:uid]) |> Enum.filter(&is_integer/1)
end
