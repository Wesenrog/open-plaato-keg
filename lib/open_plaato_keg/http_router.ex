defmodule OpenPlaatoKeg.HttpRouter do
  use Plug.Router
  require Logger
  alias OpenPlaatoKeg.KegCommander
  alias OpenPlaatoKeg.KegId
  alias OpenPlaatoKeg.Models.KegData
  alias OpenPlaatoKeg.WebSocketHandler

  plug(Plug.Static,
    at: "/",
    from: :open_plaato_keg
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: Poison
  )

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_header("location", "/index.html")
    |> send_resp(302, "")
  end

  # ============================================
  # Keg Data Endpoints
  # ============================================

  get "api/kegs/devices" do
    json_response(conn, 200, KegData.devices())
  end

  get "api/kegs/connected" do
    json_response(conn, 200, KegCommander.connected_kegs())
  end

  get "api/kegs" do
    json_response(conn, 200, KegData.all())
  end

  get "api/kegs/:id" do
    case KegData.get(conn.params["id"]) do
      %{} = data when map_size(data) > 1 ->
        json_response(conn, 200, data)

      _ ->
        json_response(conn, 404, %{error: "not_found"})
    end
  end

  # ============================================
  # Keg Device Setup / Calibration Commands
  # ============================================

  post "api/kegs/:id/tare" do
    command(conn, &KegCommander.tare/1, "tare")
  end

  post "api/kegs/:id/tare-release" do
    command(conn, &KegCommander.tare_release/1, "tare_release")
  end

  post "api/kegs/:id/empty-keg-weight" do
    keg_id = conn.params["id"]
    %{"value" => value} = conn.body_params

    # The scale does not report this pin back: what is stored is what was sent,
    # so it is stored only when it was sent.
    case KegCommander.set_empty_keg_weight_value(keg_id, value) do
      :ok ->
        KegData.publish(keg_id, [{:empty_keg_weight, value}])
        json_response(conn, 200, %{status: "ok", command: "empty_keg_weight", value: value})

      {:error, reason} ->
        json_response(conn, 503, %{error: reason})
    end
  end

  post "api/kegs/:id/max-keg-volume" do
    keg_id = conn.params["id"]
    %{"value" => value} = conn.body_params

    case KegCommander.set_max_keg_volume(keg_id, value) do
      :ok -> json_response(conn, 200, %{status: "ok", command: "max_keg_volume", value: value})
      {:error, reason} -> json_response(conn, 503, %{error: reason})
    end
  end

  post "api/kegs/:id/calibrate-known-weight" do
    keg_id = conn.params["id"]
    %{"value" => value} = conn.body_params

    case KegCommander.calibrate_with_known_weight(keg_id, value) do
      :ok ->
        json_response(conn, 200, %{status: "ok", command: "known_weight_calibrate", value: value})

      {:error, reason} ->
        json_response(conn, 503, %{error: reason})
    end
  end

  post "api/kegs/:id/temperature-offset" do
    keg_id = conn.params["id"]
    %{"value" => value} = conn.body_params

    KegData.publish(keg_id, [{:temperature_offset, value}])

    case KegCommander.set_temperature_offset(keg_id, value) do
      :ok ->
        json_response(conn, 200, %{status: "ok", command: "temperature_offset", value: value})

      {:error, reason} ->
        json_response(conn, 503, %{error: reason})
    end
  end

  post "api/kegs/:id/sensitivity" do
    keg_id = conn.params["id"]
    %{"value" => value} = conn.body_params

    case parse_sensitivity(value) do
      nil ->
        json_response(conn, 400, %{error: "invalid sensitivity"})

      level ->
        case KegCommander.set_sensitivity(keg_id, level) do
          :ok -> json_response(conn, 200, %{status: "ok", command: "sensitivity", value: level})
          {:error, reason} -> json_response(conn, 503, %{error: reason})
        end
    end
  end

  # ============================================
  # Keg Display / Metadata (local DETS only)
  # ============================================

  post "api/kegs/:id/label" do
    keg_id = conn.params["id"]
    value = (conn.body_params || %{})["value"] |> Kernel.to_string() |> String.trim()

    KegData.publish(keg_id, [{:my_label, value}])
    WebSocketHandler.publish(keg_id, [])

    json_response(conn, 200, %{status: "ok", command: "label", value: value})
  end

  # What is in the keg on the scale now. The label is the scale's own name.
  post "api/kegs/:id/contents" do
    keg_id = conn.params["id"]
    value = (conn.body_params || %{})["value"] |> Kernel.to_string() |> String.trim()

    KegData.publish(keg_id, [{:my_contents, value}])
    WebSocketHandler.publish(keg_id, [])

    json_response(conn, 200, %{status: "ok", command: "contents", value: value})
  end

  # Delete a keg and all its stored data from DETS (e.g. decommissioned or phantom kegs).
  post "api/kegs/:id/delete" do
    keg_id = conn.params["id"]
    KegCommander.disconnect(keg_id)
    KegData.delete(keg_id)
    WebSocketHandler.broadcast_keg_removed(keg_id)
    Logger.info("Deleted keg #{KegId.short(keg_id)} from DETS", [])
    json_response(conn, 200, %{status: "ok", deleted: keg_id})
  end

  # ============================================
  # Other Endpoints
  # ============================================

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(OpenPlaatoKeg.WebSocketHandler, [], timeout: :infinity)
    |> halt()
  end

  get "/api/alive" do
    version = Application.spec(:open_plaato_keg, :vsn) |> to_string()
    json_response(conn, 200, %{status: "ok", version: version})
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  # ============================================
  # Helpers
  # ============================================

  defp parse_sensitivity("very_low"), do: 1
  defp parse_sensitivity("low"), do: 2
  defp parse_sensitivity("medium"), do: 3
  defp parse_sensitivity("high"), do: 4
  defp parse_sensitivity(v) when is_integer(v) and v in 1..4, do: v

  defp parse_sensitivity(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n in 1..4 -> n
      _ -> nil
    end
  end

  defp parse_sensitivity(_), do: nil

  defp command(conn, fun, name) do
    case fun.(conn.params["id"]) do
      :ok -> json_response(conn, 200, %{status: "ok", command: name})
      {:error, reason} -> json_response(conn, 503, %{error: reason})
    end
  end

  defp json_response(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Poison.encode!(data))
  end
end
