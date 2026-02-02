# pi-nvim

A Neovim plugin for interacting with the [Pi coding agent](https://github.com/anthropics/pi-mono).

## Features

- **Terminal Mode**: Open a terminal running the `pi` command directly
- **RPC Mode**: Connect to a running Pi agent via TCP RPC, with a chat-style interface
- **Visual Selection**: Select code and send it to the agent with a custom prompt
- **Extension UI**: Handle extension requests (select, confirm, input, editor dialogs)

## Requirements

- Neovim >= 0.9.0
- Pi coding agent installed (`pi` command available, or a running RPC instance)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-username/pi-nvim",
  config = function()
    require("pi-nvim").setup({
      -- options (see Configuration below)
    })
  end,
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "your-username/pi-nvim",
  config = function()
    require("pi-nvim").setup()
  end,
}
```

## Usage

### Commands

| Command | Description |
|---------|-------------|
| `:PiAgent new` | Open a terminal running `pi` |
| `:vertical PiAgent new` | Open terminal in vertical split |
| `:PiAgent <port>` | Connect to RPC server on given port |
| `:PiAgent status` | Show current session status |
| `:PiAgent abort` | Abort current RPC operation |
| `:PiAgent reconnect` | Reconnect to RPC server |

### Keymaps

| Mode | Keymap | Description |
|------|--------|-------------|
| Visual | `<leader>a` | Open prompt popup for selected text |
| Normal (in chat) | `<CR>` | Submit prompt (when cursor in input area) |
| Insert (in chat) | `<C-CR>` | Submit prompt |
| Any (in chat) | `<C-c>` | Abort current operation |

### Workflow

#### Terminal Mode

1. Run `:PiAgent new` to open a terminal with the Pi agent
2. Interact directly with the terminal
3. Use `<leader>pi` in visual mode to send selected code with a prompt

#### RPC Mode

1. Start Pi agent with RPC: `pi --rpc --port 9999`
2. In Neovim: `:PiAgent 9999`
3. Type prompts in the input area at the bottom
4. Press `<CR>` to submit
5. Use `<leader>pi` in visual mode to send selected code with a prompt

## Configuration

```lua
require("pi-nvim").setup({
  -- RPC connection settings
  host = "127.0.0.1",
  default_port = 9999,

  -- UI settings
  split_direction = "horizontal", -- "horizontal" or "vertical"
  filetype = "pi", -- filetype for chat buffer

  -- Terminal settings
  pi_command = "pi",

  -- Visual selection prompt format
  -- Available placeholders: {file}, {start_line}, {end_line}, {filetype}, {selection}, {prompt}
  prompt_format = "In file `{file}` lines {start_line}-{end_line}:\n```{filetype}\n{selection}\n```\n\n{prompt}",

  -- Keymaps
  keymaps = {
    visual_prompt = "<leader>pi", -- set to nil to disable
  },
})
```

