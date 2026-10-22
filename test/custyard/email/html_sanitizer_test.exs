defmodule Custyard.Email.HtmlSanitizerTest do
  use ExUnit.Case, async: true

  alias Custyard.Email.HtmlSanitizer

  describe "sanitize/1" do
    test "keeps text markup, lists, tables and safe links" do
      html =
        ~S|<p>Hello <b>world</b> <a href="https://example.com/?a=1&b=2" title="t">link</a></p>| <>
          ~S|<ol start="3"><li>x</li></ol><table><tr><td colspan="2">c</td></tr></table>|

      out = HtmlSanitizer.sanitize(html)

      assert out =~ ~s(<b>world</b>)
      assert out =~ ~s(href="https://example.com/?a=1&amp;b=2")
      assert out =~ ~s(title="t")
      assert out =~ ~s(<ol start="3">)
      assert out =~ ~s(<td colspan="2">)
    end

    test "drops scripts, styles, handlers, inline styles and unsafe link schemes" do
      html = """
      <html><head><style>p{color:red}</style><title>t</title></head><body>
      <p onclick="evil()" style="color:red" class="x" id="y">Hi</p>
      <a href="javascript:alert(1)">bad</a>
      <script>alert(1)</script><iframe src="https://x"></iframe>
      </body></html>
      """

      out = HtmlSanitizer.sanitize(html)

      refute out =~ "alert"
      refute out =~ "color:red"
      refute out =~ "onclick"
      refute out =~ "class="
      refute out =~ "id="
      refute out =~ "javascript"
      refute out =~ "iframe"
      refute out =~ "<title"
      assert out =~ "<p>Hi</p>"
      assert out =~ "<a>bad</a>"
    end

    test "an unterminated script tag cannot leak its payload as text" do
      refute HtmlSanitizer.sanitize("<p>a</p><script>alert(1)") =~ "alert"
      assert HtmlSanitizer.sanitize("<p>a</p><script>alert(1)") == "<p>a</p>"
    end

    test "removes images, remote or otherwise" do
      out = HtmlSanitizer.sanitize(~S|<p>x <img src="https://t.example/p.gif" alt="a"></p>|)
      refute out =~ "img"
      refute out =~ "t.example"
    end

    test "links open in a new tab without a referrer" do
      out = HtmlSanitizer.sanitize(~S|<a href="https://example.com">x</a>|)

      assert out ==
               ~S|<a target="_blank" rel="noopener noreferrer" href="https://example.com">x</a>|
    end

    test "returns nil for blank input, non-strings and markup without text" do
      assert HtmlSanitizer.sanitize(nil) == nil
      assert HtmlSanitizer.sanitize("") == nil
      assert HtmlSanitizer.sanitize("   ") == nil
      assert HtmlSanitizer.sanitize(42) == nil
      assert HtmlSanitizer.sanitize(~S|<div><img src="https://x"/><br>&nbsp;</div>|) == nil
    end

    test "returns nil above the raw size cap instead of truncating" do
      big = "<p>" <> String.duplicate("a", HtmlSanitizer.max_raw_bytes()) <> "</p>"
      assert HtmlSanitizer.sanitize(big) == nil
    end

    test "preserves entities and non-ASCII text" do
      out = HtmlSanitizer.sanitize("<p>caf&eacute; &amp; <strong>co</strong> &lt;tag&gt; ü</p>")
      assert out == "<p>café &amp; <strong>co</strong> &lt;tag&gt; ü</p>"
    end
  end
end
