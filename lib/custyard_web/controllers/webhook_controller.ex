defmodule CustyardWeb.WebhookController do
  use CustyardWeb, :controller

  alias Custyard.Email.Processor

  def inbound(conn, params) do
    case Processor.process(params) do
      {:ok, conversation} ->
        json(conn, %{status: "ok", conversation_id: conversation.id})

      {:error, reason} ->
        conn
        |> put_status(422)
        |> json(%{status: "error", reason: reason})
    end
  end
end
