defmodule CustyardWeb.InlineImagesTest do
  use ExUnit.Case, async: true

  alias Custyard.MessageAttachment
  alias CustyardWeb.InlineImages

  defp attachment(id, content_id, attrs \\ []) do
    struct(
      MessageAttachment,
      [id: id, content_id: content_id, state: :fetched, sniffed_type: "image/png"] ++ attrs
    )
  end

  test "points a cid: image at the message's own inline attachment" do
    html = ~S|<p>Hi <img src="cid:logo@acme" alt="Logo" /></p>|

    assert InlineImages.render(html, [attachment(7, "<Logo@Acme>")]) ==
             ~S|<p>Hi <img src="/operator/attachments/7/inline" alt="Logo" loading="lazy" /></p>|
  end

  test "decodes percent escapes in the cid: URL" do
    html = ~S|<img src="cid:logo%40acme" />|

    assert InlineImages.render(html, [attachment(7, "logo@acme")]) ==
             ~S|<img src="/operator/attachments/7/inline" alt="" loading="lazy" />|
  end

  test "drops images it cannot resolve to a fetched raster attachment" do
    html = ~S|<p>a<img src="cid:x" />b<img src="cid:pdf" />c<img src="cid:gone" />d</p>|

    attachments = [
      attachment(1, "pdf", sniffed_type: "application/pdf"),
      attachment(2, "gone", state: :skipped)
    ]

    assert InlineImages.render(html, attachments) == "<p>abcd</p>"
  end

  test "survives a malformed escape" do
    assert InlineImages.render(~S|<img src="cid:%zz" />|, [attachment(1, "%zz")]) =~
             "/operator/attachments/1/inline"
  end
end
