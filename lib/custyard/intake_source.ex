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
  @max_link_title_length 80
  @max_link_url_length 2000

  schema "intake_sources" do
    field :key, :string
    field :name, :string
    field :mode, Ecto.Enum, values: @modes, default: :active
    field :headline, :string
    field :intro_copy, :string
    field :questions, {:array, :map}, default: []
    field :link_title, :string
    field :link_url, :string
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc "The shared intake-source key format regex."
  def key_format, do: @key_format

  def modes, do: @modes

  @doc "Maximum number of Q&A entries per source (UI cap mirrors validation)."
  def max_questions, do: @max_questions

  @doc """
  Whether the source carries a renderable branded link — both `link_title`
  and `link_url` present and non-blank. Prospect surfaces render the anchor
  only when this is true; `nil` (deleted source) is always false.
  """
  def link?(%__MODULE__{link_title: title, link_url: url}) do
    present?(title) and present?(url)
  end

  def link?(nil), do: false

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @update_fields [
    :name,
    :mode,
    :headline,
    :intro_copy,
    :questions,
    :link_title,
    :link_url,
    :enabled
  ]

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
    |> validate_length(:link_title, max: @max_link_title_length)
    |> validate_length(:link_url, max: @max_link_url_length)
    |> validate_link_url()
    |> validate_questions()
  end

  # Only absolute http/https URLs with a host: the value renders verbatim as
  # an anchor href on public prospect pages, so javascript:/data:/relative
  # values are rejected at the changeset boundary.
  defp validate_link_url(changeset) do
    validate_change(changeset, :link_url, fn :link_url, url ->
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _other ->
          [link_url: "must be an http or https URL"]
      end
    end)
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
