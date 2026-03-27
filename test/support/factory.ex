defmodule Custyard.Factory do
  @moduledoc """
  Simple factory functions for test data.
  Returns maps with defaults that can be merged with overrides.
  """

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
      conversation_id: nil
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

  @doc """
  Insert a conversation into the database.
  Requires organization_id or will create one.
  """
  def insert_conversation(overrides \\ []) do
    overrides = ensure_organization(overrides)
    attrs = build_conversation(overrides)

    # Extract cached_score (not in changeset cast list for security)
    {cached_score, attrs} = Map.pop(attrs, :cached_score, 0)

    %Custyard.Conversation{}
    |> Custyard.Conversation.changeset(attrs)
    |> Ecto.Changeset.change(cached_score: cached_score)
    |> Custyard.Repo.insert!()
  end

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

  defp ensure_project(overrides) do
    if Keyword.has_key?(overrides, :project_id) do
      overrides
    else
      project = insert_project()
      Keyword.put(overrides, :project_id, project.id)
    end
  end
end
