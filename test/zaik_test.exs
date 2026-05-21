defmodule ZaikTest do
  use ExUnit.Case, async: true

  describe "Zaik module" do
    test "starts and stops successfully" do
      assert :ok == Zaik.start()
      assert :ok == Zaik.stop()
    end

    test "gets hello message" do
      assert :ok == Zaik.start()
      assert "Hello, World!" == Zaik.hello()
      assert :ok == Zaik.stop()
    end

    test "sends message successfully" do
      assert :ok == Zaik.start()
      assert :ok == Zaik.send_message("Test message")
      assert :ok == Zaik.stop()
    end
  end
end