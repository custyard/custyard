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
  Creates or updates an operator account in the database.

  Reads password from the OPERATOR_PASSWORD environment variable to avoid
  exposing it in the process list. Optionally accepts an email override.

  ## Examples

      # In a release eval (reads OPERATOR_PASSWORD from env):
      Custyard.Release.setup_operator()
      Custyard.Release.setup_operator("ops@example.com")
  """
  def setup_operator(email \\ @default_operator_email) do
    load_app()

    {:ok, _} = Application.ensure_all_started(@app)

    # Read password from environment to avoid exposing it in the process list
    password =
      System.get_env("OPERATOR_PASSWORD") ||
        raise "OPERATOR_PASSWORD environment variable is not set"

    alias Custyard.{OperatorAccount, Repo}

    case Repo.get_by(OperatorAccount, email: email) do
      nil ->
        %OperatorAccount{}
        |> OperatorAccount.changeset(%{email: email, password: password})
        |> Repo.insert!()

      existing ->
        existing
        |> OperatorAccount.password_changeset(%{password: password})
        |> Repo.update!()
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
