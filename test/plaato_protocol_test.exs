defmodule OpenPlaatoKeg.PlaatoProtocolTest do
  use ExUnit.Case

  alias OpenPlaatoKeg.PlaatoProtocol

  test "internal properties are key/value pairs" do
    assert PlaatoProtocol.decode({:internal, 1, 9, "ver\0" <> "2.0\0" <> "dev\0" <> "ESP32"}) ==
             {:internal, :not_relevant, :not_relevant, %{"ver" => "2.0", "dev" => "ESP32"}}
  end

  test "a key without a value is left out instead of raising" do
    assert PlaatoProtocol.decode({:internal, 1, 9, "ver\0" <> "2.0\0" <> "dev"}) ==
             {:internal, :not_relevant, :not_relevant, %{"ver" => "2.0"}}

    assert PlaatoProtocol.decode({:internal, 1, 0, ""}) ==
             {:internal, :not_relevant, :not_relevant, %{}}
  end
end
