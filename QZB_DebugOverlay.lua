-- QZB_DebugOverlay: lightweight developer overlay for QuestZoneBroker
local ADDON = ...
local DB = { visible = false, autoscroll = true, fontSize = 12, width = 520, height = 360,
 point = {"CENTER", UIParent, "CENTER", 0, 0} }
local function _mkFrame()
 if QZB_DEBUG_FRAME then return QZB_DEBUG_FRAME end
 local f = CreateFrame("Frame", "QZB_DEBUG_FRAME", UIParent, "BasicFrameTemplateWithInset")
 f:SetSize(DB.width, DB.height)
 f:SetPoint(DB.point[1], DB.point[2], DB.point[3], DB.point[4], DB.point[5])
 f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
 f:SetScript("OnDragStart", f.StartMoving)
 f:SetScript("OnDragStop", function(self)
   self:StopMovingOrSizing()
   local p,_,rp,x,y = self:GetPoint(1)
   DB.point = {p, UIParent, rp, x, y}; DB.width, DB.height = self:GetSize()
 end)
 f:SetClampedToScreen(true)
 f.title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
 f.title:SetPoint("LEFT", f.TitleBg, "LEFT", 6, 0)
 f.title:SetText("QuestZoneBroker – Debug Overlay")
 local scroll = CreateFrame("ScrollingMessageFrame", nil, f)
 scroll:SetPoint("TOPLEFT", f.Inset or f, "TOPLEFT", 8, -8)
 scroll:SetPoint("BOTTOMRIGHT", f.Inset or f, "BOTTOMRIGHT", -8, 40)
 scroll:SetMaxLines(4000); scroll:SetFading(false); scroll:SetJustifyH("LEFT"); scroll:SetIndentedWordWrap(true)
 local font,_,flags = GameFontHighlight:GetFont()
 scroll:SetFont(font, DB.fontSize, flags)
 scroll:SetScript("OnMouseWheel", function(self, delta) if delta>0 then self:ScrollUp() else self:ScrollDown() end end)
 scroll:EnableMouseWheel(true)
 f.scroll = scroll
 local function addBtn(text, x, handler)
   local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
   b:SetSize(90, 22)
   b:SetPoint("BOTTOMLEFT", f.Inset or f, "BOTTOMLEFT", x, 10)
   b:SetText(text)
   b:SetScript("OnClick", handler)
   return b
 end
 local px = 8
 f.btnRescan = addBtn("Rescan", px, function()
   if QuestZoneBroker_Refresh then QuestZoneBroker_Refresh() end
   QZB_DebugOverlay_Dump()
 end); px = px + 96
 f.btnClear = addBtn("Clear", px, function() f.scroll:Clear() end); px = px + 96
 f.btnCopy = addBtn("Copy", px, function()
   local dlg = CreateFrame("Frame", nil, f, "BasicFrameTemplateWithInset"); dlg:SetSize(520, 280); dlg:SetPoint("CENTER")
   dlg.title = dlg:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); dlg.title:SetPoint("LEFT", dlg.TitleBg, "LEFT", 6, 0); dlg.title:SetText("Debug Copy")
   local e = CreateFrame("EditBox", nil, dlg, "InputBoxTemplate"); e:SetMultiLine(true); e:SetAutoFocus(true); e:SetFontObject(ChatFontNormal); e:SetAllPoints(dlg.Inset or dlg); e:SetText(QZB_DebugOverlay_TextDump or ""); e:HighlightText(); e:SetScript("OnEscapePressed", function() dlg:Hide() end)
   dlg:Show()
 end); px = px + 96
 local chk = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
 chk:SetPoint("LEFT", f.btnCopy, "RIGHT", 8, 0)
 chk.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormal"); chk.text:SetPoint("LEFT", chk, "RIGHT", 2, 0); chk.text:SetText("Autoscroll")
 chk:SetChecked(DB.autoscroll)
 chk:SetScript("OnClick", function(self) DB.autoscroll = not not self:GetChecked() end)
 f.chkAuto = chk
 f:SetScript("OnShow", function() DB.visible = true end)
 f:SetScript("OnHide", function() DB.visible = false end)
 QZB_DEBUG_FRAME = f
 return f
end
local function _print(line)
 local f = _mkFrame()
 f.scroll:AddMessage(line)
 if DB.autoscroll then f.scroll:ScrollToBottom() end
end
local function _color(tag, r,g,b)
 return ("|cff%02x%02x%02x%s|r"):format((r or 1)*255,(g or 1)*255,(b or 1)*255, tostring(tag))
end
local function _fmtXY(x,y)
 if type(x)=='number' and type(y)=='number' then return ("%.1f/%.1f"):format(x*100, y*100) end
 return "-"
end
local function snapshot_dump(snap)
 local buf = {}
 local function A(s) table.insert(buf, s.."\n"); _print(s) end
 A(_color("== Zonenstatus ==",0.6,0.9,1))
 A(string.format("MapID=%s Zone=%s", tostring(snap.currentMapID or '?'), tostring(snap.currentZoneName or '?')))
 A(" ")
 A(_color("== Pin Cache ==",0.6,1,0.6))
 for k, list in pairs(snap.pinCache or {}) do
   A(string.format("%s: %d", k, type(list)=='table' and #list or 0))
   if type(list)=='table' then
     for i,p in ipairs(list) do if i>50 then A(" ..." ) break end
       A(string.format(" - %s qid=%s %s", tostring(k), tostring(p.questID or '-'), _fmtXY(p.x, p.y)))
     end
   end
 end
 local function dumpList(title, list)
   A(" ")
   A(_color("== "..title.." ==",1,0.85,0.6))
   local cnt = 0
   for _, e in ipairs(list or {}) do cnt=cnt+1; if cnt>300 then A(" ...") break end
     local lab = string.format(" - [%s] %s (qid=%s) %s", tostring(e.type or '?'), tostring(e.title or '?'), tostring(e.questID or '-'), _fmtXY(e.x, e.y))
     if e._grouped then lab = lab .. " ".._color("[grouped]",0.8,0.8,0.8) end
     A(lab)
   end
   A(string.format("Gesamt: %d", cnt))
 end
 dumpList("Entries", snap.entries)
 A(" ")
 A(_color("== Hubs ==",1,0.8,0.4))
 for _, h in ipairs(snap.hubsForRender or {}) do
   A(string.format("* Hub: %s (%d) %s", tostring(h.title or 'Hub'), #(h.children or {}), _fmtXY(h.x,h.y)))
   for _, c in ipairs(h.children or {}) do
     A(string.format(" • %s (qid=%s) %s", tostring(c.title or '?'), tostring(c.questID or '-'), _fmtXY(c.x, c.y)))
   end
 end
 A(" ")
 A(_color("== Neighbor Zones ==",0.8,0.8,1))
 for zid, z in pairs(snap.neighborZones or {}) do
   A(string.format("- %s (%s)", tostring(z.name or '?'), tostring(zid)))
   local shown = 0
   for _, e in ipairs(z.entries or {}) do shown=shown+1; if shown>40 then A(" ...") break end
     A(string.format(" • [%s] %s (qid=%s) %s", tostring(e.type or '?'), tostring(e.title or '?'), tostring(e.questID or '-'), _fmtXY(e.x,e.y)))
   end
 end
 A(" ")
 A(_color("== Presence Sets ==",0.9,0.9,0.5))
 local qOn=0; for _ in pairs(snap.questsOnMapSet or {}) do qOn=qOn+1 end
 local tOn=0; for _ in pairs(snap.taskOnMapSet or {}) do tOn=tOn+1 end
 A(string.format("questsOnMapSet=%d, taskOnMapSet=%d", qOn, tOn))
 QZB_DebugOverlay_TextDump = table.concat(buf, '')
end
function QZB_DebugOverlay_Dump()
 local f = _mkFrame(); f:Show(); f.scroll:Clear()
 local snap = QuestZoneBroker_GetSnapshot and QuestZoneBroker_GetSnapshot() or {}
 snapshot_dump(snap)
end
-- Slash commands
SLASH_QZBDBG1 = "/qzb"
SlashCmdList["QZBDBG"] = function(msg)
 msg = (msg or ''):lower()
 if msg == 'debug on' or msg=='debug' then QZB_DebugOverlay_Dump()
 elseif msg=='debug off' then if QZB_DEBUG_FRAME then QZB_DEBUG_FRAME:Hide() end
 elseif msg=='debug toggle' then if QZB_DEBUG_FRAME and QZB_DEBUG_FRAME:IsShown() then QZB_DEBUG_FRAME:Hide() else QZB_DebugOverlay_Dump() end
 elseif msg=='dump' then QZB_DebugOverlay_Dump()
 elseif msg=='rescan' then if QuestZoneBroker_Refresh then QuestZoneBroker_Refresh() end; QZB_DebugOverlay_Dump()
 else
   DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[QZB]|r Nutzung: /qzb debug on|off|toggle | dump | rescan")
 end
end
local ev = CreateFrame("Frame")
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function()
 if QZB_DEBUG_FRAME and QZB_DEBUG_FRAME:IsShown() then
   if QuestZoneBroker_Refresh then QuestZoneBroker_Refresh() end
   QZB_DebugOverlay_Dump()
 end
end)
