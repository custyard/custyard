defmodule CustyardWeb.OperatorComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias CustyardWeb.OperatorComponents

  describe "tier_badge/1" do
    test "renders enterprise tier badge with purple styling" do
      html = render_component(&OperatorComponents.tier_badge/1, tier: :enterprise)

      assert html =~ "enterprise"
      assert html =~ "text-purple-700"
      assert html =~ "bg-purple-50"
      assert html =~ ~s(data-testid="operator-tier-badge-enterprise")
    end

    test "renders standard tier badge with gray styling" do
      html = render_component(&OperatorComponents.tier_badge/1, tier: :standard)

      assert html =~ "standard"
      assert html =~ "text-gray-600"
      assert html =~ "bg-gray-50"
      assert html =~ ~s(data-testid="operator-tier-badge-standard")
    end

    test "renders basic tier badge with lighter gray styling" do
      html = render_component(&OperatorComponents.tier_badge/1, tier: :basic)

      assert html =~ "basic"
      assert html =~ "text-gray-400"
      assert html =~ "bg-gray-50"
      assert html =~ ~s(data-testid="operator-tier-badge-basic")
    end

    test "renders unknown tier with default gray styling" do
      html = render_component(&OperatorComponents.tier_badge/1, tier: :unknown)

      assert html =~ "unknown"
      assert html =~ "text-gray-600"
    end
  end

  describe "state_badge/1" do
    test "renders new state badge with blue styling" do
      html = render_component(&OperatorComponents.state_badge/1, state: :new)

      assert html =~ "new"
      assert html =~ "bg-blue-100"
      assert html =~ "text-blue-800"
      assert html =~ ~s(data-testid="operator-state-badge-new")
    end

    test "renders active state badge with green styling" do
      html = render_component(&OperatorComponents.state_badge/1, state: :active)

      assert html =~ "active"
      assert html =~ "bg-green-100"
      assert html =~ "text-green-800"
      assert html =~ ~s(data-testid="operator-state-badge-active")
    end

    test "renders waiting state badge with yellow styling" do
      html = render_component(&OperatorComponents.state_badge/1, state: :waiting)

      assert html =~ "waiting"
      assert html =~ "bg-yellow-100"
      assert html =~ "text-yellow-800"
      assert html =~ ~s(data-testid="operator-state-badge-waiting")
    end

    test "renders dormant state badge with gray styling" do
      html = render_component(&OperatorComponents.state_badge/1, state: :dormant)

      assert html =~ "dormant"
      assert html =~ "bg-gray-100"
      assert html =~ "text-gray-600"
      assert html =~ ~s(data-testid="operator-state-badge-dormant")
    end

    test "renders resolved state badge with lighter gray styling" do
      html = render_component(&OperatorComponents.state_badge/1, state: :resolved)

      assert html =~ "resolved"
      assert html =~ "bg-gray-100"
      assert html =~ "text-gray-400"
      assert html =~ ~s(data-testid="operator-state-badge-resolved")
    end

    test "renders unknown state with default gray styling" do
      html = render_component(&OperatorComponents.state_badge/1, state: :unknown)

      assert html =~ "unknown"
      assert html =~ "bg-gray-100"
    end
  end

  describe "neglect_badge/1" do
    test "renders critical neglect badge with red styling and border" do
      html = render_component(&OperatorComponents.neglect_badge/1, level: :critical)

      assert html =~ "NEGLECTED"
      assert html =~ "bg-red-100"
      assert html =~ "text-red-800"
      assert html =~ "border-red-300"
      assert html =~ ~s(data-testid="operator-neglect-badge-critical")
    end

    test "renders warning neglect badge with amber styling and border" do
      html = render_component(&OperatorComponents.neglect_badge/1, level: :warning)

      assert html =~ "aging"
      assert html =~ "bg-amber-100"
      assert html =~ "text-amber-800"
      assert html =~ "border-amber-300"
      assert html =~ ~s(data-testid="operator-neglect-badge-warning")
    end

    test "renders nothing for ok level" do
      html = render_component(&OperatorComponents.neglect_badge/1, level: :ok)

      refute html =~ "NEGLECTED"
      refute html =~ "aging"
      refute html =~ "data-testid"
    end

    test "renders nothing for unknown level" do
      html = render_component(&OperatorComponents.neglect_badge/1, level: :normal)

      refute html =~ "NEGLECTED"
      refute html =~ "aging"
    end
  end

  describe "urgency_badge/1" do
    test "renders urgent badge with red styling" do
      html = render_component(&OperatorComponents.urgency_badge/1, urgency: :urgent)

      assert html =~ "urgent"
      assert html =~ "bg-red-100"
      assert html =~ "text-red-800"
      assert html =~ "font-medium"
      assert html =~ ~s(data-testid="operator-urgency-badge-urgent")
    end

    test "renders elevated badge with orange styling" do
      html = render_component(&OperatorComponents.urgency_badge/1, urgency: :elevated)

      assert html =~ "elevated"
      assert html =~ "bg-orange-100"
      assert html =~ "text-orange-800"
      assert html =~ "font-medium"
      assert html =~ ~s(data-testid="operator-urgency-badge-elevated")
    end

    test "renders nothing for normal urgency" do
      html = render_component(&OperatorComponents.urgency_badge/1, urgency: :normal)

      refute html =~ "urgent"
      refute html =~ "elevated"
      refute html =~ "data-testid"
    end

    test "renders nothing for unknown urgency" do
      html = render_component(&OperatorComponents.urgency_badge/1, urgency: :unknown)

      refute html =~ "urgent"
      refute html =~ "elevated"
    end
  end

  describe "score_breakdown/1" do
    test "renders breakdown with all positive factors" do
      breakdown = %{
        idle: 10,
        state: 15,
        tier: 20,
        urgency: 5,
        velocity: 8,
        neglect_bonus: 12,
        total: 70
      }

      html = render_component(&OperatorComponents.score_breakdown/1, breakdown: breakdown)

      assert html =~ "Score breakdown"
      assert html =~ "(total: 70)"
      assert html =~ "idle"
      assert html =~ "state"
      assert html =~ "tier"
      assert html =~ "urgency"
      assert html =~ "velocity"
      assert html =~ "neglect"
      assert html =~ ~s(data-testid="operator-score-breakdown")
    end

    test "hides total when show_total is false" do
      breakdown = %{
        idle: 10,
        state: 15,
        tier: 20,
        urgency: 0,
        velocity: 5,
        neglect_bonus: 0,
        total: 50
      }

      html =
        render_component(&OperatorComponents.score_breakdown/1,
          breakdown: breakdown,
          show_total: false
        )

      assert html =~ "Score breakdown"
      refute html =~ "(total:"
    end

    test "excludes zero-value factors from display" do
      breakdown = %{
        idle: 10,
        state: 0,
        tier: 20,
        urgency: 0,
        velocity: 0,
        neglect_bonus: 0,
        total: 30
      }

      html = render_component(&OperatorComponents.score_breakdown/1, breakdown: breakdown)

      assert html =~ "idle"
      assert html =~ "tier"
      refute html =~ ">state<"
      refute html =~ ">urgency<"
      refute html =~ ">velocity<"
      refute html =~ ">neglect<"
    end

    test "handles all-zero breakdown gracefully" do
      breakdown = %{
        idle: 0,
        state: 0,
        tier: 0,
        urgency: 0,
        velocity: 0,
        neglect_bonus: 0,
        total: 0
      }

      html = render_component(&OperatorComponents.score_breakdown/1, breakdown: breakdown)

      assert html =~ "Score breakdown"
      assert html =~ "(total: 0)"
      # Should not show any bar entries since all are zero
      refute html =~ ">idle<"
    end

    test "renders bar widths proportionally" do
      breakdown = %{
        idle: 50,
        state: 50,
        tier: 0,
        urgency: 0,
        velocity: 0,
        neglect_bonus: 0,
        total: 100
      }

      html = render_component(&OperatorComponents.score_breakdown/1, breakdown: breakdown)

      # Each should be 50% width
      assert html =~ "width: 50.0%"
    end
  end

  # Helper to render a function component to a string
  defp render_component(component, assigns) do
    assigns
    |> Enum.into(%{__changed__: %{}})
    |> component.()
    |> rendered_to_string()
  end
end
