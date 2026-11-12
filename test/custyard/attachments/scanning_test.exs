defmodule Custyard.Attachments.ScanningTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import ExUnit.CaptureLog

  alias Custyard.{Attachments, Files, Message, Repo, Scope, Tenants, Thread}
  alias Custyard.Attachments.{Scanner, ScanRetry}
  alias Custyard.Files.{Chunk, StoredFile}

  @no_scans %{clean: 0, infected: 0, error: 0, pending: 0}

  setup do
    previous = Application.get_env(:custyard, :attachment_scanner)
    previous_options = Application.get_env(:custyard, :attachment_scanner_options)

    on_exit(fn ->
      Application.put_env(:custyard, :attachment_scanner, previous)

      if previous_options,
        do: Application.put_env(:custyard, :attachment_scanner_options, previous_options),
        else: Application.delete_env(:custyard, :attachment_scanner_options)
    end)

    customer = insert_organization()
    thread = insert_thread(organization_id: customer.id)
    message = insert_message(thread_id: thread.id)
    admin = insert_staff_account(role: "admin")
    scope = Scope.for_staff(admin, Tenants.get_tenant!(admin.tenant_id))
    %{customer: customer, thread: thread, message: message, scope: scope}
  end

  test "an unavailable scanner quarantines files without rejecting inbound mail", %{
    customer: customer,
    message: message,
    scope: scope
  } do
    Application.put_env(:custyard, :attachment_scanner, nil)
    row = fetched(message, "Unscanned content")
    assert row.state == :fetched
    assert row.scan_status == :pending
    assert Files.read(Attachments.stored_file(row)) == {:ok, "Unscanned content"}
    refute Attachments.get(scope, row.id)
    refute Attachments.get_for_portal(row.id, customer.id)
    refute Attachments.downloadable?(row)
  end

  test "malware and scan failures remain quarantined", %{message: message, scope: scope} do
    for {bytes, status} <- [
          {"CUSTYARD_TEST_INFECTED content", :infected},
          {"CUSTYARD_TEST_SCAN_ERROR content", :error}
        ] do
      other_message = insert_message(thread_id: message.thread_id)
      row = fetched(other_message, bytes)
      assert row.state == :fetched
      assert row.scan_status == status
      refute Attachments.get(scope, row.id)
    end
  end

  test "only clean files become downloadable", %{message: message, scope: scope} do
    row = fetched(message, "Clean test content")
    assert row.scan_status == :clean
    assert Attachments.downloadable?(row)
    assert Attachments.get(scope, row.id).id == row.id
  end

  test "rescanning old files requires the tenant administrator", %{
    thread: thread,
    message: message,
    scope: scope
  } do
    row = fetched(message, "Stored before malware scans existed")
    row |> Ecto.Changeset.change(scan_status: :pending, scanned_at: nil) |> Repo.update!()
    agent = insert_staff_account(role: "agent")
    agent_scope = Scope.for_staff(agent, Tenants.get_tenant!(agent.tenant_id))
    assert {:error, :unauthorized} = Attachments.rescan_thread(agent_scope, thread.id)

    foreign = insert_staff_account(role: "admin", tenant_id: insert_tenant().id)
    foreign_scope = Scope.for_staff(foreign, Tenants.get_tenant!(foreign.tenant_id))
    assert {:error, :not_found} = Attachments.rescan_thread(foreign_scope, thread.id)
    assert Repo.reload!(row).scan_status == :pending

    assert {:ok, %{clean: 1}} = Attachments.rescan_thread(scope, thread.id)
    assert Repo.reload!(row).scan_status == :clean
  end

  test "a corrupt stored file cannot receive a clean verdict", %{
    thread: thread,
    message: message,
    scope: scope
  } do
    row = fetched(message, "Original content")
    assert row.scan_status == :clean
    %StoredFile{id: file_id} = Attachments.stored_file(row)

    # Same length, so only the hash can tell.
    Repo.update_all(from(c in Chunk, where: c.file_id == ^file_id),
      set: [data: "Tampered content"]
    )

    assert {:ok, %{error: 1}} = Attachments.rescan_thread(scope, thread.id)
    assert Repo.reload!(row).scan_status == :error
    refute Attachments.get(scope, row.id)
  end

  test "stored content that is gone cannot receive a clean verdict", %{
    thread: thread,
    message: message,
    scope: scope
  } do
    missing = fetched(message, "Content that will be removed")
    truncated = fetched(insert_message(thread_id: thread.id), "Content that will lose its chunk")
    assert missing.scan_status == :clean
    assert truncated.scan_status == :clean

    :ok = Files.delete(missing.tenant_id, :attachment, missing.sha256)
    %StoredFile{id: file_id} = Attachments.stored_file(truncated)
    Repo.delete_all(from c in Chunk, where: c.file_id == ^file_id)

    assert {:ok, %{error: 2, clean: 0}} = Attachments.rescan_thread(scope, thread.id)

    for row <- [missing, truncated] do
      assert Repo.reload!(row).scan_status == :error
      refute Attachments.get(scope, row.id)
      refute Attachments.downloadable?(Repo.reload!(row))
    end
  end

  test "stored content past the scan bound is not loaded and gets no verdict", %{
    thread: thread,
    message: message,
    scope: scope
  } do
    row = fetched(message, "Recorded as larger than a scan accepts")
    %StoredFile{id: file_id} = Attachments.stored_file(row)

    Repo.update_all(from(f in StoredFile, where: f.id == ^file_id),
      set: [size: Scanner.max_bytes() + 1]
    )

    Application.put_env(:custyard, :attachment_scanner, __MODULE__.BlockingScanner)
    Application.put_env(:custyard, :attachment_scanner_options, caller: self())

    assert {:ok, %{error: 1}} = Attachments.rescan_thread(scope, thread.id)
    refute_received {:scanning, _pid}
    assert Repo.reload!(row).scan_status == :error
  end

  test "a rescan reads content of several chunks back for the scanner", %{
    thread: thread,
    message: message,
    scope: scope
  } do
    bytes = :crypto.strong_rand_bytes(3 * Files.chunk_bytes() + 9)
    row = fetched(message, bytes)
    row |> Ecto.Changeset.change(scan_status: :pending, scanned_at: nil) |> Repo.update!()

    Application.put_env(:custyard, :attachment_scanner, __MODULE__.EchoScanner)
    Application.put_env(:custyard, :attachment_scanner_options, caller: self())

    assert {:ok, %{clean: 1}} = Attachments.rescan_thread(scope, thread.id)
    assert_received {:scanned, ^bytes}
    assert Repo.reload!(row).scan_status == :clean
  end

  test "scanner exception and unexpected verdict are failures" do
    assert Scanner.scan("bytes", scanner: __MODULE__) == :error
    assert Scanner.scan("bytes", scanner: String) == :error
  end

  test "an older clean scan cannot overwrite a newer infected verdict", %{
    thread: thread,
    message: message,
    scope: scope
  } do
    row = fetched(message, "Concurrent scan content")
    parent = self()
    Application.put_env(:custyard, :attachment_scanner, __MODULE__.BlockingScanner)
    Application.put_env(:custyard, :attachment_scanner_options, caller: parent)

    older = Task.async(fn -> Attachments.rescan_thread(scope, thread.id) end)
    assert_receive {:scanning, older_pid}
    newer = Task.async(fn -> Attachments.rescan_thread(scope, thread.id) end)
    assert_receive {:scanning, newer_pid}

    send(newer_pid, {:verdict, :infected})
    assert {:ok, %{infected: 1}} = Task.await(newer)
    send(older_pid, {:verdict, :clean})
    assert {:ok, %{pending: 1}} = Task.await(older)
    assert Repo.reload!(row).scan_status == :infected
  end

  test "malware detection blocks every same-tenant reference and future duplicate", %{
    message: message,
    scope: scope
  } do
    bytes = "Same bytes attached to several messages"
    first = fetched(message, bytes)
    second = fetched(insert_message(thread_id: message.thread_id), bytes)
    foreign_customer = insert_organization(tenant_id: insert_tenant().id)
    foreign_thread = insert_thread(organization_id: foreign_customer.id)
    foreign = fetched(insert_message(thread_id: foreign_thread.id), bytes)

    first |> Ecto.Changeset.change(scan_status: :infected) |> Repo.update!()
    assert Repo.reload!(first).scan_status == :infected
    assert Repo.reload!(second).scan_status == :infected
    assert Repo.reload!(foreign).scan_status == :clean
    refute Attachments.get(scope, second.id)

    later = fetched(insert_message(thread_id: message.thread_id), bytes)
    assert later.scan_status == :infected

    for status <- [:clean, :error, :pending] do
      first |> Repo.reload!() |> Ecto.Changeset.change(scan_status: status) |> Repo.update!()
      assert Repo.reload!(first).scan_status == :infected
    end
  end

  test "a stale clean scan of one duplicate cannot undo another duplicate's detection", %{
    customer: customer,
    thread: thread,
    message: message,
    scope: scope
  } do
    bytes = "Duplicate concurrently scanned content"
    first = fetched(message, bytes)
    other_thread = insert_thread(organization_id: customer.id)
    second = fetched(insert_message(thread_id: other_thread.id), bytes)
    Application.put_env(:custyard, :attachment_scanner, __MODULE__.BlockingScanner)
    Application.put_env(:custyard, :attachment_scanner_options, caller: self())
    older = Task.async(fn -> Attachments.rescan_thread(scope, thread.id) end)
    assert_receive {:scanning, older_pid}

    Application.put_env(:custyard, :attachment_scanner, __MODULE__.InfectedScanner)
    assert {:ok, %{infected: 1}} = Attachments.rescan_thread(scope, other_thread.id)
    send(older_pid, {:verdict, :clean})
    assert {:ok, %{pending: 1}} = Task.await(older)

    assert Repo.reload!(first).scan_status == :infected
    assert Repo.reload!(second).scan_status == :infected
  end

  describe "retry_failed_scans/1" do
    setup %{thread: thread} do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "thread:#{thread.id}")
      %{now: DateTime.utc_now() |> DateTime.truncate(:second)}
    end

    test "retries a failed scan once its backoff has passed and refreshes the thread", %{
      thread: %{id: thread_id} = thread,
      now: now
    } do
      # Stored ten minutes ago and last scanned five minutes later, so due
      # five minutes after that scan.
      row = failed_scan(thread, DateTime.add(now, -600), DateTime.add(now, -300))
      echo_scanner()

      assert Attachments.retry_failed_scans(DateTime.add(now, -1)) == @no_scans
      refute_received {:scanned, _bytes}
      refute_received {:message_updated, _id}
      assert Repo.reload!(row).scan_status == :error

      assert Attachments.retry_failed_scans(now) == %{@no_scans | clean: 1}
      assert_received {:scanned, "CUSTYARD_TEST_SCAN_ERROR" <> _}
      assert_received {:message_updated, ^thread_id}
      assert Repo.reload!(row).scan_status == :clean
    end

    test "the first retry comes a minute after the failed scan; a repeated failure only moves the backoff",
         %{thread: thread, now: now} do
      row = failed_scan(thread, DateTime.add(now, -30), DateTime.add(now, -30))

      assert Attachments.retry_failed_scans(now) == @no_scans
      assert Attachments.retry_failed_scans(DateTime.add(now, 30)) == %{@no_scans | error: 1}

      retried = Repo.reload!(row)
      assert retried.scan_status == :error
      assert DateTime.compare(retried.scanned_at, row.scanned_at) == :gt
      refute_received {:message_updated, _id}
    end

    test "rows stored more than a day ago are left to an explicit rescan", %{
      thread: thread,
      now: now
    } do
      # Due by its backoff, but stored a day and a second ago.
      row = failed_scan(thread, DateTime.add(now, -86_401), DateTime.add(now, -86_341))

      assert Attachments.retry_failed_scans(now) == @no_scans
      assert Repo.reload!(row).scanned_at == row.scanned_at

      # Two seconds earlier the same row was still inside the day.
      assert Attachments.retry_failed_scans(DateTime.add(now, -2)) == %{@no_scans | error: 1}
    end

    test "clean, infected and pending verdicts are not rescanned", %{thread: thread, now: now} do
      stored = DateTime.add(now, -7_200)
      scanned = DateTime.add(now, -3_600)

      rows =
        for {bytes, attrs} <- [
              {"Clean content", []},
              {"CUSTYARD_TEST_INFECTED content", []},
              {"Content scanned before a scanner existed", [scan_status: :pending]}
            ] do
          insert_message(thread_id: thread.id)
          |> fetched(bytes)
          |> Ecto.Changeset.change([inserted_at: stored, scanned_at: scanned] ++ attrs)
          |> Repo.update!()
        end

      echo_scanner()
      assert Attachments.retry_failed_scans(now) == @no_scans
      refute_received {:scanned, _bytes}

      assert Enum.map(rows, &Repo.reload!(&1).scan_status) == [:clean, :infected, :pending]
      assert Enum.all?(rows, &(Repo.reload!(&1).scanned_at == scanned))
    end

    test "suspect threads and deleted messages are not rescanned", %{
      customer: customer,
      thread: thread,
      now: now
    } do
      suspect_thread = insert_thread(organization_id: customer.id)
      in_suspect = failed_scan(suspect_thread, DateTime.add(now, -600), DateTime.add(now, -300))
      on_deleted = failed_scan(thread, DateTime.add(now, -600), DateTime.add(now, -300))

      Repo.update_all(from(t in Thread, where: t.id == ^suspect_thread.id), set: [suspect: true])

      Repo.update_all(from(m in Message, where: m.id == ^on_deleted.message_id),
        set: [deleted_at: now]
      )

      echo_scanner()
      assert Attachments.retry_failed_scans(now) == @no_scans
      refute_received {:scanned, _bytes}
      assert Repo.reload!(in_suspect).scan_status == :error
      assert Repo.reload!(on_deleted).scan_status == :error
    end

    test "without a configured scanner nothing is rescanned", %{thread: thread, now: now} do
      row = failed_scan(thread, DateTime.add(now, -600), DateTime.add(now, -300))
      Application.put_env(:custyard, :attachment_scanner, nil)

      assert Attachments.retry_failed_scans(now) == @no_scans

      unchanged = Repo.reload!(row)
      assert unchanged.scan_status == :error
      assert unchanged.scanned_at == row.scanned_at
    end
  end

  test "a failed scan is labelled as retried while the retry lasts", %{thread: thread} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    recent = failed_scan(thread, DateTime.add(now, -60), DateTime.add(now, -60))
    old = failed_scan(thread, DateTime.add(now, -86_401), DateTime.add(now, -86_401))

    assert Attachments.scan_label(recent) == "Quarantined: security scan will be retried"
    assert Attachments.scan_label(old) == "Quarantined: security scan failed"

    # Nothing retries without a scanner.
    Application.put_env(:custyard, :attachment_scanner, nil)
    assert Attachments.scan_label(recent) == "Quarantined: security scan failed"
  end

  describe "ScanRetry" do
    test "retries failed scans on its interval", %{thread: %{id: thread_id} = thread} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      row = failed_scan(thread, DateTime.add(now, -600), DateTime.add(now, -300))
      echo_scanner()
      Phoenix.PubSub.subscribe(Custyard.PubSub, "thread:#{thread_id}")

      start_supervised!({ScanRetry, interval: 10})
      assert_receive {:message_updated, ^thread_id}, 2_000
      stop_supervised!(ScanRetry)

      assert Repo.reload!(row).scan_status == :clean
    end

    test "a tick that raises is logged and the next tick still runs" do
      test = self()

      retry = fn ->
        send(test, {:tick, self()})
        raise "retry failed"
      end

      log =
        capture_log(fn ->
          pid = start_supervised!({ScanRetry, interval: 10, retry: retry})
          assert_receive {:tick, ^pid}, 2_000
          assert_receive {:tick, ^pid}, 2_000
          stop_supervised!(ScanRetry)
        end)

      assert log =~ "attachment_scan_retry_failed"
      refute log =~ "retry failed"
    end
  end

  defmodule EchoScanner do
    @behaviour Custyard.Attachments.Scanner
    def scan(bytes, opts) do
      send(opts[:caller], {:scanned, bytes})
      :clean
    end
  end

  defmodule InfectedScanner do
    @behaviour Custyard.Attachments.Scanner
    def scan(_bytes, _opts), do: :infected
  end

  defmodule BlockingScanner do
    @behaviour Custyard.Attachments.Scanner
    def scan(_bytes, opts) do
      send(opts[:caller], {:scanning, self()})

      receive do
        {:verdict, result} -> result
      after
        2000 -> {:error, :timeout}
      end
    end
  end

  def scan(_bytes, _opts), do: :unexpected

  # A fetched attachment, on a message of its own in `thread`, whose scan
  # failed; stored at `inserted_at` and last scanned at `scanned_at`.
  defp failed_scan(thread, inserted_at, scanned_at) do
    row =
      insert_message(thread_id: thread.id)
      |> fetched("CUSTYARD_TEST_SCAN_ERROR #{System.unique_integer([:positive])}")

    assert row.scan_status == :error

    row
    |> Ecto.Changeset.change(inserted_at: inserted_at, scanned_at: scanned_at)
    |> Repo.update!()
  end

  defp echo_scanner do
    Application.put_env(:custyard, :attachment_scanner, __MODULE__.EchoScanner)
    Application.put_env(:custyard, :attachment_scanner_options, caller: self())
  end

  defp fetched(message, bytes) do
    {:ok, [row]} =
      Attachments.fetch_for_message(message, [%{filename: "document.txt", content: bytes}])

    row
  end
end
