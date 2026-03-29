defmodule CustyardWeb.CoreComponents.BannerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias CustyardWeb.CoreComponents

  describe "banner/1" do
    test "renders each kind with correct data-testid" do
      for kind <- [:note, :warning, :success, :error, :caution] do
        html = render_banner(kind: kind, inner_block: "test content")

        assert html =~ ~s(data-testid="banner-#{kind}"),
               "expected data-testid=\"banner-#{kind}\" for kind #{kind}"
      end
    end

    test "renders title when provided" do
      html = render_banner(kind: :warning, title: "Watch out", inner_block: "details here")

      assert html =~ "Watch out"
      assert html =~ "details here"
    end

    test "omits title element when not provided" do
      html = render_banner(kind: :note, inner_block: "just a note")

      assert html =~ "just a note"
      refute html =~ "font-semibold"
    end

    test "renders inner block content" do
      html = render_banner(kind: :success, inner_block: "Operation completed")

      assert html =~ "Operation completed"
    end

    test "renders correct icon per kind" do
      assert render_banner(kind: :note, inner_block: "x") =~ "hero-information-circle-mini"
      assert render_banner(kind: :warning, inner_block: "x") =~ "hero-exclamation-triangle-mini"
      assert render_banner(kind: :success, inner_block: "x") =~ "hero-check-circle-mini"
      assert render_banner(kind: :error, inner_block: "x") =~ "hero-x-circle-mini"
      assert render_banner(kind: :caution, inner_block: "x") =~ "hero-exclamation-circle-mini"
    end

    test "has role=alert for accessibility" do
      html = render_banner(kind: :note, inner_block: "accessible")

      assert html =~ ~s(role="alert")
    end
  end

  defp render_banner(opts) do
    kind = Keyword.fetch!(opts, :kind)
    title = Keyword.get(opts, :title)
    inner_block = Keyword.fetch!(opts, :inner_block)

    assigns = %{
      __changed__: %{},
      kind: kind,
      title: title,
      class: nil,
      rest: %{},
      inner_block: [%{__slot__: :inner_block, inner_block: fn _, _ -> inner_block end}]
    }

    assigns
    |> CoreComponents.banner()
    |> rendered_to_string()
  end
end
