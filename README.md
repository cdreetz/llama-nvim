# Setup

Add the following to your Lazy Nvim config:

```
-- In their plugins.lua or similar config file
return {
  {
    "cdreetz/llama-nvim",
    config = function()
      require("llama-nvim").setup({
        api_key = "your_llama_api_key",
        model = "Llama-4-Maverick-17B-128E-Instruct-FP8"
      })
    end,
    dependencies = {
      "nvim-lua/plenary.nvim"  -- Since your plugin uses plenary.curl
    }
  }
}
```
