defmodule Custyard.Email.ImapClient do
  @moduledoc """
  The IMAP operations an IMAP channel needs (spec-inbound-channels, D8),
  behind a behaviour so the poll logic is tested without a server.

  The folder is opened read-only (EXAMINE) and messages are fetched with
  `BODY.PEEK[]`: polling never sets `\\Seen` or any other flag in the
  staff's mailbox. New mail is listed by UID with `UID FETCH`, not
  `SEARCH`, because the response format of FETCH is the same on every
  server.

  `client/0` returns `config :custyard, :imap_client`
  (`Custyard.Email.ImapClient.Plover` in production).
  """

  @type conn :: term()
  @type mailbox :: %{uid_validity: pos_integer(), uid_next: pos_integer() | nil}
  @type listed :: %{uid: pos_integer(), size: non_neg_integer() | nil}

  @doc """
  Open an implicit-TLS connection. `opts[:server_name]` is the name the
  certificate must match when `address` is an IP the caller resolved.
  """
  @callback connect(address :: String.t(), port :: :inet.port_number(), opts :: keyword()) ::
              {:ok, conn()} | {:error, term()}

  @doc "`:ok`, `{:error, :auth_failed}` when the server rejects the credentials, or another error."
  @callback login(conn(), username :: String.t(), password :: String.t()) ::
              :ok | {:error, term()}

  @doc "Open `folder` read-only and report its UIDVALIDITY and UIDNEXT."
  @callback examine(conn(), folder :: String.t()) :: {:ok, mailbox()} | {:error, term()}

  @doc "Highest UID in the open folder, nil when it is empty."
  @callback highest_uid(conn()) :: {:ok, pos_integer() | nil} | {:error, term()}

  @doc "Messages with a UID greater than `after_uid`, ascending, with their sizes."
  @callback list_after(conn(), after_uid :: non_neg_integer()) ::
              {:ok, [listed()]} | {:error, term()}

  @doc "The full RFC 5322 message, fetched without setting `\\\\Seen`."
  @callback fetch_message(conn(), uid :: pos_integer()) :: {:ok, binary()} | {:error, term()}

  @callback logout(conn()) :: :ok

  @doc "The configured client module."
  def client, do: Application.fetch_env!(:custyard, :imap_client)
end
