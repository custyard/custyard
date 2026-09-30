defmodule Custyard.Acknowledgments.Topology do
  @moduledoc "Provision durable quorum queues independently of the running consumer. Requires RabbitMQ 3.10+."
  def failure(config), do: config[:queue] <> ".failed"
  def retry(config, attempt), do: config[:queue] <> ".retry.#{attempt}"

  def provision(channel, config) do
    with :ok <- declare(channel, config[:queue], [{"x-delivery-limit", :long, -1}]),
         :ok <- declare(channel, failure(config), [{"x-delivery-limit", :long, -1}]) do
      config[:retry_delays]
      |> Enum.with_index(1)
      |> Enum.reduce_while(:ok, fn {delay, attempt}, :ok ->
        args = [
          {"x-delivery-limit", :long, -1},
          {"x-message-ttl", :long, delay},
          {"x-dead-letter-exchange", :longstr, ""},
          {"x-dead-letter-routing-key", :longstr, config[:queue]},
          {"x-dead-letter-strategy", :longstr, "at-least-once"},
          {"x-overflow", :longstr, "reject-publish"}
        ]

        case declare(channel, retry(config, attempt), args) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp declare(channel, queue, arguments) do
    case AMQP.Queue.declare(channel, queue,
           durable: true,
           arguments: [{"x-queue-type", :longstr, "quorum"} | arguments]
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
