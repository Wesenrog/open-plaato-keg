defmodule OpenPlaatoKeg.KegId do
  @moduledoc """
  A keg id is the Blynk auth token the scale logs in with: 32 hex characters.

  It is the only thing a keg has to identify itself, so logs carry `short/1`
  and never the id. A keg goes by its id in the store and the API unless the
  allow-list file gives it a name (see `OpenPlaatoKeg.AllowList`).
  """

  def valid?(id) when is_binary(id), do: Regex.match?(~r/\A[0-9a-fA-F]{32}\z/, id)
  def valid?(_id), do: false

  @doc """
  The form an id is registered and stored in. Hex has no case, so one token is
  one keg however it is written.
  """
  def canonical(id), do: String.downcase(id)

  @doc "For logs: an id by its first characters, a keg's name as it is."
  def short(id) when is_binary(id) do
    if valid?(id), do: String.slice(id, 0, 6) <> "…", else: String.slice(id, 0, 32)
  end

  def short(id), do: inspect(id)
end
