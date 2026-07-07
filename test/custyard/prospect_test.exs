defmodule Custyard.ProspectTest do
  use Custyard.DataCase, async: true

  alias Custyard.Auth.Token
  alias Custyard.Prospect

  import Custyard.Factory

  describe "create_changeset/2" do
    test "requires conversation_id and resume_token_hash" do
      changeset = Prospect.create_changeset(%Prospect{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).conversation_id
      assert "can't be blank" in errors_on(changeset).resume_token_hash
    end

    test "enforces one prospect per conversation" do
      prospect = insert_prospect()

      assert {:error, changeset} =
               %Prospect{}
               |> Prospect.create_changeset(%{
                 conversation_id: prospect.conversation_id,
                 resume_token_hash: Token.generate() |> elem(1)
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).conversation_id
    end

    test "enforces unique resume_token_hash" do
      prospect = insert_prospect()
      conversation = insert_conversation(source: :public_intake)

      assert {:error, changeset} =
               %Prospect{}
               |> Prospect.create_changeset(%{
                 conversation_id: conversation.id,
                 resume_token_hash: prospect.resume_token_hash
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).resume_token_hash
    end

    test "does not cast email or notification fields" do
      changeset =
        Prospect.create_changeset(%Prospect{}, %{
          conversation_id: 1,
          resume_token_hash: "hash",
          email: "sneaky@example.com",
          notify_on_reply: true,
          revoked_at: DateTime.utc_now()
        })

      assert Ecto.Changeset.get_change(changeset, :email) == nil
      assert Ecto.Changeset.get_change(changeset, :notify_on_reply) == nil
      assert Ecto.Changeset.get_change(changeset, :revoked_at) == nil
    end
  end

  describe "capture_email_changeset/2" do
    setup do
      %{prospect: insert_prospect()}
    end

    test "casts exactly email, email_captured_at, and notify_on_reply", %{prospect: prospect} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        Prospect.capture_email_changeset(prospect, %{
          email: "person@example.com",
          email_captured_at: now,
          notify_on_reply: true,
          # Must be ignored: not in the cast list
          resume_token_hash: "attacker-controlled",
          revoked_at: now,
          conversation_id: 999_999
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :email) == "person@example.com"
      assert Ecto.Changeset.get_change(changeset, :email_captured_at) == now
      assert Ecto.Changeset.get_change(changeset, :notify_on_reply) == true
      assert Ecto.Changeset.get_change(changeset, :resume_token_hash) == nil
      assert Ecto.Changeset.get_change(changeset, :revoked_at) == nil
      assert Ecto.Changeset.get_change(changeset, :conversation_id) == nil
    end

    test "downcases and trims the email at write", %{prospect: prospect} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        Prospect.capture_email_changeset(prospect, %{
          email: "  MiXeD@Example.COM  ",
          email_captured_at: now
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :email) == "mixed@example.com"
    end

    test "requires email and email_captured_at", %{prospect: prospect} do
      changeset = Prospect.capture_email_changeset(prospect, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).email
      assert "can't be blank" in errors_on(changeset).email_captured_at
    end

    test "rejects invalid email addresses", %{prospect: prospect} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for bad <- ["not-an-email", "two@@example.com", "missing-tld@localhost"] do
        changeset =
          Prospect.capture_email_changeset(prospect, %{email: bad, email_captured_at: now})

        refute changeset.valid?, "expected #{inspect(bad)} to be rejected"
        assert "must be a valid email address" in errors_on(changeset).email
      end
    end

    test "rejects control characters", %{prospect: prospect} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        Prospect.capture_email_changeset(prospect, %{
          email: "bad\x01@example.com",
          email_captured_at: now
        })

      refute changeset.valid?
      assert "must not contain control characters" in errors_on(changeset).email
    end
  end

  describe "revoke_changeset/2 and rotate_token_changeset/2" do
    test "revoke sets revoked_at" do
      prospect = insert_prospect()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, revoked} = prospect |> Prospect.revoke_changeset(now) |> Repo.update()
      assert revoked.revoked_at == now
    end

    test "rotate replaces the token hash" do
      prospect = insert_prospect()
      {_token, new_hash} = Token.generate()

      {:ok, rotated} = prospect |> Prospect.rotate_token_changeset(new_hash) |> Repo.update()
      assert rotated.resume_token_hash == new_hash
      refute rotated.resume_token_hash == prospect.resume_token_hash
    end
  end
end
