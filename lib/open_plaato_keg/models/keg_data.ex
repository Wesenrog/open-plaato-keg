defmodule OpenPlaatoKeg.Models.KegData do
  require Logger

  def all do
    Enum.map(devices(), &get/1)
  end

  def get(id) do
    query = {{id, :"$1"}, :"$2"}

    data =
      :keg_data
      |> :dets.match(query)
      |> Enum.map(fn [key, value] -> {key, value} end)
      |> Enum.reject(fn {key, _value} -> key == :calibration end)
      |> Map.new()
      |> Map.put(:id, id)

    # Metric-only build: beer volume is reported in litres unless the device
    # explicitly reports weight-based measurement (kg).
    measure = to_string(data[:measure_unit] || "")
    Map.put(data, :beer_left_unit, if(measure == "1", do: "kg", else: "litre"))
  end

  def devices do
    query = {{:_, :id}, :"$1"}

    :keg_data
    |> :dets.match(query)
    |> List.flatten()
  end

  def known?(id), do: :dets.lookup(:keg_data, {id, :id}) != []

  def publish(id, data) do
    Enum.each(data, fn {key, value} ->
      :dets.insert(:keg_data, {{id, key}, value})
    end)
  end

  @doc """
  Moves everything stored for the keg `old` to `new`: for a keg that gets a
  name in the allow-list file, or another one. Refuses to overwrite a keg.
  """
  def rename(old, new) do
    cond do
      not known?(old) ->
        {:error, :not_found}

      known?(new) ->
        {:error, :exists}

      true ->
        :keg_data
        |> :dets.match({{old, :"$1"}, :"$2"})
        |> Enum.each(fn [key, value] ->
          :dets.insert(:keg_data, {{new, key}, if(key == :id, do: new, else: value)})
          :dets.delete(:keg_data, {old, key})
        end)

        :dets.sync(:keg_data)
    end
  end

  def delete(id) do
    # Find all keys stored for this id, then delete each record individually.
    :keg_data
    |> :dets.match({{id, :"$1"}, :_})
    |> List.flatten()
    |> Enum.each(fn key -> :dets.delete(:keg_data, {id, key}) end)
  end
end
