defmodule Mix.Tasks.Custyard.Dsar do
  @moduledoc """
  Data subject requests for an email address, including messages where
  the person is only a To or CC participant (spec-inbound-channels,
  Privacy and compliance).

  ## Usage

      mix custyard.dsar export EMAIL --org ORG_ID
      mix custyard.dsar erase EMAIL --org ORG_ID --yes
      mix custyard.dsar erase-contact EMAIL --org ORG_ID --yes

  `export` prints JSON: every message in the organization the address
  appears on, with its roles; the body only for messages the person sent.
  `erase` removes the address from recipient lists and Reply-To on messages
  the person did not send, and reports how many messages they sent.
  `erase-contact` does the same and also erases the messages the person
  sent, their attachments, their contact record, the subjects of their
  conversations and their rejection-log entries (`DataSubjects.erase_subject/2`).
  Both erasures refuse to run without `--yes`.

  Starts only the Repo, so it works while the server is running.
  """

  use Mix.Task

  alias Custyard.DataSubjects

  @shortdoc "Export or erase a data subject's participation in messages"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, strict: [org: :integer, yes: :boolean])

    with [action, email] when action in ~w(export erase erase-contact) <- positional,
         true <- DataSubjects.valid_email?(email),
         org_id when is_integer(org_id) <- Keyword.get(opts, :org) do
      Mix.Task.run("app.config")

      {:ok, _result, _started} =
        Ecto.Migrator.with_repo(Custyard.Repo, fn _repo ->
          perform(action, email, org_id, opts)
        end)
    else
      _usage ->
        Mix.raise(
          "Usage: mix custyard.dsar export|erase|erase-contact EMAIL --org ORG_ID [--yes]"
        )
    end
  end

  defp perform("export", email, org_id, _opts) do
    email
    |> DataSubjects.export(org_id)
    |> Jason.encode!(pretty: true)
    |> Mix.shell().info()
  end

  defp perform("erase", email, org_id, opts) do
    confirm!(opts, "erase")

    {:ok, %{erased: erased, sent_by_subject: sent}} =
      DataSubjects.erase_participation(email, org_id)

    Mix.shell().info(
      "Removed the address from #{erased} message(s) as a recipient. " <>
        "#{sent} message(s) were sent by this address; erase-contact erases those too."
    )
  end

  defp perform("erase-contact", email, org_id, opts) do
    confirm!(opts, "erase-contact")

    {:ok, counts} = DataSubjects.erase_subject(email, org_id)

    Mix.shell().info("""
    Address removed as a recipient: #{counts.erased} message(s)
    Sent messages erased: #{counts.messages_erased}
    Attachments removed: #{counts.attachments_removed}
    Contact records removed: #{counts.contacts_removed}
    Conversation subjects erased: #{counts.conversations_retitled}
    Rejection-log entries removed: #{counts.rejections_removed}
    """)
  end

  defp confirm!(opts, action) do
    unless Keyword.get(opts, :yes, false) do
      Mix.raise("#{action} is irreversible; pass --yes to confirm")
    end
  end
end
