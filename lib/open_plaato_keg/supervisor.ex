defmodule OpenPlaatoKeg.Supervisor do
  use Supervisor
  require Logger

  alias OpenPlaatoKeg.AllowList
  alias OpenPlaatoKeg.KegId

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
    config = OpenPlaatoKeg.tcp_listener_config()
    port = config[:port]
    allowed_ids = config[:allowed_ids] || []
    allowed_ids_file = config[:allowed_ids_file]

    Logger.info("TCP keg listener starting on port #{port}...")

    if allowed_ids == [] and allowed_ids_file == nil do
      Logger.warning("No allow-list is set: any well-formed keg id is accepted and stored")
    end

    case Enum.count(allowed_ids, &(not KegId.valid?(&1))) do
      0 -> :ok
      n -> Logger.warning("#{n} entries in KEG_ALLOWED_IDS are not 32 hex characters")
    end

    if allowed_ids_file, do: log_allow_list_file(allowed_ids_file)

    # The port faces the internet: few acceptors and a hard cap on connections
    # (num_connections is per acceptor) instead of the defaults of 100 x 16 384.
    # The cap has to stay under the file-descriptor limit, 1024 in a container:
    # an acceptor that runs out of descriptors crashes and takes its
    # connections with it. The handler reads the allow-list from the config
    # itself; these options are printed when an acceptor crashes.
    {ThousandIsland,
     port: port,
     handler_module: OpenPlaatoKeg.KegConnectionHandler,
     num_acceptors: 4,
     num_connections: 200,
     read_timeout: 60_000}
  end

  # The handler reads the file at every login; this is only what it holds now.
  defp log_allow_list_file(file) do
    case AllowList.read(file) do
      {:ok, entries, 0} ->
        Logger.info("Allow-list file #{file}: #{length(entries)} ids")

      {:ok, entries, other} ->
        Logger.warning(
          "Allow-list file #{file}: #{length(entries)} ids, #{other} lines that are not an id and a name"
        )

      {:error, reason} ->
        Logger.warning("Allow-list file #{file} is not readable (#{reason}): it allows no keg")
    end
  end

  defp http_router_spec do
    port = OpenPlaatoKeg.http_listener_config()[:port]

    {Bandit, scheme: :http, plug: OpenPlaatoKeg.HttpRouter, port: port}
  end
end
