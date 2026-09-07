defmodule Journeys.KegSetupTest do
  use ExUnit.Case
  import AssertValue

  alias OpenPlaatoKeg.PlaatoData
  alias OpenPlaatoKeg.PlaatoProtocol

  test "tare" do
    cmd = {:hardware, 19392, 7, <<118, 119, 0, 54, 48, 0, 49>>}
    decoded = decode(cmd)

    assert_value(
      decoded == [plaato_decoded: {:hardware, "vw", "60", "1"}, plaato_data_decoded: {:tare, "1"}]
    )

    cmd = {:hardware, 9043, 7, <<118, 119, 0, 54, 48, 0, 48>>}
    decoded = decode(cmd)

    assert_value(
      decoded == [plaato_decoded: {:hardware, "vw", "60", "0"}, plaato_data_decoded: {:tare, "0"}]
    )
  end

  test "empty keg" do
    cmd = {:hardware, 13671, 7, <<118, 119, 0, 54, 50, 0, 49>>}
    decoded = decode(cmd)

    assert_value(
      decoded == [
        plaato_decoded: {:hardware, "vw", "62", "1"},
        plaato_data_decoded: {:empty_keg_weight, "1"}
      ]
    )

    cmd = {:hardware, 13671, 7, <<118, 119, 0, 54, 50, 0, 48>>}
    decoded = decode(cmd)

    assert_value(
      decoded == [
        plaato_decoded: {:hardware, "vw", "62", "0"},
        plaato_data_decoded: {:empty_keg_weight, "0"}
      ]
    )
  end

  test "max keg volume to 19.66" do
    cmd = {:hardware, 31460, 11, <<118, 119, 0, 55, 54, 0, 49, 57, 46, 54, 54>>}
    decoded = decode(cmd)

    assert_value(
      decoded == [
        plaato_decoded: {:hardware, "vw", "76", "19.66"},
        plaato_data_decoded: {:max_keg_volume, "19.66"}
      ]
    )
  end

  test "calculate" do
    cmd = {:hardware, 22383, 7, <<118, 119, 0, 55, 50, 0, 49>>}
    decoded = decode(cmd)

    assert_value(
      decoded == [
        plaato_decoded: {:hardware, "vw", "72", "1"},
        plaato_data_decoded: {:calculate, "1"}
      ]
    )

    cmd = {:hardware, 32027, 7, <<118, 119, 0, 55, 50, 0, 48>>}
    decoded = decode(cmd)

    assert_value(
      decoded == [
        plaato_decoded: {:hardware, "vw", "72", "0"},
        plaato_data_decoded: {:calculate, "0"}
      ]
    )
  end

  defp decode(blynk_cmd) do
    plaato_decoded = PlaatoProtocol.decode(blynk_cmd)
    plaato_data_decoded = PlaatoData.decode(plaato_decoded)

    [
      plaato_decoded: plaato_decoded,
      plaato_data_decoded: plaato_data_decoded
    ]
  end
end
