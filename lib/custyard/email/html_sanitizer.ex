defmodule Custyard.Email.HtmlSanitizer do
  @moduledoc """
  Allowlist sanitiser for inbound HTML bodies (spec-inbound-channels D9).

  Runs at ingest, inside the adapter, so raw provider HTML never travels
  further than the normalisation step. The output is what the thread renders
  with `raw/1`, so this module is a security boundary:

    * Only inline text markup, lists, headings, blockquotes, code, tables and
      links survive. Every other tag is dropped, its text kept.
    * `script`, `style`, `head`, `title`, `iframe`, `object`, `embed`,
      `svg` and `math` are removed with their contents before parsing, so
      their payload cannot surface as visible text.
    * No attributes survive except `href` and `title` on links (`http`,
      `https`, `mailto` only), `colspan`/`rowspan` on cells and `start` on
      ordered lists. No `style`, `class`, `id` or event handlers.
    * Images survive only with a `cid:` source, which names a part of the
      same message, plus `alt`. Remote and `data:` images are removed:
      remote images are tracking pixels as often as content. The thread maps
      each `cid:` to that message's stored attachment at render time
      (`CustyardWeb.InlineImages`); a stored `cid:` never loads anything.
    * Links open in a new tab with `rel="noopener noreferrer"`.

  Returns `nil` for blank input, for HTML over the raw size cap and for
  markup that carries no text once sanitised, so a text-only message never
  stores an empty HTML shell.
  """

  @max_raw_bytes 300_000

  @removed_blocks ~w(script style head title iframe object embed svg math noscript template)
  # The element with its contents; an unterminated one runs to the end of the
  # input so a dangling `<script>` cannot surface its payload as text.
  @block_regex Enum.map(@removed_blocks, fn tag ->
                 ~r/<#{tag}\b[^>]*>.*?(?:<\/#{tag}\s*>|\z)/is
               end)
  # A stray closing or self-closing form of the same tags.
  @loose_tag_regex ~r/<\/?(?:#{Enum.join(@removed_blocks, "|")})\b[^>]*>/i

  @anchor_regex ~r/<a\s/i

  # An image the scrubber left without a source: its src was not `cid:`.
  @sourceless_img_regex ~r/<img(?![^>]*\ssrc=")[^>]*>/i

  defmodule Scrubber do
    @moduledoc false
    # `use HtmlSanitizeEx` installs the compiler hook that strips every tag and
    # attribute not allowed below (their text content is kept).
    use HtmlSanitizeEx

    allow_tag_with_uri_attributes("a", ["href"], ["http", "https", "mailto"])
    allow_tag_with_these_attributes("a", ["title"])

    for tag <- ~w(p br div span b strong i em u s strike del ins blockquote pre code
                  ul li h1 h2 h3 h4 h5 h6 hr sup sub small table thead tbody tfoot tr) do
      allow_tag_with_these_attributes(tag, [])
    end

    # Inline images only: a `cid:` source names a part of the same message
    # and loads nothing until render time maps it to that attachment.
    allow_tag_with_uri_attributes("img", ["src"], ["cid"])
    allow_tag_with_these_attributes("img", ["alt"])

    allow_tag_with_these_attributes("ol", ["start"])
    allow_tag_with_these_attributes("td", ["colspan", "rowspan"])
    allow_tag_with_these_attributes("th", ["colspan", "rowspan"])
  end

  @doc "Raw HTML size cap in bytes; larger bodies are dropped, not truncated."
  def max_raw_bytes, do: @max_raw_bytes

  @doc """
  Sanitise `html`. Returns the cleaned markup or `nil` (see moduledoc).
  """
  @spec sanitize(term()) :: String.t() | nil
  def sanitize(html) when is_binary(html) and byte_size(html) <= @max_raw_bytes do
    cleaned =
      html
      |> remove_blocks()
      |> HtmlSanitizeEx.Scrubber.scrub(Scrubber)
      |> String.trim()

    cond do
      cleaned == "" -> nil
      text_content(cleaned) == "" -> nil
      true -> cleaned |> drop_sourceless_images() |> harden_links()
    end
  end

  def sanitize(_html), do: nil

  defp remove_blocks(html) do
    html =
      Enum.reduce(@block_regex, html, fn regex, acc -> Regex.replace(regex, acc, " ") end)

    Regex.replace(@loose_tag_regex, html, " ")
  end

  defp drop_sourceless_images(html), do: Regex.replace(@sourceless_img_regex, html, "")

  # Sanitised output is well-formed, so a textual rewrite of the anchor open
  # tag is safe; `target`/`rel` can never have survived the scrubber.
  defp harden_links(html) do
    Regex.replace(@anchor_regex, html, ~s(<a target="_blank" rel="noopener noreferrer" ))
  end

  defp text_content(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
