defmodule OpenPlaatoKeg.AllowList do
  @moduledoc """
  Which keg ids may log in, and which keg each of them is: the ids in
  `KEG_ALLOWED_IDS` and the lines of the file `KEG_ALLOWED_IDS_FILE` names.
  With neither set, any well-formed id may.

  A line of the file is an id, optionally followed by a name for the keg;
  blank lines and `#` comments are skipped. A keg with a name is stored,
  registered and served under that name, so its id can be changed without it
  becoming another keg, and the id stays out of the store and the API. Without
  a name the keg goes by its id.

  The file is read at every login, so an edit applies to the next connection
  without a restart. A file that is set but cannot be read allows nothing.
  """

  alias OpenPlaatoKeg.KegId

  @name ~r/\A[A-Za-z0-9_-]{1,32}\z/

  @doc """
  `{:ok, keg}` with what the keg goes by, or `{:error, reason}` with a reason
  for the log. `config` is the listener's config: `:allowed_ids` (canonical
  ids) and `:allowed_ids_file`.
  """
  def check(id, config) do
    id = KegId.canonical(id)
    ids = config[:allowed_ids] || []

    case from_file(id, config[:allowed_ids_file]) do
      {:ok, keg} -> {:ok, keg}
      :unset when ids == [] -> {:ok, id}
      miss -> if id in ids, do: {:ok, id}, else: {:error, describe(miss, id)}
    end
  end

  @doc """
  How many scales the allow-list lets in, or `:any` when there is none. Two
  ids with the same name in the file are one scale. A file that cannot be
  read adds none.
  """
  def scales(config) do
    ids = config[:allowed_ids] || []

    case config[:allowed_ids_file] do
      nil when ids == [] ->
        :any

      nil ->
        ids |> Enum.uniq() |> length()

      file ->
        entries =
          case read(file) do
            {:ok, entries, _other} -> entries
            {:error, _reason} -> []
          end

        listed = Enum.map(entries, &elem(&1, 0))

        (Enum.map(entries, &elem(&1, 1)) ++ (ids -- listed)) |> Enum.uniq() |> length()
    end
  end

  @doc """
  The file's `{id, keg}` entries, ids in canonical form, and the number of
  lines that are neither an entry, a comment nor blank.
  """
  def read(path) do
    with {:ok, text} <- File.read(path) do
      lines = text |> String.split("\n") |> Enum.map(&parse/1)

      {:ok, Enum.filter(lines, &is_tuple/1), Enum.count(lines, &(&1 == :error))}
    end
  end

  defp parse(line) do
    case line |> String.split("#") |> hd() |> String.split() do
      [] -> :blank
      [id] -> entry(id, KegId.canonical(id))
      [id, name] -> if Regex.match?(@name, name), do: entry(id, name), else: :error
      _ -> :error
    end
  end

  defp entry(id, keg) do
    if KegId.valid?(id), do: {KegId.canonical(id), keg}, else: :error
  end

  defp from_file(_id, nil), do: :unset

  defp from_file(id, file) do
    case read(file) do
      {:ok, entries, _other} ->
        case List.keyfind(entries, id, 0) do
          {_id, keg} -> {:ok, keg}
          nil -> :not_listed
        end

      {:error, reason} ->
        {:unreadable, reason}
    end
  end

  defp describe({:unreadable, reason}, _id), do: "allow-list file is not readable (#{reason})"
  defp describe(_miss, id), do: "id #{KegId.short(id)} is not on the allow-list"
end
