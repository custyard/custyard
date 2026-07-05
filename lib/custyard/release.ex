defmodule Custyard.Release do
  @moduledoc """
  Release tasks for running migrations and setting up operator accounts.

  Used by the container entrypoint to perform database setup.
  """

  @app :custyard
  @default_operator_email "admin@custyard.local"

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Creates an operator account in the database if one doesn't already exist.

  Email-only auth means no password is needed. Operators log in via magic link.

  ## Examples

      Custyard.Release.setup_operator()
      Custyard.Release.setup_operator("ops@example.com")
  """
  def setup_operator(email \\ @default_operator_email) do
    load_app()

    {:ok, _} = Application.ensure_all_started(@app)

    alias Custyard.{OperatorAccount, Repo}

    case Repo.get_by(OperatorAccount, email: email) do
      nil ->
        %OperatorAccount{}
        |> OperatorAccount.changeset(%{email: email})
        |> Repo.insert!()

      _existing ->
        :already_exists
    end

    :ok
  end

  defp load_app do
    Application.load(@app)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end
end
