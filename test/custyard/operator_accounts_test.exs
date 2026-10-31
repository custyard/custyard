defmodule Custyard.OperatorAccountsTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import ExUnit.CaptureLog

  alias Custyard.{AuditEvent, Message, OperatorAccount, OperatorAccounts}

  # Creation and removal log at info; the test config caps Logger at warning.
  defp capture_info_log(fun) do
    Logger.put_module_level(OperatorAccounts, :info)

    try do
      capture_log([metadata: [:operator_id, :organization_id, :role]], fun)
    after
      Logger.delete_module_level(OperatorAccounts)
    end
  end

  defp audit_events(type) do
    Repo.all(from(a in AuditEvent, where: a.event_type == ^type, order_by: a.id))
  end

  defp insert_raw_operator(email, role \\ "super_admin") do
    Repo.query!(
      "INSERT INTO operator_accounts (email, role, inserted_at, updated_at) " <>
        "VALUES (?, ?, '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z') RETURNING id",
      [email, role]
    ).rows
    |> then(fn [[id]] -> id end)
  end

  describe "create_operator/2" do
    test "creates a super_admin by default, normalized, with an audit event and a log line" do
      log =
        capture_info_log(fn ->
          assert {:created, operator} =
                   OperatorAccounts.create_operator("  New.Op@Example.COM ", via: "cli")

          send(self(), {:operator, operator})
        end)

      assert_received {:operator, operator}
      assert operator.email == "new.op@example.com"
      assert operator.role == "super_admin"
      assert operator.organization_id == nil

      assert log =~ "operator_account_created"
      assert log =~ "operator_id=#{operator.id}"
      assert log =~ "role=super_admin"
      refute log =~ operator.email

      assert [event] = audit_events(:operator_created)
      assert event.source == "cli"
      # Payload only: the column would block deleting the organization later.
      assert event.organization_id == nil

      assert event.payload == %{
               "operator_id" => operator.id,
               "tenant_id" => nil,
               "role" => "super_admin",
               "organization_id" => nil,
               "via" => "cli"
             }
    end

    test "creates an admin scoped to an existing organization" do
      org = insert_organization()

      assert {:created, operator} =
               OperatorAccounts.create_operator("admin@example.com",
                 via: "mix",
                 role: "admin",
                 organization_id: org.id
               )

      assert operator.role == "admin"
      assert operator.organization_id == org.id

      assert [%{source: "mix", organization_id: nil, payload: payload}] =
               audit_events(:operator_created)

      assert payload["organization_id"] == org.id
      assert payload["via"] == "mix"
    end

    test "reports an existing account, matched ignoring case, and never modifies it" do
      org = insert_organization()

      inserted =
        insert_operator_account(
          email: "agent@example.com",
          role: "agent",
          organization_id: org.id
        )

      existing = Repo.get!(OperatorAccount, inserted.id)

      assert {:exists, found} =
               OperatorAccounts.create_operator("AGENT@Example.com",
                 via: "boot",
                 role: "super_admin"
               )

      assert found.id == existing.id
      assert Repo.get!(OperatorAccount, existing.id) == existing
      assert audit_events(:operator_created) == []
    end

    test "matches an existing account across Unicode case and normalization form" do
      assert {:created, %{id: id}} =
               OperatorAccounts.create_operator("ünal@bücher.de", via: "cli")

      assert {:exists, %{id: ^id}} =
               OperatorAccounts.create_operator("ÜNAL@BÜCHER.DE", via: "cli")

      # "u" followed by a combining diaeresis is the same address in NFC.
      assert {:exists, %{id: ^id}} =
               OperatorAccounts.create_operator("u\u0308nal@bu\u0308cher.de", via: "cli")

      assert [%OperatorAccount{email: "ünal@bücher.de"}] = Repo.all(OperatorAccount)
      assert length(audit_events(:operator_created)) == 1
    end

    test "validates only when creating" do
      existing = insert_operator_account(email: "valid@example.com")

      assert {:exists, %{id: id}} =
               OperatorAccounts.create_operator("valid@example.com", via: "cli", role: "bogus")

      assert id == existing.id
    end

    test "rejects invalid input without writing anything" do
      org = insert_organization()

      assert {:error, "email: must be a valid email address"} =
               OperatorAccounts.create_operator("not-an-email", via: "cli")

      assert {:error, "role: must be one of: super_admin, admin, agent"} =
               OperatorAccounts.create_operator("role@example.com", via: "cli", role: "owner")

      assert {:error, "organization_id: admin operators must be assigned to an organization"} =
               OperatorAccounts.create_operator("admin@example.com", via: "cli", role: "admin")

      assert {:error,
              "organization_id: super_admin operators cannot be scoped to an organization"} =
               OperatorAccounts.create_operator("super@example.com",
                 via: "cli",
                 organization_id: org.id
               )

      assert Repo.aggregate(OperatorAccount, :count) == 0
      assert audit_events(:operator_created) == []
    end

    test "refuses a present but empty, blank or unknown role instead of defaulting it" do
      # cast/4 turns "" into the field default, which is super_admin.
      for role <- ["", "   ", nil, "owner"] do
        assert {:error, "role: must be one of: super_admin, admin, agent"} =
                 OperatorAccounts.create_operator("empty-role@example.com",
                   via: "cli",
                   role: role
                 )

        assert {:error, "role: must be one of: super_admin, admin, agent"} =
                 OperatorAccounts.insert_operator("empty-role@example.com",
                   via: "cli",
                   role: role
                 )
      end

      assert Repo.aggregate(OperatorAccount, :count) == 0
    end

    test "refuses an organization id outside 1..2^63-1 without touching the database" do
      for id <- [0, -1, 9_223_372_036_854_775_808, 99_999_999_999_999_999_999_999, "3"] do
        assert {:error, "organization_id: must be an integer from 1 to 9223372036854775807"} =
                 OperatorAccounts.create_operator("agent@example.com",
                   via: "cli",
                   role: "agent",
                   organization_id: id
                 )
      end

      assert Repo.aggregate(OperatorAccount, :count) == 0
    end

    test "checks that the organization exists before inserting" do
      assert {:error, "organization 999999 does not exist"} =
               OperatorAccounts.create_operator("agent@example.com",
                 via: "cli",
                 role: "agent",
                 organization_id: 999_999
               )

      assert Repo.aggregate(OperatorAccount, :count) == 0
    end

    test "refuses the non-routable placeholder unless allowed" do
      assert {:error, message} =
               OperatorAccounts.create_operator("Admin@Custyard.local", via: "boot")

      assert message =~ "non-routable placeholder"
      assert Repo.aggregate(OperatorAccount, :count) == 0

      assert {:created, %{email: "admin@custyard.local"}} =
               OperatorAccounts.create_operator("admin@custyard.local",
                 via: "mix",
                 allow_placeholder: true
               )
    end

    test "a unique-constraint race on insert counts as exists" do
      # Another creator inserted between create_operator/2's lookup and its insert.
      winner = insert_operator_account(email: "race@example.com")

      assert {:exists, found} = OperatorAccounts.insert_operator("race@example.com", via: "cli")
      assert found.id == winner.id
      assert Repo.aggregate(OperatorAccount, :count) == 1
      assert audit_events(:operator_created) == []
    end

    test "rolls the insert back when the audit event cannot be written" do
      # AuditEvent.source is limited to 100 characters.
      assert {:error, message} =
               OperatorAccounts.create_operator("audit@example.com",
                 via: String.duplicate("x", 101)
               )

      assert message =~ "could not record the audit event"
      assert Repo.aggregate(OperatorAccount, :count) == 0
    end
  end

  describe "remove_operator/2" do
    test "deletes the operator and records an audit event" do
      _keeper = insert_operator_account(email: "keeper@example.com")
      org = insert_organization()

      agent =
        insert_operator_account(
          email: "agent@example.com",
          role: "agent",
          organization_id: org.id
        )

      log =
        capture_info_log(fn ->
          assert {:ok, %{operator: removed, soft_deleted_message_ids: []}} =
                   OperatorAccounts.remove_operator("Agent@Example.com", via: "cli")

          assert removed.id == agent.id
        end)

      assert log =~ "operator_account_removed"
      assert log =~ "operator_id=#{agent.id}"
      refute log =~ agent.email
      assert Repo.get(OperatorAccount, agent.id) == nil

      assert [%{source: "cli", organization_id: nil, payload: payload}] =
               audit_events(:operator_removed)

      assert payload == %{
               "operator_id" => agent.id,
               "tenant_id" => nil,
               "role" => "agent",
               "organization_id" => org.id,
               "via" => "cli",
               "soft_deleted_message_ids" => []
             }
    end

    test "refuses to remove the last super_admin" do
      only = insert_operator_account(email: "only@example.com")

      assert {:error, message} = OperatorAccounts.remove_operator("only@example.com", via: "cli")
      assert message =~ "last super_admin"
      assert Repo.get(OperatorAccount, only.id)
      assert audit_events(:operator_removed) == []
    end

    test "does not count the placeholder as a super_admin who can log in" do
      placeholder = insert_operator_account(email: "admin@custyard.local")
      real = insert_operator_account(email: "real@example.com")

      assert {:error, message} = OperatorAccounts.remove_operator("real@example.com", via: "cli")
      assert message =~ "last super_admin"
      assert Repo.get(OperatorAccount, real.id)

      assert {:ok, _} = OperatorAccounts.remove_operator("admin@custyard.local", via: "cli")
      assert Repo.get(OperatorAccount, placeholder.id) == nil
    end

    test "does not count a super_admin whose email is not normalized" do
      insert_raw_operator("Mixed@Example.com")
      real = insert_operator_account(email: "real@example.com")

      assert {:error, message} = OperatorAccounts.remove_operator("real@example.com", via: "cli")
      assert message =~ "refusing to remove the last super_admin who can log in"
      assert Repo.get(OperatorAccount, real.id)
    end

    test "explains the refusal when the placeholder is the only super_admin" do
      placeholder = insert_operator_account(email: "admin@custyard.local")

      assert {:error, message} =
               OperatorAccounts.remove_operator("admin@custyard.local", via: "cli")

      assert message ==
               "refusing to remove admin@custyard.local: no super_admin who can log in exists " <>
                 "yet. Add one first with `bin/operator add you@example.com`, then remove " <>
                 "admin@custyard.local."

      assert Repo.get(OperatorAccount, placeholder.id)

      # Once a real super_admin exists, the placeholder can go.
      insert_operator_account(email: "real@example.com")
      assert {:ok, _} = OperatorAccounts.remove_operator("admin@custyard.local", via: "cli")
    end

    test "removes an admin or agent even when no super_admin exists" do
      org = insert_organization()
      insert_operator_account(email: "admin@example.com", role: "admin", organization_id: org.id)

      assert {:ok, _} = OperatorAccounts.remove_operator("admin@example.com", via: "cli")
    end

    test "reports an unknown email" do
      assert {:error, "no operator with email nobody@example.com"} =
               OperatorAccounts.remove_operator("Nobody@Example.com", via: "cli")
    end

    test "picks the exact stored email among case variants and refuses an ambiguous one" do
      insert_operator_account(email: "keeper@example.com")
      upper = insert_raw_operator("Bob@Example.com")
      shout = insert_raw_operator("BOB@EXAMPLE.COM")

      assert {:error, message} = OperatorAccounts.remove_operator("bob@example.com", via: "cli")
      assert message =~ "2 operators match bob@example.com ignoring case (ids #{upper}, #{shout})"

      assert {:ok, %{operator: %{id: ^upper}}} =
               OperatorAccounts.remove_operator("Bob@Example.com", via: "cli")

      # One variant left, so it now matches on its own.
      assert {:ok, %{operator: %{id: ^shout}}} =
               OperatorAccounts.remove_operator("bob@example.com", via: "cli")
    end

    test "an exact stored email wins over a trimmed or case-folded match" do
      insert_operator_account(email: "keeper@example.com")
      padded = insert_raw_operator(" Foo@Example.com ")
      plain = insert_raw_operator("Foo@Example.com")

      assert {:ok, %{operator: %{id: ^padded}}} =
               OperatorAccounts.remove_operator(" Foo@Example.com ", via: "cli")

      assert Repo.get(OperatorAccount, plain)
    end

    test "a stale row cannot be removed: the lookup runs inside the removal" do
      insert_operator_account(email: "keeper@example.com")

      leaver =
        insert_operator_account(
          email: "leaver@example.com",
          role: "agent",
          organization_id: insert_organization().id
        )

      assert {:ok, _} = OperatorAccounts.remove_operator("leaver@example.com", via: "cli")

      # A replacement takes the freed id with a different email and role.
      assert {:created, joiner} =
               OperatorAccounts.create_operator("joiner@example.com", via: "cli")

      assert joiner.id == leaver.id

      assert {:error, "no operator with email leaver@example.com"} =
               OperatorAccounts.remove_operator("leaver@example.com", via: "cli")

      assert Repo.get(OperatorAccount, joiner.id).email == "joiner@example.com"
    end

    test "keeps the ids of messages the operator soft-deleted in the audit event" do
      insert_operator_account(email: "keeper@example.com")
      org = insert_organization()

      admin =
        insert_operator_account(email: "mod@example.com", role: "admin", organization_id: org.id)

      conversation = insert_conversation(organization_id: org.id)
      first = insert_message(conversation_id: conversation.id)
      second = insert_message(conversation_id: conversation.id)
      untouched = insert_message(conversation_id: conversation.id)

      Repo.update_all(from(m in Message, where: m.id in ^[first.id, second.id]),
        set: [deleted_by_operator_id: admin.id, deleted_at: DateTime.utc_now(:second)]
      )

      assert {:ok, %{soft_deleted_message_ids: ids}} =
               OperatorAccounts.remove_operator("mod@example.com", via: "cli")

      assert ids == [first.id, second.id]
      # ON DELETE SET NULL cleared the column; the audit event keeps the link.
      assert Repo.get!(Message, first.id).deleted_by_operator_id == nil
      assert Repo.get!(Message, untouched.id).deleted_at == nil

      assert [%{payload: %{"soft_deleted_message_ids" => ^ids}}] =
               audit_events(:operator_removed)
    end

    test "reports a blocking foreign key instead of raising, and removes nothing" do
      insert_operator_account(email: "keeper@example.com")
      referenced = insert_operator_account(email: "referenced@example.com")

      # A table referencing operators without ON DELETE, as a future one might.
      # SQLite DDL is transactional, so the sandbox rolls it back.
      Repo.query!(
        "CREATE TABLE operator_fk_probe (id INTEGER PRIMARY KEY, " <>
          "operator_id INTEGER REFERENCES operator_accounts(id))"
      )

      Repo.query!("INSERT INTO operator_fk_probe (operator_id) VALUES (?)", [referenced.id])

      assert {:error, message} =
               OperatorAccounts.remove_operator("referenced@example.com", via: "cli")

      assert message =~ "other records still reference operator #{referenced.id}"
      assert Repo.get(OperatorAccount, referenced.id)
      assert audit_events(:operator_removed) == []
    end
  end
end
