# Zaik Project Enhancement Plan - Technical Details

## Enhancement 1: Remote Harness via WhatsApp or Signal

### Technical Implementation Approach

#### 1. Messaging Service Integration
```elixir
# Define a generic messaging adapter behaviour
defmodule Zaik.Messaging.Adapter do
  @callback send_message(to, message) :: :ok | {:error, term}
  @callback receive_message() :: {:ok, message} | {:error, term}
  @callback parse_command(message) :: command
end

# WhatsApp adapter example
defmodule Zaik.Messaging.WhatsAppAdapter do
  @behaviour Zaik.Messaging.Adapter
  
  def send_message(to, message) do
    # Implementation using WhatsApp Business API or Twilio
  end
  
  def receive_message() do
    # Implementation to receive messages
  end
  
  def parse_command(message) do
    # Parse message into command structure
  end
end
```

#### 2. Command Processing System
```elixir
defmodule Zaik.CommandProcessor do
  def process_command(command) do
    case command do
      %{"type" => "agent", "action" => "hello"} -> 
        Zaik.hello()
      %{"type" => "agent", "action" => "send_message", "message" => msg} ->
        Zaik.send_message(msg)
      _ -> 
        "Unknown command"
    end
  end
end
```

### Core Modules to Create:
1. `Zaik.Messaging.Adapter` - Generic interface
2. `Zaik.Messaging.WhatsApp` - WhatsApp integration
3. `Zaik.Messaging.Signal` - Signal integration  
4. `Zaik.CommandProcessor` - Command handling
5. `Zaik.Messaging.Supervisor` - Manage messaging processes

## Enhancement 2: Local LLM Agent

### Technical Implementation Approach

#### 1. LLM Model Interface
```elixir
# Define standard LLM interface
defmodule Zaik.LLM.Model do
  @callback generate(prompt, options) :: {:ok, response} | {:error, reason}
  @callback model_info() :: model_description
end

# Ollama-based implementation
defmodule Zaik.LLM.Ollama do
  @behaviour Zaik.LLM.Model
  
  def generate(prompt, options) do
    # Call ollama API with prompt and options
  end
  
  def model_info() do
    # Return model information
  end
end
```

#### 2. LLM Agent Behavior
```elixir
defmodule Zaik.Agent.LLM do
  use Zaik.Agent.Base
  
  def agent_init(args) do
    {:ok, %{
      model: Keyword.get(args, :model, :ollama),
      context: [],
      temperature: Keyword.get(args, :temperature, 0.7)
    }}
  end
  
  def handle_message(message, state) do
    # Integrate with LLM model
    response = Zaik.LLM.Model.generate(message, temperature: state.temperature)
    # Process and respond to message
    {:reply, response, state}
  end
  
  def handle_tick(state) do
    # Handle periodic updates
    state
  end
end
```

### Core Modules to Create:
1. `Zaik.LLM.Model` - Generic interface for LLMs
2. `Zaik.LLM.Ollama` - Ollama integration
3. `Zaik.LLM.LlamaCpp` - Local llama.cpp integration
4. `Zaik.Agent.LLM` - LLM-aware agent behavior
5. `Zaik.LLM.Supervisor` - Manage LLM processes

## Integration Strategy

### Phase 1: Messaging Integration
1. Create basic messaging adapters
2. Implement command parsing
3. Connect to WhatsApp using Twilio or official API
4. Test basic send/receive functionality

### Phase 2: LLM Integration
1. Implement local model runner
2. Create LLM agent behavior
3. Test with sample models (e.g., llama2, mistral)
4. Add context management and response processing

### Phase 3: System Integration
1. Combine messaging and LLM capabilities
2. Build end-to-end workflows
3. Add error handling and logging
4. Optimize performance and memory usage

## Deployment Requirements

### For Messaging:
- WhatsApp Business API credentials or Twilio account
- Webhook endpoint for message receiving
- SSL certificate for webhook endpoints
- Proper error handling and retry mechanisms

### For Local LLM:
- Local machine with sufficient CPU/GPU resources
- ollama installed and running
- Model files downloaded and available
- Memory management for concurrent requests

## Configuration Files

### config/messaging.exs
```elixir
config :zaik, :messaging,
  provider: :whatsapp,
  webhook_url: "https://your-domain.com/webhook",
  credentials: [
    api_key: "your_api_key",
    phone_number_id: "your_phone_number_id"
  ]
```

### config/llm.exs
```elixir
config :zaik, :llm,
  default_model: "llama2",
  ollama_url: "http://localhost:11434",
  models: [
    %{
      name: "llama2",
      url: "http://localhost:11434",
      context_length: 2048
    },
    %{
      name: "mistral",
      url: "http://localhost:11434",
      context_length: 8192
    }
  ]
```

This approach leverages Elixir's strengths in concurrency and fault tolerance while maintaining clean separation between messaging, model, and agent responsibilities.