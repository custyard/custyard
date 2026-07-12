defmodule Custyard.Slugs.ClaimExpiryTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.Slugs.ClaimExpiry
  alias Custyard.{Conversation, Slug, Slugs}

  defp claim!(slug_text, email) do
    conversation = insert_conversation(source: :public_intake)
    {:ok, slug, token} = Slugs.claim(slug_text, email, conversation)
    %{conversation: conversation, slug: slug, token: token}
  end

  test "the sweep process is not running in tests (flag off in config/test.exs)" do
    refute Application.get_env(:custyard, :start_intake_sweeps, true)
    refute Process.whereis(ClaimExpiry)
  end

  describe "sweep/1 with an injected clock" do
    test "deletes claimed rows past expiry as of the injected now" do
      %{slug: slug, conversation: conversation} = claim!("sweep-me", "buyer@example.com")

      # A clock just before expiry deletes nothing.
      before_expiry = DateTime.add(slug.expires_at, -1, :minute)
      assert ClaimExpiry.sweep(before_expiry) == 0
      assert Repo.get(Slug, slug.id)

      # A clock past expiry releases the slug — and only the slug.
      after_expiry = DateTime.add(slug.expires_at, 1, :minute)
      assert ClaimExpiry.sweep(after_expiry) == 1
      refute Repo.get(Slug, slug.id)
      assert Repo.get(Conversation, conversation.id)
      assert Slugs.available?("sweep-me")
    end

    test "confirmed and provisioned rows are never swept" do
      %{token: token} = claim!("confirmed-keeper", "buyer@example.com")
      {:ok, confirmed} = Slugs.confirm(token)

      org = insert_organization()

      provisioned =
        insert_slug(
          slug: "provisioned-keeper",
          status: :provisioned,
          organization_id: org.id,
          confirmation_token_hash: nil,
          expires_at: nil
        )

      far_future = DateTime.add(DateTime.utc_now(), 365 * 24, :hour)
      assert ClaimExpiry.sweep(far_future) == 0

      assert Repo.get(Slug, confirmed.id)
      assert Repo.get(Slug, provisioned.id)
    end

    test "sweeps multiple expired claims and reports the count" do
      claims = for i <- 1..3, do: claim!("bulk-#{i}", "buyer-#{i}@example.com")
      %{slug: survivor} = claim!("survivor", "keeper@example.com")

      past =
        DateTime.utc_now()
        |> DateTime.add(-1, :hour)
        |> DateTime.truncate(:second)

      for %{slug: slug} <- claims do
        {1, _} =
          Repo.update_all(from(s in Slug, where: s.id == ^slug.id), set: [expires_at: past])
      end

      assert ClaimExpiry.sweep() == 3
      assert Repo.get(Slug, survivor.id)
    end
  end
end
