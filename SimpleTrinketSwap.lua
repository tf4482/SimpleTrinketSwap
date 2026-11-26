-- SimpleTrinketSwap: equips trinkets by a priority list per slot and trinket set, out of combat

local ADDON, ns = ...

-- trinket inventory slots and their labels
local SLOTS = { 13, 14 }
local SLOT_NAMES = { [13] = "Trinket 1", [14] = "Trinket 2" }
-- priority positions per slot list; the settings page shows one more than are filled
local POSITIONS = 10
-- equipping starts a 30 s cooldown, so less remaining counts as ready
local READY = 30
-- key of the trinket set used without an active equipment set
local DEFAULT = "default"
-- prefix of trinket set keys tied to an equipment set name
local PREFIX = "set:"

-- pending swap check
local timer
-- guard against change callbacks from our own page updates
local loading = false
-- settings page controls exist
local registered = false
-- dropdown choices, refilled in place: items and trinket sets
local itemChoices = {}
local setChoices = {}
-- items whose data was requested, to redraw once loaded
local requested = {}
-- forward declaration
local Apply

-- settings key of a list position
local function Key(slot, position)
  return "t" .. slot .. "_" .. position
end

-- display name of a trinket set key
local function SetName(key)
  if key == DEFAULT then
    return "Default"
  end
  return key:sub(#PREFIX + 1)
end

-- trinket set key of the equipment set name, if that set exists
local function EquipmentSetKey(name)
  if name and C_EquipmentSet.GetEquipmentSetID(name) then
    return PREFIX .. name
  end
end

-- whether a trinket set key belongs to an existing set
local function SetExists(key)
  return key == DEFAULT or (key:sub(1, #PREFIX) == PREFIX and EquipmentSetKey(SetName(key)) ~= nil)
end

-- trinket set of the last equipped equipment set, else the default set
local function ActiveKey()
  local key = ns.char.activeSet
  if key and SetExists(key) then
    return key
  end
  return DEFAULT
end

-- slot lists of a trinket set, created on first use
local function Lists(key)
  local sets = ns.char.sets
  sets[key] = sets[key] or { [13] = {}, [14] = {} }
  return sets[key]
end

-- trinket without a use effect
local function IsPassive(id)
  return C_Item.GetItemSpell(id) == nil
end

-- icon and name of an item; requests uncached data
local function ItemText(id)
  local name = C_Item.GetItemNameByID(id)
  if not name then
    requested[id] = true
    C_Item.RequestLoadItemData(id)
    name = "item " .. id
  end
  return "|T" .. (C_Item.GetItemIconByID(id) or 134400) .. ":0|t " .. name
end

-- trinket equipped or in the bags
local function Owned(id)
  return GetInventoryItemID("player", 13) == id or GetInventoryItemID("player", 14) == id
    or C_Item.GetItemCount(id) > 0
end

-- seconds until the item's cooldown ends
local function Remaining(id)
  local start, duration = C_Item.GetItemCooldown(id)
  if not start or start == 0 or duration == 0 then
    return 0
  end
  return math.max(0, start + duration - GetTime())
end

-- list cleaned up: no gaps or duplicates, at most one passive trinket and that one last;
-- the entry at position `changed` wins over older entries
local function Normalize(values, changed)
  local winner = changed and values[changed]
  local result, seen, passive = {}, {}, nil
  for index = 1, #values do
    local id = values[index]
    local beaten = winner and index ~= changed and id == winner
    if id ~= 0 and not seen[id] and not beaten then
      seen[id] = true
      if not IsPassive(id) then
        result[#result + 1] = id
      elseif not passive or index == changed then
        passive = id
      end
    end
  end
  result[#result + 1] = passive
  return result
end

-- best trinket for a slot, never `taken`: first owned and ready, else keep a listed one,
-- else the first owned
local function Choose(list, slot, taken)
  local fallback
  for _, id in ipairs(list) do
    if id ~= taken and Owned(id) then
      if Remaining(id) <= READY then
        return id
      end
      fallback = fallback or id
    end
  end
  local current = GetInventoryItemID("player", slot)
  if current and current ~= taken and tContains(list, current) then
    return current
  end
  return fallback
end

-- put a trinket into a slot, swapping with the other slot if it sits there
local function Equip(id, slot)
  local other = slot == 13 and 14 or 13
  ns.Debug("equip item " .. id .. " into slot " .. slot)
  if GetInventoryItemID("player", other) == id then
    PickupInventoryItem(other)
    PickupInventoryItem(slot)
    -- never leave a trinket on the cursor if the swap failed
    if CursorHasItem() then
      ClearCursor()
    end
  else
    -- C_Item version where available, global in older clients
    (C_Item and C_Item.EquipItemByName or EquipItemByName)(id, slot)
  end
end

-- run the swap check out of combat
local function Run()
  ns.AfterCombat(Apply)
end

-- run the swap check after a delay; replaces a pending check
local function Schedule(delay)
  if timer then
    timer:Cancel()
  end
  timer = C_Timer.NewTimer(delay, Run)
end

-- recheck soon; merges bursts of events into one check
local function Refresh()
  Schedule(0.1)
end

-- seconds an equipped trinket must still stay on: its hold time counted from its last use,
-- also through combat; 0 without hold time or use
local function HoldLeft(id)
  local hold = id and ns.char.hold[id]
  if not hold then
    return 0
  end
  local start, duration = C_Item.GetItemCooldown(id)
  -- the equip cooldown is no use
  if not start or start == 0 or duration <= READY then
    return 0
  end
  return math.max(0, start + hold - GetTime())
end

-- recheck when the next listed trinket becomes ready or a hold time ends
local function ScheduleNext(lists, holds)
  local wait
  for _, left in ipairs(holds) do
    if left > 0 and (not wait or left < wait) then
      wait = left
    end
  end
  for _, slot in ipairs(SLOTS) do
    for _, id in ipairs(lists[slot]) do
      local left = Remaining(id) - READY
      if left > 0 and Owned(id) and (not wait or left < wait) then
        wait = left
      end
    end
  end
  if wait then
    ns.Debug(string.format("next check in %.1f s", wait + 0.5))
    Schedule(wait + 0.5)
  end
end

-- one swap per pass, slot 1 picks first; a trinket in its hold time stays where it is;
-- the equipment event starts the next pass
function Apply()
  if ns.db == nil or not ns.Get("enabled") then
    return
  end
  -- mounted: leave the trinkets to addons that equip mount gear
  if ns.Get("mountPause") and IsMounted() then
    ns.Debug("mounted, swaps paused")
    return
  end
  if CursorHasItem() or UnitIsDeadOrGhost("player") or UnitCastingInfo("player")
    or UnitChannelInfo("player") then
    ns.Debug("busy, retry in 1 s")
    return Schedule(1)
  end
  local lists = Lists(ActiveKey())
  local current13 = GetInventoryItemID("player", 13)
  local current14 = GetInventoryItemID("player", 14)
  local hold13, hold14 = HoldLeft(current13), HoldLeft(current14)
  local first = hold13 > 0 and current13 or Choose(lists[13], 13, hold14 > 0 and current14 or nil)
  local second = hold14 > 0 and current14 or Choose(lists[14], 14, first)
  if first and current13 ~= first then
    return Equip(first, 13)
  elseif second and current14 ~= second then
    return Equip(second, 14)
  end
  ScheduleNext(lists, { hold13, hold14 })
end

-- refill the item dropdown choices: none, owned trinkets, and every listed trinket
local function RebuildItemChoices()
  local ids, seen = {}, {}
  local function Consider(id)
    if id and not seen[id] and select(4, C_Item.GetItemInfoInstant(id)) == "INVTYPE_TRINKET" then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  Consider(GetInventoryItemID("player", 13))
  Consider(GetInventoryItemID("player", 14))
  for bag = 0, NUM_BAG_SLOTS do
    for bagSlot = 1, C_Container.GetContainerNumSlots(bag) do
      Consider(C_Container.GetContainerItemID(bag, bagSlot))
    end
  end
  for _, lists in pairs(ns.char.sets) do
    for _, slot in ipairs(SLOTS) do
      for _, id in ipairs(lists[slot] or {}) do
        Consider(id)
      end
    end
  end
  -- on-use trinkets first, each group by name
  local labels = {}
  for _, id in ipairs(ids) do
    labels[id] = ItemText(id)
  end
  table.sort(ids, function(a, b)
    if IsPassive(a) ~= IsPassive(b) then
      return not IsPassive(a)
    end
    return (C_Item.GetItemNameByID(a) or "") < (C_Item.GetItemNameByID(b) or "")
  end)
  wipe(itemChoices)
  itemChoices[1] = { 0, "None" }
  for _, id in ipairs(ids) do
    local label = labels[id]
    if IsPassive(id) then
      label = label .. ns.Color("muted", " (passive)")
    end
    itemChoices[#itemChoices + 1] = { id, label }
  end
end

-- refill the trinket set choices: default plus one per equipment set
local function RebuildSetChoices()
  wipe(setChoices)
  setChoices[1] = { DEFAULT, "Default" }
  for _, setID in ipairs(C_EquipmentSet.GetEquipmentSetIDs()) do
    local name, icon = C_EquipmentSet.GetEquipmentSetInfo(setID)
    if name then
      setChoices[#setChoices + 1] = { PREFIX .. name, "|T" .. (icon or 134400) .. ":0|t " .. name }
    end
  end
end

-- position key by settings variable, for the hold time boxes
local positionKeys = {}
for _, slot in ipairs(SLOTS) do
  for position = 1, POSITIONS do
    positionKeys[ADDON .. "_" .. Key(slot, position)] = Key(slot, position)
  end
end
-- hold time box by settings row frame; rows are recycled, so each box follows its row
local holdBoxes = {}
-- dropdown width of settings rows: Blizzard's, and ours a bit wider than it with arrows
local DEFAULT_DROPDOWN = 220
local WIDE_DROPDOWN = 290
-- settings rows whose dropdown this addon widened
local widened = {}

-- item tooltip shown above the info tooltip of a position row
local itemTip = CreateFrame("GameTooltip", ADDON .. "ItemTooltip", UIParent, "GameTooltipTemplate")

-- show the item tooltip of a row's trinket above another tooltip; nothing for none
local function ShowItemTip(above, key)
  local id = ns.Get(key)
  if id == 0 then
    return
  end
  itemTip:SetOwner(above, "ANCHOR_NONE")
  itemTip:ClearAllPoints()
  itemTip:SetPoint("BOTTOMLEFT", above, "TOPLEFT", 0, 2)
  itemTip:SetItemByID(id)
  itemTip:Show()
end

-- position key of the row a frame belongs to, searching a few parents up
local function RowKey(frame)
  for _ = 1, 4 do
    if not frame then
      return nil
    end
    local box = holdBoxes[frame]
    if box then
      return box.key
    end
    frame = frame:GetParent()
  end
end

-- show the hold time of the trinket in the box's row; hidden for none and passive trinkets
local function UpdateBox(box)
  local id = box.key and ns.Get(box.key)
  if not id or id == 0 or IsPassive(id) then
    return box:Hide()
  end
  box:SetText(tostring(ns.char.hold[id] or 0))
  box:Show()
end

-- refresh every hold time box on the page
local function UpdateBoxes()
  for _, box in pairs(holdBoxes) do
    UpdateBox(box)
  end
end

-- store a trinket's hold time; 0 removes it
local function SetHold(id, seconds)
  ns.char.hold[id] = seconds > 0 and seconds or nil
  UpdateBoxes()
  Refresh()
end

-- small seconds box right of a position dropdown
local function CreateHoldBox(row)
  local box = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
  box:SetSize(32, 20)
  box:SetPoint("LEFT", row.Control.Dropdown, "RIGHT", 14, 0)
  box:SetAutoFocus(false)
  box:SetNumeric(true)
  box:SetMaxLetters(3)
  box:SetJustifyH("CENTER")
  local unit = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  unit:SetPoint("LEFT", box, "RIGHT", 4, 0)
  unit:SetText("s")
  box:SetScript("OnEnterPressed", box.ClearFocus)
  box:SetScript("OnEscapePressed", function(self)
    UpdateBox(self)
    self:ClearFocus()
  end)
  box:SetScript("OnEditFocusLost", function(self)
    local id = self.key and ns.Get(self.key)
    if id and id ~= 0 then
      SetHold(id, tonumber(self:GetText()) or 0)
    end
  end)
  box:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Hold time")
    GameTooltip:AddLine("Seconds this trinket stays equipped after its use, also counted"
      .. " during combat; 0 = swap as soon as possible", 1, 1, 1, true)
    GameTooltip:Show()
    if self.key then
      ShowItemTip(GameTooltip, self.key)
    end
  end)
  box:SetScript("OnLeave", function()
    GameTooltip:Hide()
    itemTip:Hide()
  end)
  holdBoxes[row] = box
  return box
end

-- add the hold time box to position rows of the settings page as they are shown
local function OnRowInit(row)
  local setting = row:GetSetting()
  local variable = setting and setting:GetVariable() or ""
  local key = positionKeys[variable]
  local box = holdBoxes[row]
  -- own dropdowns without stepper arrows but wider; recycled rows get the defaults back
  if variable:sub(1, #ADDON + 1) == ADDON .. "_" then
    row.Control:SetSteppersShown(false)
    row.Control.Dropdown:SetWidth(WIDE_DROPDOWN)
    widened[row] = true
  elseif widened[row] then
    row.Control:SetSteppersShown(true)
    row.Control.Dropdown:SetWidth(DEFAULT_DROPDOWN)
    widened[row] = nil
  end
  if not key then
    if box then
      box.key = nil
      box:Hide()
    end
    return
  end
  box = box or CreateHoldBox(row)
  box.key = key
  UpdateBox(box)
end
if SettingsDropdownControlMixin then
  hooksecurefunc(SettingsDropdownControlMixin, "Init", OnRowInit)
end

-- item tooltip above the settings tooltip of a position row, hidden with it
if SettingsTooltip then
  SettingsTooltip:HookScript("OnShow", function(self)
    local key = RowKey(self:GetOwner())
    if key then
      ShowItemTip(self, key)
    end
  end)
  SettingsTooltip:HookScript("OnHide", function()
    itemTip:Hide()
  end)
end

-- copy the edited set's lists into the position settings and redraw the page
local function ShowSet()
  local lists = Lists(ns.Get("editSet"))
  loading = true
  for _, slot in ipairs(SLOTS) do
    for position = 1, POSITIONS do
      local key = Key(slot, position)
      local value = lists[slot][position] or 0
      ns.char[key] = value
      if registered then
        Settings.NotifyUpdate(ADDON .. "_" .. key)
      end
    end
  end
  loading = false
  UpdateBoxes()
end

-- store a slot list of the edited set, then update page and equipment
local function SaveList(slot, list)
  Lists(ns.Get("editSet"))[slot] = list
  RebuildItemChoices()
  ShowSet()
  Refresh()
end

-- a position dropdown changed on the page
local function OnPosition(slot, position)
  if loading then
    return
  end
  local values = {}
  for index = 1, POSITIONS do
    values[index] = ns.Get(Key(slot, index))
  end
  SaveList(slot, Normalize(values, position))
end

-- edited trinket set changed: show its lists
local function OnEditSet()
  if not loading then
    ShowSet()
  end
end

-- one line per slot list of a trinket set
local function PrintLists(key)
  local lists = Lists(key)
  for _, slot in ipairs(SLOTS) do
    local names = {}
    for index, id in ipairs(lists[slot]) do
      local hold = ns.char.hold[id]
      names[index] = index .. ". " .. ItemText(id)
        .. (hold and ns.Color("muted", " (hold " .. hold .. " s)") or "")
    end
    local text = #names > 0 and table.concat(names, ", ") or ns.Color("muted", "empty, not swapped")
    ns.Detail(ns.Color("command", SLOT_NAMES[slot]) .. ": " .. text)
  end
end

-- current state, active set, and the edited set's lists
local function Status()
  local hint = ""
  if ns.Get("enabled") and InCombatLockdown() then
    hint = ns.Color("warning", " (swaps after combat)")
  end
  ns.Print("swapping " .. ns.OnOff(ns.Get("enabled")) .. hint)
  ns.Status("pause while mounted", ns.OnOff(ns.Get("mountPause")))
  ns.Status("active set", SetName(ActiveKey()))
  ns.Status("edited set", SetName(ns.Get("editSet")))
  PrintLists(ns.Get("editSet"))
end

-- switch swapping and report the new state
local function Switch(enabled)
  ns.Set("enabled", enabled)
  Status()
end

-- run the swap check once now, for checking it in game
local function Test()
  ns.Print("test: checking the trinket lists now" .. (InCombatLockdown()
    and ns.Color("warning", " (swaps after combat)") or ""))
  Run()
end

-- reset the settings to defaults; the trinket lists stay, the page shows them again
local function Reset()
  loading = true
  ns.ResetSettings()
  loading = false
  ShowSet()
  ns.Success("settings reset to defaults, trinket lists kept")
  Status()
end

-- choose the trinket set to edit by name; lists the sets without a name
local function EditSet(name)
  if not name then
    ns.Print("trinket sets:")
    for _, choice in ipairs(setChoices) do
      ns.Detail(ns.Color("value", SetName(choice[1])))
    end
    return
  end
  local key = name:lower() == "default" and DEFAULT or EquipmentSetKey(name)
  if not key then
    return ns.Error("no equipment set named " .. name .. " - see " .. ns.slash .. " set")
  end
  ns.Set("editSet", key)
  Status()
end

-- replace a slot list of the edited set from item IDs
local function SetList(args)
  local slot = args.slot == "1" and 13 or 14
  local values = {}
  for position = 1, POSITIONS do
    local id = args["item" .. position]
    if id and select(4, C_Item.GetItemInfoInstant(id)) ~= "INVTYPE_TRINKET" then
      ns.Warn("item " .. id .. " is no trinket, skipped")
      id = nil
    end
    values[position] = id or 0
  end
  SaveList(slot, Normalize(values))
  Status()
end

-- active equipment set at login: keep the known one, else the first fully equipped
local function DetectActiveSet()
  if ns.char.activeSet and SetExists(ns.char.activeSet) then
    return
  end
  ns.char.activeSet = DEFAULT
  for _, setID in ipairs(C_EquipmentSet.GetEquipmentSetIDs()) do
    local name, _, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
    if name and isEquipped then
      ns.char.activeSet = PREFIX .. name
      return
    end
  end
end

-- event handlers by event name
local events = {}

-- world ready: equipment sets known; edit the active set
function events.PLAYER_LOGIN()
  DetectActiveSet()
  RebuildSetChoices()
  RebuildItemChoices()
  ns.Set("editSet", ActiveKey())
  Refresh()
end

-- equipment set equipped: its trinket set becomes active and edited
function events.EQUIPMENT_SWAP_FINISHED(result, setID)
  local name = result and setID and C_EquipmentSet.GetEquipmentSetInfo(setID)
  if name then
    ns.char.activeSet = PREFIX .. name
    ns.Set("editSet", ns.char.activeSet)
    Refresh()
  end
end

-- equipment sets created, renamed, or deleted
function events.EQUIPMENT_SETS_CHANGED()
  RebuildSetChoices()
  if not SetExists(ns.Get("editSet")) then
    ns.Set("editSet", ActiveKey())
  end
  Refresh()
end

-- trinket used or cooldowns changed
function events.BAG_UPDATE_COOLDOWN()
  Refresh()
end

-- bags changed: trinkets gained or lost
function events.BAG_UPDATE_DELAYED()
  RebuildItemChoices()
  Refresh()
end

-- equipment changed: next swap pass
function events.PLAYER_EQUIPMENT_CHANGED()
  RebuildItemChoices()
  Refresh()
end

-- mounted or dismounted; after dismounting, mount gear addons swap back first
function events.PLAYER_MOUNT_DISPLAY_CHANGED()
  Schedule(1)
end

-- zoning
function events.PLAYER_ENTERING_WORLD()
  Refresh()
end

-- back alive: swaps possible again
function events.PLAYER_UNGHOST()
  Refresh()
end

-- requested item names arrived: redraw labels
function events.ITEM_DATA_LOAD_RESULT(itemID)
  if requested[itemID] then
    requested[itemID] = nil
    RebuildItemChoices()
    ShowSet()
  end
end

-- one frame dispatching all events above
local frame = CreateFrame("Frame")
for event in pairs(events) do
  -- skip events this client does not know
  if C_EventUtils.IsEventValid(event) then frame:RegisterEvent(event) end
end
frame:SetScript("OnEvent", function(_, event, ...)
  ns.Debug(event)
  events[event](...)
end)

-- everything is saved per character: settings (off, no mount pause, default set edited,
-- empty positions), trinket sets, active set, and hold times by item; _version 1 marks
-- data from before settings moved out of the account store
local defaults = {
  _version = 1, enabled = false, mountPause = false, editSet = DEFAULT,
  sets = {}, activeSet = DEFAULT, hold = {},
}
for _, slot in ipairs(SLOTS) do
  for position = 1, POSITIONS do
    defaults[Key(slot, position)] = 0
  end
end
ns.Store(ADDON .. "CharDB", defaults, nil, "char")

-- take the switches over from the account store once; trinket lists were always per
-- character
local function Migrate()
  local char = ns.char
  if char._version < 2 then
    for _, key in ipairs({ "enabled", "mountPause" }) do
      if not char.perCharacter and ns.db[key] ~= nil then
        char[key] = ns.db[key]
      end
    end
    char.perCharacter = false
    char._version = 2
  end
end

-- account store only kept for the migration; settings page and first check once loaded
ns.Store(ADDON .. "DB", {}, function()
  Migrate()
  RebuildSetChoices()
  RebuildItemChoices()
  ShowSet()
  ns.Settings()
  -- this addon is always per character: hide the shared "Per character" checkbox, which
  -- ns.Settings() adds first
  local initializers = SettingsPanel:GetLayout(ns.Category):GetInitializers()
  initializers[1]:AddShownPredicate(function()
    return false
  end)
  ns.Checkbox("enabled", "Enabled", "Swap trinkets by priority whenever out of combat", Refresh)
  ns.Checkbox("mountPause", "Pause while mounted",
    "No swaps while mounted, so addons that equip mount gear are not disturbed", Refresh)
  ns.Dropdown("editSet", "Trinket set", setChoices,
    "Trinket set shown below; each equipment set has its own, Default is used without one",
    OnEditSet)
  -- the layout gets each dropdown last, so its initializer can get a shown rule
  for _, slot in ipairs(SLOTS) do
    for position = 1, POSITIONS do
      ns.Dropdown(Key(slot, position), SLOT_NAMES[slot] .. " priority " .. position, itemChoices,
        "Trinket at priority " .. position .. " for the " .. SLOT_NAMES[slot]:lower()
          .. " slot; the first ready one is equipped. Only one trinket without use effect"
          .. " per list, always last",
        function()
          OnPosition(slot, position)
        end)
      -- shown up to one empty position after the filled ones
      initializers[#initializers]:AddShownPredicate(function()
        return position <= #Lists(ns.Get("editSet"))[slot] + 1
      end)
    end
  end
  registered = true
  Refresh()
end)

-- item ID arguments of the slot command
local itemArgs = { { name = "slot", choices = { "1", "2" } } }
for position = 1, POSITIONS do
  itemArgs[#itemArgs + 1] = { name = "item" .. position, type = "number", optional = true }
end

-- chat commands
ns.Command({ name = "on", help = "turn swapping on", run = function() Switch(true) end })
ns.Command({ name = "off", help = "turn swapping off", run = function() Switch(false) end })
ns.Command({
  name = "mount",
  help = "pause swaps while mounted, or swap also when mounted",
  args = { { name = "state", choices = { "on", "off" } } },
  run = function(args)
    ns.Set("mountPause", args.state == "on")
    Status()
  end,
})
ns.Command({
  name = "set",
  help = "edit the trinket set of an equipment set (\"quoted name\" or default); lists sets",
  args = { { name = "name", optional = true } },
  run = function(args) EditSet(args.name) end,
})
ns.Command({
  name = "slot",
  help = "replace the edited set's list for trinket slot 1 or 2 with item IDs; none clears it",
  args = itemArgs,
  run = SetList,
})
ns.Command({
  name = "hold",
  help = "seconds a trinket stays equipped after its use; 0 removes the hold time",
  args = {
    { name = "itemID", type = "number", min = 1 },
    { name = "seconds", type = "number", min = 0, max = 999 },
  },
  run = function(args)
    SetHold(args.itemID, math.floor(args.seconds))
    ns.Status("hold time of " .. ItemText(args.itemID), math.floor(args.seconds) .. " s")
  end,
})
ns.Command({ name = "test", help = "check the trinket lists and swap once now", run = Test })
ns.Command({ name = "reset", help = "reset the settings to defaults", run = Reset })
ns.Command({
  name = "debug",
  help = "show what the addon does in chat, until /reload",
  args = { { name = "state", choices = { "on", "off" } } },
  run = function(args)
    ns.debug = args.state == "on"
    ns.Status("debug", ns.OnOff(ns.debug))
  end,
})
ns.Command({ name = "config", help = "open the settings page", run = ns.OpenSettings })
ns.Slash({ "/sts", "/simpletrinketswap" }, Status)
