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

  describe "recipients of the original" do
    test "Gmail: display names, a quoted name with a comma, and a list wrapped after <" do
      body = """
      ---------- Forwarded message ---------
      From: Me <me@acme.example>
      Date: Mon, 6 Oct 2025 at 09:12
      Subject: Re: Login broken
      To: Alice Customer <Alice@Customer.example>, "Builder, Bob" <
      bob@builder.example>, carol@customer.example
      Cc: Dave <dave@customer.example>


      Fixed, please try again.
      """

      assert {:ok, original} = ForwardUnwrapper.unwrap(body, "Fwd: Re: Login broken")

      assert original.to == [
               "alice@customer.example",
               "bob@builder.example",
               "carol@customer.example"
             ]

      assert original.cc == ["dave@customer.example"]
      assert original.subject == "Re: Login broken"
      assert original.body == "Fixed, please try again."
    end

    test "Gmail: a list wrapped inside a display name" do
      body = """
      ---------- Forwarded message ---------
      From: Me <me@acme.example>
      Date: Mon, 6 Oct 2025 at 09:12
      Subject: Re: Login broken
      To: Alice Customer <alice@customer.example>, Bob
      Builder <bob@builder.example>

      Fixed.
      """

      assert {:ok, original} = ForwardUnwrapper.unwrap(body, "Fwd: Re: Login broken")
      assert original.to == ["alice@customer.example", "bob@builder.example"]
      assert original.cc == []
      assert original.body == "Fixed."
    end

    test "Apple Mail: a quoted block with several recipients and a Bcc line" do
      body = """
      Begin forwarded message:

      > From: Me <me@acme.example>
      > Subject: Re: Invoice 42
      > Date: 3 October 2025 at 14:02:11 CEST
      > To: Bob <bob@customer.example>, alice@customer.example
      > Cc: Carol Customer <carol@customer.example>
      > Bcc: archive@acme.example
      >
      > The corrected invoice is attached.
      """

      assert {:ok, original} = ForwardUnwrapper.unwrap(body, "Fwd: Re: Invoice 42")
      assert original.to == ["bob@customer.example", "alice@customer.example"]
      assert original.cc == ["carol@customer.example"]
      assert original.body == "The corrected invoice is attached."
    end

    test "Outlook: semicolons, mailto brackets, quotes, and a recipient shown by name only" do
      body = """
      -----Original Message-----
      From: Me <me@acme.example>
      Sent: Tuesday, October 7, 2025 10:00 AM
      To: Carol Customer <carol@customer.example>; Dave [mailto:dave@customer.example];
       'erin@customer.example'; Frank Customer
      Cc: "Customer, Gina" <gina@customer.example>
      Subject: RE: Export

      The export button is under Reports.
      """

      assert {:ok, original} = ForwardUnwrapper.unwrap(body, "FW: RE: Export")

      assert original.to == [
               "carol@customer.example",
               "dave@customer.example",
               "erin@customer.example"
             ]

      assert original.cc == ["gina@customer.example"]
      assert original.subject == "RE: Export"
      assert original.body == "The export button is under Reports."
    end

    test "Thunderbird: tabs after the colon and an upper-case CC" do
      body =
        Enum.join(
          [
            "-------- Forwarded Message --------",
            "Subject: \tRe: Feature request",
            "Date: \tWed, 8 Oct 2025 11:00:00 +0200",
            "From: \tMe <me@acme.example>",
            "To: \tDave Customer <dave@customer.example>, erin@customer.example",
            "CC: \tFrank <frank@customer.example>",
            "",
            "Dark mode ships next week."
          ],
          "\n"
        )

      assert {:ok, original} = ForwardUnwrapper.unwrap(body, "Fwd: Re: Feature request")
      assert original.to == ["dave@customer.example", "erin@customer.example"]
      assert original.cc == ["frank@customer.example"]
      assert original.body == "Dark mode ships next week."
    end

    test "Proton: an address repeated as a quoted display name counts once" do
      body = """
      ------- Forwarded Message -------
      From: Me <me@acme.example>
      Date: On Monday, October 6th, 2025 at 09:12
      Subject: Re: Feature request
      To: Dave Customer <dave@customer.example>, "erin@old.example" <erin@customer.example>
      CC: frank@customer.example <frank@customer.example>

      Dark mode ships next week.
      """

      assert {:ok, original} = ForwardUnwrapper.unwrap(body, "Fwd: Re: Feature request")
      assert original.to == ["dave@customer.example", "erin@customer.example"]
      assert original.cc == ["frank@customer.example"]
    end

    test "a block without To or Cc has no recipients" do
      body = """
      ---------- Forwarded message ---------
      From: eve@customer.example
      Date: today

      Hello
      """

      assert {:ok, %{to: [], cc: []}} = ForwardUnwrapper.unwrap(body, "Fwd: Hello")
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
