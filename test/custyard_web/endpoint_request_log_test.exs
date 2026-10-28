defmodule CustyardWeb.EndpointRequestLogTest do
  use ExUnit.Case, async: true

  alias CustyardWeb.Endpoint

  test "requests whose path carries a bearer token are kept out of the request log" do
    assert Endpoint.request_log_level(%Plug.Conn{request_path: "/threads/resume-token"}) == false
    assert Endpoint.request_log_level(%Plug.Conn{request_path: "/claims/tok/confirm"}) == false
    assert Endpoint.request_log_level(%Plug.Conn{request_path: "/portal/org-token"}) == false

    assert Endpoint.request_log_level(%Plug.Conn{
             request_path: "/app/login/verify/login-token"
           }) ==
             false
  end

  test "other requests are logged at :info" do
    assert Endpoint.request_log_level(%Plug.Conn{request_path: "/"}) == :info
    assert Endpoint.request_log_level(%Plug.Conn{request_path: "/app/login"}) == :info
  end
end
