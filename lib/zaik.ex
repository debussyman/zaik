defmodule Zaik do
  @moduledoc """
  Zaik is a personal AI agent runtime inspired by OpenClaw, built with Elixir's actor system.

  The system is designed to run multiple AI agents that can:
  - Process messages 
  - Handle periodic ticks
  - Store state
  - Communicate with each other
  """

  @doc """
  Start the Zaik system with all required supervisors and agents.
  """
  def start do
    Application.start(:zaik)
  end

  @doc """
  Stop the Zaik system.
  """
  def stop do
    Application.stop(:zaik)
  end

  @doc """
  Create a filesystem-backed session.
  """
  def create_session(opts \\ []) do
    Zaik.SessionStore.create(opts)
  end

  @doc """
  List filesystem-backed sessions.
  """
  def list_sessions(opts \\ []) do
    Zaik.SessionStore.list(opts)
  end

  @doc """
  Build context from a session's active branch.
  """
  def get_session_context(session_id, opts \\ []) do
    Zaik.ContextBuilder.build(session_id, opts)
  end

  @doc """
  Fetch a task by ID.
  """
  def get_task(task_id) do
    Zaik.TaskStore.get(task_id)
  end

  @doc """
  List tasks from the in-memory task store.
  """
  def list_tasks(opts \\ []) do
    Zaik.TaskStore.list(opts)
  end

  @doc """
  Get the current task queue size.
  """
  def queue_size do
    Zaik.TaskQueue.size()
  end

  @doc """
  Get a greeting from the hello world agent.
  """
  def hello do
    Zaik.Agent.HelloWorld.hello()
  end

  @doc """
  Send a message to the hello world agent.
  """
  def send_message(message) do
    Zaik.Agent.HelloWorld.send_message(message)
  end
end
