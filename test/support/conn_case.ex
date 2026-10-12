defmodule CustyardWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CustyardWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint CustyardWeb.Endpoint

      use CustyardWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CustyardWeb.ConnCase
    end
  end

  setup tags do
    Custyard.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Puts an operator session the way login does: the operator id plus the
  account's creation-time claim (see
  `CustyardWeb.Live.OperatorAuth.session_operator/2`). Takes an operator
  or an id; an id without a row gets no claim. The session must already
  be initialized (`init_test_session/2`).
  """
  def put_operator_session(conn, %Custyard.OperatorAccount{} = operator) do
    conn
    |> Plug.Conn.put_session(:operator_id, operator.id)
    |> Plug.Conn.put_session(:operator_created, Custyard.OperatorAccount.session_claim(operator))
  end

  def put_operator_session(conn, operator_id) do
    case Custyard.Repo.get(Custyard.OperatorAccount, operator_id) do
      nil -> Plug.Conn.put_session(conn, :operator_id, operator_id)
      operator -> put_operator_session(conn, operator)
    end
  end
end
