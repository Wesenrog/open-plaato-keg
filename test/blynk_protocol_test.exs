defmodule OpenPlaatoKeg.BlynkProtocolTest do
  use ExUnit.Case

  alias OpenPlaatoKeg.BlynkProtocol

  defp frame(cmd, msg_id, body), do: BlynkProtocol.encode_command(cmd, msg_id, body)

  describe "parse/2" do
    test "returns the complete frames and no rest" do
      data = frame(:hardware, 7, "vw\0" <> "51\0" <> "12.5") <> frame(:ping, 8, "")

      assert BlynkProtocol.parse(data) ==
               {:ok, [{:hardware, 7, 10, "vw\0" <> "51\0" <> "12.5"}, {:ping, 8, 0, ""}], ""}
    end

    test "keeps an incomplete frame as rest, wherever it is cut" do
      data = frame(:ping, 1, "") <> frame(:hardware, 2, "vw\0" <> "51\0" <> "12.5")

      for cut <- 0..(byte_size(data) - 1) do
        <<head::binary-size(cut), tail::binary>> = data

        {:ok, first, rest} = BlynkProtocol.parse(head)
        {:ok, second, ""} = BlynkProtocol.parse(rest <> tail)

        assert first ++ second == BlynkProtocol.decode(data)
      end
    end

    test "fewer bytes than a header are rest, not an error" do
      assert BlynkProtocol.parse(<<20, 0>>) == {:ok, [], <<20, 0>>}
      assert BlynkProtocol.parse("") == {:ok, [], ""}
    end

    test "refuses a frame whose header announces more than the limit" do
      assert BlynkProtocol.parse(<<20, 1::16, 1025::16>>) == {:error, :frame_too_large}
      assert BlynkProtocol.parse(<<20, 1::16, 11::16>>, 10) == {:error, :frame_too_large}

      # ... also behind a valid frame, and never for a frame at the limit.
      assert BlynkProtocol.parse(frame(:ping, 1, "") <> "GET / HTTP/1.1\r\n") ==
               {:error, :frame_too_large}

      body = String.duplicate("a", 1024)

      assert {:ok, [{:hardware, 1, 1024, ^body}], ""} =
               BlynkProtocol.parse(frame(:hardware, 1, body))
    end

    test "a response is a bare header whose length field is the status" do
      data = BlynkProtocol.response_success(9) <> frame(:ping, 10, "")

      assert BlynkProtocol.parse(data) ==
               {:ok, [{:response, 9, :success, ""}, {:ping, 10, 0, ""}], ""}
    end

    test "an unknown command is a frame like any other" do
      assert BlynkProtocol.parse(<<200, 1::16, 2::16, "ab">>) ==
               {:ok, [{:unknown_cmd, 1, 2, "ab"}], ""}
    end
  end

  describe "the recorded firmware session in local/bin" do
    test "every read is whole frames within the listener's limits" do
      files = Path.wildcard("local/bin/*.bin")
      assert length(files) > 100

      for file <- files do
        assert {:ok, [_ | _] = frames, ""} = BlynkProtocol.parse(File.read!(file))

        for {_cmd, _msg_id, _length, body} <- frames do
          assert String.valid?(body)
        end
      end
    end
  end
end
