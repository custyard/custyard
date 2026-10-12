defmodule Custyard.Release do
  @moduledoc """
  Release tasks for running migrations and setting up operator accounts.

  Used by the container entrypoint to perform database setup.
  """

  @app :custyard
  @default_operator_email "admin@custyard.local"

  def migrate do
    load_app()
    Custyard.Storage.validate_fly_storage!()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    Custyard.Storage.validate_fly_storage!()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Creates an operator account in the database if one doesn't already exist.

  Email-only auth means no password is needed. Operators log in via magic link.

  Starts only the Repo, not the application: on a running machine the
  Endpoint already holds the HTTP port, so starting the application from
  `bin/custyard eval` would fail binding a second listener.

  ## Examples

      Custyard.Release.setup_operator()
      Custyard.Release.setup_operator("ops@example.com")
  """
  def setup_operator(email \\ @default_operator_email) do
    load_app()
    Custyard.Storage.validate_fly_storage!()

    {:ok, result, _} =
      Ecto.Migrator.with_repo(Custyard.Repo, fn _repo ->
        Custyard.OperatorAccounts.ensure_exists(email)
      end)

    case result do
      {:ok, _created_or_exists} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp load_app do
    Application.load(@app)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end
end
