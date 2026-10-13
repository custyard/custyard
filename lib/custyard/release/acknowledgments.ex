defmodule Custyard.Release.Acknowledgments do
  @moduledoc """
  Release commands behind `bin/acknowledgments` for the Colonel acknowledgment
  subscription; the Mix tasks run the same commands in development.

  They never start the application: the repository runs through
  `Ecto.Migrator.with_repo/2` and broker work starts only `:amqp`, so they
  work beside a running server. Input arrives only as argv. The broker URL and
  credentials come from the environment and are never accepted as arguments
  or printed.
  """
  alias Custyard.{Acknowledgments, OperatorAccounts}
  alias Custyard.Acknowledgments.{Config, Evidence, Operations}

  @app :custyard
  # The largest id OperatorAccounts.valid_id?/1 accepts (signed 64 bits).
  @max_id 9_223_372_036_854_775_807

  @usage """
  Usage: bin/acknowledgments COMMAND
         (mix acknowledgments.COMMAND in development)

  Commands:
    status                    Show configuration and per-queue ready and consumer counts
    provision                 Declare the work, retry and failure queues (needs the
                              provisioning credential, not the runtime one)
    bind SOURCE SOURCE_ORG_ID CUSTYARD_ORG_ID
                              Attribute a source organization's evidence to a Custyard
                              organization. Permanent: bindings cannot be removed or
                              reassigned
    inspect [--evidence]      Summarize the oldest failed message; --evidence prints the
                              full original evidence
    replay [SUBMISSION_ID]    Replay the oldest failed message to the work queue; with
                              SUBMISSION_ID, only while it is still the oldest
    help                      Show this help

  The broker URL and source come from ACKNOWLEDGMENTS_AMQP_URL and
  ACKNOWLEDGMENTS_SOURCE; they are never accepted as arguments.
  """

  # Command => {strict switches, accepted positional argument counts}.
  @commands %{
    "help" => {[], [0]},
    "status" => {[], [0]},
    "provision" => {[], [0]},
    "bind" => {[], [3]},
    "inspect" => {[evidence: :boolean], [0]},
    "replay" => {[], [0, 1]}
  }

  @doc "Entry point for `bin/acknowledgments`: runs the command, then halts with its status."
  def main(argv), do: argv |> run(mode: :release) |> System.halt()

  @doc """
  Runs a command and returns its exit status. Options: `:mode` is `:release`
  (start only what the command needs: the release command and the Mix tasks)
  or `:running` (the Repo and `:amqp` already run, as in tests); `:actor` names
  the audit channel.
  """
  def run(argv, opts \\ []) do
    opts = Keyword.merge([mode: :running, actor: "cli"], opts)

    case parse(argv) do
      {:ok, command} -> execute(command, opts)
      :usage -> usage_error()
    end
  end

  defp parse([name | rest]) when is_map_key(@commands, name) do
    {switches, counts} = Map.fetch!(@commands, name)

    with {parsed, args, []} <- OptionParser.parse(rest, strict: switches),
         true <- length(args) in counts do
      {:ok, {name, parsed, args}}
    else
      _ -> :usage
    end
  end

  defp parse(_), do: :usage

  defp execute({"help", _, _}, _opts) do
    IO.write(@usage)
    0
  end

  defp execute({"status", _, _}, opts) do
    load(opts)
    config = Config.load()
    print_configuration(config)

    case Config.connection_mode(config) do
      :configured ->
        with_broker(opts, fn ->
          case Config.validation_error(config) do
            nil -> print_queue_status()
            message -> fail("Invalid configuration: #{message}")
          end
        end)

      :not_configured ->
        IO.puts("Set ACKNOWLEDGMENTS_AMQP_URL and ACKNOWLEDGMENTS_SOURCE to use the broker.")
        0

      {:incomplete, missing} ->
        fail("#{missing} is not set; set both, or the application will not start")
    end
  end

  defp execute({"provision", _, _}, opts) do
    load(opts)

    with_broker(opts, fn ->
      case Operations.provision() do
        :ok ->
          Config.load()
          |> Operations.queues()
          |> Enum.each(fn {_, queue} -> IO.puts("Provisioned #{queue}") end)

          0

        error ->
          fail(Operations.error_message(error))
      end
    end)
  end

  defp execute({"bind", _, [source, external_id, organization_id]}, opts) do
    # Bounded to signed 64 bits: anything larger makes the SQLite driver raise.
    with {id, ""} <- Integer.parse(organization_id),
         true <- OperatorAccounts.valid_id?(id) do
      with_repo(opts, fn -> bind(source, external_id, id, opts) end)
    else
      _ -> fail("CUSTYARD_ORG_ID must be an integer from 1 to #{@max_id}")
    end
  end

  defp execute({"inspect", switches, _}, opts) do
    load(opts)

    with_broker(opts, fn ->
      if switches[:evidence], do: print_evidence(), else: print_summary()
    end)
  end

  # The replay writes its audit row through the Repo, so the Repo starts first.
  defp execute({"replay", _, args}, opts) do
    with_repo(opts, fn ->
      with_broker(opts, fn ->
        case Operations.replay(List.first(args), opts[:actor]) do
          :ok -> ok("Replayed the oldest failed message to the work queue")
          :empty -> ok("No failed messages")
          error -> fail(Operations.error_message(error))
        end
      end)
    end)
  end

  defp bind(source, external_id, id, opts) do
    binding = "#{printable(source)} #{printable(external_id)}"

    case Acknowledgments.bind(source, external_id, id, opts[:actor]) do
      {:ok, :created, _} ->
        ok("Bound #{binding} to organization #{id}")

      {:ok, :existing, _} ->
        ok("#{binding} is already bound to organization #{id}; nothing changed")

      {:error, :conflicting_binding} ->
        fail("#{binding} is already bound to another organization; bindings cannot be reassigned")

      {:error, :organization_not_found} ->
        fail("Organization #{id} does not exist")

      {:error, _} ->
        fail(
          "SOURCE and SOURCE_ORG_ID must be nonblank identities of at most 255 bytes " <>
            "without surrounding spaces or control characters"
        )
    end
  end

  defp print_configuration(config) do
    enabled = if config[:enabled], do: "enabled", else: "disabled"
    url = if is_binary(config[:url]) and config[:url] != "", do: "set", else: "not set"

    source =
      if Evidence.valid_identity?(config[:source]),
        do: printable(config[:source]),
        else: if(is_nil(config[:source]), do: "not set", else: "set but invalid")

    IO.puts("Consumer: #{enabled}")
    IO.puts("Source: #{source}")
    IO.puts("Broker URL: #{url}")
    IO.puts("Queue: #{printable(config[:queue])}, prefetch #{config[:prefetch]}")
  end

  defp print_queue_status do
    case Operations.status() do
      {:ok, queues} ->
        Enum.each(queues, &IO.puts(queue_line(&1)))
        0

      error ->
        fail(Operations.error_message(error))
    end
  end

  defp queue_line(%{queue: queue, ready: ready, consumers: consumers}),
    do: "#{printable(queue)}: #{ready} ready, #{consumers} #{plural(consumers, "consumer")}"

  defp queue_line(%{queue: queue, error: error}),
    do: "#{printable(queue)}: #{Operations.error_message(error)}"

  defp print_summary do
    case Operations.failure_summary() do
      {:ok, summary} ->
        print_summary_lines(summary)
        0

      :empty ->
        ok("No failed messages")

      error ->
        fail(Operations.error_message(error))
    end
  end

  defp print_evidence do
    case Operations.inspect_failure() do
      {:ok, %{body: body, summary: summary}} ->
        IO.puts(
          :stderr,
          "WARNING: the full original evidence follows. Use an authorized terminal only."
        )

        print_summary_lines(summary)
        IO.puts("Evidence (each line prefixed with \"  | \"):")
        # Raw newlines in the body cannot start a line that reads like a
        # summary line: every body line carries the prefix.
        body
        |> String.split("\n")
        |> Enum.each(&IO.puts("  | " <> printable(&1)))

        0

      :empty ->
        ok("No failed messages")

      error ->
        fail(Operations.error_message(error))
    end
  end

  defp print_summary_lines(summary) do
    IO.puts("Oldest failed message:")

    if summary.readable do
      IO.puts("  Source: #{printable(summary.source)}")
      IO.puts("  Submission ID: #{printable(summary.submission_id)}")
    else
      IO.puts("  Source and submission ID: unreadable")
    end

    IO.puts("  Failure category: #{summary.category || "unknown"}")
    IO.puts("  Attempt: #{summary.attempt || "unknown"}")
  end

  defp load(opts) do
    if opts[:mode] == :release, do: Application.load(@app)
    :ok
  end

  defp with_broker(opts, fun) do
    if opts[:mode] == :release, do: {:ok, _} = Application.ensure_all_started(:amqp)
    fun.()
  end

  # The storage check runs before the Repo starts, as Release.migrate does:
  # opening SQLite first would create an empty database on the container's
  # root filesystem when the Fly volume is missing.
  defp with_repo(opts, fun) do
    load(opts)
    Custyard.Storage.validate_fly_storage!()

    if opts[:mode] == :release do
      case Ecto.Migrator.with_repo(Custyard.Repo, fn _repo -> fun.() end) do
        {:ok, status, _} -> status
        {:error, _} -> fail("The database is unavailable")
      end
    else
      fun.()
    end
  end

  # Printed text can come from a failed message or the environment. Every
  # control, format (bidi override, zero-width), surrogate, private-use or
  # unassigned code point, and the Unicode line and paragraph separators, is
  # printed as an escape, so nothing printed can move the cursor, reorder text
  # or start a new line. Invalid UTF-8 bytes are printed as \xNN.
  @unsafe ~r/[\p{C}\x{2028}\x{2029}]/u

  defp printable(value) when is_binary(value) do
    value
    |> String.chunk(:valid)
    |> Enum.map_join(fn chunk ->
      if String.valid?(chunk),
        do: Regex.replace(@unsafe, chunk, &escape_code_point/1),
        else: for(<<byte <- chunk>>, into: "", do: "\\x" <> Base.encode16(<<byte>>))
    end)
  end

  defp printable(value), do: inspect(value)

  defp escape_code_point(char) do
    [code_point] = String.to_charlist(char)
    "\\u{" <> Integer.to_string(code_point, 16) <> "}"
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp ok(message) do
    IO.puts(message)
    0
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    1
  end

  defp usage_error do
    IO.write(:stderr, @usage)
    1
  end
end
