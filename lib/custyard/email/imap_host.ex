defmodule Custyard.Email.ImapHost do
  @moduledoc """
  Resolve an IMAP channel's host to the address the poller connects to.

  An operator types the host, so it must not reach the instance's own
  network: the name is resolved here and the connection goes to the
  resolved public address, with the certificate checked against the name.
  A name with any private, loopback, link-local, shared or reserved address
  is refused outright rather than filtered, so a resolver that mixes public
  and internal answers gains nothing. IP literals are refused.

  `config :custyard, :imap_allow_private_hosts, true` (development) skips
  the checks and connects by name.
  """

  import Bitwise

  @doc """
  `{:ok, address, server_name}` where `server_name` is the name to verify the
  certificate against (nil when connecting by name), or
  `{:error, :disallowed_host | :unresolvable}`.
  """
  def resolve(host) when is_binary(host) do
    if Application.get_env(:custyard, :imap_allow_private_hosts, false) do
      {:ok, host, nil}
    else
      resolve_public(host)
    end
  end

  defp resolve_public(host) do
    charlist = String.to_charlist(host)

    with {:error, _} <- :inet.parse_address(charlist),
         [_ | _] = addresses <- lookup(charlist) do
      if Enum.all?(addresses, &public?/1),
        do: {:ok, addresses |> hd() |> :inet.ntoa() |> to_string(), host},
        else: {:error, :disallowed_host}
    else
      {:ok, _ip_literal} -> {:error, :disallowed_host}
      [] -> {:error, :unresolvable}
    end
  end

  # IPv4 only: Plover's TLS connect uses the default inet family, so an
  # IPv6 address would need options Plover cannot pass through. A server
  # without an A record is reported as unresolvable.
  defp lookup(charlist), do: ok_list(:inet.getaddrs(charlist, :inet))

  defp ok_list({:ok, addresses}), do: addresses
  defp ok_list(_error), do: []

  # Non-public ranges as {network, prefix length}: this network, private,
  # shared (CGNAT), loopback, link-local, IETF protocol assignments,
  # benchmarking, multicast and reserved (224/3 covers 224/4 and 240/4).
  @non_public_v4 [
    {{0, 0, 0, 0}, 8},
    {{10, 0, 0, 0}, 8},
    {{100, 64, 0, 0}, 10},
    {{127, 0, 0, 0}, 8},
    {{169, 254, 0, 0}, 16},
    {{172, 16, 0, 0}, 12},
    {{192, 0, 0, 0}, 24},
    {{192, 168, 0, 0}, 16},
    {{198, 18, 0, 0}, 15},
    {{224, 0, 0, 0}, 3}
  ]

  # Unspecified, loopback, unique local, link-local, multicast.
  @non_public_v6 [
    {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
    {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
    {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
    {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
  ]

  @doc false
  # IPv4-mapped IPv6 addresses are judged as the IPv4 address they carry.
  def public?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: public?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})

  def public?(ip) when tuple_size(ip) == 4, do: not in_any?(ip, @non_public_v4, 8, 32)
  def public?(ip) when tuple_size(ip) == 8, do: not in_any?(ip, @non_public_v6, 16, 128)

  defp in_any?(ip, ranges, part_bits, total_bits) do
    address = to_integer(ip, part_bits)

    Enum.any?(ranges, fn {network, prefix} ->
      shift = total_bits - prefix
      address >>> shift == to_integer(network, part_bits) >>> shift
    end)
  end

  defp to_integer(ip, part_bits),
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< part_bits ||| &1))
end
