defmodule OpenPlaatoKeg.AllowListTest do
  use ExUnit.Case, async: true

  alias OpenPlaatoKeg.AllowList

  @keg "0123456789abcdef0123456789abcdef"
  @other "fedcba9876543210fedcba9876543210"

  defp file(content) do
    path = Path.join(System.tmp_dir!(), "allow_list_test_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "read/1" do
    test "takes one id per line, skipping comments and blank lines" do
      path = file("# my kegs\n\n#{@keg}\n  #{String.upcase(@other)}  # the second\r\n")

      assert AllowList.read(path) == {:ok, [{@keg, @keg}, {@other, @other}], 0}
    end

    test "takes the keg's name after the id" do
      path = file("#{String.upcase(@keg)}   Left_tap-1  # in the bar\n#{@other}\tright\n")

      assert AllowList.read(path) == {:ok, [{@keg, "Left_tap-1"}, {@other, "right"}], 0}
    end

    test "counts the lines that are not an id and a name" do
      path = file("#{@keg}\nnot-an-id\n#{@keg}ff\n#{@other} two words\n#{@other} a/b\n")

      assert AllowList.read(path) == {:ok, [{@keg, @keg}], 4}
    end

    test "gives the error for a file that cannot be read" do
      assert AllowList.read("/nonexistent/allowed-ids") == {:error, :enoent}
    end
  end

  describe "check/2" do
    test "allows any id when neither a list nor a file is set" do
      assert AllowList.check(String.upcase(@other), allowed_ids: []) == {:ok, @other}
    end

    test "allows the ids of the list and of the file, in any case" do
      config = [allowed_ids: [@keg], allowed_ids_file: file(@other <> "\n")]

      assert AllowList.check(String.upcase(@keg), config) == {:ok, @keg}
      assert AllowList.check(String.upcase(@other), config) == {:ok, @other}

      assert AllowList.check(String.duplicate("a", 32), config) ==
               {:error, "id aaaaaa… is not on the allow-list"}
    end

    test "gives the name the file has for the id, also when the list has the id too" do
      config = [allowed_ids: [@keg], allowed_ids_file: file("#{@keg} left\n#{@other} left\n")]

      assert AllowList.check(@keg, config) == {:ok, "left"}
      assert AllowList.check(@other, config) == {:ok, "left"}
    end

    test "falls back on the list when the file cannot be read" do
      config = [allowed_ids: [@keg], allowed_ids_file: "/nonexistent/allowed-ids"]

      assert AllowList.check(@keg, config) == {:ok, @keg}
      assert {:error, _} = AllowList.check(@other, config)
    end

    test "allows nothing from an empty or unreadable file" do
      assert {:error, _} = AllowList.check(@keg, allowed_ids_file: file(""))

      assert AllowList.check(@keg, allowed_ids_file: "/nonexistent/allowed-ids") ==
               {:error, "allow-list file is not readable (enoent)"}
    end
  end
end
