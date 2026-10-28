defmodule CustyardWeb.ClaimConfirmationControllerTest do
  # Shares the rate-limit ETS table and rewrites bucket config — sequential only.
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory
  import Ecto.Query

  alias Custyard.{RateLimit, Repo, Slug, Slugs, Tenants}

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
      public_instance_ip: @generous,
      intake_get: @generous,
      intake_post: @generous,
      conversation_mount: @generous,
      conversation_reply: @generous,
      email_capture: @generous,
      claim_submit: @generous,
      claim_confirm: @generous,
      claim_email_send: @generous,
      intake_arrival_email: @generous,
      intake_receipt_email: @generous
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

  describe "GET /claim/:token (peek)" do
    test "renders the slug and a confirm form with ZERO state change", %{conn: conn} do
      %{slug: slug, token: token} = claim!()

      conn = get(conn, ~p"/claims/#{token}")
      html = html_response(conn, 200)

      assert html =~ "claim-confirm-page"
      assert html =~ "acme-corp"
      assert html =~ ~s(action="/claims/#{token}/confirm")
      assert html =~ "claim-confirm-submit"

      # Zero state change: still claimed, hash untouched.
      reloaded = Repo.get!(Slug, slug.id)
      assert reloaded.status == :claimed
      assert reloaded.confirmation_token_hash == slug.confirmation_token_hash
    end

    test "a prefetching scanner issuing repeated GETs consumes nothing", %{conn: conn} do
      %{slug: slug, token: token} = claim!()

      for _scan <- 1..5 do
        assert build_conn() |> get(~p"/claims/#{token}") |> html_response(200) =~ "acme-corp"
      end

      assert Repo.get!(Slug, slug.id).status == :claimed

      # The prospect's explicit POST still confirms after all the scans.
      conn = post(conn, ~p"/claims/#{token}/confirm")
      assert html_response(conn, 200) =~ "claim-confirmed-page"
      assert Repo.get!(Slug, slug.id).status == :confirmed
    end

    test "sends Referrer-Policy: no-referrer (the token is a bearer credential)", %{conn: conn} do
      %{token: token} = claim!()

      conn = get(conn, ~p"/claims/#{token}")
      assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    end
  end

  describe "POST /claim/:token/confirm" do
    test "consumes the token and renders the success page without the conversation URL", %{
      conn: conn
    } do
      %{slug: slug, token: token} = claim!()

      conn = post(conn, ~p"/claims/#{token}/confirm")
      html = html_response(conn, 200)

      assert html =~ "claim-confirmed-page"
      assert html =~ "acme-corp"
      # The success page must not mint or reveal the conversation URL.
      refute html =~ "/threads/"

      reloaded = Repo.get!(Slug, slug.id)
      assert reloaded.status == :confirmed
      assert is_nil(reloaded.confirmation_token_hash)
      assert is_nil(reloaded.expires_at)
    end
  end

  describe "tenant host boundaries" do
    setup do
      {:ok, tenant} = Tenants.create_tenant(%{name: "Atlas", slug: "atlas-claims"})
      {:ok, other} = Tenants.create_tenant(%{name: "Beacon", slug: "beacon-claims"})
      {:ok, _} = Tenants.add_host(tenant.id, "atlas-claims.test")
      {:ok, _} = Tenants.add_host(other.id, "beacon-claims.test")
      conversation = insert_conversation(source: :public_intake, tenant_id: tenant.id)
      {:ok, slug, token} = Slugs.claim("atlas-claim", "buyer@example.com", conversation)

      %{tenant: tenant, other: other, slug: slug, token: token}
    end

    test "a foreign host renders unavailable without exposing the claim", c do
      conn = get(%{build_conn() | host: Tenants.host(c.other)}, "/claims/#{c.token}")
      html = html_response(conn, 200)

      assert html =~ "claim-unavailable"
      refute html =~ "atlas-claim"
      assert Repo.reload!(c.slug).status == :claimed

      own = get(%{build_conn() | host: Tenants.host(c.tenant)}, "/claims/#{c.token}")
      assert html_response(own, 200) =~ "atlas-claim"
      assert Repo.reload!(c.slug).status == :claimed
    end

    test "a foreign host cannot consume a token that still works on its own tenant", c do
      conn =
        post(%{build_conn() | host: Tenants.host(c.other)}, "/claims/#{c.token}/confirm")

      assert html_response(conn, 200) =~ "claim-unavailable"
      assert Repo.reload!(c.slug).status == :claimed
      assert Repo.reload!(c.slug).confirmation_token_hash == c.slug.confirmation_token_hash

      own =
        post(%{build_conn() | host: Tenants.host(c.tenant)}, "/claims/#{c.token}/confirm")

      assert html_response(own, 200) =~ "claim-confirmed-page"
      assert Repo.reload!(c.slug).status == :confirmed
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
      post(build_conn(), ~p"/claims/#{used_token}/confirm")

      # Expired token
      conversation = insert_conversation(source: :public_intake)
      {:ok, expired_slug, expired_token} = Slugs.claim("lapsed", "b@example.com", conversation)
      expire!(expired_slug)

      # Purged token (claim released entirely)
      other = insert_conversation(source: :public_intake)
      {:ok, purged_slug, purged_token} = Slugs.claim("purged", "c@example.com", other)
      {:ok, _} = Slugs.release(staff_scope(purged_slug.tenant_id), purged_slug)

      tokens = [
        "not-a-real-token",
        used_token,
        expired_token,
        purged_token
      ]

      get_pages =
        for token <- tokens do
          build_conn() |> get(~p"/claims/#{token}") |> html_response(200) |> normalized_page()
        end

      post_pages =
        for token <- tokens do
          build_conn()
          |> post(~p"/claims/#{token}/confirm")
          |> html_response(200)
          |> normalized_page()
        end

      assert Enum.uniq(get_pages ++ post_pages) |> length() == 1
      assert hd(get_pages) =~ "claim-unavailable"
    end
  end

  describe "rate limiting (:claim_confirm)" do
    test "GET and POST share the per-IP bucket and 429 past the limit", %{conn: conn} do
      put_buckets(claim_confirm: [limit: 2, window_ms: 60_000])
      %{token: token} = claim!()

      assert conn |> get(~p"/claims/#{token}") |> html_response(200)
      assert build_conn() |> get(~p"/claims/#{token}") |> html_response(200)

      denied = build_conn() |> post(~p"/claims/#{token}/confirm")
      assert denied.status == 429
      assert [retry_after] = get_resp_header(denied, "retry-after")
      assert String.to_integer(retry_after) >= 1

      # The denied POST consumed nothing.
      assert Custyard.Slugs.peek(token, factory_tenant_id()) |> elem(0) == :ok
    end

    test "shape-invalid tokens render unavailable without consuming the bucket" do
      put_buckets(claim_confirm: [limit: 1, window_ms: 60_000])
      %{token: token} = claim!()

      # Scanner garbage — wrong length, wrong charset — fails the shape
      # check before the rate limit and spends nothing.
      for garbage <- ["not-a-real-token", String.duplicate("a", 44), "shell$injection!"] do
        assert build_conn() |> get(~p"/claims/#{garbage}") |> html_response(200) =~
                 "claim-unavailable"

        assert build_conn() |> post(~p"/claims/#{garbage}/confirm") |> html_response(200) =~
                 "claim-unavailable"
      end

      # The whole budget survived the garbage: the real token still confirms.
      assert build_conn() |> post(~p"/claims/#{token}/confirm") |> html_response(200) =~
               "claim-confirmed-page"
    end

    test "well-formed but nonexistent tokens still consume the bucket (no existence oracle)" do
      put_buckets(claim_confirm: [limit: 1, window_ms: 60_000])

      # Shape-valid: exactly what Custyard.Auth.Token mints, just unknown.
      # It must spend budget — rate-limit accounting may reveal token
      # SHAPE, never whether a token EXISTS.
      phantom = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      assert build_conn() |> get(~p"/claims/#{phantom}") |> html_response(200) =~
               "claim-unavailable"

      denied = build_conn() |> get(~p"/claims/#{phantom}")
      assert denied.status == 429
    end
  end
end
