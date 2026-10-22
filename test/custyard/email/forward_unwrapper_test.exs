defmodule Custyard.Email.ForwardUnwrapperTest do
  use ExUnit.Case, async: true

  alias Custyard.Email.ForwardUnwrapper

  describe "unwrap/2" do
    test "Gmail forward" do
      body = """
      FYI, this came in last week.

      ---------- Forwarded message ---------
      From: Alice Customer <alice@customer.example>
      Date: Mon, 6 Oct 2025 at 09:12
      Subject: Login broken
      To: <support@acme.example>


      I cannot log in since this morning.
      Thanks, Alice
      """

      assert {:ok, original} = ForwardUnwrapper.unwrap(body, "Fwd: Login broken")
      assert original.email == "alice@customer.example"
      assert original.from == "Alice Customer <alice@customer.example>"
      assert original.subject == "Login broken"
      assert original.date == "Mon, 6 Oct 2025 at 09:12"
      assert original.body == "I cannot log in since this morning.\nThanks, Alice"
    end

    test "Apple Mail forward with a blank line after the marker and a quoted block" do
      body = """
      Please handle.

      Begin forwarded message:

      > From: Bob <bob@customer.example>
      > Subject: Re: Invoice 42
      > Date: 3 October 2025 at 14:02:11 CEST
      > To: support@acme.example
      >
      > The invoice total is wrong.
      > Bob
      """

      assert {:ok, original} = ForwardUnwrapper.unwrap(body, "Fwd: Re: Invoice 42")
      assert original.email == "bob@customer.example"
      assert original.subject == "Re: Invoice 42"
      assert original.body == "The invoice total is wrong.\nBob"
    end

    test "Outlook original-message block with Sent: and a wrapped header" do
      body = """
      -----Original Message-----
      From: Carol <carol@customer.example>
      Sent: Tuesday, October 7, 2025 10:00 AM
      To: Support
       <support@acme.example>
      Subject: Export

      Where is the export button?
      """

      assert {:ok, original} = ForwardUnwrapper.unwrap(body, "FW: Export")
      assert original.email == "carol@customer.example"
      assert original.date == "Tuesday, October 7, 2025 10:00 AM"
      assert original.subject == "Export"
      assert original.body == "Where is the export button?"
    end

    test "Thunderbird and Proton forwarded-message block" do
      body = """
      -------- Forwarded Message --------
      Subject: Feature request
      Date: Wed, 8 Oct 2025 11:00:00 +0200
      From: dave@customer.example
      To: support@acme.example

      Dark mode please.
      """

      assert {:ok, %{email: "dave@customer.example", subject: "Feature request"}} =
               ForwardUnwrapper.unwrap(body, "Fwd: Feature request")
    end

    test "falls back to the outer subject without its prefix" do
      body = """
      ---------- Forwarded message ---------
      From: eve@customer.example
      Date: today

      Hello
      """

      assert {:ok, %{subject: "Billing question"}} =
               ForwardUnwrapper.unwrap(body, "Fwd: FW: Billing question")
    end

    test "no block, or no parsable sender, is an error" do
      assert :error = ForwardUnwrapper.unwrap("Just a normal reply", "Re: hi")

      assert :error =
               ForwardUnwrapper.unwrap(
                 "---------- Forwarded message ---------\nFrom: nobody\n\nx",
                 "Fwd: x"
               )

      assert :error = ForwardUnwrapper.unwrap(nil, "Fwd: x")
    end
  end

  test "forward_subject?/1 and strip_forward_prefix/1" do
    assert ForwardUnwrapper.forward_subject?("Fwd: hi")
    assert ForwardUnwrapper.forward_subject?("FW: hi")
    assert ForwardUnwrapper.forward_subject?("WG: hallo")
    assert ForwardUnwrapper.forward_subject?("TR: bonjour")
    refute ForwardUnwrapper.forward_subject?("Re: hi")
    refute ForwardUnwrapper.forward_subject?("Forward thinking")
    assert ForwardUnwrapper.strip_forward_prefix("Fwd: FW: hi") == "hi"
  end
end
