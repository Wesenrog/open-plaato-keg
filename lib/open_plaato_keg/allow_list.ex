defmodule OpenPlaatoKeg.AllowList do
  @moduledoc """
  Which keg ids may log in: the ids in `KEG_ALLOWED_IDS` and the ids in the
  file `KEG_ALLOWED_IDS_FILE` names. With neither set, any well-formed id may.

  The file holds one id per line; blank lines and `#` comments are skipped. It
  is read at every login, so an edit applies to the next connection without a
  restart. A file that is set but cannot be read allows nothing.
  """

  alias OpenPlaatoKeg.KegId

  @doc """
  `:ok`, or `{:error, reason}` with a reason for the log. `config` is the
  listener's config: `:allowed_ids` (canonical ids) and `:allowed_ids_file`.
  """
  def check(id, config) do
    ids = config[:allowed_ids] || []
    file = config[:allowed_ids_file]

    cond do
      file == nil and ids == [] -> :ok
      KegId.canonical(id) in ids -> :ok
      file == nil -> {:error, not_listed(id)}
      true -> check_file(id, file)
    end
  end

  @doc """
  The ids in the file, in canonical form, and the number of lines that are
  neither an id, a comment nor blank.
  """
  def read(path) do
    with {:ok, text} <- File.read(path) do
      {ids, other} =
        text
        |> String.split("\n")
        |> Enum.map(&strip/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.split_with(&KegId.valid?/1)

      {:ok, Enum.map(ids, &KegId.canonical/1), length(other)}
    end
  end

  defp strip(line) do
    line |> String.split("#") |> hd() |> String.trim()
  end

  defp check_file(id, file) do
    case read(file) do
      {:ok, ids, _other} ->
        if KegId.canonical(id) in ids, do: :ok, else: {:error, not_listed(id)}

      {:error, reason} ->
        {:error, "allow-list file is not readable (#{reason})"}
    end
  end

  defp not_listed(id), do: "id #{KegId.short(id)} is not on the allow-list"
end
