defmodule CustyardWeb.InlineImages do
  @moduledoc """
  Maps the `cid:` images that `Custyard.Email.HtmlSanitizer` keeps to the
  message's own stored attachments when the staff thread renders an
  email's HTML (spec-inbound-channels D9).

  An image is shown only when the same message has a fetched attachment
  with that Content-ID whose bytes sniffed as a raster image
  (`CustyardWeb.AttachmentDownload.inline_image?/1`); it then loads from the
  authenticated inline endpoint. Every other image tag is dropped, so a
  stored `cid:` never reaches the browser. The input is sanitiser output,
  whose image tags have the form `<img src="cid:..." alt="..." />`.
  """

  use CustyardWeb, :verified_routes

  alias CustyardWeb.AttachmentDownload

  @img_regex ~r/<img\b[^>]*>/i
  @src_regex ~r/\ssrc="cid:([^"]*)"/
  @alt_regex ~r/\salt="[^"]*"/

  @doc "Rewrite the `cid:` images in sanitised `html` for `attachments` of the same message."
  def render(html, attachments) when is_binary(html) and is_list(attachments) do
    by_cid =
      for %{content_id: cid} = attachment <- attachments,
          is_binary(cid),
          AttachmentDownload.inline_image?(attachment),
          into: %{},
          do: {normalize(cid), attachment.id}

    Regex.replace(@img_regex, html, &rewrite(&1, by_cid))
  end

  defp rewrite(tag, by_cid) do
    with [_, cid] <- Regex.run(@src_regex, tag),
         id when is_integer(id) <- Map.get(by_cid, cid |> unescape() |> normalize()) do
      alt =
        case Regex.run(@alt_regex, tag) do
          [alt] -> alt
          nil -> ~s( alt="")
        end

      ~s(<img src="#{~p"/app/attachments/#{id}/inline"}"#{alt} loading="lazy" />)
    else
      _unresolved -> ""
    end
  end

  # cid: URLs percent-encode (RFC 2392); Content-ID headers may keep their
  # angle brackets.
  defp normalize(cid) do
    cid
    |> percent_decode()
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
    |> String.downcase()
  end

  # A malformed escape in hostile mail must not crash the thread.
  defp percent_decode(value) do
    URI.decode(value)
  rescue
    ArgumentError -> value
  end

  defp unescape(value) do
    value
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end
end
