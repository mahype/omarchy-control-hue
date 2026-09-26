-- Omarchy Control for Hue shortcuts, loaded from ~/.config/hypr/bindings.lua.
--   SUPER + CTRL + ALT + 1..9  apply the Hue profile on that key
--   SUPER + CTRL + ALT + 0     turn all Hue lights off
-- Profiles live in the plugin; a key without a profile does nothing.
local target = "omarchy-shell -q io.github.mahype.omarchy-control-hue "
for slot = 1, 9 do
  o.bind("SUPER + CTRL + ALT + " .. slot, "Apply Hue profile " .. slot, target .. "applyProfile " .. slot)
end
o.bind("SUPER + CTRL + ALT + 0", "Turn all Hue lights off", target .. "allOff")
