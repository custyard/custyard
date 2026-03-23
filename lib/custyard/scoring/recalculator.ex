defmodule Custyard.Scoring.Recalculator do
  @moduledoc "Background recalculation of all active conversation scores"

  import Ecto.Query
  alias Custyard.{Repo, Conversation, Scoring}

  def recalculate_all do
    from(c in Conversation,
      where: c.state in [:new, :active, :waiting, :dormant],
      where: is_nil(c.snoozed_until) or c.snoozed_until < ^DateTime.utc_now()
    )
    |> Repo.all()
    |> Enum.each(&Scoring.calculate_and_cache(&1.id))
  end
end
