defmodule OpenPlaatoKeg.KegListenerTest do
  # The keg port over real sockets: what a connection gets before it has logged
  # in with an allowed id (nothing), and what a logged-in keg can and cannot do.
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias OpenPlaatoKeg.BlynkProtocol
  alias OpenPlaatoKeg.KegCommander
  alias OpenPlaatoKeg.KegConnectionHandler
  alias OpenPlaatoKeg.Models.KegData

  @moduletag :capture_log

  @keg "0123456789abcdef0123456789abcdef"
  @other "fedcba9876543210fedcba9876543210"

  setup_all do
    {:ok, _} = Application.ensure_all_started(:thousand_island)
    :ok
  end

  setup do
    :dets.close(:keg_data)

    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "open_plaato_keg_listener_test_#{unique}")
    File.mkdir_p!(dir)
    file = String.to_charlist(Path.join(dir, "kegs.dets"))

    # Owned by a supervised process, so the table outlives the test process and
    # is still there when the handlers see the test's sockets close.
    start_supervised!({Agent, fn -> {:ok, _} = :dets.open_file(:keg_data, file: file) end})
    start_supervised!({Registry, keys: :unique, name: OpenPlaatoKeg.KegSocketRegistry})

    start_supervised!(
      {Registry, keys: :duplicate, name: OpenPlaatoKeg.WebSocketConnectionRegistry}
    )

    on_exit(fn -> File.rm_rf(dir) end)

    :ok
  end

  defp listen(handler_options \\ []) do
    handler_options = Keyword.merge([allowed_ids: [@keg], prelogin_timeout: 600], handler_options)

    server =
      start_supervised!(
        {ThousandIsland,
         port: 0,
         num_acceptors: 1,
         handler_module: KegConnectionHandler,
         handler_options: handler_options}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    socket
  end

  defp send_data(socket, data), do: :ok = :gen_tcp.send(socket, data)
  defp recv(socket, timeout \\ 1_000), do: :gen_tcp.recv(socket, 0, timeout)

  defp frame(cmd, msg_id, body), do: BlynkProtocol.encode_command(cmd, msg_id, body)
  defp login(msg_id \\ 1, id \\ @keg), do: frame(:get_shared_dash, msg_id, id)
  defp pin(msg_id, pin, value), do: frame(:hardware, msg_id, Enum.join(["vw", pin, value], "\0"))
  defp ack(msg_id), do: {:ok, BlynkProtocol.response_success(msg_id)}

  defp stored(key, id \\ @keg), do: KegData.get(id)[key]

  defp eventually(condition, attempts \\ 100) do
    cond do
      condition.() ->
        :ok

      attempts == 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        eventually(condition, attempts - 1)
    end
  end

  # The connection got no byte back, and left nothing behind.
  defp assert_refused(socket) do
    assert recv(socket) == {:error, :closed}
    assert KegCommander.connected_kegs() == []
    assert :dets.info(:keg_data, :size) == 0
  end

  describe "before login" do
    test "an HTTP request is closed without an answer, with one log line" do
      port = listen()

      log =
        capture_log(fn ->
          socket = connect(port)
          send_data(socket, "GET /secret-path HTTP/1.1\r\nHost: example\r\n\r\n")
          assert_refused(socket)
        end)

      assert length(String.split(log, "Keg listener closed")) == 2
      assert log =~ "127.0.0.1"
      refute log =~ "secret-path"
    end

    test "a frame that is not from a keg is refused on its first byte" do
      # Well before the deadline, which would close it too.
      socket = connect(listen(prelogin_timeout: 5_000))

      # A TLS hello: as a Blynk header, an unfinished 512-byte save_dash frame.
      send_data(socket, <<0x16, 0x03, 0x01, 0x02, 0x00, 0x01, 0x00>>)

      assert_refused(socket)
    end

    test "a frame over the size limit is refused" do
      socket = connect(listen())
      send_data(socket, <<20, 1::16, 2000::16, "vw">>)
      assert_refused(socket)
    end

    test "pin data without a login is refused" do
      socket = connect(listen())
      send_data(socket, pin(1, "51", "12.5"))
      assert_refused(socket)
    end

    test "an id that is not on the list is refused, and logged by its first characters only" do
      port = listen()

      log =
        capture_log(fn ->
          socket = connect(port)
          send_data(socket, login(1, @other) <> pin(2, "51", "12.5"))
          assert_refused(socket)
        end)

      assert log =~ "fedcba…"
      refute log =~ @other
    end

    test "an id that is not 32 hex characters is refused, allow-list or not" do
      port = listen(allowed_ids: [])

      for id <- ["", String.duplicate("a", 31), String.duplicate("g", 32), @keg <> "0"] do
        socket = connect(port)
        send_data(socket, login(1, id) <> pin(2, "51", "12.5"))
        assert_refused(socket)
      end
    end

    test "a silent connection is closed at the deadline" do
      socket = connect(listen())
      assert_refused(socket)
    end

    test "trickled bytes do not move the deadline" do
      socket = connect(listen())

      # Deadline at 600 ms. A timeout restarted by the byte at 400 ms would
      # keep the connection until 1000 ms, past what recv waits for.
      send_data(socket, <<17>>)
      Process.sleep(400)
      send_data(socket, <<0>>)

      assert recv(socket, 450) == {:error, :closed}
    end

    test "more than the byte limit before the login is refused" do
      socket = connect(listen(prelogin_bytes: 100))
      info = frame(:internal, 1, Enum.join(["ver", String.duplicate("1", 60)], "\0"))

      send_data(socket, info)
      assert recv(socket, 100) == {:error, :timeout}
      send_data(socket, info)

      assert_refused(socket)
    end

    test "internal info ahead of the login is unanswered, then stored with the login" do
      socket = connect(listen())

      send_data(socket, frame(:internal, 1, Enum.join(["ver", "2.0", "dev", "ESP32"], "\0")))
      assert recv(socket, 100) == {:error, :timeout}
      assert :dets.info(:keg_data, :size) == 0

      # The ack echoes the login's msg_id, not that of the first frame seen.
      send_data(socket, login(2))
      assert recv(socket) == ack(2)

      eventually(fn -> stored(:internal) == %{"ver" => "2.0", "dev" => "ESP32"} end)
    end
  end

  describe "a keg on the allow-list" do
    test "is acked, registered and stored" do
      socket = connect(listen())

      send_data(socket, login(1) <> pin(2, "51", "12.5"))
      assert recv(socket) == ack(1)

      eventually(fn -> stored(:amount_left) == "12.5" end)
      assert KegData.devices() == [@keg]
      assert KegCommander.connected_kegs() == [@keg]
    end

    test "is one keg whatever the case of the id it sends" do
      socket = connect(listen())

      send_data(socket, login(1, String.upcase(@keg)) <> pin(2, "51", "12.5"))
      assert recv(socket) == ack(1)

      eventually(fn -> stored(:amount_left) == "12.5" end)
      assert KegData.devices() == [@keg]
      assert KegCommander.connected_kegs() == [@keg]

      send_data(socket, login(3, @keg))
      assert recv(socket) == ack(3)
    end

    test "a frame split across reads is put together" do
      socket = connect(listen())
      send_data(socket, login())
      assert recv(socket) == ack(1)

      for {cut, msg_id, value} <- [{3, 2, "7.25"}, {9, 3, "8.5"}] do
        <<head::binary-size(cut), tail::binary>> = pin(msg_id, "51", value)

        send_data(socket, head)
        assert recv(socket, 100) == {:error, :timeout}
        send_data(socket, tail)
        assert recv(socket) == ack(msg_id)

        eventually(fn -> stored(:amount_left) == value end)
      end
    end

    test "a value that is not UTF-8 is dropped, and the API still encodes" do
      socket = connect(listen())
      send_data(socket, login())
      assert recv(socket) == ack(1)

      send_data(socket, pin(2, "56", <<0xFF, 0xFE>>))
      assert recv(socket) == ack(2)
      send_data(socket, pin(3, "51", "3.5"))
      assert recv(socket) == ack(3)

      eventually(fn -> stored(:amount_left) == "3.5" end)
      assert stored(:keg_temperature) == nil
      assert Poison.encode!(KegData.all()) =~ "3.5"
    end

    test "cannot become another keg with a second login" do
      socket = connect(listen(allowed_ids: []))
      send_data(socket, login())
      assert recv(socket) == ack(1)

      send_data(socket, login(2, @other) <> pin(3, "51", "12.5"))
      assert recv(socket) == {:error, :closed}

      eventually(fn -> KegCommander.connected_kegs() == [] end)
      assert KegData.devices() == []
    end

    test "may repeat its own login" do
      socket = connect(listen())
      send_data(socket, login())
      assert recv(socket) == ack(1)

      send_data(socket, login(2))
      assert recv(socket) == ack(2)
      assert KegCommander.connected_kegs() == [@keg]
    end

    test "a new login with the same id closes the earlier connection and gets its commands" do
      port = listen()

      first = connect(port)
      send_data(first, login() <> pin(2, "51", "12.5"))
      assert recv(first) == ack(1)

      second = connect(port)
      send_data(second, login())
      assert recv(second) == ack(1)

      assert recv(first) == {:error, :closed}
      assert KegCommander.connected_kegs() == [@keg]

      KegCommander.tare(@keg)
      assert {:ok, command} = recv(second)

      assert {:ok, [{:hardware, _msg_id, _length, body}], ""} = BlynkProtocol.parse(command)
      assert String.split(body, "\0") == ["vw", "60", "1"]
    end

    test "its id and its data stay out of the process status" do
      socket = connect(listen())
      send_data(socket, login() <> pin(2, "51", "12.5"))
      assert recv(socket) == ack(1)

      [{handler, _socket}] = Registry.lookup(OpenPlaatoKeg.KegSocketRegistry, @keg)
      status = inspect(:sys.get_status(handler), limit: :infinity, printable_limit: :infinity)

      refute status =~ @keg
      assert status =~ "012345…"

      # The last message is part of a crash report too.
      assert %{message: {:tcp, :port, 7}} =
               KegConnectionHandler.format_status(%{message: {:tcp, :port, "payload"}})
    end
  end

  describe "the configured allow-list" do
    setup do
      config = Application.get_env(:open_plaato_keg, :tcp_listener)
      on_exit(fn -> Application.put_env(:open_plaato_keg, :tcp_listener, config) end)

      Application.put_env(:open_plaato_keg, :tcp_listener, port: 0, allowed_ids: [@keg])
    end

    test "is what a listener started without ids in its options goes by" do
      port = listen(allowed_ids: nil)

      refused = connect(port)
      send_data(refused, login(1, @other))
      assert_refused(refused)

      socket = connect(port)
      send_data(socket, login())
      assert recv(socket) == ack(1)
    end

    test "includes the ids in the file, as the file is at each login" do
      file = Path.join(System.tmp_dir!(), "allowed_ids_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(file) end)
      File.write!(file, "# kegs\n\n#{String.upcase(@other)}  # the second one\n")

      Application.put_env(:open_plaato_keg, :tcp_listener,
        allowed_ids: [@keg],
        allowed_ids_file: file
      )

      port = listen(allowed_ids: nil)
      stranger = String.duplicate("a", 32)

      for id <- [@keg, @other] do
        socket = connect(port)
        send_data(socket, login(1, id))
        assert recv(socket) == ack(1)
      end

      refused = connect(port)
      send_data(refused, login(1, stranger))
      assert recv(refused) == {:error, :closed}

      # No restart: the next login sees the file as it is now.
      File.write!(file, stranger <> "\n")

      socket = connect(port)
      send_data(socket, login(1, stranger))
      assert recv(socket) == ack(1)

      removed = connect(port)
      send_data(removed, login(1, @other))
      assert recv(removed) == {:error, :closed}
    end

    test "a keg with a name in the file goes by it, and keeps it under another id" do
      file = Path.join(System.tmp_dir!(), "allowed_ids_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(file) end)
      File.write!(file, "#{@keg} left-tap\n")

      Application.put_env(:open_plaato_keg, :tcp_listener,
        allowed_ids: [],
        allowed_ids_file: file
      )

      port = listen(allowed_ids: nil)

      first = connect(port)
      send_data(first, login() <> pin(2, "51", "12.5"))
      assert recv(first) == ack(1)

      eventually(fn -> stored(:amount_left, "left-tap") == "12.5" end)
      assert KegCommander.connected_kegs() == ["left-tap"]
      assert KegData.devices() == ["left-tap"]
      refute inspect(KegData.all()) =~ @keg

      # Its own login again is fine; the keg's name is not a login.
      send_data(first, login(3))
      assert recv(first) == ack(3)

      # The keg gets a new id: the same keg, taking over from its old connection.
      File.write!(file, "#{@other} left-tap\n")

      second = connect(port)
      send_data(second, login(1, @other) <> pin(2, "51", "11.0"))
      assert recv(second) == ack(1)
      assert recv(first) == {:error, :closed}

      eventually(fn -> stored(:amount_left, "left-tap") == "11.0" end)
      eventually(fn -> KegCommander.connected_kegs() == ["left-tap"] end)
      assert KegData.devices() == ["left-tap"]

      old = connect(port)
      send_data(old, login())
      assert recv(old) == {:error, :closed}
    end

    test "allows nothing from a file that cannot be read" do
      Application.put_env(:open_plaato_keg, :tcp_listener,
        allowed_ids: [],
        allowed_ids_file: "/nonexistent/allowed-ids"
      )

      port = listen(allowed_ids: nil)

      log =
        capture_log(fn ->
          socket = connect(port)
          send_data(socket, login())
          assert_refused(socket)
        end)

      assert log =~ "allow-list file is not readable (enoent)"
    end
  end

  describe "without an allow-list" do
    test "any well-formed id logs in" do
      socket = connect(listen(allowed_ids: []))

      send_data(socket, login(1, @other) <> pin(2, "51", "12.5"))
      assert recv(socket) == ack(1)

      eventually(fn -> stored(:amount_left, @other) == "12.5" end)
    end
  end

  describe "the recorded firmware session in local/bin" do
    test "is accepted read by read and ends up in the store" do
      reads =
        "local/bin/*.bin"
        |> Path.wildcard()
        |> Enum.sort_by(&(&1 |> Path.basename(".bin") |> String.to_integer()))
        |> Enum.map(&File.read!/1)

      {:ok, [{:get_shared_dash, _msg_id, _length, id} | _], ""} = BlynkProtocol.parse(hd(reads))

      id = String.downcase(id)
      socket = connect(listen(allowed_ids: [id]))

      for read <- reads do
        send_data(socket, read)
        assert {:ok, <<0, _msg_id::16, 200::16>>} = recv(socket)
      end

      eventually(fn -> KegCommander.connected_kegs() == [id] end)
      :gen_tcp.close(socket)
      eventually(fn -> KegCommander.connected_kegs() == [] end)

      keg = KegData.get(id)
      assert keg[:internal]["ver"]
      assert keg[:amount_left]
      assert keg[:is_pouring] == "0"
      assert Poison.decode!(Poison.encode!(KegData.all())) |> length() == 1
    end
  end
end
