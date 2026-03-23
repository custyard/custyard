defmodule Custyard.Release do
  @moduledoc """
  Release tasks for running migrations and setting up operator accounts.

  Used by the container entrypoint to perform database setup.
  """

  @app :custyard

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

  def setup_operator(password) do
    load_app()

    {:ok, _} = Application.ensure_all_started(@app)

    # Hash the password and store/update operator account
    # This will be implemented once the accounts context exists
    # For now, just configure the password in the application env
    Application.put_env(@app, :operator_password, password)

    :ok
  end

  defp load_app do
    Application.load(@app)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end
end
