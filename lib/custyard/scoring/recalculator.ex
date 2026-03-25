defmodule Custyard.Scoring.Recalculator do
  @moduledoc "Background recalculation of all active conversation scores"

  import Ecto.Query
  alias Custyard.{Conversation, Repo, Scoring}

  @batch_size 100

  def recalculate_all do
    query =
      from(c in Conversation,
        where: c.state in [:new, :active, :waiting, :dormant],
        where: is_nil(c.snoozed_until) or c.snoozed_until < ^DateTime.utc_now(),
        select: c.id
      )

    Repo.transaction(fn ->
      query
      |> Repo.stream(max_rows: @batch_size)
      |> Stream.each(&Scoring.calculate_and_cache/1)
      |> Stream.run()
    end)
  end
end
