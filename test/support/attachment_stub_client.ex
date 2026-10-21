defmodule Custyard.Attachments.StubClient do
  @moduledoc """
  Test double for `Custyard.Attachments.Client`: bodies are registered per
  URL in an Agent started by `test/test_helper.exs`, so no test touches the
  network. `put/2` registers a body; `fail/2` registers an error. URLs are
  unique per test (`unique_url/0`), so async tests never collide.
  """

  @behaviour Custyard.Attachments.Client

  def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def put(url, body) when is_binary(url) and is_binary(body),
    do: Agent.update(__MODULE__, &Map.put(&1, url, {:ok, body}))

  def on_fetch(url, fun) when is_function(fun, 1),
    do: Agent.update(__MODULE__, &Map.put(&1, url, fun))

  def fail(url, reason) when is_binary(url),
    do: Agent.update(__MODULE__, &Map.put(&1, url, {:error, reason}))

  def unique_url,
    do: "https://storage.lettermint.test/signed/#{System.unique_integer([:positive])}"

  @impl true
  def fetch(url, max_bytes) do
    case Agent.get(__MODULE__, &Map.get(&1, url)) do
      {:ok, body} when byte_size(body) > max_bytes -> {:error, :too_large}
      callback when is_function(callback, 1) -> callback.(max_bytes)
      nil -> {:error, :not_stubbed}
      result -> result
    end
  end
end
