defmodule CustyardWeb.Live.OperatorAuth do
  @moduledoc """
  LiveView on_mount hook for operator authentication and role-based authorization.

  Supports three mount modes:
  - `:default` - any authenticated operator
  - `:require_admin` - admin or super_admin only
  - `:require_super_admin` - super_admin only

  All modes assign `:current_operator`, `:scoped_organization_id`,
  `:current_role`, and `:is_super_admin` to the socket.

  A session is accepted only while the operator row with its id still has
  the session claim recorded at login (`session_operator/2`), checked on
  mount and again on every later event.

  An admin or agent without an organization (`OperatorAccount.orphaned?/1`,
  e.g. after their organization was deleted) is never authorized: on mount
  or on any later event they are sent to the login page with
  `no_organization_message/0`.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  alias Custyard.{Authorization, OperatorAccount, Repo, Tenants}

  @no_organization_message "No organization assigned; ask a super admin."

  @doc """
  Shown wherever an orphaned admin or agent is turned away.
  """
  def no_organization_message, do: @no_organization_message

  @doc """
  The operator a session belongs to, or nil.

  The session holds the operator id and, since login, the account's random
  session claim (`OperatorAccount.session_claim/1`). The id alone is not
  enough: SQLite reuses the highest id after a delete, so a removed
  operator's cookie would otherwise sign in as the next account created.
  A session without the claim (issued before it existed) is signed out.
  Shared by the `:require_operator` plug, this hook and the landing page.
  """
  def session_operator(operator_id, claim) do
    with id when not is_nil(id) <- operator_id,
         %OperatorAccount{} = operator <- Repo.get(OperatorAccount, id),
         true <- OperatorAccount.session_claim_matches?(operator, claim) do
      operator
    else
      _ -> nil
    end
  end

  def on_mount(:default, _params, session, socket) do
    authenticate(session, socket)
  end

  def on_mount(:require_admin, _params, session, socket) do
    authorize_role(session, socket, "admin")
  end

  def on_mount(:require_super_admin, _params, session, socket) do
    authorize_role(session, socket, "super_admin")
  end

  defp authorize_role(session, socket, required_role) do
    with {:cont, socket} <- authenticate(session, socket) do
      if Authorization.has_minimum_role?(socket.assigns.current_operator, required_role) do
        {:cont, socket}
      else
        {:halt,
         socket
         |> put_flash(:error, "Insufficient permissions")
         |> redirect(to: "/operator")}
      end
    end
  end

  defp authenticate(session, socket) do
    claim = session["operator_claim"]

    case session_operator(session["operator_id"], claim) do
      nil ->
        {:halt, redirect(socket, to: "/operator/login")}

      operator ->
        if OperatorAccount.orphaned?(operator) or
             not Tenants.operator_on_host?(operator, session["host_tenant_id"]) do
          {:halt, deny_no_organization(socket)}
        else
          # The claim captured here is what refresh_operator/1 compares
          # against: the id could be reused while this socket is open.
          {:cont,
           socket
           |> assign(:operator_id, operator.id)
           |> assign(:operator_session_claim, claim)
           |> assign(:selected_tenant_id, session["selected_tenant_id"])
           |> assign(:host_tenant_id, session["host_tenant_id"])
           |> assign_operator(operator)
           |> attach_refresh_hooks()}
        end
    end
  end

  defp deny_no_organization(socket) do
    socket
    |> put_flash(:error, @no_organization_message)
    |> redirect(to: "/operator/login")
  end

  defp assign_operator(socket, operator) do
    tenant_id =
      socket.assigns[:host_tenant_id] || operator.tenant_id ||
        (OperatorAccount.super_admin?(operator) && socket.assigns[:selected_tenant_id])

    tenant = (tenant_id && Tenants.get_tenant(tenant_id)) || Tenants.for_operator(operator)

    socket
    |> assign(:current_operator, operator)
    |> assign(:scoped_organization_id, OperatorAccount.scoped_organization_id(operator))
    |> assign(:current_role, operator.role)
    |> assign(:is_super_admin, operator.role == "super_admin")
    |> assign(:current_tenant, tenant)
    |> assign(:site_name, tenant.name)
  end

  defp attach_refresh_hooks(socket) do
    socket
    |> attach_hook(:refresh_operator_event, :handle_event, fn _event, _params, socket ->
      refresh_operator(socket)
    end)
    |> attach_hook(:refresh_operator_info, :handle_info, fn _message, socket ->
      refresh_operator(socket)
    end)
    |> attach_hook(:refresh_operator_params, :handle_params, fn _params, _uri, socket ->
      refresh_operator(socket)
    end)
    |> attach_hook(:refresh_operator_async, :handle_async, fn _name, _result, socket ->
      refresh_operator(socket)
    end)
  end

  defp refresh_operator(socket) do
    case session_operator(socket.assigns.operator_id, socket.assigns.operator_session_claim) do
      nil ->
        {:halt, redirect(socket, to: "/operator/login")}

      operator ->
        previous = socket.assigns.current_operator

        cond do
          # Organization deleted under an open view (ON DELETE SET NULL).
          OperatorAccount.orphaned?(operator) ->
            {:halt, deny_no_organization(socket)}

          operator.role == previous.role and operator.organization_id == previous.organization_id and
              operator.tenant_id == previous.tenant_id ->
            {:cont, assign_operator(socket, operator)}

          true ->
            # Remount under the new role and organization before any existing
            # view can render or act on resources loaded under the old scope.
            {:halt, redirect(socket, to: "/operator")}
        end
    end
  end
end
