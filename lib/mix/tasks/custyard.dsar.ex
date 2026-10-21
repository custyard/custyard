defmodule Mix.Tasks.Custyard.Dsar do
  @moduledoc """
  Data subject requests for an email address, including messages where
  the person is only a To or CC participant (spec-inbound-channels,
  Privacy and compliance).

  ## Usage

      mix custyard.dsar export EMAIL --org ORG_ID
      mix custyard.dsar erase EMAIL --org ORG_ID --yes

  `export` prints JSON: every message in the organization the address
  appears on, with its roles; the body only for messages the person sent.
  `erase` removes the address from recipient lists and Reply-To on messages
  the person did not send, and reports how many messages they sent (those
  belong to the contact-level erasure). It refuses to run without `--yes`.

  Starts only the Repo, so it works while the server is running.
  """

  use Mix.Task

  alias Custyard.DataSubjects

  @shortdoc "Export or erase a data subject's participation in messages"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [org: :integer, yes: :boolean])

    with [action, email] when action in ~w(export erase) <- positional,
         true <- DataSubjects.valid_email?(email),
         org_id when is_integer(org_id) <- Keyword.get(opts, :org) do
      Mix.Task.run("app.config")

      {:ok, _result, _started} =
        Ecto.Migrator.with_repo(Custyard.Repo, fn _repo ->
          perform(action, email, org_id, opts)
        end)
    else
      _usage -> Mix.raise("Usage: mix custyard.dsar export|erase EMAIL --org ORG_ID [--yes]")
    end
  end

  defp perform("export", email, org_id, _opts) do
    email
    |> DataSubjects.export(org_id)
    |> Jason.encode!(pretty: true)
    |> Mix.shell().info()
  end

  defp perform("erase", email, org_id, opts) do
    unless Keyword.get(opts, :yes, false) do
      Mix.raise("erase is irreversible; pass --yes to confirm")
    end

    {:ok, %{erased: erased, sent_by_subject: sent}} =
      DataSubjects.erase_participation(email, org_id)

    Mix.shell().info(
      "Removed the address from #{erased} message(s) as a recipient. " <>
        "#{sent} message(s) were sent by this address and are left for the contact erasure."
    )
  end
end
