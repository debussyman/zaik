defmodule Zaik.Tools.RegistryTest do
  use ExUnit.Case, async: true

  defmodule HotTool do
    @behaviour Zaik.Tool

    def descriptor do
      %{
        name: "hot_tool",
        aliases: ["hot_alias"],
        description: "A runtime configured test tool.",
        input_schema: %{"type" => "object"},
        kind: :read,
        risk: :none
      }
    end

    def run(args, context), do: {:ok, %{args: args, context: context}}
  end

  defmodule DuplicateHotTool do
    @behaviour Zaik.Tool

    def descriptor do
      %{
        name: "hot_tool",
        description: "Duplicate name.",
        input_schema: %{},
        kind: :read,
        risk: :none
      }
    end

    def run(_args, _context), do: {:ok, :duplicate}
  end

  test "discovers and invokes runtime-configured modules without a process cache" do
    opts = [modules: [HotTool]]

    assert :ok = Zaik.Tools.Registry.validate(opts)
    assert {:ok, %{module: HotTool}} = Zaik.Tools.Registry.fetch("hot_alias", opts)

    assert {:ok, %{args: %{"value" => 1}, context: %{request_id: "r1"}}} =
             Zaik.Tools.Registry.run(
               "hot_tool",
               %{"value" => 1},
               %{request_id: "r1"},
               opts
             )
  end

  test "rejects duplicate canonical tool names" do
    assert {:error, {:duplicate_tool_names, ["hot_tool"]}} =
             Zaik.Tools.Registry.validate(modules: [HotTool, DuplicateHotTool])
  end

  test "default registry exposes typed state and existing compatibility tools" do
    names = Zaik.Tools.Registry.descriptors() |> Enum.map(& &1.name)

    assert "get_home_state" in names
    assert "list_devices" in names
    assert "execute_home_plan" in names
    assert "retry_home_action" in names
    assert "sql_query" in names
    assert "control_device" in names
    assert "control_blind" in names
  end
end
