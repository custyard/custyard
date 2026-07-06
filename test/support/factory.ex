defmodule Custyard.Factory do
  @moduledoc """
  Simple factory functions for test data.
  Returns maps with defaults that can be merged with overrides.
  """

  alias Custyard.Auth.Token

  @doc """
  Build organization attributes.

  ## Examples

      build_organization()
      build_organization(name: "Acme Corp", tier: :enterprise)
  """
  def build_organization(overrides \\ []) do
    defaults = %{
      name: "Test Organization #{unique_id()}",
      domain: "test-#{unique_id()}.example.com",
      tier: :standard,
      token: generate_token()
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Build contact attributes.

  ## Examples

      build_contact()
      build_contact(email: "alice@example.com", organization_id: 1)
  """
  def build_contact(overrides \\ []) do
    id = unique_id()

    defaults = %{
      name: "Contact #{id}",
      email: "contact-#{id}@example.com",
      is_admin: false,
      organization_id: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Build conversation attributes.

  States: :new, :active, :waiting, :dormant, :resolved
  Urgencies: :normal, :elevated, :urgent

  ## Examples

      build_conversation()
      build_conversation(state: :active, urgency: :elevated)
  """
  def build_conversation(overrides \\ []) do
    defaults = %{
      subject: "Test conversation #{unique_id()}",
      state: :new,
      urgency: :normal,
      cached_score: 0,
      organization_id: nil,
      contact_id: nil,
      last_operator_action_at: nil,
      last_customer_action_at: nil,
      snoozed_until: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Build message attributes.

  Sources: :email, :portal, :operator

  ## Examples

      build_message()
      build_message(source: :email, body: "Hello")
  """
  def build_message(overrides \\ []) do
    defaults = %{
      body: "Test message body #{unique_id()}",
      source: :email,
      sender_email: "sender-#{unique_id()}@example.com",
      is_internal_note: false,
      message_id: "mid-#{unique_id()}",
      in_reply_to: nil,
      conversation_id: nil,
      delivery_status: nil,
      lettermint_message_id: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Build project attributes.

  ## Examples

      build_project()
      build_project(title: "Website Redesign", portal_visible: true)
  """
  def build_project(overrides \\ []) do
    defaults = %{
      title: "Test project #{unique_id()}",
      description: "Test project description",
      portal_visible: true,
      project_type: :customer,
      organization_id: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Build task attributes.

  States: :open, :in_progress, :done

  ## Examples

      build_task()
      build_task(title: "Implement feature", state: :in_progress)
  """
  def build_task(overrides \\ []) do
    defaults = %{
      title: "Test task #{unique_id()}",
      state: :open,
      portal_visible: true,
      project_id: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Build audit event attributes.

  Event types: :webhook_received, :webhook_processed, :webhook_error

  ## Examples

      build_audit_event()
      build_audit_event(event_type: :webhook_error, source: "zendesk")
  """
  def build_audit_event(overrides \\ []) do
    defaults = %{
      event_type: :webhook_received,
      source: "email",
      message_id: "audit-mid-#{unique_id()}",
      payload: %{"test" => "data"},
      conversation_id: nil,
      organization_id: nil,
      project_id: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Build operator account attributes.

  Roles: "super_admin", "admin", "agent"
  - super_admin: No organization_id (can access all)
  - admin/agent: Requires organization_id

  ## Examples

      build_operator_account()
      build_operator_account(role: "admin", organization_id: 1)
  """
  def build_operator_account(overrides \\ []) do
    id = unique_id()

    defaults = %{
      email: "operator-#{id}@example.com",
      password: "password123",
      role: "super_admin",
      organization_id: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Insert an organization into the database.
  """
  def insert_organization(overrides \\ []) do
    %Custyard.Organization{}
    |> Custyard.Organization.changeset(build_organization(overrides))
    |> Custyard.Repo.insert!()
  end

  @doc """
  Insert a contact into the database.
  Requires organization_id or will create one.
  """
  def insert_contact(overrides \\ []) do
    overrides = ensure_organization(overrides)

    %Custyard.Contact{}
    |> Custyard.Contact.changeset(build_contact(overrides))
    |> Custyard.Repo.insert!()
  end

  # Sources whose conversations may exist without an organization; the factory
  # skips auto-creating one for these unless organization_id is given.
  @org_exempt_sources [:disambiguation, :public_intake]

  @doc """
  Insert a conversation into the database.
  Requires organization_id or will create one — except for org-exempt sources
  (:disambiguation, :public_intake), which stay organization-less unless an
  organization_id override is provided.
  """
  def insert_conversation(overrides \\ []) do
    overrides =
      if Keyword.get(overrides, :source) in @org_exempt_sources do
        overrides
      else
        ensure_organization(overrides)
      end

    attrs = build_conversation(overrides)

    # Extract cached_score (not in changeset cast list for security)
    {cached_score, attrs} = Map.pop(attrs, :cached_score, 0)
    # intake_source_key is creation-only (not in the operator changeset cast
    # list); apply it as a raw change like cached_score
    {intake_source_key, attrs} = Map.pop(attrs, :intake_source_key)

    %Custyard.Conversation{}
    |> Custyard.Conversation.changeset(attrs)
    |> Ecto.Changeset.change(cached_score: cached_score)
    |> maybe_change_intake_source_key(intake_source_key)
    |> Custyard.Repo.insert!()
  end

  defp maybe_change_intake_source_key(changeset, nil), do: changeset

  defp maybe_change_intake_source_key(changeset, key),
    do: Ecto.Changeset.change(changeset, intake_source_key: key)

  @doc """
  Insert a message into the database.
  Requires conversation_id or will create one.
  """
  def insert_message(overrides \\ []) do
    overrides = ensure_conversation(overrides)

    %Custyard.Message{}
    |> Custyard.Message.changeset(build_message(overrides))
    |> Custyard.Repo.insert!()
  end

  @doc """
  Insert a project into the database.
  Requires organization_id or will create one.
  """
  def insert_project(overrides \\ []) do
    overrides = ensure_organization(overrides)

    %Custyard.Project{}
    |> Custyard.Project.changeset(build_project(overrides))
    |> Custyard.Repo.insert!()
  end

  @doc """
  Insert a task into the database.
  Requires project_id or will create one.
  """
  def insert_task(overrides \\ []) do
    overrides = ensure_project(overrides)

    %Custyard.Task{}
    |> Custyard.Task.changeset(build_task(overrides))
    |> Custyard.Repo.insert!()
  end

  @doc """
  Build inbound route attributes.

  ## Examples

      build_inbound_route()
      build_inbound_route(route_type: :project, project_id: 1)
  """
  def build_inbound_route(overrides \\ []) do
    defaults = %{
      route_type: :general,
      organization_id: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Insert an inbound route into the database.
  Requires organization_id or will create one.
  """
  def insert_inbound_route(overrides \\ []) do
    overrides = ensure_organization(overrides)

    %Custyard.InboundRoute{}
    |> Custyard.InboundRoute.changeset(build_inbound_route(overrides))
    |> Custyard.Repo.insert!()
  end

  @doc """
  Build inbound route webhook attributes.
  """
  def build_inbound_route_webhook(overrides \\ []) do
    defaults = %{
      purpose: :sender_matching,
      enabled: true,
      inbound_route_id: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Insert an inbound route webhook into the database.
  Requires inbound_route_id or will create one.
  """
  def insert_inbound_route_webhook(overrides \\ []) do
    overrides = ensure_inbound_route(overrides)

    %Custyard.InboundRouteWebhook{}
    |> Custyard.InboundRouteWebhook.changeset(build_inbound_route_webhook(overrides))
    |> Custyard.Repo.insert!()
  end

  @doc """
  Build team attributes.

  ## Examples

      build_team()
      build_team(name: "Support Team")
  """
  def build_team(overrides \\ []) do
    defaults = %{
      name: "Team #{unique_id()}"
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Insert a team into the database.
  Requires organization_id or will create one.
  """
  def insert_team(overrides \\ []) do
    overrides = ensure_organization(overrides)

    %Custyard.Team{}
    |> Custyard.Team.changeset(build_team(overrides))
    |> Custyard.Repo.insert!()
  end

  @doc """
  Build prospect attributes.

  ## Examples

      build_prospect()
      build_prospect(email: "prospect@example.com", notify_on_reply: true)
  """
  def build_prospect(overrides \\ []) do
    defaults = %{
      resume_token_hash: Token.generate() |> elem(1),
      email: nil,
      notify_on_reply: false,
      email_captured_at: nil,
      revoked_at: nil,
      conversation_id: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Insert a prospect into the database.
  Requires conversation_id or will create an org-less :public_intake conversation.
  """
  def insert_prospect(overrides \\ []) do
    overrides = ensure_intake_conversation(overrides)
    attrs = build_prospect(overrides)

    # create_changeset casts only conversation_id and resume_token_hash;
    # the remaining fields (normally set via Intake.capture_email/3 or the
    # revoke path) are applied as raw changes.
    {create_attrs, extra} = Map.split(attrs, [:conversation_id, :resume_token_hash])
    extra = extra |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

    %Custyard.Prospect{}
    |> Custyard.Prospect.create_changeset(create_attrs)
    |> Ecto.Changeset.change(extra)
    |> Custyard.Repo.insert!()
  end

  @doc """
  Build intake source attributes.

  ## Examples

      build_intake_source()
      build_intake_source(key: "landing-page", mode: :passive)
  """
  def build_intake_source(overrides \\ []) do
    id = unique_id()

    defaults = %{
      key: "source-#{id}",
      name: "Intake Source #{id}",
      mode: :active,
      headline: nil,
      intro_copy: nil,
      questions: [],
      enabled: true
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Insert an intake source into the database.
  """
  def insert_intake_source(overrides \\ []) do
    %Custyard.IntakeSource{}
    |> Custyard.IntakeSource.changeset(build_intake_source(overrides))
    |> Custyard.Repo.insert!()
  end

  @doc """
  Build slug registry row attributes.

  ## Examples

      build_slug()
      build_slug(slug: "acme", status: :confirmed)
  """
  def build_slug(overrides \\ []) do
    id = unique_id()

    defaults = %{
      slug: "org-#{id}",
      status: :claimed,
      email: "claimant-#{id}@example.com",
      conversation_id: nil,
      organization_id: nil,
      confirmation_token_hash: Token.generate() |> elem(1),
      expires_at: DateTime.utc_now() |> DateTime.add(72, :hour) |> DateTime.truncate(:second),
      confirmed_at: nil
    }

    Map.merge(defaults, Map.new(overrides))
  end

  @doc """
  Insert a slug registry row into the database.

  Requires conversation_id or will create an org-less :public_intake
  conversation. Inserted as a raw struct (no changeset) so tests can build
  confirmed/provisioned rows directly; the database CHECK constraints
  still apply (provisioned requires organization_id and vice versa).
  """
  def insert_slug(overrides \\ []) do
    overrides = ensure_intake_conversation(overrides)

    Custyard.Slug
    |> struct(build_slug(overrides))
    |> Custyard.Repo.insert!()
  end

  @doc """
  Insert an audit event into the database.
  """
  def insert_audit_event(overrides \\ []) do
    %Custyard.AuditEvent{}
    |> Custyard.AuditEvent.changeset(build_audit_event(overrides))
    |> Custyard.Repo.insert!()
  end

  @doc """
  Insert an operator account into the database.
  For admin/agent roles, requires organization_id or will create one.
  """
  def insert_operator_account(overrides \\ []) do
    attrs = build_operator_account(overrides)
    role = Map.get(attrs, :role, "super_admin")

    # Ensure organization_id for non-super_admin roles
    attrs =
      if role in ["admin", "agent"] and is_nil(Map.get(attrs, :organization_id)) do
        org = insert_organization()
        Map.put(attrs, :organization_id, org.id)
      else
        attrs
      end

    %Custyard.OperatorAccount{}
    |> Custyard.OperatorAccount.changeset(attrs)
    |> Custyard.Repo.insert!()
  end

  # Private helpers

  defp unique_id do
    System.unique_integer([:positive, :monotonic])
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp ensure_organization(overrides) do
    if Keyword.has_key?(overrides, :organization_id) do
      overrides
    else
      org = insert_organization()
      Keyword.put(overrides, :organization_id, org.id)
    end
  end

  defp ensure_conversation(overrides) do
    if Keyword.has_key?(overrides, :conversation_id) do
      overrides
    else
      conv = insert_conversation()
      Keyword.put(overrides, :conversation_id, conv.id)
    end
  end

  defp ensure_intake_conversation(overrides) do
    if Keyword.has_key?(overrides, :conversation_id) do
      overrides
    else
      conv = insert_conversation(source: :public_intake)
      Keyword.put(overrides, :conversation_id, conv.id)
    end
  end

  defp ensure_project(overrides) do
    if Keyword.has_key?(overrides, :project_id) do
      overrides
    else
      project = insert_project()
      Keyword.put(overrides, :project_id, project.id)
    end
  end

  defp ensure_inbound_route(overrides) do
    if Keyword.has_key?(overrides, :inbound_route_id) do
      overrides
    else
      route = insert_inbound_route()
      Keyword.put(overrides, :inbound_route_id, route.id)
    end
  end
end
