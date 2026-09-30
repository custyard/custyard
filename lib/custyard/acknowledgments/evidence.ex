defmodule Custyard.Acknowledgments.Evidence do
  @moduledoc "Validates the version 1 Colonel evidence contract without changing historical values."
  @fields ~w(schema_version source submission_id organization_id actor_id actor_role actor_type statement_key statement_version statement_text statement_hash acknowledged_at)
  @identities ~w(source submission_id organization_id actor_id actor_role statement_key statement_version)
  @max_message_bytes 65_536

  def max_message_bytes, do: @max_message_bytes

  def validate(payload) when is_map(payload) do
    with true <- Enum.sort(Map.keys(payload)) == Enum.sort(@fields),
         true <- payload["schema_version"] === 1,
         true <- Enum.all?(@identities, &valid_identity?(payload[&1])),
         true <- payload["actor_type"] == "internal_operator",
         text when is_binary(text) <- payload["statement_text"],
         true <- String.valid?(text) and byte_size(text) in 1..16_384,
         hash when is_binary(hash) <- payload["statement_hash"],
         true <- hash == :crypto.hash(:sha256, text) |> Base.encode16(case: :lower),
         timestamp when is_binary(timestamp) <- payload["acknowledged_at"],
         true <- byte_size(timestamp) <= 40,
         {:ok, _time, 0} <- DateTime.from_iso8601(timestamp),
         {:ok, encoded} <- Jason.encode(payload),
         true <- byte_size(encoded) <= @max_message_bytes do
      attrs = Map.new(@fields, fn field -> {String.to_existing_atom(field), payload[field]} end)

      {:ok,
       attrs
       |> Map.put(:source_organization_id, attrs.organization_id)
       |> Map.delete(:organization_id)}
    else
      _ ->
        {:error,
         {:invalid_evidence,
          "expected complete version 1 evidence with UTC time and exact SHA256 wording hash"}}
    end
  end

  def validate(_), do: {:error, {:invalid_evidence, "expected an object"}}

  @doc false
  def valid_identity?(value) when is_binary(value),
    do:
      String.valid?(value) and byte_size(value) in 1..255 and String.trim(value) == value and
        not Regex.match?(~r/[\x00-\x1f\x7f]/u, value)

  def valid_identity?(_), do: false
end
