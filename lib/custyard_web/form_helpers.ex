defmodule CustyardWeb.FormHelpers do
  @moduledoc """
  Shared form helper functions for LiveViews.

  Provides consistent error formatting for Ecto changesets across the application.
  """

  @doc """
  Formats changeset errors into a human-readable string.

  ## Examples

      iex> format_changeset_errors(%Ecto.Changeset{errors: [name: {"can't be blank", []}]})
      "name: can't be blank"
  """
  def format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&format_error/1)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  @doc """
  Formats a single error tuple into a string.

  Handles interpolation of values in error messages (e.g., `%{count}` for length validations).
  """
  def format_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
