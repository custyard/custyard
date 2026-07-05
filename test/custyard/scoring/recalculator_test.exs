defmodule Custyard.Scoring.RecalculatorTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{Conversation, Scoring}
  alias Custyard.Scoring.Recalculator

  describe "recalculate_all/0" do
    test "preserves scores for conversations without an organization" do
      conv =
        insert_conversation(
          organization_id: nil,
          source: :disambiguation,
          state: :new,
          last_operator_action_at: DateTime.utc_now()
        )

      {:ok, score} = Scoring.calculate_and_cache(conv.id)
      assert score > 0

      assert Recalculator.recalculate_all() == 1

      recalculated = Repo.get!(Conversation, conv.id)
      assert recalculated.cached_score == score
    end

    test "recalculates org-linked and unlinked conversations in one sweep" do
      org = insert_organization(tier: :standard)

      linked =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          last_operator_action_at: DateTime.utc_now()
        )

      unlinked =
        insert_conversation(
          organization_id: nil,
          source: :disambiguation,
          state: :new,
          last_operator_action_at: DateTime.utc_now()
        )

      assert Recalculator.recalculate_all() == 2

      # Both score new(30) + tier(10): the unlinked tier score defaults to the
      # standard tier score on purpose
      assert Repo.get!(Conversation, linked.id).cached_score == 40
      assert Repo.get!(Conversation, unlinked.id).cached_score == 40
    end
  end
end
