defmodule CustyardWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use CustyardWeb, :controller` and
  `use CustyardWeb, :live_view`.
  """
  use CustyardWeb, :html

  embed_templates "layouts/*"

  @doc """
  Sitewide warning banner shown when the app runs in production but is backed
  by a local SQLite file, meaning the database lives on ephemeral storage and
  is destroyed on every deploy/restart/machine-migration.

  The `:ephemeral_db_warning?` flag is set in `config/runtime.exs` only when the
  SQLite default branch is taken under `:prod`. Not dismissible by design — see
  https://github.com/onetimesecret/custyard/issues/71.
  """
  def ephemeral_db_banner(assigns) do
    ~H"""
    <div
      :if={Application.get_env(:custyard, :ephemeral_db_warning?, false)}
      role="alert"
      class="bg-red-600 text-white text-sm font-medium text-center px-4 py-2"
      data-testid="ephemeral-db-banner"
    >
      ⚠️ Production is running on a local SQLite file — data is NOT durable across
      deploys. Configure a Turso <code class="font-mono">DATABASE_URL</code> before
      linking any public CTA.
    </div>
    """
  end
end
