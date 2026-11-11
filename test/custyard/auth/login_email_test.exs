defmodule Custyard.Auth.LoginEmailTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory

  alias Custyard.Auth.LoginEmail
  alias Custyard.InstanceAdmins

  test "both account realms append a readable UTC timestamp" do
    staff = insert_staff_account()

    {:created, admin} =
      InstanceAdmins.create_admin("instance-#{System.unique_integer([:positive])}@example.com")

    for account <- [staff, admin] do
      before_send = Calendar.strftime(DateTime.utc_now(), "%Y-%m%d-%H:%M:%S")
      assert {:ok, _} = LoginEmail.deliver_login_link(account, "https://example.com/login/token")
      assert_receive {:email, email}
      assert email.to == [{"", account.email}]

      assert [_, timestamp] =
               Regex.run(
                 ~r/^Your Custyard login link \| (\d{4}-\d{4}-\d{2}:\d{2}:\d{2})$/,
                 email.subject
               )

      assert timestamp >= before_send
      assert timestamp <= Calendar.strftime(DateTime.utc_now(), "%Y-%m%d-%H:%M:%S")
    end
  end

  test "deliveries keep the login URL and email bodies unchanged" do
    staff = insert_staff_account()
    login_url = "https://example.com/login/same-token"

    assert {:ok, _} = LoginEmail.deliver_login_link(staff, login_url)
    assert_receive {:email, first}
    assert {:ok, _} = LoginEmail.deliver_login_link(staff, login_url)
    assert_receive {:email, second}

    assert first.text_body == second.text_body
    assert first.html_body == second.html_body
  end
end
