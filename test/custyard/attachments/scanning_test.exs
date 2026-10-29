defmodule Custyard.Attachments.ScanningTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.{Attachments, Repo, Scope, Tenants}
  alias Custyard.Attachments.Scanner

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
    assert File.regular?(Attachments.file_path(row))
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
    File.write!(Attachments.file_path(row), "Tampered content")
    assert {:ok, %{error: 1}} = Attachments.rescan_thread(scope, thread.id)
    assert Repo.reload!(row).scan_status == :error
    refute Attachments.get(scope, row.id)
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

  defp fetched(message, bytes) do
    {:ok, [row]} =
      Attachments.fetch_for_message(message, [%{filename: "document.txt", content: bytes}])

    row
  end
end
