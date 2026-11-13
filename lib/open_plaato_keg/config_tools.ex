defmodule OpenPlaatoKeg.Config do
  require Logger

  def get_env!(var, type \\ :string, default \\ nil) do
    case get_env(var, type, default) do
      nil -> raise "Missing environment variable #{var}!"
      value -> value
    end
  end

  def get_env(var, type \\ :string, default \\ nil) do
    case System.get_env(var, default) do
      nil -> default
      value -> convert(value, type)
    end
  end

  def convert(value, :integer), do: String.to_integer(value)

  def convert(value, :string), do: value

  def convert("true", :boolean), do: true
  def convert(_, :boolean), do: false

  def convert(value, :csv) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def convert(value, :key_value_csv) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn pair ->
      [key, value] = String.split(pair, ":", trim: true)
      {key, value}
    end)
    |> Enum.into(%{})
  rescue
    exception ->
      Logger.error("Failed to parse key-value CSV: #{inspect(value)}")
      reraise exception, __STACKTRACE__
  end
end
