import Config
import OpenPlaatoKeg.Config

config :open_plaato_keg,
  include_unknown_data: get_env!("INCLUDE_UNKNOWN_DATA", :boolean, "false")

config :open_plaato_keg, :db,
  file_path: get_env("DATABASE_FILE_PATH", :string, "priv/db/keg_data.bin")

config :open_plaato_keg, :tcp_listener,
  port: get_env!("KEG_LISTENER_PORT", :integer, "1234"),
  allowed_ids: get_env("KEG_ALLOWED_IDS", :csv, "") |> Enum.map(&String.downcase/1),
  allowed_ids_file:
    (case get_env("KEG_ALLOWED_IDS_FILE", :string, "") do
       "" -> nil
       path -> path
     end)

config :open_plaato_keg, :http_listener, port: get_env!("HTTP_LISTENER_PORT", :integer, "8085")
