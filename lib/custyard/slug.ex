defmodule Custyard.Slug do
  @moduledoc """
  A row in the slug registry — the single table that owns the entire
  organization-slug namespace.

  Lifecycle: `available → claimed (provisional) → confirmed → provisioned`,
  where `available` means no row exists. Expiry and operator release DELETE
  the row (no tombstones — a tombstone would block re-claim under the unique
  index). Promotion to `provisioned` arrives with prospect conversion
  (separate work); this module never builds provisioned rows.

  The slug is a label, not a key: it appears in public URLs once portal
  routing consumes the registry, so the format is DNS-label safe (3–63
  chars, lowercase alphanumerics, interior hyphens, no `xn--` punycode
  prefix). Reserved words live in code, not Settings — they encode router
  facts (every first path segment the application owns) and must not be
  operator-mutable. `config :custyard, :additional_reserved_slugs` is the
  deployment escape hatch.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Custyard.EmailAddress

  @statuses [:claimed, :confirmed, :provisioned]

  # 3-63 chars, DNS-label safe: lowercase alphanumerics with interior
  # hyphens only. \A/\z (not ^/$): $ can match before a trailing newline.
  @slug_format ~r/\A[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])\z/

  # Reserved words are code, not settings: they encode router facts.
  # Covers every first path segment the application owns — router scopes
  # (i, r, c, api, operator, p), endpoint paths (live, phoenix, dev,
  # assets, fonts, images, uploads), the `_unmatched_` sentinel, and
  # infrastructure/mail names a slug-based host or address must never
  # shadow. Single-letter entries can never pass the 3-char format floor,
  # but stay listed so the intent survives a format change.
  @reserved_slugs ~w(
    www mail api portal admin operator app assets static uploads webhook
    webhooks login logout signup support help status docs blog p i r c
    claim intake resume confirm settings health smtp imap pop mx ns1 ns2
    ftp webmail email autodiscover autoconfig postmaster hostmaster abuse
    security root system internal billing noreply no-reply custyard
    unmatched fonts images live phoenix dev
  )

  schema "slugs" do
    field :slug, :string
    field :status, Ecto.Enum, values: @statuses, default: :claimed
    field :email, :string
    field :confirmation_token_hash, :string
    field :expires_at, :utc_datetime
    field :confirmed_at, :utc_datetime

    belongs_to :conversation, Custyard.Conversation
    belongs_to :organization, Custyard.Organization

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc "The shared slug format regex (DNS-label safe, 3-63 chars)."
  def slug_format, do: @slug_format

  @doc """
  The full reserved list: the in-code router facts plus the
  `:additional_reserved_slugs` config escape hatch.
  """
  def reserved_slugs do
    @reserved_slugs ++ Application.get_env(:custyard, :additional_reserved_slugs, [])
  end

  @doc """
  Changeset for claiming a slug.

  The slug is trimmed and downcased before validation (`force_change`) so
  storage, the unique index, and the reserved-word check never diverge on
  case. Email is normalized and validated through `Custyard.EmailAddress`,
  the same rules as contacts and prospects.

  Status is deliberately not castable: rows are born `:claimed` (schema
  default); `confirmed`/`provisioned` transitions go through the
  `Custyard.Slugs` context's conditional updates.
  """
  def claim_changeset(slug, attrs) do
    slug
    |> cast(attrs, [:slug, :email, :conversation_id, :expires_at, :confirmation_token_hash])
    |> normalize_slug()
    |> update_change(:email, &EmailAddress.normalize/1)
    |> validate_required([:slug, :email, :conversation_id, :expires_at, :confirmation_token_hash])
    |> validate_format(:slug, @slug_format,
      message: "must be 3-63 characters: lowercase letters, digits, and interior hyphens"
    )
    |> validate_no_punycode_prefix()
    |> validate_exclusion(:slug, reserved_slugs(), message: "is reserved")
    |> validate_length(:email, max: 320, message: "must be at most 320 characters")
    |> EmailAddress.validate_email(:email)
    |> unique_constraint(:slug, message: "is already claimed")
    |> unique_constraint(:conversation_id, message: "already has a slug claim")
    |> unique_constraint(:confirmation_token_hash)
    |> foreign_key_constraint(:conversation_id)
  end

  # Downcase/trim BEFORE validation so "Acme " and "acme" are the same
  # claim. force_change: the normalized value must land even when it equals
  # the cast value string-wise after trimming.
  defp normalize_slug(changeset) do
    case get_change(changeset, :slug) do
      value when is_binary(value) ->
        force_change(changeset, :slug, value |> String.trim() |> String.downcase())

      _no_change ->
        changeset
    end
  end

  # Punycode-encoded labels (xn--) could render as homoglyphs of other
  # slugs or reserved names once the registry backs host-visible routing.
  defp validate_no_punycode_prefix(changeset) do
    validate_change(changeset, :slug, fn :slug, value ->
      if String.starts_with?(value, "xn--") do
        [slug: "must not start with xn--"]
      else
        []
      end
    end)
  end
end
