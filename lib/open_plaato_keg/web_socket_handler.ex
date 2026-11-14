defmodule OpenPlaatoKeg.WebSocketHandler do
  alias OpenPlaatoKeg.KegCommander
  alias OpenPlaatoKeg.Models.KegData

  def init(state) do
    Registry.register(OpenPlaatoKeg.WebSocketConnectionRegistry, "websocket_clients", self())
    {:ok, state}
  end

  def handle_info({:broadcast, message}, state) do
    {:reply, :ok, {:text, message}, state}
  end

  def terminate(_reason, _state) do
    Registry.unregister(OpenPlaatoKeg.WebSocketConnectionRegistry, "websocket_clients")
    :ok
  end

  # The record goes out with `connected`, so that a page can tell the update a
  # scale sends from the one that is published when it drops.
  def publish(id, _data) do
    connected = match?({:ok, _}, KegCommander.lookup_socket(id))

    message =
      id
      |> KegData.get()
      |> Map.put(:connected, connected)
      |> Poison.encode!()

    Registry.dispatch(
      OpenPlaatoKeg.WebSocketConnectionRegistry,
      "websocket_clients",
      fn entries ->
        for {pid, _} <- entries do
          send(pid, {:broadcast, message})
        end
      end
    )
  end

  def broadcast_keg_removed(id) do
    message = Poison.encode!(%{type: "keg_removed", id: id})

    Registry.dispatch(
      OpenPlaatoKeg.WebSocketConnectionRegistry,
      "websocket_clients",
      fn entries ->
        for {pid, _} <- entries do
          send(pid, {:broadcast, message})
        end
      end
    )
  end
end
