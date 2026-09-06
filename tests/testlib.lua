local M = { failures = 0 }
function M.eq(name, got, want)
  if got ~= want then
    M.failures = M.failures + 1
    io.stderr:write(string.format("FAIL %s: got %q want %q\n", name, tostring(got), tostring(want)))
  else
    io.stdout:write("PASS " .. name .. "\n")
  end
end
function M.truthy(name, value)
  M.eq(name, not not value, true)
end
function M.finish()
  if M.failures > 0 then os.exit(1) end
end
return M
