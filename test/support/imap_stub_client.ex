defmodule Custyard.Email.ImapClient.Stub do
  @moduledoc """
  Test double for `Custyard.Email.ImapClient`. Each test creates a fake
  mailbox under a unique host name (`mailbox/1`) in an Agent started by
  `test/test_helper.exs`; the channel's `imap_host` selects it, so async
  tests never collide and nothing touches the network (test config allows
  private hosts, so the host is passed through unresolved).

  State per host: `password`, `uid_validity`, `folders`, `messages`
  (`%{uid => raw}`), `sizes` (`%{uid => bytes}`, overriding the listed
  size), `connect_error`, `fetch_error` (`%{uid => reason}`), `on_login`
  (a zero-arity function run during login, to change state mid-session),
  `on_fetch` (a function receiving the UID during fetch), and `calls`, the operations in order, for asserting that polling never
  changes the mailbox.
  """

  @behaviour Custyard.Email.ImapClient

  def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "Create a mailbox and return its host name."
  def mailbox(overrides \\ []) do
    host = "imap-#{System.unique_integer([:positive])}.example.test"

    state =
      Map.merge(
        %{
          password: "secret",
          uid_validity: 1,
          folders: ["INBOX"],
          messages: %{},
          sizes: %{},
          connect_error: nil,
          fetch_error: %{},
          on_login: nil,
          calls: []
        },
        Map.new(overrides)
      )

    Agent.update(__MODULE__, &Map.put(&1, host, state))
    host
  end

  def put_message(host, uid, raw), do: update(host, &put_in(&1, [:messages, uid], raw))

  def update(host, fun), do: Agent.update(__MODULE__, &Map.update!(&1, host, fun))

  def get(host), do: Agent.get(__MODULE__, &Map.fetch!(&1, host))

  def calls(host), do: host |> get() |> Map.fetch!(:calls) |> Enum.reverse()

  defp record(host, call),
    do: update(host, &Map.update!(&1, :calls, fn calls -> [call | calls] end))

  @impl true
  def connect(host, _port, _opts) do
    case Agent.get(__MODULE__, &Map.get(&1, host)) do
      nil ->
        {:error, :nxdomain}

      %{connect_error: nil} ->
        record(host, :connect)
        {:ok, host}

      %{connect_error: reason} ->
        {:error, reason}
    end
  end

  @impl true
  def login(host, _username, password) do
    record(host, :login)
    state = get(host)
    if state.on_login, do: state.on_login.()
    if state.password == password, do: :ok, else: {:error, :auth_failed}
  end

  @impl true
  def examine(host, folder) do
    record(host, {:examine, folder})
    state = get(host)

    if folder in state.folders,
      do: {:ok, %{uid_validity: state.uid_validity, uid_next: next_uid(state)}},
      else: {:error, :folder_unavailable}
  end

  @impl true
  def highest_uid(host) do
    {:ok, host |> get() |> Map.fetch!(:messages) |> Map.keys() |> Enum.max(fn -> nil end)}
  end

  @impl true
  def list_after(host, after_uid) do
    record(host, {:list_after, after_uid})

    state = get(host)

    listed =
      state.messages
      |> Enum.filter(fn {uid, _raw} -> uid > after_uid end)
      |> Enum.sort()
      |> Enum.map(fn {uid, raw} ->
        %{uid: uid, size: Map.get(state.sizes, uid, byte_size(raw))}
      end)

    {:ok, listed}
  end

  @impl true
  def fetch_message(host, uid) do
    record(host, {:fetch, uid})
    state = get(host)
    if callback = Map.get(state, :on_fetch), do: callback.(uid)

    case {Map.fetch(state.fetch_error, uid), Map.fetch(state.messages, uid)} do
      {{:ok, reason}, _message} -> {:error, reason}
      {:error, {:ok, raw}} -> {:ok, raw}
      {:error, :error} -> {:error, :message_not_found}
    end
  end

  @impl true
  def logout(host) do
    record(host, :logout)
    :ok
  end

  defp next_uid(%{messages: messages}) when map_size(messages) == 0, do: 1
  defp next_uid(%{messages: messages}), do: (messages |> Map.keys() |> Enum.max()) + 1
end
