defmodule OpenPlaatoKeg.Models.KegDataTest do
  use ExUnit.Case

  alias OpenPlaatoKeg.Models.KegData

  setup do
    :dets.close(:keg_data)

    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "open_plaato_keg_test_#{unique}")
    File.mkdir_p!(dir)

    {:ok, _} = :dets.open_file(:keg_data, file: String.to_charlist(Path.join(dir, "kegs.dets")))

    on_exit(fn ->
      :dets.close(:keg_data)
      File.rm_rf(dir)
    end)

    :ok
  end

  test "devices lists every registered keg id" do
    KegData.publish("keg-a", id: "keg-a", amount_left: "12.3")
    KegData.publish("keg-b", id: "keg-b", amount_left: "0.0")

    assert Enum.sort(KegData.devices()) == ["keg-a", "keg-b"]
  end

  test "get returns stored properties plus a derived litre unit" do
    KegData.publish("keg-a", id: "keg-a", amount_left: "12.3")

    assert KegData.get("keg-a") == %{
             id: "keg-a",
             amount_left: "12.3",
             beer_left_unit: "litre"
           }
  end

  test "get derives a kg unit when the device measures by weight" do
    KegData.publish("keg-a", id: "keg-a", amount_left: "9.0", measure_unit: "1")

    assert KegData.get("keg-a")[:beer_left_unit] == "kg"
  end

  test "rename moves a keg, with its id, to another name" do
    KegData.publish("keg-a", id: "keg-a", amount_left: "12.3", my_label: "Left")
    KegData.publish("keg-b", id: "keg-b", amount_left: "0.0")

    assert KegData.rename("keg-a", "left") == :ok

    assert Enum.sort(KegData.devices()) == ["keg-b", "left"]
    assert KegData.get("left")[:my_label] == "Left"
    assert KegData.get("left")[:id] == "left"
    refute KegData.known?("keg-a")
  end

  test "rename does not overwrite a keg, or move one that is not there" do
    KegData.publish("keg-a", id: "keg-a", amount_left: "12.3")
    KegData.publish("keg-b", id: "keg-b", amount_left: "0.0")

    assert KegData.rename("keg-a", "keg-b") == {:error, :exists}
    assert KegData.rename("keg-c", "left") == {:error, :not_found}
    assert KegData.get("keg-b")[:amount_left] == "0.0"
  end

  test "all returns one map per device" do
    KegData.publish("keg-a", id: "keg-a", amount_left: "12.3")

    assert KegData.all() == [%{id: "keg-a", amount_left: "12.3", beer_left_unit: "litre"}]
  end
end
