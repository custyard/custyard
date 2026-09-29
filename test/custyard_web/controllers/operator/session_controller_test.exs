defmodule CustyardWeb.Operator.SessionControllerTest do
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory

  alias Custyard.{OperatorAccount, Repo}

  test "limits all login-link requests from one address, including successful redirects" do
    operator = insert_operator_account()
    ip = {10, 44, 3, 1}

    for _ <- 1..5 do
      assert request_login(ip, operator.email).status == 302
    end

    before_denied = Repo.get!(OperatorAccount, operator.id).login_token
    denied = request_login(ip, operator.email)

    assert denied.status == 429
    assert get_resp_header(denied, "retry-after") != []
    assert Repo.get!(OperatorAccount, operator.id).login_token == before_denied
  end

  test "limits requests to an address across client IPs without revealing account existence" do
    operator = insert_operator_account()

    for n <- 1..5 do
      assert request_login({10, 44, 4, n}, operator.email).status == 302
    end

    assert request_login({10, 44, 4, 6}, operator.email).status == 429

    unknown = "missing-#{System.unique_integer([:positive])}@example.com"

    for n <- 1..5 do
      assert request_login({10, 44, 5, n}, unknown).status == 302
    end

    assert request_login({10, 44, 5, 6}, unknown).status == 429
  end

  defp request_login(ip, email) do
    build_conn()
    |> Map.put(:remote_ip, ip)
    |> post("/operator/login", %{"email" => email})
  end
end
