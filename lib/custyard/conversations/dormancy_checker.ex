defmodule Custyard.Conversations.DormancyChecker do
  @moduledoc """
  Transitions stale waiting conversations to dormant state.

  A conversation becomes dormant when it has been in :waiting state with no
  customer action beyond the tier-based dormancy threshold. This prevents
  abandoned conversations from cluttering the attention queue.

  Dormancy thresholds use the neglect critical thresholds from Settings:
  - Enterprise: default 8 hours
  - Standard: default 48 hours
  - Basic: default 72 hours

  These thresholds are database-configurable via the Settings module.
  """

  import Ecto.Query
  alias Custyard.{Conversation, Conversations, Repo, Settings}

  @doc """
  Find and transition all stale waiting conversations to dormant.

  Returns the count of transitioned conversations.
  """
  def transition_stale_conversations do
    stale_conversations()
    |> Enum.map(&transition_to_dormant/1)
    |> Enum.count(& &1)
  end

  @doc """
  Query conversations in :waiting state that have exceeded their dormancy threshold.

  Uses the critical threshold from Settings.get_neglect_thresholds/0 as the
  dormancy cutoff for each tier.
  """
  def stale_conversations do
    # Get thresholds from Settings (database-configurable)
    # Use the critical threshold as the dormancy cutoff
    thresholds = Settings.get_neglect_thresholds()
    {_, enterprise_critical} = thresholds.enterprise
    {_, standard_critical} = thresholds.standard
    {_, basic_critical} = thresholds.basic

    enterprise_cutoff = hours_ago(enterprise_critical)
    standard_cutoff = hours_ago(standard_critical)
    basic_cutoff = hours_ago(basic_critical)

    from(c in Conversation,
      join: o in assoc(c, :organization),
      where: c.state == :waiting,
      where:
        (o.tier == :enterprise and
           coalesce(c.last_customer_action_at, c.inserted_at) <= ^enterprise_cutoff) or
          (o.tier == :standard and
             coalesce(c.last_customer_action_at, c.inserted_at) <= ^standard_cutoff) or
          (o.tier == :basic and
             coalesce(c.last_customer_action_at, c.inserted_at) <= ^basic_cutoff),
      select: c
    )
    |> Repo.all()
  end

  defp hours_ago(hours) do
    DateTime.add(DateTime.utc_now(), -hours, :hour)
  end

  defp transition_to_dormant(conversation) do
    case conversation
         |> Conversation.state_changeset(:dormant)
         |> Repo.update() do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "conversations",
          {:conversation_updated, updated.id}
        )

        Conversations.broadcast_to_org(
          updated.organization_id,
          {:conversation_updated, updated.id}
        )

        true

      {:error, _changeset} ->
        false
    end
  end
end
