defmodule CustyardWeb.ClaimConfirmationControllerTest do
  # Shares the rate-limit ETS table and rewrites bucket config — sequential only.
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory
  import Ecto.Query

  alias Custyard.{RateLimit, Repo, Slug, Slugs}

  @generous [limit: 1000, window_ms: 60_000]

  setup do
    RateLimit.reset()
    original = Application.get_env(:custyard, :rate_limit_buckets)
    put_buckets()

    on_exit(fn ->
      Application.put_env(:custyard, :rate_limit_buckets, original)
      RateLimit.reset()
    end)

    :ok
  end

  defp put_buckets(overrides \\ []) do
    base = [
      intake_get: @generous,
      intake_post: @generous,
      resume_mount: @generous,
      resume_reply: @generous,
      email_capture: @generous,
      claim_submit: @generous,
      claim_confirm: @generous,
      claim_email_send: @generous
    ]

    Application.put_env(:custyard, :rate_limit_buckets, Keyword.merge(base, overrides))
  end

  defp claim! do
    conversation = insert_conversation(source: :public_intake)
    {:ok, slug, token} = Slugs.claim("acme-corp", "buyer@example.com", conversation)
    %{conversation: conversation, slug: slug, token: token}
  end

  defp expire!(%Slug{} = slug) do
    past =
      DateTime.utc_now()
      |> DateTime.add(-1, :hour)
      |> DateTime.truncate(:second)

    {1, _} =
      Repo.update_all(from(s in Slug, where: s.id == ^slug.id), set: [expires_at: past])

    :ok
  end

  describe "GET /c/:token (peek)" do
    test "renders the slug and a confirm form with ZERO state change", %{conn: conn} do
      %{slug: slug, token: token} = claim!()

      conn = get(conn, ~p"/c/#{token}")
      html = html_response(conn, 200)

      assert html =~ "claim-confirm-page"
      assert html =~ "acme-corp"
      assert html =~ ~s(action="/c/#{token}/confirm")
      assert html =~ "claim-confirm-submit"

      # Zero state change: still claimed, hash untouched.
      reloaded = Repo.get!(Slug, slug.id)
      assert reloaded.status == :claimed
      assert reloaded.confirmation_token_hash == slug.confirmation_token_hash
    end

    test "a prefetching scanner issuing repeated GETs consumes nothing", %{conn: conn} do
      %{slug: slug, token: token} = claim!()

      for _scan <- 1..5 do
        assert build_conn() |> get(~p"/c/#{token}") |> html_response(200) =~ "acme-corp"
      end

      assert Repo.get!(Slug, slug.id).status == :claimed

      # The prospect's explicit POST still confirms after all the scans.
      conn = post(conn, ~p"/c/#{token}/confirm")
      assert html_response(conn, 200) =~ "claim-confirmed-page"
      assert Repo.get!(Slug, slug.id).status == :confirmed
    end

    test "sends Referrer-Policy: no-referrer (the token is a bearer credential)", %{conn: conn} do
      %{token: token} = claim!()

      conn = get(conn, ~p"/c/#{token}")
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end
  end

  describe "POST /c/:token/confirm" do
    test "consumes the token and renders the success page without the resume URL", %{conn: conn} do
      %{slug: slug, token: token} = claim!()

      conn = post(conn, ~p"/c/#{token}/confirm")
      html = html_response(conn, 200)

      assert html =~ "claim-confirmed-page"
      assert html =~ "acme-corp"
      # The success page must not mint or reveal the resume URL.
      refute html =~ "/r/"

      reloaded = Repo.get!(Slug, slug.id)
      assert reloaded.status == :confirmed
      assert is_nil(reloaded.confirmation_token_hash)
      assert is_nil(reloaded.expires_at)
    end
  end

  describe "no validity oracle" do
    # Strip per-request noise — the CSRF token in the root layout's meta
    # tag (and any form input) — so the remaining page bytes can be
    # compared for identity across failure classes.
    defp normalized_page(html) do
      html
      |> String.replace(~r/<meta name="csrf-token" content="[^"]*"/, ~s(<meta name="csrf-token"))
      |> String.replace(~r/<input name="_csrf_token"[^>]*>/, "")
    end

    test "invalid, expired, used, and purged tokens all render one identical page" do
      # Used token
      %{token: used_token} = claim!()
      post(build_conn(), ~p"/c/#{used_token}/confirm")

      # Expired token
      conversation = insert_conversation(source: :public_intake)
      {:ok, expired_slug, expired_token} = Slugs.claim("lapsed", "b@example.com", conversation)
      expire!(expired_slug)

      # Purged token (claim released entirely)
      other = insert_conversation(source: :public_intake)
      {:ok, purged_slug, purged_token} = Slugs.claim("purged", "c@example.com", other)
      {:ok, _} = Slugs.release(purged_slug)

      tokens = [
        "not-a-real-token",
        used_token,
        expired_token,
        purged_token
      ]

      get_pages =
        for token <- tokens do
          build_conn() |> get(~p"/c/#{token}") |> html_response(200) |> normalized_page()
        end

      post_pages =
        for token <- tokens do
          build_conn() |> post(~p"/c/#{token}/confirm") |> html_response(200) |> normalized_page()
        end

      assert Enum.uniq(get_pages ++ post_pages) |> length() == 1
      assert hd(get_pages) =~ "claim-unavailable"
    end
  end

  describe "rate limiting (:claim_confirm)" do
    test "GET and POST share the per-IP bucket and 429 past the limit", %{conn: conn} do
      put_buckets(claim_confirm: [limit: 2, window_ms: 60_000])
      %{token: token} = claim!()

      assert conn |> get(~p"/c/#{token}") |> html_response(200)
      assert build_conn() |> get(~p"/c/#{token}") |> html_response(200)

      denied = build_conn() |> post(~p"/c/#{token}/confirm")
      assert denied.status == 429
      assert [retry_after] = get_resp_header(denied, "retry-after")
      assert String.to_integer(retry_after) >= 1

      # The denied POST consumed nothing.
      assert Custyard.Slugs.peek(token) |> elem(0) == :ok
    end
  end
end
