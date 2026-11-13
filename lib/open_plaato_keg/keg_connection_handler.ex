defmodule OpenPlaatoKeg.KegConnectionHandler do
  @moduledoc """
  ThousandIsland handler; one process per connection on the keg port.

  The port faces the internet, so a connection gets nothing until it has logged
  in with a well-formed keg id that is on the allow-list: no ack, no registry
  entry, nothing stored. Before that it may send only `internal` frames and the
  login itself, within `:prelogin_bytes` and within `:prelogin_timeout` of the
  accept. Anything else closes the socket with one log line.
  """
  use ThousandIsland.Handler
  require Logger

  alias OpenPlaatoKeg.BlynkProtocol
  alias OpenPlaatoKeg.KegDataProcessor
  alias OpenPlaatoKeg.KegId
  alias OpenPlaatoKeg.Models.KegData

  # Newer Plaato Keg firmware uses get_shared_dash (cmd 29) for the auth token.
  # Older firmware uses login (cmd 2).
  @login_cmds [:login, :get_shared_dash]
  @prelogin_cmds [:internal | @login_cmds]

  @takeover_wait_ms 1_000
  @takeover_attempts 3

  def handle_connection(_socket, opts) do
    prelogin_timeout = Keyword.get(opts, :prelogin_timeout, 10_000)

    state = %{
      # Normally nil: the list is then read from the application env at login.
      # The listener's options are printed when an acceptor crashes, so the
      # supervisor does not put the ids there.
      allowed_ids: Keyword.get(opts, :allowed_ids),
      max_frame: Keyword.get(opts, :max_frame, 1024),
      prelogin_bytes: Keyword.get(opts, :prelogin_bytes, 1024),
      prelogin_timeout: prelogin_timeout,
      # Absolute, so that trickling bytes does not keep a connection open.
      deadline: now() + prelogin_timeout,
      received: 0,
      buffer: "",
      pending: [],
      keg_id: nil,
      processor: nil
    }

    {:continue, state, prelogin_timeout}
  end

  def handle_data(data, socket, state) do
    # A read is not a frame: keep the incomplete tail for the next one.
    case BlynkProtocol.parse(state.buffer <> data, state.max_frame) do
      {:ok, frames, rest} ->
        handle_frames(frames, byte_size(data), socket, %{state | buffer: rest})

      {:error, :frame_too_large} ->
        reject("frame over #{state.max_frame} bytes", socket, state)
    end
  end

  def handle_close(_socket, state), do: disconnected(state)

  def handle_error(_reason, _socket, state), do: disconnected(state)

  def handle_timeout(socket, %{keg_id: nil} = state) do
    Logger.info(
      "Keg listener closed #{peer(socket)}: no login within #{state.prelogin_timeout} ms"
    )
  end

  def handle_timeout(_socket, state), do: disconnected(state)

  # A later connection logged in with this keg's id.
  def handle_cast(:takeover, {socket, state}) do
    {:stop, {:shutdown, :takeover}, {socket, state}}
  end

  # Crash reports and `:sys.get_status/1` print the process state and its last
  # message: keep keg ids and payloads out of them.
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, &redact_state/1)
    |> Map.replace_lazy(:message, &redact_message/1)
  end

  defp redact_state({socket, %{keg_id: _} = state}) do
    {socket,
     %{
       state
       | allowed_ids: state.allowed_ids && length(state.allowed_ids),
         buffer: byte_size(state.buffer),
         pending: length(state.pending),
         keg_id: state.keg_id && KegId.short(state.keg_id),
         processor: nil
     }}
  end

  defp redact_state(state), do: state

  defp redact_message({tag, raw_socket, data}) when is_binary(data) do
    {tag, raw_socket, byte_size(data)}
  end

  defp redact_message(message), do: message

  defp handle_frames(frames, read_size, socket, %{keg_id: nil} = state) do
    state = %{state | received: state.received + read_size}

    case take_login(frames, state.pending) do
      {:login, id, msg_id, frames} -> login(id, msg_id, frames, socket, state)
      {:waiting, pending} -> wait_for_login(socket, %{state | pending: pending})
      {:error, reason} -> reject(reason, socket, state)
    end
  end

  defp handle_frames(frames, _read_size, socket, state) do
    # Acknowledge Blynk-style packets, echoing the msg_id from the incoming frame.
    # Some firmware validates that the response msg_id matches the request.
    ack_id =
      case Enum.find(frames, &(elem(&1, 0) != :response)) do
        {_cmd, msg_id, _length, _body} -> msg_id
        nil -> nil
      end

    process(frames, ack_id, socket, state)
  end

  # Firmware may send its `internal` info before the login. Those frames are
  # held in memory, bounded by `:prelogin_bytes`, and used once the login passes.
  defp take_login([], pending), do: {:waiting, pending}

  defp take_login([{:internal, _msg_id, _length, body} = frame | rest], pending) do
    if String.valid?(body),
      do: take_login(rest, [frame | pending]),
      else: {:error, "malformed internal frame before login"}
  end

  defp take_login([{cmd, msg_id, _length, id} | rest], pending) when cmd in @login_cmds do
    {:login, id, msg_id, Enum.reverse(pending, rest)}
  end

  defp take_login([{cmd, _msg_id, _length, _body} | _rest], _pending) do
    {:error, "#{cmd} before login"}
  end

  defp wait_for_login(socket, state) do
    remaining = state.deadline - now()
    # Of the incomplete frame in the buffer, if any: its first byte is enough
    # to turn away what is not a keg without holding the connection.
    cmd = BlynkProtocol.next_command(state.buffer)

    cond do
      cmd != nil and cmd not in @prelogin_cmds ->
        reject("#{cmd} before login", socket, state)

      state.received > state.prelogin_bytes ->
        reject("more than #{state.prelogin_bytes} bytes before login", socket, state)

      remaining <= 0 ->
        reject("no login within #{state.prelogin_timeout} ms", socket, state)

      true ->
        {:continue, state, remaining}
    end
  end

  defp login(id, msg_id, frames, socket, state) do
    cond do
      not KegId.valid?(id) ->
        reject("malformed id", socket, state)

      not KegId.allowed?(id, state.allowed_ids || configured_ids()) ->
        reject("id #{KegId.short(id)} is not in KEG_ALLOWED_IDS", socket, state)

      true ->
        # One keg per token, whatever case it is sent in.
        register_keg(KegId.canonical(id), msg_id, frames, socket, state)
    end
  end

  defp configured_ids, do: OpenPlaatoKeg.tcp_listener_config()[:allowed_ids] || []

  defp register_keg(id, msg_id, frames, socket, state) do
    case register(id, socket, @takeover_attempts) do
      :ok ->
        Logger.info("Keg #{KegId.short(id)} connected from #{peer(socket)}")
        state = %{state | keg_id: id, pending: [], processor: KegDataProcessor.new(id)}

        # The ack carries the login's own msg_id: the firmware does not see
        # itself as connected otherwise.
        process(frames, msg_id, socket, state)

      {:error, reason} ->
        reject("keg #{KegId.short(id)} not registered: #{inspect(reason)}", socket, state)
    end
  end

  # A connection is one keg for as long as it lasts.
  defp process(frames, ack_id, socket, state) do
    if Enum.any?(frames, &other_login?(&1, state.keg_id)) do
      reject("second login with another id", socket, state)
    else
      if ack_id, do: ack(socket, ack_id)

      processor =
        frames
        |> Enum.filter(&keg_data?/1)
        |> KegDataProcessor.process_frames(state.processor)

      {:continue, %{state | processor: processor}}
    end
  end

  defp other_login?({cmd, _msg_id, _length, id}, keg_id) do
    cmd in @login_cmds and not (KegId.valid?(id) and KegId.canonical(id) == keg_id)
  end

  # A value that is not valid UTF-8 cannot be served as JSON, and one such
  # value in the store would break the API for every keg.
  defp keg_data?({cmd, _msg_id, _length, body}) do
    cmd != :response and cmd not in @login_cmds and String.valid?(body)
  end

  defp register(id, socket, attempts) do
    case Registry.register(OpenPlaatoKeg.KegSocketRegistry, id, socket) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, old_pid}} when attempts > 0 ->
        take_over(id, old_pid)
        register(id, socket, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The id is all a keg has to identify itself, and a keg whose connection died
  # without the server noticing must be able to come back: the newcomer wins.
  defp take_over(id, old_pid) do
    Logger.warning("Keg #{KegId.short(id)} logged in again; closing its earlier connection")

    ref = Process.monitor(old_pid)
    GenServer.cast(old_pid, :takeover)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      @takeover_wait_ms ->
        Process.exit(old_pid, :kill)
        Process.demonitor(ref, [:flush])
        # The registry drops a killed process's entry asynchronously.
        Process.sleep(50)
    end
  end

  defp disconnected(%{keg_id: nil}), do: :ok

  defp disconnected(%{keg_id: keg_id}) do
    Logger.info("Keg #{KegId.short(keg_id)} disconnected")

    # Unregister the socket (only affects this process's registration)
    Registry.unregister(OpenPlaatoKeg.KegSocketRegistry, keg_id)

    # Only push a disconnect update for kegs we already know about, to avoid
    # creating a phantom entry for an unrecognised connection.
    if KegData.known?(keg_id) do
      # Prevent phantom "pouring" UI by pushing a disconnect update.
      # Plaato values are typically stringy, so "0" is safest.
      disconnect_update = [is_pouring: "0"]
      KegData.publish(keg_id, disconnect_update)
      OpenPlaatoKeg.WebSocketHandler.publish(keg_id, disconnect_update)
    end

    :ok
  end

  # One line per closed connection, without the payload.
  defp reject(reason, socket, state) do
    who =
      if state.keg_id,
        do: "keg #{KegId.short(state.keg_id)} (#{peer(socket)})",
        else: peer(socket)

    Logger.info("Keg listener closed #{who}: #{reason}")
    {:close, state}
  end

  defp ack(socket, msg_id) do
    ThousandIsland.Socket.send(socket, BlynkProtocol.response_success(msg_id))
  end

  defp peer(socket) do
    case ThousandIsland.Socket.peername(socket) do
      {:ok, {address, port}} when is_tuple(address) -> "#{:inet.ntoa(address)}:#{port}"
      _ -> "unknown peer"
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
