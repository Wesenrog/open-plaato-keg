defmodule OpenPlaatoKeg do
  use Application

  def start(_type, _args) do
    bootstrap()
    OpenPlaatoKeg.Supervisor.start_link()
  end

  def bootstrap do
    db_file_path =
      Application.get_env(:open_plaato_keg, :db)[:file_path]

    # create folder if doesn't exist
    db_folder = Path.dirname(db_file_path)
    File.mkdir_p!(db_folder)

    {:ok, _keg_table} =
      :dets.open_file(:keg_data, [
        {:file, String.to_charlist(db_file_path)}
      ])

    :ok
  end

  def tcp_listener_config do
    Application.get_env(:open_plaato_keg, :tcp_listener)
  end

  def http_listener_config do
    Application.get_env(:open_plaato_keg, :http_listener)
  end
end
