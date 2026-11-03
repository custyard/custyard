defmodule CustyardWeb.Operator.SystemController do
  @moduledoc """
  `/operator/system`: the boot verdict, first-run progress, last outbound
  mail result and the ground-truth block, inspectable after login
  (docs/backlog/1103-first-run-experience.md). A dead view behind
  `:require_operator`.

  Migration and operator counts come from the boot probe when it recorded
  them; otherwise they are read live, which is fine here because this page
  only exists once the Repo is up.
  """

  use CustyardWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Custyard.Boot.State
  alias Custyard.{OperatorAccount, OperatorAccounts, Repo}

  plug :put_layout, html: {CustyardWeb.Layouts, :operator}

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
    |> Map.put_new_lazy(:operators, fn ->
      placeholder = OperatorAccounts.placeholder_email()
      Repo.aggregate(from(o in OperatorAccount, where: o.email != ^placeholder), :count)
    end)
  end
end
