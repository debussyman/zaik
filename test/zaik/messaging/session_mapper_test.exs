defmodule Zaik.Messaging.SessionMapperTest do
  use ExUnit.Case, async: false

  test "same sender maps to same session" do
    sender = "+1555#{System.unique_integer([:positive])}"

    assert {:ok, first} = Zaik.Messaging.SessionMapper.get_or_create_session(:signal, sender)
    assert {:ok, second} = Zaik.Messaging.SessionMapper.get_or_create_session(:signal, sender)

    assert first.id == second.id
    assert first.cwd == "signal:#{sender}"
  end

  test "different senders map to different sessions" do
    sender_a = "+1555#{System.unique_integer([:positive])}"
    sender_b = "+1555#{System.unique_integer([:positive])}"

    assert {:ok, first} = Zaik.Messaging.SessionMapper.get_or_create_session(:signal, sender_a)
    assert {:ok, second} = Zaik.Messaging.SessionMapper.get_or_create_session(:signal, sender_b)

    refute first.id == second.id
  end
end
