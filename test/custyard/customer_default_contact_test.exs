defmodule Custyard.CustomerDefaultContactTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{Organization, Organizations, Repo, Threads}
  alias Ecto.Adapters.SQL

  test "default contacts cannot cross customer or tenant boundaries" do
    org = insert_organization()
    own = insert_contact(organization_id: org.id)
    other_org = insert_organization()
    other = insert_contact(organization_id: other_org.id)
    foreign_org = insert_organization(tenant_id: insert_tenant().id)
    foreign = insert_contact(organization_id: foreign_org.id, tenant_id: foreign_org.tenant_id)

    for contact <- [other, foreign] do
      changeset = Organization.changeset(org, %{default_contact_id: contact.id})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :default_contact_id)

      assert {:error, _} =
               SQL.query(Repo, "UPDATE organizations SET default_contact_id = ? WHERE id = ?", [
                 contact.id,
                 org.id
               ])
    end

    {:ok, updated} = org |> Organization.changeset(%{default_contact_id: own.id}) |> Repo.update()
    assert Organizations.default_contact(updated).id == own.id
    Repo.delete!(own)
    assert is_nil(Repo.reload!(updated).default_contact_id)
  end

  test "existing customer requests resolve the current default contact without bypassing prospect consent" do
    org = insert_organization()
    first = insert_contact(organization_id: org.id, email: "first@example.com")
    second = insert_contact(organization_id: org.id, email: "second@example.com")
    portal = insert_thread(organization_id: org.id, source: :portal)
    old_portal = insert_thread(organization_id: org.id, source: :email)
    public = insert_thread(organization_id: org.id, source: :public_intake)

    assert Threads.reply_channel(portal) == :none
    Repo.update!(Ecto.Changeset.change(org, default_contact_id: first.id))
    assert Threads.reply_channel(portal) == {:contact, first.email}
    assert Threads.reply_channel(old_portal) == {:contact, first.email}
    assert Threads.reply_channel(public) == :none
    Repo.update!(Ecto.Changeset.change(org, default_contact_id: second.id))
    assert Threads.reply_channel(portal) == {:contact, second.email}
  end
end
