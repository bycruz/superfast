-- Lapis benchmark app: empty 200 on "/" (comparable to the other servers).
-- Run with: lapis server  (the lapis CLI drives OpenResty; see config.lua)
local lapis = require("lapis")

local app = lapis.Application()

app:get("/", function()
  return { status = 200 }
end)

return app
