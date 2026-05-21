# Zaik

Zaik is a personal AI agent runtime inspired by OpenClaw, built with Elixir's actor system.

## Overview

This system demonstrates the core capabilities of an agent-based architecture using Elixir's GenServer and OTP primitives. The architecture includes:

- An agent supervisor that manages multiple agent instances
- A clock service that provides periodic tick messages
- A base agent behavior for defining custom agent functionality
- A hello world agent example

## Features

- Actor-based architecture using GenServer
- Periodic ticking system for time-based processing
- Message-passing between agents
- State persistence for agents
- Supervisor tree for system management

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `zaik` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:zaik, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
# Start the system
Zaik.start()

# Get a greeting from the hello world agent
Zaik.hello()

# Send a message to the hello world agent
Zaik.send_message("Hello, Zaik!")

# Stop the system
Zaik.stop()
```

## Development

To run the application and interact with agents:

1. Create a new Elixir project
2. Add `zaik` as a dependency
3. Start the application with `Zaik.start()`

## License

MIT License. See [LICENSE](LICENSE) for more information.