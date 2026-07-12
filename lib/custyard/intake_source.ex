defmodule Custyard.IntakeSource do
  @moduledoc """
  Operator-configured public intake source (CTA).

  Each row defines a public intake entry point identified by `key`, a public
  URL segment. The key format is locked to lowercase alphanumerics with
  hyphens/underscores because it appears verbatim in URLs and as conversation
  provenance (`conversations.intake_source_key`).

  Modes:
  - `:active` — form-first intake page
  - `:passive` — informational page (headline, intro copy, Q&A list)
  """

  use Ecto.Schema
  import Ecto.Changeset

  # Same format as conversations.intake_source_key: 1-50 chars, lowercase
  # alphanumeric start, then lowercase alphanumerics/underscore/hyphen.
  # \A/\z (not ^/$): Erlang's re lets $ match before a trailing newline, which
  # would admit "valid-key\n" into a public URL segment.
  @key_format ~r/\A[a-z0-9][a-z0-9_-]{0,49}\z/

  @modes [:active, :passive]

  @max_questions 20
  @max_question_length 200
  @max_answer_length 2000

  schema "intake_sources" do
    field :key, :string
    field :name, :string
    field :mode, Ecto.Enum, values: @modes, default: :active
    field :headline, :string
    field :intro_copy, :string
    field :questions, {:array, :map}, default: []
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc "The shared intake-source key format regex."
  def key_format, do: @key_format

  def modes, do: @modes

  @doc "Maximum number of Q&A entries per source (UI cap mirrors validation)."
  def max_questions, do: @max_questions

  @update_fields [:name, :mode, :headline, :intro_copy, :questions, :enabled]

  @doc false
  def changeset(intake_source, attrs) do
    intake_source
    |> cast(attrs, [:key | @update_fields])
    |> validate_required([:key, :name])
    |> validate_format(:key, @key_format)
    |> unique_constraint(:key)
    |> validate_content()
  end

  @doc """
  Changeset for updating an existing source. Does not cast `:key`: the key is
  a public URL segment and conversation provenance
  (`conversations.intake_source_key`), immutable after creation regardless of
  caller.
  """
  def update_changeset(intake_source, attrs) do
    intake_source
    |> cast(attrs, @update_fields)
    |> validate_required([:name])
    |> validate_content()
  end

  defp validate_content(changeset) do
    changeset
    |> validate_length(:name, max: 200)
    |> validate_length(:headline, max: 200)
    |> validate_length(:intro_copy, max: 2000)
    |> validate_questions()
  end

  # Q&A list validation: at most 20 entries; each entry must be a map with
  # exactly the "question" (<= 200 chars) and "answer" (<= 2000 chars) string
  # keys — unknown keys are rejected.
  defp validate_questions(changeset) do
    validate_change(changeset, :questions, fn :questions, questions ->
      cond do
        length(questions) > @max_questions ->
          [questions: "must have at most #{@max_questions} entries"]

        not Enum.all?(questions, &valid_question_entry?/1) ->
          [
            questions:
              "entries must have exactly \"question\" (max #{@max_question_length} chars) " <>
                "and \"answer\" (max #{@max_answer_length} chars) keys"
          ]

        true ->
          []
      end
    end)
  end

  defp valid_question_entry?(%{"question" => question, "answer" => answer} = entry) do
    map_size(entry) == 2 and
      is_binary(question) and is_binary(answer) and
      String.length(question) <= @max_question_length and
      String.length(answer) <= @max_answer_length
  end

  defp valid_question_entry?(_entry), do: false
end
