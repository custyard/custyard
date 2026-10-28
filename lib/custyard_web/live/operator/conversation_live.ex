defmodule CustyardWeb.Operator.ConversationLive do
  @moduledoc """
  Operator view for a single conversation with reply, state management, and task tools.

  ## Authorization Model

  Tenant staff can access threads and unassigned intake within their workspace.
  Administrators can change thread state. Every read and mutation rechecks the
  authenticated tenant scope.
  """
  use CustyardWeb, :live_view

  import CustyardWeb.OperatorComponents
  import CustyardWeb.FormHelpers

  alias Custyard.Attachments.Recovery
  alias Custyard.Email.Outbound
  alias CustyardWeb.InlineImages

  alias Custyard.{
    Attachments,
    Authorization,
    Conversation,
    Conversations,
    Labels,
    Message,
    MessageRecipientStatus,
    Organizations,
    Scoring,
    Slugs
  }

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case load_conversation(socket.assigns.current_scope, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Conversation not found")
         |> redirect(to: ~p"/app")}

      conversation ->
        if Authorization.can_access_conversation?(socket.assigns.current_operator, conversation) do
          mount_conversation(socket, id, conversation)
        else
          {:ok,
           socket
           |> put_flash(:error, "You do not have access to this conversation")
           |> redirect(to: ~p"/app")}
        end
    end
  end

  defp mount_conversation(socket, id, conversation) do
    if connected?(socket) do
      # Subscribe to org-scoped topic instead of global "conversations" to reduce
      # unnecessary PubSub traffic. Unlinked (nil-org) conversations have no org
      # topic, and their state changes are only published on the global topic
      # (the "conversation:{id}" topic carries message events, not state changes),
      # so fall back to the global topic; handle_info filters by conversation id.
      if conversation.organization_id do
        Phoenix.PubSub.subscribe(
          Custyard.PubSub,
          "conversations:org:#{conversation.organization_id}"
        )
      else
        Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")
      end

      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{id}")
    end

    case activate_if_new(conversation, socket.assigns.current_scope) do
      {:ok, current} ->
        if current &&
             Authorization.can_access_conversation?(socket.assigns.current_operator, current) do
          mount_loaded_conversation(socket, current)
        else
          {:ok,
           socket
           |> put_flash(:error, "You do not have access to this conversation")
           |> redirect(to: ~p"/app")}
        end

      {:error, :unauthorized} ->
        {:ok,
         socket
         |> put_flash(:error, "You do not have access to this conversation")
         |> redirect(to: ~p"/app")}
    end
  end

  defp activate_if_new(%Conversation{state: :new} = conversation, scope) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Conversations.with_access(scope, conversation.id, fn current, _operator ->
           if current.state == :new do
             Conversations.transition_state(current, :new, :active, last_operator_action_at: now)
           else
             {:ok, :already_transitioned}
           end
         end) do
      {:ok, %Conversation{}} ->
        Scoring.calculate_and_cache(conversation.id)
        broadcast_conversation_update(conversation.id, conversation.organization_id)
        {:ok, load_conversation(scope, conversation.id)}

      {:ok, :already_transitioned} ->
        {:ok, load_conversation(scope, conversation.id)}

      {:error, :unauthorized} = error ->
        error
    end
  end

  defp activate_if_new(conversation, _scope), do: {:ok, conversation}

  defp mount_loaded_conversation(socket, conversation) do
    breakdown = Scoring.breakdown(conversation)
    neglect_status = Scoring.neglect_status(conversation)
    other_conversations = fetch_other_org_conversations(conversation)

    socket =
      socket
      |> assign(:page_title, truncate_subject(conversation.subject))
      |> assign(:conversation, conversation)
      |> assign_labels(conversation)
      |> assign_reply_delivery(conversation)
      |> assign_reply_identity(conversation)
      |> assign(:reply_cc_edited?, false)
      |> assign_reply_cc(conversation)
      |> assign(:breakdown, breakdown)
      |> assign(:neglect_status, neglect_status)
      |> assign(:other_conversations, other_conversations)
      |> assign(:reply_text, "")
      |> assign(:note_text, "")
      |> assign(:new_task_title, "")
      |> assign(:new_task_due_at, "")
      |> assign(:new_task_portal_visible, false)
      |> assign(:show_task_form, false)
      |> assign(:editing_task_id, nil)
      |> assign(:edit_task_title, "")
      |> assign(:edit_task_due_at, "")
      |> assign(:edit_task_portal_visible, false)
      |> assign(:show_sidebar, false)
      |> assign(:show_convert_form, false)
      |> assign(:convert_form_data, %{name: "", domain: ""})
      |> attach_hook(
        :authorize_conversation_events,
        :handle_event,
        &authorize_conversation_event/3
      )

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_event("send_reply", %{"body" => body} = params, socket) when byte_size(body) > 0 do
    conversation = socket.assigns.conversation
    operator = socket.assigns.current_operator

    case Conversations.send_reply(conversation, body,
           operator: operator,
           operator_email: operator.email,
           expected_recipient:
             socket.assigns.reply_recipient && socket.assigns.reply_recipient.address,
           cc: Map.get(params, "cc", socket.assigns.reply_cc)
         ) do
      {:ok, message} ->
        socket =
          socket
          |> assign(:reply_text, "")
          |> assign(:reply_cc_edited?, false)
          |> reload_conversation()

        {:noreply, flash_undeliverable_reply(socket, message)}

      {:error, :unauthorized} ->
        {:noreply, access_revoked(socket)}

      {:error, :recipient_changed} ->
        {:noreply,
         socket
         |> assign(:reply_text, body)
         |> reload_conversation()
         |> put_flash(:error, "The recipient changed. Review the updated reply before sending.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reply_error_message(reason))}
    end
  end

  def handle_event("send_reply", _params, socket), do: {:noreply, socket}

  def handle_event("add_note", %{"body" => body}, socket) when byte_size(body) > 0 do
    conversation = socket.assigns.conversation

    case conversation_mutation(socket, fn current, _operator ->
           Conversations.create_message(%{
             source: :operator,
             body: body,
             is_internal_note: true,
             conversation_id: current.id
           })
         end) do
      {:ok, _message} ->
        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "conversation:#{conversation.id}",
          {:message_added, conversation.id}
        )

        {:noreply, socket |> assign(:note_text, "") |> reload_conversation()}

      {:error, :unauthorized} ->
        {:noreply, access_revoked(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to add note")}
    end
  end

  def handle_event("add_note", _params, socket), do: {:noreply, socket}

  # Soft delete: the message row (and its body) stays in the database; every
  # rendering surface shows a tombstone instead. Scoped to the loaded
  # conversation's messages so an id from another conversation is a no-op.
  def handle_event("delete_message", %{"id" => id}, socket) do
    case find_conversation_message(socket.assigns.conversation, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Message not found")}

      message ->
        case conversation_mutation(socket, fn _current, current_operator ->
               Conversations.soft_delete_message(message, current_operator)
             end) do
          {:ok, _message} ->
            {:noreply, reload_conversation(socket)}

          {:error, :unauthorized} ->
            {:noreply, access_revoked(socket)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to delete message")}
        end
    end
  end

  def handle_event("retry_attachments", _params, socket) do
    case conversation_mutation(socket, fn current, _operator -> {:ok, current} end) do
      {:ok, _conversation} -> {:noreply, begin_attachment_recovery(socket)}
      _ -> {:noreply, access_revoked(socket)}
    end
  end

  def handle_event("retry_reply", %{"id" => id}, socket) do
    case find_conversation_message(socket.assigns.conversation, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Message not found")}

      message ->
        case Outbound.retry(socket.assigns.current_scope, message) do
          {:ok, _} ->
            {:noreply, reload_conversation(socket)}

          {:error, :unauthorized} ->
            {:noreply, access_revoked(socket)}

          {:error, _} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Check the provider's delivery activity before sending another copy"
             )}
        end
    end
  end

  # Triage flagged the conversation as suspect (spec-inbound-channels D6).
  # The flag is a notification suppressor, never a filter; clearing it is an
  # operator judgement and goes through the same locked access check as
  # every other mutation.
  def handle_event("dismiss_suspect", _params, socket) do
    case conversation_mutation(socket, fn current, _current_operator ->
           Conversations.set_suspect(current, false)
         end) do
      {:ok, _conversation} ->
        {:noreply, begin_attachment_recovery(reload_conversation(socket))}

      {:error, :unauthorized} ->
        {:noreply, access_revoked(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update the conversation")}
    end
  end

  def handle_event("update_reply", %{"body" => body} = params, socket) do
    socket = assign(socket, :reply_text, body)

    case Map.fetch(params, "cc") do
      {:ok, cc} when is_binary(cc) ->
        {:noreply,
         socket
         |> assign(:reply_cc, cc)
         |> assign(
           :reply_cc_edited?,
           socket.assigns.reply_cc_edited? or cc != socket.assigns.reply_cc
         )}

      _no_cc ->
        {:noreply, socket}
    end
  end

  def handle_event("update_note", %{"body" => body}, socket) do
    {:noreply, assign(socket, :note_text, body)}
  end

  def handle_event("set_state", %{"state" => state}, socket)
      when state in ~w(active waiting resolved) do
    if Authorization.can_set_conversation_state?(socket.assigns.current_operator) do
      conversation = socket.assigns.conversation
      new_state = String.to_existing_atom(state)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      case conversation_mutation(socket, fn current, current_operator ->
             if Authorization.can_set_conversation_state?(current_operator) do
               Conversations.update_conversation(current, %{
                 state: new_state,
                 last_operator_action_at: now
               })
             else
               {:error, :unauthorized}
             end
           end) do
        {:ok, _} ->
          Scoring.calculate_and_cache(conversation.id)
          broadcast_conversation_update(conversation.id, conversation.organization_id)

          {:noreply, reload_conversation(socket)}

        {:error, :unauthorized} ->
          {:noreply, access_revoked(socket)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to update state")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only admins can change conversation state")}
    end
  end

  def handle_event("set_state", %{"state" => _state}, socket) do
    # Invalid state value - silently ignore (could also flash an error)
    {:noreply, socket}
  end

  def handle_event("show_convert_form", _params, socket) do
    if Authorization.can_create_organization?(socket.assigns.current_operator) do
      {:noreply,
       socket
       |> assign(:show_convert_form, true)
       |> assign(:convert_form_data, prefill_convert_form(socket.assigns.conversation))}
    else
      {:noreply, put_flash(socket, :error, "Only tenant administrators can convert prospects")}
    end
  end

  def handle_event("hide_convert_form", _params, socket) do
    {:noreply, assign(socket, :show_convert_form, false)}
  end

  def handle_event("validate_convert_form", params, socket) do
    form_data = %{
      name: Map.get(params, "name", ""),
      domain: Map.get(params, "domain", "")
    }

    {:noreply, assign(socket, :convert_form_data, form_data)}
  end

  def handle_event("convert_prospect", params, socket) do
    operator = socket.assigns.current_operator

    if Authorization.can_create_organization?(operator) do
      attrs = %{
        name: Map.get(params, "name", ""),
        domain: empty_to_nil(Map.get(params, "domain", ""))
      }

      Organizations.convert(socket.assigns.current_scope, socket.assigns.conversation, attrs)
      |> handle_convert_result(socket)
    else
      {:noreply, put_flash(socket, :error, "Only tenant administrators can convert prospects")}
    end
  end

  def handle_event("toggle_task_form", _params, socket) do
    {:noreply, assign(socket, :show_task_form, !socket.assigns.show_task_form)}
  end

  def handle_event("create_label", %{"name" => name}, socket) do
    socket.assigns.current_scope
    |> Labels.create_and_assign(socket.assigns.conversation, name)
    |> label_result(socket)
  end

  def handle_event("assign_label", %{"label_id" => id}, socket) do
    socket.assigns.current_scope
    |> Labels.assign(socket.assigns.conversation, id)
    |> label_result(socket)
  end

  def handle_event("remove_label", %{"id" => id}, socket) do
    socket.assigns.current_scope
    |> Labels.remove(socket.assigns.conversation, id)
    |> label_result(socket)
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :show_sidebar, !socket.assigns.show_sidebar)}
  end

  def handle_event("update_new_task", params, socket) do
    socket =
      socket
      |> assign(:new_task_title, params["title"] || socket.assigns.new_task_title)
      |> assign(:new_task_due_at, params["due_at"] || socket.assigns.new_task_due_at)
      |> assign(:new_task_portal_visible, params["portal_visible"] == "true")

    {:noreply, socket}
  end

  def handle_event("add_task", params, socket) do
    title = params["title"] || ""

    if byte_size(title) > 0 do
      due_at = params["due_at"]
      portal_visible = params["portal_visible"] == "true"

      case conversation_mutation(socket, fn current, _operator ->
             Conversations.create_task(%{
               title: title,
               due_at: due_at,
               portal_visible: portal_visible,
               conversation_id: current.id
             })
           end) do
        {:ok, _task} ->
          {:noreply,
           socket
           |> assign(:new_task_title, "")
           |> assign(:new_task_due_at, "")
           |> assign(:new_task_portal_visible, false)
           |> assign(:show_task_form, false)
           |> put_flash(:info, "Task created")
           |> reload_conversation()}

        {:error, :unauthorized} ->
          {:noreply, access_revoked(socket)}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, task_error(changeset))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_task", %{"id" => id}, socket) do
    with_scoped_task(socket, id, fn task ->
      new_state =
        case task.state do
          :open -> :in_progress
          :in_progress -> :done
          :done -> :open
        end

      case conversation_mutation(socket, fn _current, _operator ->
             Conversations.update_task_state(task, new_state)
           end) do
        {:ok, _} ->
          {:noreply, reload_conversation(socket)}

        {:error, :unauthorized} ->
          {:noreply, access_revoked(socket)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to update task")}
      end
    end)
  end

  def handle_event("edit_task", %{"id" => id}, socket) do
    with_scoped_task(socket, id, fn task ->
      due_at_str = if task.due_at, do: format_datetime_local(task.due_at), else: ""

      {:noreply,
       socket
       |> assign(:editing_task_id, task.id)
       |> assign(:edit_task_title, task.title)
       |> assign(:edit_task_due_at, due_at_str)
       |> assign(:edit_task_portal_visible, task.portal_visible)}
    end)
  end

  def handle_event("cancel_edit_task", _params, socket) do
    {:noreply, assign(socket, :editing_task_id, nil)}
  end

  def handle_event("update_edit_task", params, socket) do
    socket =
      socket
      |> assign(:edit_task_title, params["title"] || socket.assigns.edit_task_title)
      |> assign(:edit_task_due_at, params["due_at"] || socket.assigns.edit_task_due_at)
      |> assign(:edit_task_portal_visible, params["portal_visible"] == "true")

    {:noreply, socket}
  end

  def handle_event("save_task", params, socket) do
    title = params["title"] || ""

    if byte_size(title) > 0 do
      with_scoped_task(socket, socket.assigns.editing_task_id, fn task ->
        due_at = params["due_at"]
        portal_visible = params["portal_visible"] == "true"

        case conversation_mutation(socket, fn _current, _operator ->
               Conversations.update_task(task, %{
                 title: title,
                 due_at: due_at,
                 portal_visible: portal_visible
               })
             end) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:editing_task_id, nil)
             |> reload_conversation()}

          {:error, :unauthorized} ->
            {:noreply, access_revoked(socket)}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, task_error(changeset))}
        end
      end)
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_task", %{"id" => id}, socket) do
    with_scoped_task(socket, id, fn task ->
      delete_scoped_task(socket, task)
    end)
  end

  defp delete_scoped_task(socket, task) do
    case conversation_mutation(socket, fn _current, _operator ->
           Conversations.delete_task(task)
         end) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:editing_task_id, nil)
         |> reload_conversation()}

      {:error, :unauthorized} ->
        {:noreply, access_revoked(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete task")}
    end
  end

  @impl true
  def handle_info({:message_added, _id}, socket) do
    {:noreply, reload_conversation(socket)}
  end

  # Broadcast by Email.Outbound when async delivery resolves, so the
  # pending/sent/failed indicator updates without a manual refresh.
  def handle_info({:message_updated, _id}, socket) do
    {:noreply, reload_conversation(socket)}
  end

  def handle_info({:conversation_updated, id}, socket) do
    if id == socket.assigns.conversation.id do
      {:noreply, reload_conversation(socket)}
    else
      {:noreply, socket}
    end
  end

  # Nil-org conversations subscribe to the global "conversations" topic (see
  # mount_conversation/3), which also carries :conversation_created for every
  # new inbound email — never relevant to an already-open conversation.
  def handle_info({:conversation_created, _id}, socket) do
    {:noreply, socket}
  end

  # Catch-all for unexpected PubSub messages to prevent LiveView crashes
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp broadcast_conversation_update(id, organization_id) do
    Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_updated, id})
    Conversations.broadcast_to_org(organization_id, {:conversation_updated, id})
  end

  defp handle_convert_result({:ok, _conversation}, socket) do
    {:noreply,
     socket
     |> assign(:show_convert_form, false)
     |> put_flash(:info, "Converted to a new organization")
     |> reload_conversation()}
  end

  defp handle_convert_result({:error, :already_converted}, socket) do
    {:noreply,
     socket
     |> assign(:show_convert_form, false)
     |> put_flash(:error, "This conversation was already converted")
     |> reload_conversation()}
  end

  defp handle_convert_result({:error, :not_convertible}, socket) do
    {:noreply, put_flash(socket, :error, "This conversation cannot be converted")}
  end

  defp handle_convert_result({:error, %Ecto.Changeset{} = changeset}, socket) do
    {:noreply,
     put_flash(socket, :error, "Failed to convert: #{format_changeset_errors(changeset)}")}
  end

  # Prefill only — never auto-set: freemail domains would match-link every
  # same-domain prospect if the operator submitted the form unedited, so
  # both fields stay plain editable text inputs.
  defp prefill_convert_form(conversation) do
    slug = Slugs.get_claim_for_conversation(conversation.id)
    prospect = conversation.prospect

    %{
      name: (slug && slug.slug) || "",
      domain: email_domain(prospect && prospect.email)
    }
  end

  defp email_domain(nil), do: ""

  defp email_domain(email) do
    case String.split(email, "@") do
      [_local, domain] -> domain
      _ -> ""
    end
  end

  # Find a message by id within the already-loaded conversation thread.
  # Inherently conversation-scoped: an id belonging to another conversation
  # simply isn't in the list.
  defp find_conversation_message(conversation, id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> Enum.find(conversation.messages, &(&1.id == int_id))
      _ -> nil
    end
  end

  # Resolve a task id from the UI against this conversation and run `fun`
  # with it. A task that was deleted from another session (nothing
  # broadcasts task deletions, so the row stays on screen), an id from
  # another conversation, or a malformed id ends in a flash and a reload
  # rather than a raise that would crash the LiveView and drop any draft
  # reply or note the operator was typing.
  defp with_scoped_task(socket, task_id, fun) do
    case scoped_task(socket, task_id) do
      %Custyard.Task{} = task ->
        fun.(task)

      nil ->
        {:noreply,
         socket
         |> assign(:editing_task_id, nil)
         |> put_flash(:error, "That task no longer exists")
         |> reload_conversation()}
    end
  end

  defp scoped_task(socket, task_id) when is_binary(task_id) do
    case Integer.parse(task_id) do
      {int_id, ""} -> scoped_task(socket, int_id)
      _ -> nil
    end
  end

  defp scoped_task(socket, task_id) when is_integer(task_id) do
    conversation_id = socket.assigns.conversation.id

    case Custyard.Repo.get(Custyard.Task, task_id) do
      %Custyard.Task{conversation_id: ^conversation_id} = task -> task
      _ -> nil
    end
  end

  defp scoped_task(_socket, _task_id), do: nil

  defp load_conversation(scope, id) do
    Conversations.get_with_messages(scope, id)
  rescue
    Ecto.NoResultsError -> nil
    Ecto.Query.CastError -> nil
  end

  # A LiveView stays connected after mount. Check the current database row before
  # every client event so a prospect linked to another organization cannot keep
  # mutating it through an already-open socket.
  defp authorize_conversation_event(_event, _params, socket) do
    conversation = Conversations.get(socket.assigns.current_scope, socket.assigns.conversation.id)

    if conversation &&
         Authorization.can_access_conversation?(socket.assigns.current_operator, conversation) do
      {:cont, socket}
    else
      {:halt, access_revoked(socket)}
    end
  end

  defp conversation_mutation(socket, fun) do
    Conversations.with_access(
      socket.assigns.current_scope,
      socket.assigns.conversation.id,
      fun
    )
  end

  defp access_revoked(socket) do
    socket
    |> put_flash(:error, "You no longer have access to this conversation")
    |> push_navigate(to: ~p"/app")
  end

  defp begin_attachment_recovery(socket) do
    id = socket.assigns.conversation.id
    start_async(socket, :recover_attachments, fn -> Recovery.recover(id) end)
  end

  @impl true
  def handle_async(:recover_attachments, {:ok, :ok}, socket) do
    {:noreply, reload_conversation(socket)}
  end

  def handle_async(:recover_attachments, _result, socket) do
    {:noreply,
     socket
     |> reload_conversation()
     |> put_flash(
       :error,
       "Some attachments could not be recovered. Retry while the provider still retains the original delivery (28 days)."
     )}
  end

  defp reload_conversation(socket) do
    case load_conversation(socket.assigns.current_scope, socket.assigns.conversation.id) do
      nil ->
        # Conversation was deleted - redirect to queue
        socket
        |> put_flash(:error, "Conversation no longer exists")
        |> push_navigate(to: ~p"/app")

      conversation ->
        if Authorization.can_access_conversation?(socket.assigns.current_operator, conversation) do
          breakdown = Scoring.breakdown(conversation)
          neglect_status = Scoring.neglect_status(conversation)
          other_conversations = fetch_other_org_conversations(conversation)

          socket
          |> assign(:conversation, conversation)
          |> assign_labels(conversation)
          |> assign_reply_delivery(conversation)
          |> assign_reply_identity(conversation)
          |> assign_reply_cc(conversation)
          |> assign(:breakdown, breakdown)
          |> assign(:neglect_status, neglect_status)
          |> assign(:other_conversations, other_conversations)
        else
          access_revoked(socket)
        end
    end
  end

  # The consent advisory keys on :prospect_no_consent specifically — a
  # public-intake conversation with no captured email (or revoked conversation
  # access) has no opt-in to speak of, and that state is conveyed by the
  # reply-channel badge instead.
  defp assign_reply_delivery(socket, conversation) do
    reply_delivery = Conversations.reply_delivery(conversation)

    socket
    |> assign(:reply_delivery, reply_delivery)
    |> assign(:reply_will_email?, reply_delivery in [:contact, :prospect_opted_in])
    |> assign(:reply_recipient, reply_recipient(conversation))
  end

  # The To of the next reply, from the resolver delivery uses, so the
  # composer never shows an address the reply will not go to.
  defp reply_recipient(conversation) do
    case Outbound.reply_recipient(conversation) do
      {:ok, address} -> %{address: address, reply_to?: reply_to_override?(conversation, address)}
      {:error, _reason} -> nil
    end
  end

  # Email threads follow their latest participant or Reply-To. A prospect's
  # recipient remains the address for which consent was captured.
  defp reply_to_override?(conversation, address) do
    case Conversations.reply_channel(conversation) do
      {:contact, email} -> String.downcase(address) != String.downcase(email)
      _other -> false
    end
  end

  # Ground truth for this message: :withheld is only ever set by the
  # public-intake consent gate at send time, so this can't be fooled by a
  # consent flip that happens before the reload runs. The reply-box advisory
  # already explains the withheld delivery for public-intake conversations.
  defp flash_undeliverable_reply(socket, message) do
    cond do
      message.delivery_status == :withheld ->
        socket

      socket.assigns.reply_will_email? ->
        socket

      socket.assigns.conversation.source == :public_intake ->
        socket

      true ->
        put_flash(
          socket,
          :error,
          "Reply saved, but the contact has no email address so it cannot be delivered"
        )
    end
  end

  defp reply_error_message({:invalid_cc, :too_many}), do: "At most 20 CC addresses"

  defp reply_error_message({:invalid_cc, invalid}),
    do: "Invalid CC address: #{Enum.join(invalid, ", ")}"

  defp reply_error_message(_reason), do: "Failed to send reply"

  # Reply-all CC the composer starts from (spec-inbound-channels D5). A list
  # the operator has edited survives a reload triggered by an incoming
  # message; an untouched one follows the latest customer message.
  defp assign_reply_cc(%{assigns: %{reply_cc_edited?: true}} = socket, _conversation),
    do: socket

  defp assign_reply_cc(socket, conversation) do
    cc =
      Conversations.default_reply_cc(conversation,
        operator_email: socket.assigns.current_operator.email
      )

    assign(socket, :reply_cc, Enum.join(cc, ", "))
  end

  # The From identity the next reply will carry (spec-inbound-channels D3).
  # The platform fallback has no address of its own on the conversation, so
  # the configured instance sender is shown instead.
  defp assign_reply_identity(socket, conversation) do
    identity =
      Conversations.reply_identity(conversation,
        operator_email: socket.assigns.current_operator.email
      )

    identity =
      case identity do
        %{source: :platform, address: nil} = id ->
          %{
            id
            | address:
                Application.get_env(:custyard, :email_from_address, "support@custyard.local")
          }

        id ->
          id
      end

    socket
    |> assign(:reply_identity, identity)
    |> assign(:archive_copy_address, archive_copy_address(conversation))
  end

  # D4: the mailbox that receives a BCC of every reply, when the channel asks.
  defp archive_copy_address(%Conversation{
         inbound_channel: %Custyard.InboundChannel{archive_copy: true, public_address: address}
       }),
       do: address

  defp archive_copy_address(_conversation), do: nil

  defp fetch_other_org_conversations(%{organization_id: nil}), do: []

  defp fetch_other_org_conversations(conversation) do
    conversation.organization_id
    |> Conversations.list_for_organization(include_resolved: false)
    |> Enum.reject(&(&1.id == conversation.id))
    |> Enum.take(5)
  end

  # Truncate subject for page title (browser tab)
  defp truncate_subject(subject) when byte_size(subject) <= 50, do: subject

  defp truncate_subject(subject) do
    String.slice(subject, 0, 47) <> "..."
  end

  defp assign_labels(socket, conversation) do
    labels = Labels.for_conversation(socket.assigns.current_scope, conversation)

    socket
    |> assign(:available_labels, labels.available)
    |> assign(:conversation_labels, labels.assigned)
  end

  defp label_result({:ok, _}, socket), do: {:noreply, reload_conversation(socket)}

  defp label_result({:error, :unauthorized}, socket),
    do: {:noreply, put_flash(socket, :error, "You do not have permission to change these labels")}

  defp label_result({:error, %Ecto.Changeset{}}, socket),
    do: {:noreply, put_flash(socket, :error, "Use a unique label name of 1 to 40 characters")}

  defp label_result({:error, _}, socket),
    do: {:noreply, put_flash(socket, :error, "That label is not available for this organization")}

  defp task_error(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :due_at),
      do: "Enter a valid due date and time in UTC",
      else: "Enter a task title of 1 to 300 characters"
  end

  defp task_error(_), do: "Could not save the task"

  # Formats datetime for datetime-local input (displays as UTC)
  defp format_datetime_local(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%dT%H:%M")
  end

  # Keep the zone visible wherever a saved deadline is displayed.
  defp format_due_at(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0" data-testid="operator-conversation-page">
      <%!-- Left: message thread --%>
      <div class="flex-1 flex flex-col min-w-0" data-testid="operator-conversation-thread">
        <div class="border-b border-gray-200 dark:border-zinc-700 px-4 py-3 flex items-center gap-3 bg-white dark:bg-zinc-800">
          <.link
            navigate={~p"/app"}
            class="text-sm text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200"
            data-testid="operator-conversation-back"
          >
            &larr; Queue
          </.link>
          <span
            class="font-semibold text-gray-900 dark:text-zinc-100 truncate flex-1"
            data-testid="operator-conversation-subject"
          >
            {@conversation.subject}
          </span>
          <span
            :if={@conversation.inbound_channel}
            class="text-xs px-1.5 py-0.5 rounded bg-teal-50 dark:bg-teal-950 text-teal-700 dark:text-teal-300 truncate max-w-[14rem]"
            title={"Received on channel #{@conversation.inbound_channel.public_address}"}
            data-testid="conversation-channel"
          >
            {@conversation.inbound_channel.public_address}
          </span>
          <button
            :if={not @conversation.suspect and recoverable_attachments?(@conversation)}
            type="button"
            phx-click="retry_attachments"
            phx-disable-with="Recovering…"
            class="text-xs text-indigo-600 dark:text-indigo-400 hover:underline"
            data-testid="retry-attachments"
          >
            Retry attachment recovery
          </button>
          <span
            :if={@conversation.suspect}
            class="inline-flex items-center gap-1 text-xs px-1.5 py-0.5 rounded bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300"
            title="Triage flagged this conversation: notifications are suppressed until an operator clears it"
            data-testid="conversation-suspect-badge"
          >
            suspect
            <button
              phx-click="dismiss_suspect"
              class="underline hover:text-amber-950 dark:hover:text-amber-100"
              aria-label="Mark this conversation as not suspect"
              data-testid="dismiss-suspect"
            >
              Not suspect
            </button>
          </span>
          <span
            :if={@conversation.language}
            class="text-xs px-1.5 py-0.5 rounded bg-gray-100 dark:bg-zinc-700 text-gray-600 dark:text-zinc-300 uppercase"
            title={"Detected language: #{Custyard.Email.LanguageDetector.name(@conversation.language)}"}
            data-testid="conversation-language"
          >
            {@conversation.language}
          </span>
          <.source_badge source={@conversation.source} />
          <.state_badge state={@conversation.state} />
          <button
            phx-click="toggle_sidebar"
            class="lg:hidden text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200 p-1"
            aria-label="Toggle details panel"
            data-testid="operator-sidebar-toggle"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
          </button>
        </div>

        <div
          id="message-thread"
          phx-hook="ScrollBottom"
          class="flex-1 overflow-y-auto px-4 py-4 bg-gray-50 dark:bg-zinc-800 space-y-1"
          data-testid="operator-conversation-messages"
        >
          <div
            :if={@conversation.messages == []}
            class="text-center py-8 text-gray-500 dark:text-zinc-400"
            data-testid="operator-no-messages"
          >
            No messages yet
          </div>
          <%= for message <- @conversation.messages do %>
            <.message_bubble
              message={message}
              prospect_email={@conversation.prospect && @conversation.prospect.email}
            />
          <% end %>
        </div>

        <div class="border-t border-gray-200 dark:border-zinc-700 p-3 space-y-2 bg-white dark:bg-zinc-800">
          <%!-- Consent advisory: shown only when a prospect email was
          captured without the reply-notification opt-in. The reply still
          saves and stays visible via the conversation link, so sending is never
          blocked — the operator just knows up front that no email goes
          out. No-email and revoked states are covered by the reply-channel
          badge, not this opt-in wording. --%>
          <p
            :if={@reply_delivery == :prospect_no_consent}
            class="text-xs text-amber-600 dark:text-amber-400"
            data-testid="operator-reply-consent-advisory"
          >
            This prospect has not opted into email replies — replies are not
            emailed, but stay visible via their conversation link.
          </p>
          <p
            class="text-xs text-gray-500 dark:text-zinc-400 truncate"
            data-testid="composer-from-identity"
            data-identity-source={@reply_identity.source}
          >
            Replies go out as
            <span :if={@reply_identity.name} class="text-gray-700 dark:text-zinc-300">
              {@reply_identity.name}
            </span>
            <code class="text-gray-700 dark:text-zinc-300">&lt;{@reply_identity.address}&gt;</code>
            <span :if={@archive_copy_address} data-testid="composer-archive-copy">
              · a copy is kept in {@archive_copy_address}
            </span>
          </p>
          <form
            id="operator-reply-form"
            phx-submit="send_reply"
            phx-change="update_reply"
            class="space-y-1.5"
            data-testid="operator-reply-form"
          >
            <p
              :if={@reply_recipient}
              class="flex items-center gap-2 text-xs text-gray-500 dark:text-zinc-400"
              data-testid="operator-reply-to"
            >
              <span class="w-6">To</span>
              <code class="text-gray-700 dark:text-zinc-300 truncate">{@reply_recipient.address}</code>
              <span :if={@reply_recipient.reply_to?} data-testid="operator-reply-to-override">
                · from the latest customer message
              </span>
            </p>
            <%!-- Reply-all CC (spec-inbound-channels D5): visible and editable;
            hidden for prospect conversations, which never carry a CC. --%>
            <label
              :if={@conversation.source != :public_intake}
              class="flex items-center gap-2 text-xs text-gray-500 dark:text-zinc-400"
            >
              <span class="w-6">CC</span>
              <input
                type="text"
                name="cc"
                value={@reply_cc}
                placeholder="Nobody else"
                aria-label="CC addresses, comma separated"
                data-testid="operator-reply-cc"
                class="flex-1 border border-gray-200 dark:border-zinc-600 rounded px-2 py-1 text-xs dark:bg-zinc-700 dark:text-zinc-100"
              />
            </label>
            <div class="flex gap-2">
              <textarea
                name="body"
                rows="2"
                phx-hook="CtrlEnterSubmit"
                id="operator-reply-textarea"
                placeholder="Reply to customer... (Ctrl+Enter to send)"
                aria-label="Reply to customer"
                data-testid="operator-reply-input"
                class="flex-1 border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm resize-y dark:bg-zinc-700 dark:text-zinc-100"
              >{@reply_text}</textarea>
              <button
                type="submit"
                phx-disable-with="Sending..."
                class="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
                data-testid="operator-reply-submit"
              >
                Send
              </button>
            </div>
          </form>

          <form
            id="operator-note-form"
            phx-submit="add_note"
            class="flex gap-2"
            data-testid="operator-note-form"
          >
            <input
              type="text"
              name="body"
              value={@note_text}
              phx-change="update_note"
              phx-hook="CtrlEnterSubmit"
              id="operator-note-input"
              placeholder="Internal note (Ctrl+Enter to save)..."
              aria-label="Internal note (not visible to customer)"
              data-testid="operator-note-input"
              class="flex-1 border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-900/30 dark:text-zinc-100 rounded px-3 py-2 text-sm"
            />
            <button
              type="submit"
              phx-disable-with="Saving..."
              class="bg-amber-500 text-white text-sm px-4 py-2 rounded hover:bg-amber-600"
              data-testid="operator-note-submit"
            >
              Note
            </button>
          </form>
        </div>
      </div>

      <%!-- Mobile sidebar overlay --%>
      <div
        :if={@show_sidebar}
        class="lg:hidden fixed inset-0 z-40 bg-black/50"
        phx-click="toggle_sidebar"
        data-testid="operator-sidebar-backdrop"
      />

      <%!-- Right: metadata panel --%>
      <div
        class={[
          "w-72 border-l border-gray-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 overflow-y-auto",
          "lg:block lg:relative",
          if(@show_sidebar,
            do: "fixed right-0 top-0 bottom-0 z-50",
            else: "hidden"
          )
        ]}
        data-testid="operator-conversation-sidebar"
      >
        <%!-- Mobile close button --%>
        <div class="lg:hidden flex justify-between items-center p-3 border-b border-gray-200 dark:border-zinc-700">
          <span class="font-medium text-gray-700 dark:text-zinc-300">Details</span>
          <button
            phx-click="toggle_sidebar"
            class="text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200 p-1"
            aria-label="Close details panel"
            data-testid="operator-sidebar-close"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        </div>
        <div class="p-4 space-y-4">
          <%!-- Organization --%>
          <div data-testid="operator-sidebar-org">
            <div class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-1">
              Organization
            </div>
            <%= if @conversation.organization do %>
              <.link
                navigate={~p"/app/customers/#{@conversation.organization.id}"}
                class="text-sm text-indigo-600 hover:underline font-medium"
                data-testid="operator-sidebar-org-link"
              >
                {@conversation.organization.name}
              </.link>
              <div class="mt-1">
                <.tier_badge tier={@conversation.organization.tier} />
              </div>
            <% else %>
              <div
                class="text-sm font-medium text-gray-800 dark:text-zinc-200"
                data-testid="operator-sidebar-org-unlinked"
              >
                Unlinked prospect
              </div>
              <button
                :if={
                  @conversation.source == :public_intake and
                    Authorization.can_create_organization?(@current_operator) and
                    not @show_convert_form
                }
                phx-click="show_convert_form"
                class="mt-2 text-xs text-indigo-600 hover:underline"
                data-testid="operator-convert-prospect-btn"
              >
                Convert to organization
              </button>
              <form
                :if={@show_convert_form}
                id="operator-convert-form"
                phx-submit="convert_prospect"
                phx-change="validate_convert_form"
                class="mt-2 p-2 bg-gray-50 dark:bg-zinc-900 rounded border border-gray-200 dark:border-zinc-700 space-y-2"
                data-testid="operator-convert-form"
              >
                <input
                  type="text"
                  name="name"
                  value={@convert_form_data.name}
                  placeholder="Organization name"
                  aria-label="Organization name"
                  required
                  autofocus
                  class="w-full text-xs border border-gray-300 dark:border-zinc-600 rounded px-2 py-1 dark:bg-zinc-700 dark:text-zinc-100"
                  data-testid="operator-convert-name-input"
                />
                <input
                  type="text"
                  name="domain"
                  value={@convert_form_data.domain}
                  placeholder="Domain (optional)"
                  aria-label="Domain"
                  class="w-full text-xs border border-gray-300 dark:border-zinc-600 rounded px-2 py-1 dark:bg-zinc-700 dark:text-zinc-100"
                  data-testid="operator-convert-domain-input"
                />
                <div class="flex gap-2">
                  <button
                    type="submit"
                    phx-disable-with="Converting..."
                    class="text-xs bg-indigo-600 text-white px-2 py-1 rounded hover:bg-indigo-700"
                    data-testid="operator-convert-submit"
                  >
                    Convert
                  </button>
                  <button
                    type="button"
                    phx-click="hide_convert_form"
                    class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200"
                    data-testid="operator-convert-cancel"
                  >
                    Cancel
                  </button>
                </div>
              </form>
            <% end %>
          </div>

          <%!-- Contact --%>
          <div data-testid="operator-sidebar-contact">
            <div class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-1">
              Contact
            </div>
            <div class="text-sm text-gray-800 dark:text-zinc-200">
              {if @conversation.contact,
                do: @conversation.contact.name || @conversation.contact.email,
                else: "Unknown"}
            </div>
            <%= if @conversation.contact && @conversation.contact.email do %>
              <div
                class="text-xs text-gray-500 dark:text-zinc-400"
                data-testid="operator-sidebar-contact-email"
              >
                {@conversation.contact.email}
              </div>
              <div :if={@conversation.contact.email_status != :valid} class="mt-1">
                <.email_status_badge status={@conversation.contact.email_status} />
              </div>
            <% end %>
          </div>

          <%!-- State actions --%>
          <div>
            <div class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-2">
              Actions
            </div>
            <div class="space-y-1.5" data-testid="operator-state-actions">
              <%= if @conversation.state == :resolved do %>
                <button
                  phx-click="set_state"
                  phx-value-state="active"
                  class="w-full text-left text-sm px-3 py-1.5 rounded bg-blue-50 hover:bg-blue-100 text-blue-800 border border-blue-200"
                  data-testid="operator-state-reopen"
                >
                  Reopen
                </button>
              <% else %>
                <%!-- Toggle: clicking while already :waiting reverts to :active
                (a valid state-machine transition), so a mis-click is undoable
                in place. aria-pressed + solid styling mark the active state. --%>
                <button
                  phx-click="set_state"
                  phx-value-state={if @conversation.state == :waiting, do: "active", else: "waiting"}
                  aria-pressed={to_string(@conversation.state == :waiting)}
                  class={[
                    "w-full text-left text-sm px-3 py-1.5 rounded border",
                    if(@conversation.state == :waiting,
                      do:
                        "bg-yellow-200 hover:bg-yellow-100 text-yellow-900 border-yellow-400 font-medium",
                      else: "bg-yellow-50 hover:bg-yellow-100 text-yellow-800 border-yellow-200"
                    )
                  ]}
                  data-testid="operator-state-waiting"
                >
                  {if @conversation.state == :waiting,
                    do: "Waiting on customer — click to resume",
                    else: "Waiting on customer"}
                </button>
                <button
                  phx-click="set_state"
                  phx-value-state="resolved"
                  data-confirm="Mark this conversation as resolved?"
                  class="w-full text-left text-sm px-3 py-1.5 rounded bg-green-50 hover:bg-green-100 text-green-800 border border-green-200"
                  data-testid="operator-state-resolved"
                >
                  Mark resolved
                </button>
              <% end %>
            </div>
          </div>

          <section
            :if={@conversation.tenant_id}
            class="mb-5"
            data-testid="operator-labels-section"
          >
            <h3 class="text-xs font-semibold text-gray-500 dark:text-zinc-400 mb-2">Labels</h3>
            <div class="flex flex-wrap gap-1 mb-2">
              <span
                :for={label <- @conversation_labels}
                class="inline-flex items-center gap-1 rounded bg-indigo-50 dark:bg-indigo-950 px-2 py-1 text-xs"
                data-testid={"conversation-label-#{label.id}"}
              >
                {label.name}
                <button
                  type="button"
                  phx-click="remove_label"
                  phx-value-id={label.id}
                  aria-label={"Remove label #{label.name}"}
                >×</button>
              </span>
              <span :if={@conversation_labels == []} class="text-xs text-gray-500">No labels</span>
            </div>
            <form
              :if={@available_labels != []}
              id="assign-label-form"
              phx-submit="assign_label"
              class="flex gap-1 mb-2"
            >
              <select
                name="label_id"
                aria-label="Label to add"
                class="min-w-0 flex-1 rounded text-xs dark:bg-zinc-800"
              >
                <option :for={label <- @available_labels} value={label.id}>{label.name}</option>
              </select>
              <button type="submit" class="text-xs text-indigo-600">Add</button>
            </form>
            <form
              :if={@current_operator.role == "admin"}
              id="create-label-form"
              phx-submit="create_label"
              class="flex gap-1"
            >
              <input
                name="name"
                type="text"
                required
                maxlength="40"
                placeholder="New label"
                aria-label="New label name"
                class="min-w-0 flex-1 rounded text-xs dark:bg-zinc-800"
              />
              <button type="submit" class="text-xs text-indigo-600">Create</button>
            </form>
            <p class="mt-1 text-xs text-gray-500">
              Labels are internal and shared across your workspace.
            </p>
          </section>

          <%!-- Tasks --%>
          <div>
            <div
              class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-2"
              data-testid="operator-tasks-section"
            >
              Tasks ({length(@conversation.tasks)})
            </div>
            <%= if Enum.empty?(@conversation.tasks) do %>
              <div class="text-xs text-gray-400 dark:text-zinc-500">No tasks yet</div>
            <% else %>
              <div class="space-y-2">
                <%= for task <- @conversation.tasks do %>
                  <%= if @editing_task_id == task.id do %>
                    <.task_edit_form
                      task={task}
                      title={@edit_task_title}
                      due_at={@edit_task_due_at}
                      portal_visible={@edit_task_portal_visible}
                    />
                  <% else %>
                    <.task_item task={task} />
                  <% end %>
                <% end %>
              </div>
            <% end %>

            <%= if @show_task_form do %>
              <form
                id="operator-conversation-task-form"
                phx-submit="add_task"
                phx-change="update_new_task"
                class="mt-3 space-y-2 p-2 bg-gray-50 dark:bg-zinc-800 rounded border border-gray-200 dark:border-zinc-700"
                data-testid="operator-task-form"
              >
                <input
                  type="text"
                  name="title"
                  value={@new_task_title}
                  placeholder="Task title..."
                  aria-label="Task title"
                  class="w-full text-xs border border-gray-300 dark:border-zinc-600 rounded px-2 py-1"
                  autofocus
                  data-testid="operator-task-title-input"
                />
                <label class="block text-xs text-gray-600 dark:text-zinc-400" for="new-task-due-at">Due date and time (UTC)</label>
                <div class="flex gap-2">
                  <input
                    id="new-task-due-at"
                    type="datetime-local"
                    name="due_at"
                    value={@new_task_due_at}
                    aria-label="Due date and time (UTC)"
                    class="flex-1 text-xs border border-gray-300 dark:border-zinc-600 rounded px-2 py-1"
                    data-testid="operator-task-due-input"
                  />
                </div>
                <div class="flex items-center gap-2">
                  <input type="hidden" name="portal_visible" value="false" />
                  <input
                    type="checkbox"
                    name="portal_visible"
                    value="true"
                    checked={@new_task_portal_visible}
                    id="new_task_portal_visible"
                    class="h-3 w-3"
                    data-testid="operator-task-visible-checkbox"
                  />
                  <label
                    for="new_task_portal_visible"
                    class="text-xs text-gray-600 dark:text-zinc-400"
                  >
                    Visible in portal
                  </label>
                </div>
                <div class="flex gap-2">
                  <button
                    type="submit"
                    class="text-xs bg-indigo-600 text-white px-2 py-1 rounded hover:bg-indigo-700"
                    data-testid="operator-task-add-btn"
                  >
                    Add
                  </button>
                  <button
                    type="button"
                    phx-click="toggle_task_form"
                    class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200"
                    data-testid="operator-task-cancel-btn"
                  >
                    Cancel
                  </button>
                </div>
              </form>
            <% else %>
              <button
                phx-click="toggle_task_form"
                class="mt-2 text-xs text-indigo-600 hover:underline"
                data-testid="operator-add-task-btn"
              >
                + Add task
              </button>
            <% end %>
          </div>

          <%!-- Other open conversations for this org --%>
          <div :if={@other_conversations != []} data-testid="operator-sidebar-other-conversations">
            <div class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-2">
              Other Open ({length(@other_conversations)})
            </div>
            <div class="space-y-1.5">
              <.link
                :for={conv <- @other_conversations}
                navigate={~p"/app/threads/#{conv.id}"}
                class="block text-sm text-gray-700 dark:text-zinc-300 hover:text-indigo-600 dark:hover:text-indigo-400 truncate"
                data-testid={"operator-other-conv-#{conv.id}"}
              >
                <span
                  class="inline-block w-2 h-2 rounded-full mr-1.5"
                  style={state_dot_color(conv.state)}
                />
                {conv.subject}
              </.link>
            </div>
          </div>

          <%!-- Neglect status --%>
          <%= if @neglect_status != :ok do %>
            <div data-testid="operator-sidebar-neglect">
              <div class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-1">
                Status
              </div>
              <.neglect_badge level={@neglect_status} />
            </div>
          <% end %>

          <%!-- Score breakdown --%>
          <.score_breakdown breakdown={@breakdown} />
        </div>
      </div>
    </div>
    """
  end

  attr :message, Message, required: true
  attr :prospect_email, :string, default: nil

  defp message_bubble(assigns) do
    message = assigns.message
    is_operator = message.source == :operator
    is_internal = message.is_internal_note
    is_deleted = Message.deleted?(message)
    # Provider confirmations, vacation responders and other auto-replies
    # (spec-inbound-channels D6) read as system messages, not as the customer.
    is_system = message.triage_class == :auto_response and not is_internal

    bg_class =
      cond do
        is_internal ->
          "bg-amber-50 dark:bg-amber-900/30 border-amber-200 dark:border-amber-700"

        is_system ->
          "bg-gray-50 dark:bg-zinc-900 border-dashed border-gray-200 dark:border-zinc-700 text-gray-500 dark:text-zinc-400"

        is_operator ->
          "bg-indigo-50 dark:bg-indigo-900/30 border-indigo-100 dark:border-indigo-700"

        true ->
          "bg-white dark:bg-zinc-800 border-gray-200 dark:border-zinc-700"
      end

    assigns =
      assigns
      |> assign(:is_operator, is_operator)
      |> assign(:is_internal, is_internal)
      |> assign(:is_deleted, is_deleted)
      |> assign(:is_system, is_system)
      |> assign(:show_details, message.source == :email and not is_deleted)
      |> assign(:bg_class, bg_class)
      |> assign(:recipient_failures, secondary_recipient_failures(message))

    ~H"""
    <div
      class={"flex #{if @is_operator, do: "justify-end", else: "justify-start"} mb-3"}
      data-testid={"operator-message-#{@message.id}"}
    >
      <div
        class={"max-w-lg rounded-lg px-4 py-2.5 border #{@bg_class}"}
        data-testid={"operator-message-#{if @is_internal, do: "internal", else: to_string(@message.source)}"}
      >
        <div class="flex items-center gap-2 mb-1">
          <span
            class={"text-xs font-medium #{if @is_operator, do: "text-indigo-700", else: "text-gray-700 dark:text-zinc-300"}"}
            data-testid="operator-message-sender"
          >
            {sender_name(@message)}
          </span>
          <%= if @is_internal do %>
            <span
              class="text-xs bg-amber-200 text-amber-800 px-1.5 py-0.5 rounded"
              data-testid="operator-message-internal-badge"
            >
              internal note
            </span>
          <% end %>
          <span
            :if={@is_system}
            class="text-xs bg-gray-200 dark:bg-zinc-700 text-gray-700 dark:text-zinc-300 px-1.5 py-0.5 rounded"
            title="Classified as an automatic reply; not counted as a customer message"
            data-testid="message-system-tag"
          >
            auto-reply
          </span>
          <span
            :if={@message.triage_class == :suspect and not @is_internal}
            class="text-xs bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300 px-1.5 py-0.5 rounded"
            title="Triage flagged this message as suspect"
            data-testid="message-suspect-tag"
          >
            suspect
          </span>
          <span
            :if={@message.triage_class == :operator_sent}
            class="text-xs bg-indigo-100 dark:bg-indigo-950 text-indigo-800 dark:text-indigo-300 px-1.5 py-0.5 rounded"
            title="Sent from the operator's mailbox, outside Custyard, and captured from the forwarded copy"
            data-testid="message-operator-sent-tag"
          >
            sent from mailbox
          </span>
          <span
            :if={@message.triage_class == :operator_forward}
            class="text-xs bg-gray-200 dark:bg-zinc-700 text-gray-700 dark:text-zinc-300 px-1.5 py-0.5 rounded"
            title={"Forwarded into Custyard by #{@message.forwarded_by_email}"}
            data-testid="message-forwarded-tag"
          >
            forwarded by {@message.forwarded_by_email}
          </span>
          <span class="text-xs text-gray-400 dark:text-zinc-500">
            {unless @is_internal, do: via_label(@message.source, @prospect_email)}
          </span>
          <span
            class="text-xs text-gray-400 dark:text-zinc-500 ml-auto"
            data-testid="operator-message-time"
          >
            {format_time(@message.inserted_at)}
          </span>
          <.delivery_indicator
            :if={@is_operator and not @is_internal and not @is_deleted and @message.delivery_status}
            status={@message.delivery_status}
            failure_kind={@message.delivery_failure_kind}
          />
          <button
            :if={not @is_deleted}
            phx-click="delete_message"
            phx-value-id={@message.id}
            data-confirm="Delete this message? A tombstone stays visible in the thread and the customer can no longer read it."
            class="text-gray-300 dark:text-zinc-600 hover:text-red-600 dark:hover:text-red-400"
            title="Delete message"
            aria-label="Delete message"
            data-testid={"operator-message-delete-#{@message.id}"}
          >
            <.icon name="hero-trash" class="h-3 w-3" />
          </button>
        </div>
        <div
          :if={
            @is_operator and not @is_internal and not @is_deleted and
              @message.delivery_status == :failed
          }
          class="mb-2 text-xs text-amber-800 dark:text-amber-300"
          data-testid={"reply-recovery-#{@message.id}"}
        >
          <%= if @message.delivery_failure_kind == :unknown do %>
            Delivery outcome unknown. Check the provider's activity before sending another copy.
          <% else %>
            <%= if Outbound.retryable?(@message) do %>
              Reply not sent. Correct the email setup, then <button
                type="button"
                phx-click="retry_reply"
                phx-value-id={@message.id}
                class="underline font-medium"
                data-testid={"retry-reply-#{@message.id}"}
              >Retry reply</button>.
            <% else %>
              Reply needs attention. Check the provider's activity before sending another copy.
            <% end %>
          <% end %>
        </div>
        <%!-- The indicator above follows the customer's copy; a CC or archive
        copy that failed is listed here so it never hides that delivery. --%>
        <div
          :for={failure <- @recipient_failures}
          :if={@is_operator and not @is_internal and not @is_deleted}
          class="mb-1 text-xs text-amber-700 dark:text-amber-400"
          data-testid="delivery-recipient-failure"
        >
          {recipient_failure_text(failure)}
        </div>
        <div
          :if={@is_deleted}
          class="text-sm italic text-gray-400 dark:text-zinc-500"
          data-testid="operator-message-tombstone"
        >
          This message was deleted
        </div>
        <%= if not @is_deleted and @message.html_body do %>
          <%!-- Sanitised at ingest by Custyard.Email.HtmlSanitizer (D9); the
          stored markup is the allowlisted output, never provider HTML. --%>
          <div
            class="email-html text-sm break-words text-gray-800 dark:text-zinc-200"
            data-testid="operator-message-html"
          >
            {Phoenix.HTML.raw(InlineImages.render(@message.html_body, message_attachments(@message)))}
          </div>
          <details class="mt-1 text-xs text-gray-500 dark:text-zinc-400">
            <summary class="cursor-pointer select-none">Plain text</summary>
            <div class="mt-1 whitespace-pre-wrap break-words" data-testid="operator-message-body">
              {@message.body}
            </div>
          </details>
        <% end %>
        <div
          :if={not @is_deleted and is_nil(@message.html_body)}
          class={[
            "text-sm whitespace-pre-wrap break-words",
            if(@is_system,
              do: "text-gray-500 dark:text-zinc-400 italic",
              else: "text-gray-800 dark:text-zinc-200"
            )
          ]}
          data-testid="operator-message-body"
        >
          {@message.body}
        </div>
        <.attachment_list :if={not @is_deleted} attachments={message_attachments(@message)} />
        <p
          :if={
            @is_operator and not @is_internal and not @is_deleted and
              @message.cc_addresses not in [nil, []]
          }
          class="mt-1 text-xs text-gray-400 dark:text-zinc-500 break-all"
          data-testid="operator-message-cc"
        >
          CC {Enum.join(@message.cc_addresses, ", ")}
        </p>
        <.message_details :if={@show_details} message={@message} />
      </div>
    </div>
    """
  end

  defp recoverable_attachments?(conversation) do
    Enum.any?(conversation.messages, fn message ->
      Enum.any?(
        message_attachments(message),
        &(&1.skip_reason == "suspect" or &1.state in [:failed, :pending])
      )
    end)
  end

  # Attachments are preloaded by Conversations.get_with_messages/1; a message
  # reached through another loader renders without them rather than raising.
  defp message_attachments(%Message{attachments: attachments}) when is_list(attachments),
    do: attachments

  defp message_attachments(_message), do: []

  # Fetched attachments link to the authenticated download (spec D9); the
  # rest are listed so the operator knows they existed and why they were
  # not fetched.
  attr :attachments, :list, required: true

  defp attachment_list(%{attachments: []} = assigns), do: ~H""

  defp attachment_list(assigns) do
    ~H"""
    <ul class="mt-2 space-y-0.5 text-xs" data-testid="message-attachments">
      <li :for={att <- @attachments} class="flex flex-wrap items-center gap-x-1.5">
        <.icon name="hero-paper-clip" class="h-3 w-3 text-gray-400 dark:text-zinc-500" />
        <%= if att.state == :fetched do %>
          <a
            href={~p"/app/attachments/#{att.id}"}
            class="text-indigo-600 dark:text-indigo-400 hover:underline break-all"
            data-testid={"attachment-#{att.id}"}
          >
            {att.filename || "attachment"}
          </a>
          <span class="text-gray-400 dark:text-zinc-500">
            {Attachments.format_bytes(att.size)}
          </span>
        <% else %>
          <span
            class="text-gray-500 dark:text-zinc-400 break-all"
            data-testid={"attachment-#{att.id}"}
          >
            {att.filename || "attachment"}
          </span>
          <span
            class="text-gray-400 dark:text-zinc-500"
            title={attachment_skip_title(att.skip_reason)}
            data-testid={"attachment-skipped-#{att.id}"}
          >
            not fetched · {attachment_skip_label(att.skip_reason)}
          </span>
        <% end %>
      </li>
    </ul>
    """
  end

  defp attachment_skip_label("over_limit"), do: "over the channel size limit"
  defp attachment_skip_label("too_large"), do: "larger than declared"
  defp attachment_skip_label("suspect"), do: "suspect message"
  defp attachment_skip_label("disabled"), do: "fetching disabled on this channel"
  defp attachment_skip_label("no_url"), do: "provider sent no download link"
  defp attachment_skip_label("fetch_failed"), do: "download failed"
  defp attachment_skip_label(_reason), do: "not fetched"

  defp attachment_skip_title("suspect"),
    do:
      "Clearing the suspect flag requests recovery from the retained provider delivery; expired or unavailable files stay listed"

  defp attachment_skip_title(_reason),
    do: "The provider keeps the original for 28 days; fetch it there if you need it"

  # Envelope data for email messages (spec-inbound-channels D5): collapsed by
  # default so the thread stays readable; the authentication badge is the
  # trust signal operators are told to read before acting on a request.
  attr :message, Message, required: true

  defp message_details(assigns) do
    message = assigns.message

    reply_to =
      if is_binary(message.reply_to) and message.reply_to != "" and
           String.downcase(message.reply_to) != String.downcase(message.sender_email || ""),
         do: message.reply_to

    assigns = assign(assigns, :reply_to, reply_to)

    ~H"""
    <details class="mt-2 text-xs text-gray-500 dark:text-zinc-400" data-testid="message-details">
      <summary class="cursor-pointer select-none inline-flex items-center gap-2">
        <span>Details</span>
        <.auth_badge authentication={@message.authentication} />
      </summary>
      <dl class="mt-1.5 grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 break-all">
        <dt class="font-medium">From</dt>
        <dd data-testid="message-from">{@message.sender_email || "unknown"}</dd>
        <dt class="font-medium">To</dt>
        <dd data-testid="message-to">{Enum.join(@message.to_addresses || [], ", ")}</dd>
        <%= if @message.cc_addresses not in [nil, []] do %>
          <dt class="font-medium">CC</dt>
          <dd data-testid="message-cc">{Enum.join(@message.cc_addresses, ", ")}</dd>
        <% end %>
        <%= if @reply_to do %>
          <dt class="font-medium">Reply-To</dt>
          <dd data-testid="message-reply-to">{@reply_to}</dd>
        <% end %>
        <%= if @message.spam_score do %>
          <dt class="font-medium">Spam score</dt>
          <dd data-testid="message-spam-score">{@message.spam_score}</dd>
        <% end %>
      </dl>
    </details>
    """
  end

  # DKIM is the signal that survives forwarding; SPF evaluates the forwarder
  # and is not shown (spec-inbound-channels, "Forwarding provider behaviour").
  attr :authentication, :any, required: true

  defp auth_badge(assigns) do
    {colors, label, result} =
      case assigns.authentication do
        nil ->
          {"bg-gray-100 dark:bg-zinc-700 text-gray-600 dark:text-zinc-300", "no auth data",
           "none"}

        %{"dkim" => "pass"} = auth ->
          domain = auth["dkim_domain"]

          {"bg-green-100 dark:bg-green-950 text-green-800 dark:text-green-300",
           if(domain, do: "DKIM pass · #{domain}", else: "DKIM pass"), "pass"}

        %{"dkim" => dkim} when is_binary(dkim) ->
          {"bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300", "DKIM fail",
           "fail"}

        _ ->
          {"bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300", "unauthenticated",
           "unauthenticated"}
      end

    assigns =
      assigns |> assign(:colors, colors) |> assign(:label, label) |> assign(:result, result)

    ~H"""
    <span
      class={"px-1.5 py-0.5 rounded #{@colors}"}
      title="DKIM result on the forwarded copy. A pass does not make a request safe to act on."
      data-testid="message-auth-badge"
      data-auth-result={@result}
    >
      {@label}
    </span>
    """
  end

  attr :status, :atom,
    required: true,
    values: [:pending, :sending, :sent, :delivered, :failed, :bounced, :suppressed, :withheld]

  attr :failure_kind, :atom, default: nil

  defp delivery_indicator(%{status: :failed, failure_kind: :unknown} = assigns) do
    ~H"""
    <span class="text-xs text-amber-700 dark:text-amber-300" data-testid="delivery-status-unknown">Delivery unknown</span>
    """
  end

  defp delivery_indicator(%{status: status} = assigns) when status in [:pending, :sending] do
    ~H"""
    <span
      class="inline-flex items-center text-xs text-gray-400 dark:text-zinc-500"
      title="Sending..."
      data-testid="delivery-status-pending"
    >
      <svg
        class="h-3.5 w-3.5 animate-spin"
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
      >
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
      </svg>
    </span>
    """
  end

  defp delivery_indicator(%{status: :sent} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center text-xs text-green-500 dark:text-green-400"
      title="Sent"
      data-testid="delivery-status-sent"
    >
      <svg
        class="h-3.5 w-3.5"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
      >
        <path
          fill-rule="evenodd"
          d="M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z"
          clip-rule="evenodd"
        />
      </svg>
    </span>
    """
  end

  defp delivery_indicator(%{status: :delivered} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center text-xs text-green-600 dark:text-green-400"
      title="Delivered to recipient's mail server"
      data-testid="delivery-status-delivered"
    >
      <svg
        class="h-3.5 w-3.5"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
      >
        <path
          fill-rule="evenodd"
          d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.857-9.809a.75.75 0 00-1.214-.882l-3.483 4.79-1.88-1.88a.75.75 0 10-1.06 1.061l2.5 2.5a.75.75 0 001.137-.089l4-5.5z"
          clip-rule="evenodd"
        />
      </svg>
    </span>
    """
  end

  defp delivery_indicator(%{status: :failed} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center text-xs text-red-500 dark:text-red-400"
      title="Delivery failed"
      data-testid="delivery-status-failed"
    >
      <svg
        class="h-3.5 w-3.5"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
      >
        <path
          fill-rule="evenodd"
          d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-8-5a.75.75 0 01.75.75v4.5a.75.75 0 01-1.5 0v-4.5A.75.75 0 0110 5zm0 10a1 1 0 100-2 1 1 0 000 2z"
          clip-rule="evenodd"
        />
      </svg>
    </span>
    """
  end

  defp delivery_indicator(%{status: :bounced} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center text-xs text-amber-500 dark:text-amber-400"
      title="Email bounced"
      data-testid="delivery-status-bounced"
    >
      <svg
        class="h-3.5 w-3.5"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
      >
        <path
          fill-rule="evenodd"
          d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495zM10 5a.75.75 0 01.75.75v3.5a.75.75 0 01-1.5 0v-3.5A.75.75 0 0110 5zm0 9a1 1 0 100-2 1 1 0 000 2z"
          clip-rule="evenodd"
        />
      </svg>
    </span>
    """
  end

  defp delivery_indicator(%{status: :suppressed} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center text-xs text-purple-500 dark:text-purple-400"
      title="Suppressed by email provider"
      data-testid="delivery-status-suppressed"
    >
      <svg
        class="h-3.5 w-3.5"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
      >
        <path
          fill-rule="evenodd"
          d="M5.965 4.904l9.131 9.131a6.5 6.5 0 00-9.131-9.131zm8.07 10.192L4.904 5.965a6.5 6.5 0 009.131 9.131zM4.343 4.343a8 8 0 1111.314 11.314A8 8 0 014.343 4.343z"
          clip-rule="evenodd"
        />
      </svg>
    </span>
    """
  end

  defp delivery_indicator(%{status: :withheld} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center text-xs text-gray-400 dark:text-zinc-500"
      title="Not emailed — visible via conversation link"
      data-testid="delivery-status-withheld"
    >
      <svg
        class="h-3.5 w-3.5"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
      >
        <path
          fill-rule="evenodd"
          d="M10 18a8 8 0 100-16 8 8 0 000 16zM6.75 9.25a.75.75 0 000 1.5h6.5a.75.75 0 000-1.5h-6.5z"
          clip-rule="evenodd"
        />
      </svg>
    </span>
    """
  end

  # Failed CC and other secondary recipients of an outbound message, shown
  # apart from the indicator (spec-conversation-loop, "Delivery Tracking").
  defp secondary_recipient_failures(%Message{recipient_statuses: statuses})
       when is_list(statuses) do
    statuses
    |> Enum.filter(&(&1.role != :to and MessageRecipientStatus.failed?(&1)))
    |> Enum.sort_by(& &1.address)
  end

  defp secondary_recipient_failures(_message), do: []

  defp recipient_failure_text(%MessageRecipientStatus{role: :cc} = failure),
    do: "Not delivered to CC #{failure.address}: #{recipient_failure_word(failure.status)}"

  defp recipient_failure_text(%MessageRecipientStatus{} = failure),
    do: "Copy not delivered to #{failure.address}: #{recipient_failure_word(failure.status)}"

  defp recipient_failure_word(:bounced), do: "bounced"
  defp recipient_failure_word(:suppressed), do: "suppressed by the email provider"
  defp recipient_failure_word(:failed), do: "delivery failed"

  defp next_task_state(:open), do: "in progress"
  defp next_task_state(:in_progress), do: "done"
  defp next_task_state(:done), do: "open"
  defp next_task_state(_), do: "in progress"

  defp sender_name(message) do
    cond do
      message.triage_class == :operator_sent -> message.sender_email || "Operator"
      message.source == :operator -> "You"
      message.sender_email -> message.sender_email
      true -> "Customer"
    end
  end

  # Prospect messages surface the captured email (masked) so the operator can
  # see who they are talking to without exposing the full address on screen.
  # Falls back to the plain source label when no email was captured.
  defp via_label(:prospect, email) when is_binary(email) and email != "" do
    "via prospect #{mask_email(email)}"
  end

  defp via_label(source, _prospect_email), do: "via #{source}"

  # Keep up to the first 3 chars of the local part (just the first char when
  # the local part is 3 chars or fewer), then "***@domain".
  defp mask_email(email) do
    case String.split(email, "@", parts: 2) do
      [local, domain] -> "#{masked_local(local)}@#{domain}"
      [local] -> masked_local(local)
    end
  end

  defp masked_local(local) do
    keep = if String.length(local) > 3, do: 3, else: 1
    String.slice(local, 0, keep) <> "***"
  end

  defp format_time(datetime) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    diff_days = Date.diff(DateTime.to_date(now), DateTime.to_date(datetime))

    cond do
      diff_days == 0 -> Calendar.strftime(datetime, "%I:%M %p")
      diff_days == 1 -> Calendar.strftime(datetime, "Yesterday %I:%M %p")
      diff_days < 7 -> Calendar.strftime(datetime, "%a %I:%M %p")
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  attr :task, :map, required: true

  defp task_item(assigns) do
    ~H"""
    <div
      class="group flex items-start gap-2 text-sm p-1 rounded hover:bg-gray-50 dark:hover:bg-zinc-700"
      data-testid={"operator-task-item-#{@task.id}"}
    >
      <button
        phx-click="toggle_task"
        phx-value-id={@task.id}
        class="mt-0.5 shrink-0"
        title="Cycle state: open -> in_progress -> done"
        aria-label={"Task status: #{@task.state}. Click to change to #{next_task_state(@task.state)}."}
      >
        <.task_status_dot state={@task.state} />
      </button>
      <div class="flex-1 min-w-0">
        <span class={"text-gray-700 dark:text-zinc-300 #{if @task.state == :done, do: "line-through opacity-50"}"}>
          {@task.title}
        </span>
        <%= if @task.due_at do %>
          <div class="text-xs text-gray-400 dark:text-zinc-500">
            Due: {format_due_at(@task.due_at)}
          </div>
        <% end %>
      </div>
      <div class="flex items-center gap-1 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity">
        <%= if @task.portal_visible do %>
          <span
            class="text-xs text-gray-400 dark:text-zinc-500"
            title="Visible in portal"
            data-testid="operator-task-visible-icon"
          >
            <.icon name="hero-eye" class="h-3 w-3" />
          </span>
        <% else %>
          <span
            class="text-xs text-gray-300 dark:text-zinc-600"
            title="Hidden from portal"
            data-testid="operator-task-hidden-icon"
          >
            <.icon name="hero-eye-slash" class="h-3 w-3" />
          </span>
        <% end %>
        <button
          phx-click="edit_task"
          phx-value-id={@task.id}
          class="text-gray-400 dark:text-zinc-500 hover:text-indigo-600"
          title="Edit task"
          data-testid={"operator-task-edit-#{@task.id}"}
        >
          <.icon name="hero-pencil" class="h-3 w-3" />
        </button>
        <button
          phx-click="delete_task"
          phx-value-id={@task.id}
          data-confirm="Delete this task?"
          class="text-gray-400 dark:text-zinc-500 hover:text-red-600"
          title="Delete task"
          data-testid={"operator-task-delete-#{@task.id}"}
        >
          <.icon name="hero-trash" class="h-3 w-3" />
        </button>
      </div>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :title, :string, required: true
  attr :due_at, :string, required: true
  attr :portal_visible, :boolean, required: true

  defp task_edit_form(assigns) do
    ~H"""
    <form
      id={"operator-task-edit-form-#{@task.id}"}
      phx-submit="save_task"
      phx-change="update_edit_task"
      class="p-2 bg-indigo-50 dark:bg-indigo-900/30 rounded border border-indigo-200 dark:border-indigo-700 space-y-2"
      data-testid={"operator-task-edit-form-#{@task.id}"}
    >
      <input
        type="text"
        name="title"
        value={@title}
        placeholder="Task title..."
        aria-label="Task title"
        class="w-full text-xs border border-gray-300 dark:border-zinc-600 rounded px-2 py-1"
        autofocus
        data-testid="operator-task-edit-title"
      />
      <label
        for={"edit-task-due-at-#{@task.id}"}
        class="block text-xs text-gray-600 dark:text-zinc-400"
      >Due date and time (UTC)</label>
      <input
        id={"edit-task-due-at-#{@task.id}"}
        type="datetime-local"
        name="due_at"
        value={@due_at}
        aria-label="Due date and time (UTC)"
        class="w-full text-xs border border-gray-300 dark:border-zinc-600 rounded px-2 py-1"
        data-testid="operator-task-edit-due"
      />
      <div class="flex items-center gap-2">
        <input type="hidden" name="portal_visible" value="false" />
        <input
          type="checkbox"
          name="portal_visible"
          value="true"
          checked={@portal_visible}
          id={"edit_task_portal_visible_#{@task.id}"}
          class="h-3 w-3"
          data-testid="operator-task-edit-visible"
        />
        <label
          for={"edit_task_portal_visible_#{@task.id}"}
          class="text-xs text-gray-600 dark:text-zinc-400"
        >
          Visible in portal
        </label>
      </div>
      <div class="flex gap-2">
        <button
          type="submit"
          class="text-xs bg-indigo-600 text-white px-2 py-1 rounded hover:bg-indigo-700"
          data-testid="operator-task-edit-save"
        >
          Save
        </button>
        <button
          type="button"
          phx-click="cancel_edit_task"
          class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200"
          data-testid="operator-task-edit-cancel"
        >
          Cancel
        </button>
        <button
          type="button"
          phx-click="delete_task"
          phx-value-id={@task.id}
          data-confirm="Delete this task?"
          class="text-xs text-red-500 hover:text-red-700 ml-auto"
          data-testid="operator-task-edit-delete"
        >
          Delete
        </button>
      </div>
    </form>
    """
  end

  attr :state, :atom, required: true

  defp task_status_dot(assigns) do
    color =
      case assigns.state do
        :done -> "bg-green-400"
        :in_progress -> "bg-blue-400"
        :open -> "bg-gray-300 dark:bg-zinc-600"
        _ -> "bg-gray-300 dark:bg-zinc-600"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"w-2 h-2 rounded-full #{@color}"} data-testid={"operator-task-dot-#{@state}"} />
    """
  end

  defp state_dot_color(state) do
    color =
      case state do
        :new -> "#3B82F6"
        :active -> "#22C55E"
        :waiting -> "#EAB308"
        :dormant -> "#9CA3AF"
        :resolved -> "#D1D5DB"
        _ -> "#9CA3AF"
      end

    "background-color: #{color}"
  end
end
