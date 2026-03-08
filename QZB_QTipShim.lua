-- QuestZoneBroker_QTipShim: lightweight drop-in for LibQTip-1.0 (3 columns)
QuestZoneBroker_QTipShim = QuestZoneBroker_QTipShim or {}
local lib = QuestZoneBroker_QTipShim
local function CreateTooltipFrame()
  local f = CreateFrame("Frame", "QZB_QTipShimFrame", UIParent, (BackdropTemplateMixin and "BackdropTemplate") or nil)
  f:SetFrameStrata("TOOLTIP"); f:SetSize(460, 200); f:Hide()
  if f.SetBackdrop then
    f:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background", edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=16, insets={left=4,right=4,top=4,bottom=4} })
    f:SetBackdropColor(0,0,0,0.92)
  end
  local scroll = CreateFrame("ScrollFrame", nil, f)
  scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
  scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(1,1)
  scroll:SetScrollChild(child)
  f._scroll = scroll; f._child = child
  f._lines = {}; f._regularFont = GameTooltipText; f._headerFont = GameTooltipHeaderText
  f._lineGap = 4; f._colJust = {"LEFT","LEFT","RIGHT"}
  f._totalHeight = 0
  local timer = CreateFrame("Frame", nil, f)
  timer:Hide(); timer.parent = f; timer.checkElapsed = 0; timer.elapsed = 0; timer.delay = 0
  timer:SetScript("OnUpdate", function(self, elapsed)
    self.checkElapsed = self.checkElapsed + elapsed
    if self.checkElapsed > 0.1 and self.delay and self.delay > 0 then
      local function isOver(frame)
        if frame and type(frame.IsMouseOver) == 'function' then return frame:IsMouseOver() end
        if type(MouseIsOver)=='function' then return MouseIsOver(frame) end
        return GetMouseFocus and (GetMouseFocus()==frame)
      end
      if isOver(self.parent) or isOver(self.alt) then
        self.elapsed = 0
      else
        self.elapsed = self.elapsed + self.checkElapsed
        if self.elapsed >= self.delay then self.parent:Hide() end
      end
      self.checkElapsed = 0
    end
  end)
  f._timer = timer
  function f:SetAutoHideDelay(delay, alt)
    delay = tonumber(delay) or 0
    self._timer.delay = delay; self._timer.alt = alt
    if delay > 0 then self._timer:Show() else self._timer:Hide() end
  end
  function f:GetFont() return self._regularFont end
  function f:GetHeaderFont() return self._headerFont end
  function f:AddSeparator() local l = self:AddLine(" ") return l end
  local function addLine(fnt, c1, c2, c3)
    local line = CreateFrame("Button", nil, f._child)
    line:SetSize(10, 10)
    local yOff = - (f._totalHeight)
    line:SetPoint("TOPLEFT", f._child, "TOPLEFT", 0, yOff)
    local fs1 = line:CreateFontString(nil, "OVERLAY", fnt)
    local fs2 = line:CreateFontString(nil, "OVERLAY", fnt)
    local fs3 = line:CreateFontString(nil, "OVERLAY", fnt)
    fs1:SetPoint("TOPLEFT", line, "TOPLEFT", 6, 0); fs1:SetJustifyH(f._colJust[1])
    fs2:SetPoint("TOP", fs1, "TOP", 0, 0); fs2:SetPoint("LEFT", line, "LEFT", 180, 0); fs2:SetJustifyH(f._colJust[2])
    fs3:SetPoint("TOPRIGHT", line, "TOPRIGHT", -6, 0); fs3:SetJustifyH(f._colJust[3])
    fs1:SetText(c1 or ""); fs2:SetText(c2 or ""); fs3:SetText(c3 or "")
    line.fs1, line.fs2, line.fs3 = fs1, fs2, fs3
    local h = math.max(fs1:GetStringHeight(), fs2:GetStringHeight(), fs3:GetStringHeight()) + f._lineGap
    line:SetHeight(h)
    line:SetWidth(f._scroll:GetWidth()-2)
    f._totalHeight = f._totalHeight + h
    table.insert(f._lines, line)
    f._child:SetHeight(f._totalHeight)
    return line
  end
  function f:AddLine(c1, c2, c3)
    local l = addLine(self._regularFont, c1, c2, c3)
    return #self._lines, 1
  end
  function f:AddHeader(c1, c2)
    local l = addLine(self._headerFont, c1, c2 or "", "")
    return #self._lines, 1
  end
  function f:SetLineScript(lineIndex, script, func, arg)
    local line = self._lines[lineIndex]
    if not line then return end
    if script == 'OnMouseDown' then
      line:SetScript('OnMouseDown', function(btn, ...) func(arg or line, ...) end)
      line:EnableMouse(true)
    elseif script == 'OnEnter' or script == 'OnLeave' then
      line:SetScript(script, function(btn, ...) func(arg or line, ...) end)
      line:EnableMouse(true)
    end
  end
  function f:Clear()
    for i=#self._lines,1,-1 do self._lines[i]:Hide(); self._lines[i]:SetParent(nil); self._lines[i]=nil end
    self._totalHeight=0; self._child:SetHeight(1)
  end
  return f
end
function lib:Acquire(key, cols, j1, j2, j3)
  if not lib._instances then lib._instances = {} end
  local tip = lib._instances[key]
  if not tip then tip = CreateTooltipFrame(); lib._instances[key] = tip end
  tip:Clear()
  return tip
end
function lib:Release(tip)
  if not tip then return end
  tip:Hide(); tip:Clear()
end
function lib:IsAcquired(key) return lib._instances and lib._instances[key] ~= nil end
function lib:IterateTooltips() return pairs(lib._instances or {}) end
