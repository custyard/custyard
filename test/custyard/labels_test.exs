defmodule Custyard.LabelsTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{Conversations, Labels, Tenants}

  setup do
    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Labels",
        slug: "labels-#{System.unique_integer([:positive])}"
      })

    {:ok, other} =
      Tenants.create_tenant(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})

    org = insert_organization(tenant_id: tenant.id)
    other_org = insert_organization(tenant_id: other.id)

    operator =
      insert_operator_account(role: "admin", organization_id: org.id, tenant_id: tenant.id)

    conversation = insert_conversation(organization_id: org.id)

    %{
      tenant: tenant,
      other_org: other_org,
      org: org,
      operator: operator,
      conversation: conversation
    }
  end

  test "labels are reusable within a tenant and assignments are idempotent", c do
    assert {:ok, label} = Labels.create_and_assign(c.operator, c.conversation, " Billing ")
    assert label.name == "Billing"
    assert {:ok, _} = Labels.assign(c.operator, c.conversation, label.id)
    assert %{assigned: [^label]} = Labels.for_conversation(c.operator, c.conversation)
    assert {:error, changeset} = Labels.create_and_assign(c.operator, c.conversation, "billing")
    assert "has already been taken" in errors_on(changeset).tenant_id
    assert {:ok, :removed} = Labels.remove(c.operator, c.conversation, label.id)

    assert %{assigned: [], available: [^label]} =
             Labels.for_conversation(c.operator, c.conversation)
  end

  test "foreign labels cannot be read, assigned or used to cross tenant boundaries", c do
    foreign_operator =
      insert_operator_account(
        role: "admin",
        organization_id: c.other_org.id,
        tenant_id: c.other_org.tenant_id
      )

    foreign_conversation = insert_conversation(organization_id: c.other_org.id)
    {:ok, label} = Labels.create_and_assign(foreign_operator, foreign_conversation, "Private")
    refute label in Labels.list_for_operator(c.operator)

    assert %{available: [], assigned: []} =
             Labels.for_conversation(c.operator, foreign_conversation)

    assert {:error, :not_found} = Labels.assign(c.operator, c.conversation, label.id)
    assert {:error, :unauthorized} = Labels.assign(c.operator, foreign_conversation, label.id)

    assert Conversations.list_for_attention_queue(organization_id: c.org.id, label_id: label.id) ==
             []
  end

  test "agents can apply existing labels but cannot define labels", c do
    {:ok, label} = Labels.create_and_assign(c.operator, c.conversation, "Bug")
    {:ok, _} = Labels.remove(c.operator, c.conversation, label.id)

    agent =
      insert_operator_account(role: "agent", organization_id: c.org.id, tenant_id: c.tenant.id)

    assert {:ok, _} = Labels.assign(agent, c.conversation, label.id)
    assert {:error, :unauthorized} = Labels.create_and_assign(agent, c.conversation, "New")
  end

  test "unlinked public conversations use their workspace labels", c do
    conversation = insert_conversation(source: :public_intake, tenant_id: c.tenant.id)
    assert is_nil(conversation.organization_id)
    assert {:ok, label} = Labels.create_and_assign(c.operator, conversation, "Public question")
    assert %{assigned: [^label]} = Labels.for_conversation(c.operator, conversation)
    id = conversation.id
    assert %{^id => [^label]} = Labels.for_conversations([conversation])

    assert [%{conversation: %{id: ^id}}] =
             Conversations.list_for_attention_queue(tenant_id: c.tenant.id, label_id: label.id)
  end
end
