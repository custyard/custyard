defmodule Custyard.Auth.LoginEmailTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory

  alias Custyard.Auth.LoginEmail
  alias Custyard.InstanceAdmins

  test "both account realms prepend a UTC timestamp with microsecond precision" do
    staff = insert_staff_account()

    {:created, admin} =
      InstanceAdmins.create_admin("instance-#{System.unique_integer([:positive])}@example.com")

    for account <- [staff, admin] do
      before_send = DateTime.utc_now(:microsecond)
      assert {:ok, _} = LoginEmail.deliver_login_link(account, "https://example.com/login/token")
      assert_receive {:email, email}
      assert email.to == [{"", account.email}]
      assert [_, timestamp] = Regex.run(~r/^\| (\S+) Your Custyard login link$/, email.subject)
      assert String.ends_with?(timestamp, "Z")
      assert {:ok, sent_at, 0} = DateTime.from_iso8601(timestamp)
      assert {_, 6} = sent_at.microsecond
      assert DateTime.compare(sent_at, before_send) in [:eq, :gt]
      assert DateTime.compare(sent_at, DateTime.utc_now(:microsecond)) in [:eq, :lt]
    end
  end

  test "successive deliveries have different subjects even when reusing the login URL" do
    staff = insert_staff_account()
    login_url = "https://example.com/login/same-token"

    assert {:ok, _} = LoginEmail.deliver_login_link(staff, login_url)
    assert_receive {:email, first}
    assert {:ok, _} = LoginEmail.deliver_login_link(staff, login_url)
    assert_receive {:email, second}

    refute first.subject == second.subject
    assert first.text_body == second.text_body
    assert first.html_body == second.html_body
  end
end
