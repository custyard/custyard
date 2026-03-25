defmodule CustyardWeb.Plugs.UploadedFiles do
  @moduledoc """
  Serves uploaded files from the configured :upload_dir.

  In dev, this is typically priv/static/uploads (already served by Plug.Static).
  In production, this is a persistent directory like /data/uploads that survives
  deployments.

  Only serves files under /uploads/* paths, delegates to Plug.Static with
  the runtime-configured upload directory.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/uploads/" <> _} = conn, _opts) do
    upload_dir = Application.get_env(:custyard, :upload_dir)

    if upload_dir do
      opts =
        Plug.Static.init(
          at: "/uploads",
          from: upload_dir,
          gzip: false
        )

      Plug.Static.call(conn, opts)
    else
      conn
    end
  end

  def call(conn, _opts), do: conn
end
