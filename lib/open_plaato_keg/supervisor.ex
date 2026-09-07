defmodule OpenPlaatoKeg.Supervisor do
  use Supervisor
  require Logger

  def start_link do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    children = [
      ws_registry_spec(),
      keg_socket_registry_spec(),
      tcp_listener_spec(),
      http_router_spec()
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp ws_registry_spec do
    {Registry, keys: :duplicate, name: OpenPlaatoKeg.WebSocketConnectionRegistry}
  end

  defp keg_socket_registry_spec do
    {Registry, keys: :unique, name: OpenPlaatoKeg.KegSocketRegistry}
  end

  defp tcp_listener_spec do
    port = OpenPlaatoKeg.tcp_listener_config()[:port]

    Logger.info("TCP keg listener starting on port #{port}...")

    {ThousandIsland, port: port, handler_module: OpenPlaatoKeg.KegConnectionHandler}
  end

  defp http_router_spec do
    port = OpenPlaatoKeg.http_listener_config()[:port]

    {Bandit, scheme: :http, plug: OpenPlaatoKeg.HttpRouter, port: port}
  end
end
