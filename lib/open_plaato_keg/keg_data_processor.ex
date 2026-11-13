defmodule OpenPlaatoKeg.KegDataProcessor do
  @moduledoc """
  Per-connection state and processing of a logged-in keg's Blynk frames.

  Runs inside the connection handler, so a slow store slows that keg's socket
  instead of filling a mailbox. The id is the one the connection logged in
  with; a frame cannot change it.
  """
  require Logger

  alias OpenPlaatoKeg.KegId
  alias OpenPlaatoKeg.Models.KegData
  alias OpenPlaatoKeg.PlaatoData
  alias OpenPlaatoKeg.PlaatoProtocol

  def new(id), do: %{id: id}

  def process_frames(frames, state) do
    frames
    |> decode()
    |> process(state)
  rescue
    # Bad input from one keg must not take its connection down with a crash
    # report, which would carry the id and the payload.
    exception ->
      Logger.warning(
        "Dropped undecodable data from keg #{KegId.short(state.id)}: #{inspect(exception.__struct__)}"
      )

      state
  end

  defp process([], state), do: state

  defp process(payload, state) do
    # Classify the connection as a keg once we see keg-only pins or keg
    # firmware metadata, and cache it so later packets stay classified even
    # when they only carry generic fields.
    state =
      cond do
        state[:device_type] != nil -> state
        internal_keg_data?(payload) -> Map.put(state, :device_type, :keg)
        keg_data?(payload) -> Map.put(state, :device_type, :keg)
        true -> state
      end

    # Internal metadata can arrive before we have enough signals to classify
    # the connection as a keg. Hold onto that packet and publish it once the
    # device is confirmed, so setup-page system fields don't disappear.
    state = cache_pending_internal(payload, state)

    cond do
      payload == [] or only_pending_internal?(payload, state) ->
        state

      true ->
        Logger.debug("Decoded keg data", data: inspect(payload))
        process_keg(payload, state)
    end
  end

  # A packet contains keg data if it has any well-known keg pins.
  defp keg_data?(data) do
    Keyword.has_key?(data, :amount_left) or
      Keyword.has_key?(data, :keg_temperature) or
      Keyword.has_key?(data, :percent_of_beer_left) or
      Keyword.has_key?(data, :is_pouring) or
      Keyword.has_key?(data, :firmware_version)
  end

  defp internal_keg_data?(data) do
    case Keyword.get(data, :internal) do
      %{} = internal ->
        Enum.any?(["dev", "fw", "tmpl", "build", "ver"], &Map.has_key?(internal, &1))

      _ ->
        false
    end
  end

  # Valid pour range per unit. Lower bound catches near-zero scale noise;
  # upper bound catches compressor/vibration spikes (e.g. 110 lbs from a fridge compressor).
  @pour_range %{
    "kg" => {0.05, 1.4},
    "litre" => {0.05, 1.4}
  }

  defp filter_last_pour(data, id) do
    case Keyword.get(data, :last_pour) do
      nil ->
        data

      value ->
        unit = KegData.get(id)[:beer_left_unit] || "litre"
        {min, max} = Map.get(@pour_range, unit, {0.05, 1.4})

        case Float.parse(to_string(value)) do
          {v, _} when v >= min and v <= max ->
            data

          {v, _} ->
            Logger.warning(
              "Ignoring out-of-range last_pour=#{v} #{unit} for keg #{KegId.short(id)}"
            )

            Keyword.delete(data, :last_pour)

          :error ->
            data
        end
    end
  end

  defp process_keg(data, state) do
    id = state[:id]
    confirmed_keg? = state[:device_type] == :keg
    pending_internal = state[:pending_internal]

    data =
      if confirmed_keg? and pending_internal != nil and Keyword.get(data, :internal) == nil do
        Keyword.put(data, :internal, pending_internal)
      else
        data
      end

    # Only register the device in KegData (via the :id key) once we have
    # confirmed it is a keg.
    data_with_id =
      if id && confirmed_keg?,
        do: Keyword.put_new(data, :id, id),
        else: data

    # Drop out-of-range last_pour values caused by scale vibration/noise.
    data_with_id = if id, do: filter_last_pour(data_with_id, id), else: data_with_id

    publish(id, data_with_id, [
      {&KegData.publish/2, fn -> confirmed_keg? end},
      {&OpenPlaatoKeg.WebSocketHandler.publish/2, fn -> confirmed_keg? end}
    ])

    if confirmed_keg?,
      do: Map.delete(state, :pending_internal),
      else: state
  end

  defp cache_pending_internal(payload, %{device_type: nil} = state) do
    case Keyword.get(payload, :internal) do
      %{} = internal -> Map.put(state, :pending_internal, internal)
      _ -> state
    end
  end

  defp cache_pending_internal(_payload, state), do: state

  defp only_pending_internal?(payload, %{device_type: nil}) do
    payload != [] and Keyword.keys(payload) == [:internal]
  end

  defp only_pending_internal?(_payload, _state), do: false

  # The login frame decodes to an `:id` entry; the handler has dealt with it.
  defp decode(frames) do
    frames
    |> PlaatoProtocol.decode()
    |> PlaatoData.decode()
    |> Enum.reject(&match?({:id, _}, &1))
  end

  defp publish(id, data, publishers) do
    Enum.each(publishers, fn {publish_func, condition} ->
      if condition.() do
        publish_func.(id, data)
      end
    end)
  end
end
