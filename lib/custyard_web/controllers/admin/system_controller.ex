defmodule CustyardWeb.Admin.SystemController do
  @moduledoc """
  `/admin/system`: the boot verdict, first-run progress, last outbound mail
  result and the ground-truth block, inspectable after login
  (docs/backlog/1103-first-run-experience.md). A dead view for instance
  administrators only: it lists environment variable names and the database
  path, which are installation facts no tenant's staff has any business
  seeing. The host plug already confines `/admin` to the installation host.

  Migration and administrator counts come from the boot probe when it
  recorded them; otherwise they are read live, which is fine here because
  this page only exists once the Repo is up.
  """

  use CustyardWeb, :controller

  alias Custyard.Auth.Account
  alias Custyard.Boot.State
  alias Custyard.{InstanceAdmin, InstanceAdmins, Repo}

  plug :require_instance_admin
  plug :put_layout, html: {CustyardWeb.Layouts, :admin}

  # The same check as CustyardWeb.Live.InstanceAdminAuth, for a dead view.
  defp require_instance_admin(conn, _opts) do
    with id when not is_nil(id) <- get_session(conn, :instance_admin_id),
         %InstanceAdmin{} = admin <- Repo.get(InstanceAdmin, id),
         true <- Account.session_claim_matches?(admin, get_session(conn, :instance_admin_claim)) do
      assign(conn, :current_instance_admin, admin)
    else
      _ -> conn |> redirect(to: ~p"/admin/login") |> halt()
    end
  end

  def index(conn, _params) do
    state = State.get()
    state = %{state | database: %{state.database | facts: with_counts(state.database.facts)}}

    render(conn, :index,
      page_title: "System",
      state: state,
      warnings: (state.env && state.env.warnings) || []
    )
  end

  defp with_counts(facts) do
    facts
    |> Map.put_new_lazy(:migrations, fn -> length(Ecto.Migrator.migrated_versions(Repo)) end)
    |> Map.put_new_lazy(:instance_admins, &InstanceAdmins.count/0)
  end
end
