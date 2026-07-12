defmodule CustyardWeb.ResumeLive do
  @moduledoc """
  The prospect-facing conversation view behind the resume token.

  `CustyardWeb.Live.ResumeAuth` authenticates the URL token on every mount
  and assigns the conversation; this module only renders and forwards
  mutations to `Custyard.Intake`. Enumeration neutrality is binding here:
  the page never renders organization or contact linkage — not the org name,
  not a tier, not a sender email — so the rendered result is byte-identical
  whether a captured email matched a contact, an org domain, or nothing.

  Every mutating event checks its rate bucket directly (plug limits never
  see websocket events): replies use `:resume_reply` keyed by the token hash
  (the abuse handle is the credential, not the network path), while email
  capture and the notification toggle share the IP-keyed `:email_capture`
  bucket — both are low-frequency prospect-preference writes from the same
  surface, and sharing the bucket bounds total mutation volume without
  inventing a new one.

  Token rotation is enforced against mounted sockets, not just fresh
  mounts: every mutation passes the mount-time `:token_hash` to the
  context, which refuses it once the stored hash rotates, and the
  `{:resume_access_changed, id}` broadcast from rotation/revocation makes
  the view re-authenticate — so an open tab on a rotated-away token stops
  receiving operator replies instead of streaming them until disconnect.
  """

  use CustyardWeb, :live_view

  alias Custyard.Email.Normalizer
  alias Custyard.{Conversations, Intake, RateLimit}

  @unavailable_path "/r/unavailable"

  @impl true
  def mount(_params, _session, socket) do
    # :conversation, :branding, :resume_token_hash, :client_ip come from
    # the ResumeAuth on_mount hook.
    conversation = socket.assigns.conversation

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{conversation.id}")
    end

    {:ok,
     socket
     |> assign(:page_title, "Your conversation")
     |> assign(:prospect, conversation.prospect)
     |> assign(:messages, conversation.messages)
     |> assign(:reply_form, empty_reply_form())
     |> assign(:email_form, empty_email_form())}
  end

  ## Events --------------------------------------------------------------------

  @impl true
  def handle_event("submit_reply", params, socket) do
    # Rate check first: every reply attempt counts, valid or not — the
    # anonymous surface must bound the flood, not just the successes.
    case RateLimit.check_rate(:resume_reply, socket.assigns.resume_token_hash) do
      {:deny, _retry_after_ms} ->
        {:noreply,
         put_flash(socket, :error, "You are replying too quickly. Please wait and try again.")}

      {:allow, _count} ->
        submit_reply(socket, reply_body(params))
    end
  end

  @impl true
  def handle_event("capture_email", params, socket) do
    case RateLimit.check_rate(:email_capture, socket.assigns.client_ip || "unknown") do
      {:deny, _retry_after_ms} ->
        {:noreply, put_flash(socket, :error, "Too many attempts. Please wait and try again.")}

      {:allow, _count} ->
        capture_email(socket, capture_params(params))
    end
  end

  @impl true
  def handle_event("toggle_notifications", params, socket) do
    # Shares :email_capture deliberately — see the moduledoc.
    case RateLimit.check_rate(:email_capture, socket.assigns.client_ip || "unknown") do
      {:deny, _retry_after_ms} ->
        {:noreply, put_flash(socket, :error, "Too many changes. Please wait and try again.")}

      {:allow, _count} ->
        toggle_notifications(socket, params["notify"] == "true")
    end
  end

  defp submit_reply(socket, body) do
    case validate_body(body) do
      :ok ->
        case Intake.add_prospect_reply(socket.assigns.conversation, body,
               token_hash: socket.assigns.resume_token_hash
             ) do
          {:ok, %{conversation: updated}} ->
            conversation = %{
              socket.assigns.conversation
              | state: updated.state,
                last_customer_action_at: updated.last_customer_action_at
            }

            {:noreply,
             socket
             |> assign(:conversation, conversation)
             |> assign(:messages, Conversations.list_public_messages(conversation.id))
             |> assign(:reply_form, empty_reply_form())
             |> put_flash(:info, "Reply sent.")}

          # Revoked, purged, or rotated-away mid-session: same uniform page
          # as any other failure class.
          {:error, :no_prospect} ->
            {:noreply, redirect(socket, to: @unavailable_path)}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, "Could not send your reply. Please try again.")}
        end

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp capture_email(socket, %{email: email, notify: notify}) do
    if is_binary(email) and String.trim(email) != "" do
      do_capture_email(socket, email, notify)
    else
      {:noreply, put_flash(socket, :error, "Enter an email address.")}
    end
  end

  defp do_capture_email(socket, email, notify) do
    conversation = socket.assigns.conversation

    case Intake.capture_email(conversation, email,
           notify: notify,
           token_hash: socket.assigns.resume_token_hash
         ) do
      # Enumeration-neutral by construction: capture_email returns {:ok, _}
      # regardless of whether the email matched a contact, an org domain, or
      # nothing — and nothing rendered below depends on the link outcome.
      {:ok, _conversation} ->
        {:noreply,
         socket
         |> assign(:prospect, Intake.get_prospect(conversation))
         |> assign(:email_form, empty_email_form())
         |> put_flash(:info, "Email saved.")}

      {:error, :no_prospect} ->
        {:noreply, redirect(socket, to: @unavailable_path)}

      {:error, :already_captured} ->
        {:noreply, assign(socket, :prospect, Intake.get_prospect(conversation))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "That email address doesn't look valid.")}
    end
  end

  defp toggle_notifications(socket, notify?) do
    case Intake.set_notification(socket.assigns.conversation, notify?,
           token_hash: socket.assigns.resume_token_hash
         ) do
      {:ok, prospect} ->
        {:noreply, assign(socket, :prospect, prospect)}

      {:error, :no_prospect} ->
        {:noreply, redirect(socket, to: @unavailable_path)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, "Could not update your preference.")}
    end
  end

  ## PubSub --------------------------------------------------------------------

  @impl true
  def handle_info({:message_added, _id}, socket) do
    {:noreply,
     assign(socket, :messages, Conversations.list_public_messages(socket.assigns.conversation.id))}
  end

  # Rotation or revocation happened while this socket was mounted:
  # re-authenticate the mount-time hash against the stored one and shut the
  # view down unless it still holds the live credential. This closes the
  # read side — without it a tab opened before rotation keeps receiving
  # operator replies over PubSub until it happens to disconnect.
  @impl true
  def handle_info({:resume_access_changed, _id}, socket) do
    prospect = Intake.get_prospect(socket.assigns.conversation)

    if prospect && is_nil(prospect.revoked_at) &&
         prospect.resume_token_hash == socket.assigns.resume_token_hash do
      {:noreply, assign(socket, :prospect, prospect)}
    else
      {:noreply, redirect(socket, to: @unavailable_path)}
    end
  end

  # Catch-all so unexpected PubSub messages never crash the view.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Param shaping and validation ----------------------------------------------

  defp reply_body(%{"reply" => %{"body" => body}}), do: body
  defp reply_body(_params), do: nil

  defp capture_params(%{"capture" => %{} = capture}) do
    %{email: capture["email"], notify: capture["notify"] == "true"}
  end

  defp capture_params(_params), do: %{email: nil, notify: false}

  # Same shape discipline as the intake POST: non-binary and oversized input
  # gets a structured error, never a crash.
  defp validate_body(body) when is_binary(body) do
    cond do
      String.trim(body) == "" ->
        {:error, "Reply cannot be empty."}

      byte_size(body) > Normalizer.max_body_length() ->
        {:error, "Reply is too long."}

      true ->
        :ok
    end
  end

  defp validate_body(_body), do: {:error, "Reply cannot be empty."}

  defp empty_reply_form, do: to_form(%{"body" => ""}, as: :reply)
  defp empty_email_form, do: to_form(%{"email" => "", "notify" => "false"}, as: :capture)

  ## Render --------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div data-testid="resume-conversation">
      <div class="flex items-start justify-between gap-4 mb-6">
        <h1
          class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100"
          data-testid="resume-subject"
        >
          {@conversation.subject}
        </h1>
        <span
          class={"shrink-0 text-sm px-3 py-1 rounded-full #{state_color(@conversation.state)}"}
          data-testid="resume-state"
        >
          {state_label(@conversation.state)}
        </span>
      </div>

      <div class="space-y-4 mb-8" data-testid="resume-messages">
        <div
          :for={msg <- @messages}
          class={"p-4 rounded-lg #{message_style(msg)}"}
          data-testid={"resume-message-#{msg.source}"}
        >
          <div class={"flex justify-between text-sm mb-2 #{metadata_text_style(msg)}"}>
            <span data-testid="resume-message-sender">{sender_label(msg)}</span>
            <span data-testid="resume-message-time">{format_time(msg.inserted_at)}</span>
          </div>
          <div
            class={"whitespace-pre-wrap break-words #{body_text_style(msg)}"}
            data-testid="resume-message-body"
          >
            {msg.body}
          </div>
        </div>
      </div>

      <.form
        for={@reply_form}
        phx-submit="submit_reply"
        class="bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg p-4"
        data-testid="resume-reply-form"
      >
        <.input
          field={@reply_form[:body]}
          type="textarea"
          label="Reply"
          rows="4"
          placeholder="Write a reply..."
        />
        <div class="flex justify-end mt-3">
          <button
            type="submit"
            phx-disable-with="Sending..."
            class="text-sm font-medium text-white px-4 py-2 rounded-lg shadow-sm hover:opacity-90 transition-opacity"
            style={"background-color: #{@branding.primary_color || "#4f46e5"}"}
            data-testid="resume-reply-submit"
          >
            Send reply
          </button>
        </div>
      </.form>

      <%= if @prospect.email do %>
        <div
          class="mt-6 bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg p-4"
          data-testid="resume-notify-toggle"
        >
          <form phx-change="toggle_notifications" data-testid="resume-notify-form">
            <label class="flex items-center gap-3 text-sm text-zinc-700 dark:text-zinc-300">
              <input type="hidden" name="notify" value="false" />
              <input
                type="checkbox"
                name="notify"
                value="true"
                checked={@prospect.notify_on_reply}
                class="rounded border-zinc-300 dark:border-zinc-600 text-zinc-900 focus:ring-0"
                data-testid="resume-notify-checkbox"
              /> Email me when the team replies
            </label>
          </form>
        </div>
      <% else %>
        <div
          class="mt-6 bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg p-4"
          data-testid="resume-email-prompt"
        >
          <p class="text-sm text-zinc-700 dark:text-zinc-300 mb-3">
            Leave an email address so we can reply even when you're not here.
          </p>
          <.form for={@email_form} phx-submit="capture_email" data-testid="resume-email-form">
            <.input field={@email_form[:email]} type="email" label="Email" autocomplete="email" />
            <div class="mt-3">
              <.input
                field={@email_form[:notify]}
                type="checkbox"
                label="Email me when the team replies"
              />
            </div>
            <div class="flex justify-end mt-3">
              <button
                type="submit"
                phx-disable-with="Saving..."
                class="text-sm font-medium text-white px-4 py-2 rounded-lg shadow-sm hover:opacity-90 transition-opacity"
                style={"background-color: #{@branding.primary_color || "#4f46e5"}"}
                data-testid="resume-email-submit"
              >
                Save email
              </button>
            </div>
          </.form>
        </div>
      <% end %>
    </div>
    """
  end

  ## Presentation helpers -------------------------------------------------------

  # Sender labels never include an email address or a name — org/contact
  # linkage must be invisible on this page.
  defp sender_label(%{source: :operator}), do: "Support Team"
  defp sender_label(%{source: :prospect}), do: "You"
  defp sender_label(_msg), do: "Customer"

  defp message_style(%{source: :operator}) do
    "bg-indigo-50 dark:bg-indigo-950 border-l-4 border-indigo-400 dark:border-indigo-600"
  end

  defp message_style(_msg), do: "bg-gray-50 dark:bg-zinc-800"

  defp metadata_text_style(%{source: :operator}), do: "text-indigo-700 dark:text-indigo-300"
  defp metadata_text_style(_msg), do: "text-gray-500 dark:text-zinc-400"

  defp body_text_style(%{source: :operator}), do: "text-indigo-900 dark:text-indigo-100"
  defp body_text_style(_msg), do: "text-gray-900 dark:text-zinc-100"

  defp format_time(datetime), do: Calendar.strftime(datetime, "%b %d, %H:%M")

  defp state_color(:new), do: "bg-blue-100 dark:bg-blue-950 text-blue-800 dark:text-blue-300"

  defp state_color(:active),
    do: "bg-green-100 dark:bg-green-950 text-green-800 dark:text-green-300"

  defp state_color(:waiting),
    do: "bg-yellow-100 dark:bg-yellow-950 text-yellow-800 dark:text-yellow-300"

  defp state_color(_state), do: "bg-gray-100 dark:bg-zinc-700 text-gray-800 dark:text-zinc-200"

  defp state_label(:new), do: "Open"
  defp state_label(:active), do: "In Progress"
  defp state_label(:waiting), do: "Awaiting Reply"
  defp state_label(:dormant), do: "On Hold"
  defp state_label(:resolved), do: "Closed"
  defp state_label(_state), do: "Unknown"
end
