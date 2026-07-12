defmodule CustyardWeb.CoreComponents.FlashTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CustyardWeb.CoreComponents

  describe "flash/1" do
    test "info flash auto-dismisses after 5s" do
      html = render_flash(kind: :info, flash: %{"info" => "Saved!"})

      assert html =~ ~s(phx-hook="AutoDismiss")
      assert html =~ ~s(data-dismiss-timeout="5000")
    end

    test "error flash auto-dismisses after a longer 10s delay" do
      html = render_flash(kind: :error, flash: %{"error" => "Something broke"})

      assert html =~ ~s(phx-hook="AutoDismiss")
      assert html =~ ~s(data-dismiss-timeout="10000")
    end

    test "renders close button with x-mark icon" do
      html = render_flash(kind: :error, flash: %{"error" => "boom"})

      assert html =~ ~s(data-testid="flash-close-error")
      assert html =~ "hero-x-mark-solid"
    end

    test "renders title icon per kind" do
      assert render_flash(kind: :info, title: "Success!", flash: %{"info" => "ok"}) =~
               "hero-information-circle-mini"

      assert render_flash(kind: :error, title: "Error!", flash: %{"error" => "no"}) =~
               "hero-exclamation-circle-mini"
    end

    test "indents message under title only when a title is present" do
      assert render_flash(kind: :info, title: "Success!", flash: %{"info" => "ok"}) =~
               "pl-[22px]"

      refute render_flash(kind: :info, flash: %{"info" => "ok"}) =~ "pl-[22px]"
    end
  end

  defp render_flash(assigns) do
    render_component(&CoreComponents.flash/1, assigns)
  end
end
