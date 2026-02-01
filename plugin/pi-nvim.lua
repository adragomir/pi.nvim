if vim.g.loaded_pi_nvim then
  return
end
vim.g.loaded_pi_nvim = true

vim.api.nvim_create_autocmd("FileType", {
  pattern = "pi",
  callback = function(ev)
    local bufnr = ev.buf

    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].buftype = "nofile"

    vim.wo.wrap = true
    vim.wo.linebreak = true
    vim.wo.conceallevel = 2
    vim.wo.concealcursor = "nc"
  end,
})
