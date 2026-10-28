defmodule Custyard.Release.Dsar do
  @moduledoc """
  Data subject requests behind `bin/dsar` (`rel/overlays/bin/dsar`,
  `Custyard.Release.dsar_cli/1`) and `mix custyard.dsar`: one parser and one
  set of messages for the release and for development. The work itself is
  `Custyard.DataSubjects`.

  Input arrives only as argv. Nothing starts but the Repo
  (`Custyard.Release.with_repo/1`), so the commands run beside a live server.
  Every refusal happens before the database is opened, and no error prints
  the address: a request about a person is itself personal data, and
  terminal output ends up in scrollback and logs.
  """

  alias Custyard.{DataSubjects, OperatorAccounts, Release}

  @usage """
  Usage: bin/dsar ACTION EMAIL --org ID [--yes]
         (mix custyard.dsar ACTION EMAIL --org ID [--yes] in development)

  Actions:
    export EMAIL --org ID
        Print, as JSON, every message in the organization the address appears
        on as sender, To, CC or Reply-To, with the body only for messages the
        person sent.
    erase EMAIL --org ID --yes
        Remove the address from recipient lists and Reply-To on messages the
        person did not send. Reports how many messages they sent.
    erase-contact EMAIL --org ID --yes
        The same, and also erase the messages the person sent, their
        attachments, their contact record, the subjects of their conversations
        and their rejection-log entries.
    help
        Show this help.

  ID is the organization's number, the one in /operator/organizations/ID.
  Erasures are irreversible and refuse to run without --yes. Each writes a
  data_subject_erasure audit event with counts only, never the address.
  """

  @actions ~w(export erase erase-contact)

  # :keep so a repeated switch is seen and refused; by default OptionParser
  # keeps the last value, and `--org 3 --org 4` must not quietly mean one of them.
  @switches [org: [:integer, :keep], yes: [:boolean, :keep]]

  @doc """
  Runs one action, printing to stdout and stderr, and returns the exit
  status: 0 on success, 1 on a usage error, a refusal or a failure.
  """
  def run(argv) when is_list(argv) do
    case parse(argv) do
      :help ->
        IO.write(@usage)
        0

      :usage ->
        IO.write(:stderr, @usage)
        1

      {:error, message} ->
        fail(message)

      {:ok, action, email, organization_id} ->
        case Release.with_repo(fn -> perform(action, email, organization_id) end) do
          {:ok, output} ->
            IO.write(output)
            0

          {:error, message} ->
            fail(message)
        end
    end
  end

  defp parse(["help"]), do: :help

  defp parse(argv) do
    with {opts, [action, email], []} when action in @actions <-
           OptionParser.parse(argv, strict: @switches),
         true <- Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts)),
         {:ok, organization_id} <- Keyword.fetch(opts, :org),
         true <- OperatorAccounts.valid_id?(organization_id) do
      check(action, email, organization_id, Keyword.get(opts, :yes, false))
    else
      _ -> :usage
    end
  end

  # Checked after parsing so each refusal has its own message. Neither
  # message may contain the address.
  defp check(action, email, organization_id, confirmed?) do
    cond do
      not DataSubjects.valid_email?(email) ->
        {:error, "EMAIL is not a valid email address"}

      action != "export" and not confirmed? ->
        {:error, "#{action} is irreversible; pass --yes to confirm"}

      true ->
        {:ok, action, email, organization_id}
    end
  end

  defp perform(action, email, organization_id) do
    if Custyard.Repo.get(Custyard.Organization, organization_id),
      do: perform_in(action, email, organization_id),
      else: {:error, "organization #{organization_id} not found"}
  end

  # The local release command is installation-owner authority; scope it to
  # the selected customer's tenant before invoking resource operations.
  defp scope(organization_id) do
    org = Custyard.Repo.get!(Custyard.Organization, organization_id)
    %Custyard.DataSubjects.LocalAuthority{tenant_id: org.tenant_id}
  end

  defp perform_in("export", email, organization_id) do
    json =
      DataSubjects.export(scope(organization_id), email, organization_id)
      |> Jason.encode!(pretty: true)

    {:ok, json <> "\n"}
  end

  defp perform_in("erase", email, organization_id) do
    case DataSubjects.erase_participation(scope(organization_id), email, organization_id) do
      {:ok, %{erased: erased, sent_by_subject: sent}} ->
        {:ok,
         "Removed the address from #{erased} message(s) as a recipient. " <>
           "#{sent} message(s) were sent by this address; erase-contact erases those too.\n"}

      {:error, _changeset} ->
        rolled_back()
    end
  end

  defp perform_in("erase-contact", email, organization_id) do
    case DataSubjects.erase_subject(scope(organization_id), email, organization_id) do
      {:ok, counts} ->
        {:ok,
         """
         Address removed as a recipient: #{counts.erased} message(s)
         Sent messages erased: #{counts.messages_erased}
         Attachments removed: #{counts.attachments_removed}
         Contact records removed: #{counts.contacts_removed}
         Conversation subjects erased: #{counts.conversations_retitled}
         Rejection-log entries removed: #{counts.rejections_removed}
         """}

      {:error, _changeset} ->
        rolled_back()
    end
  end

  # The only rollback DataSubjects performs itself is a failed audit insert.
  defp rolled_back,
    do: {:error, "could not write the audit event; the erasure was rolled back"}

  defp fail(message) do
    IO.puts(:stderr, "Error: #{message}")
    1
  end
end
