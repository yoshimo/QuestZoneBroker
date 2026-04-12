
local ADDON_NAME = ...

-- =====================================================
-- QuestZoneBroker v1.9.3 – Pin-Scan Integration
--  - On WorldMap open, scan specific pin templates:
--      * QuestBlobPinTemplate (quest area blobs)
--      * QuestHubPinTemplate  (quest hubs)
--      * QuestOfferPinTemplate (available quests, yellow '!')
--  - Cache results and render in tooltip (extra sections)
--  - Keeps v1.9.2 features (Tasks OnMap, POI context, child maps, hubs expanded)
-- =====================================================

-- ===== Libraries =====
local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
local QTip = LibStub and LibStub:GetLibrary("LibQTip-1.0", true)

if not LDB then
    local warn = CreateFrame("Frame")
    warn:RegisterEvent("PLAYER_LOGIN")
    warn:SetScript("OnEvent", function()
        DEFAULT_CHAT_FRAME:AddMessage("|cffff6666[QuestZoneBroker]|r LibDataBroker-1.1 nicht gefunden. Bitte installiere ein LDB-Display (z.B. Titan Panel, ChocolateBar).")
    end)
end

local broker = LDB and LDB:NewDataObject("QuestZoneBroker", {
    type = "data source",
    text = "Zone Quests",
    icon = "Interface\\GossipFrame\\ActiveQuestIcon",
})

-- ===== State =====
local HUB_RANGE = 0.02 -- grouping distance
local entries = {}           -- current zone entries
local hubsForRender = {}     -- hub tree for current zone
local neighborZones = {}     -- neighbors data
local currentMapID, currentZoneName
local tooltip

-- pin scan cache
local pinCache = {
    QuestBlob = {},   -- { {mapID, questID, x, y, atlas, name} } (name optional)
    QuestHub  = {},   -- { {mapID, questID, x, y, atlas, name} }
    QuestOffer= {},   -- { {mapID, questID, x, y, atlas, name} }
}

-- presence sets for campaign filtering
local questsOnMapSet, taskOnMapSet = {}, {}

-- ===== Utils =====
local function SafeGetQuestTitle(questID)
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local t = C_QuestLog.GetTitleForQuestID(questID)
        if t and t ~= "" then return t end
    end
    return ("Quest %d"):format(questID)
end

local function GetPlayerMap()
    local mapID = C_Map.GetBestMapForUnit("player")
    local mapInfo = mapID and C_Map.GetMapInfo(mapID)
    return mapID, (mapInfo and mapInfo.name) or "Unbekannte Zone"
end

local function AddEntry(list, t)
    list[#list+1] = t
end

local function ResetAll()
    wipe(entries)
    wipe(hubsForRender)
    wipe(neighborZones)
    wipe(questsOnMapSet)
    wipe(taskOnMapSet)
    -- keep pinCache for recent map unless rebuilding later
end

local function GetWaypointForQuest(questID, hintMapID)
    if C_QuestLog.GetNextWaypointForMap then
        local v = C_QuestLog.GetNextWaypointForMap(questID, hintMapID)
        if v and v.x and v.y then return hintMapID, v.x, v.y end
    end
    if C_QuestLog.GetNextWaypoint then
        local v, mapID = C_QuestLog.GetNextWaypoint(questID)
        if v and v.x and v.y then return mapID or hintMapID, v.x, v.y end
    end
    local mapID = hintMapID or (C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
    if mapID and C_QuestLog.GetQuestsOnMap then
        for _, q in ipairs(C_QuestLog.GetQuestsOnMap(mapID) or {}) do
            if q.questID == questID and q.x and q.y then return mapID, q.x, q.y end
        end
    end
    return nil
end

local function AddTomTomWaypoint(entry)
    if not TomTom or not TomTom.AddWaypoint then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff6666[QuestZoneBroker]|r TomTom nicht gefunden. Bitte installiere TomTom.")
        return
    end
    local mapID, x, y
    if entry.x and entry.y then
        mapID, x, y = entry.mapID, entry.x, entry.y
    elseif entry.questID then
        mapID, x, y = GetWaypointForQuest(entry.questID, entry.mapID)
    elseif entry.poiID and C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIPosition then
        local pos = C_AreaPoiInfo.GetAreaPOIPosition(entry.mapID, entry.poiID)
        if pos then mapID, x, y = entry.mapID, pos.x, pos.y end
    end
    if mapID and x and y then
        TomTom:AddWaypoint(mapID, x, y, {
            title = entry.title or (entry.type .. "-Ziel"),
            persistent = false, minimap = true, world = true,
        })
        DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99[QuestZoneBroker]|r Wegpunkt: %s (%.1f%%, %.1f%%)")
            :format(entry.title or "Ziel", x*100, y*100))
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffff6666[QuestZoneBroker]|r Konnte keine Position ermitteln.")
    end
end

-- ===== Map traversal (child/micro) =====
local function ForEachChildMapRec(parentID, fn)
    if not parentID then return end
    local function addChildren(pid, mapType)
        local kids = C_Map.GetMapChildrenInfo and C_Map.GetMapChildrenInfo(pid, mapType, true) or {}
        for _, child in ipairs(kids) do
            fn(child.mapID, child.name, child.mapType)
            addChildren(child.mapID, mapType)
        end
    end
    if Enum and Enum.UIMapType then
        addChildren(parentID, Enum.UIMapType.Zone)
        addChildren(parentID, Enum.UIMapType.Micro)
    else
        addChildren(parentID)
    end
end

-- ===== Presence helpers (campaign filter) =====
local function MarkOnMapPresenceOne(mapID)
    for _, q in ipairs(C_QuestLog.GetQuestsOnMap(mapID) or {}) do questsOnMapSet[q.questID] = true end
    for _, t in ipairs(C_TaskQuest.GetQuestsOnMap and (C_TaskQuest.GetQuestsOnMap(mapID, 2) or {}) or {}) do taskOnMapSet[t.questID] = true end
end
local function MarkOnMapPresence(zoneMapID)
    MarkOnMapPresenceOne(zoneMapID)
    ForEachChildMapRec(zoneMapID, function(childID) MarkOnMapPresenceOne(childID) end)
end
local function CampaignQuestIsAllowed(qid)
    local inLog = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(qid)
    if inLog then return true end
    if questsOnMapSet[qid] or taskOnMapSet[qid] then return true end
    return false
end

-- ===== Collection (zone) =====
local function CollectTasksForMap(outTable, zoneMapID, zoneName, seen)
    local tasks = C_TaskQuest.GetQuestsOnMap and (C_TaskQuest.GetQuestsOnMap(zoneMapID, 2) or {}) or {}
    for _, t in ipairs(tasks) do
        if not seen[t.questID] then
            seen[t.questID] = true
            local title = (C_TaskQuest.GetQuestInfoByQuestID and C_TaskQuest.GetQuestInfoByQuestID(t.questID)) or SafeGetQuestTitle(t.questID)
            local tx, ty = t.x, t.y
            if (not tx or not ty) and C_TaskQuest.GetQuestLocation then
                local rx, ry = C_TaskQuest.GetQuestLocation(t.questID, zoneMapID)
                if rx and ry then tx, ty = rx, ry end
            end
            local isAvailableStart = (t.isQuestStart == true) or (t.isMapIndicatorQuest == true)
            if isAvailableStart then
                AddEntry(outTable, {type="AvailableQuest", title=title or ("Quest "..t.questID), questID=t.questID, mapID=zoneMapID, zone=zoneName, x=tx, y=ty})
            elseif Enum and Enum.QuestTagType and (t.questTagType == Enum.QuestTagType.WorldQuest) then
                AddEntry(outTable, {type="WorldQuest", title=title or ("World Quest "..t.questID), questID=t.questID, mapID=zoneMapID, zone=zoneName, x=tx, y=ty})
            else
                AddEntry(outTable, {type="TaskQuest", title=title or ("Task "..t.questID), questID=t.questID, mapID=zoneMapID, zone=zoneName, x=tx, y=ty})
            end
        end
    end
end

local function CollectZoneEntries(zoneMapID, zoneName, outTable)
    local prevPOI = C_QuestLog.GetMapForQuestPOIs and C_QuestLog.GetMapForQuestPOIs()
    if C_QuestLog.SetMapForQuestPOIs then C_QuestLog.SetMapForQuestPOIs(zoneMapID) end

    MarkOnMapPresence(zoneMapID)

    local seen = {}
    for _, q in ipairs(C_QuestLog.GetQuestsOnMap(zoneMapID) or {}) do
        seen[q.questID] = true
        AddEntry(outTable, {type="Quest", title=SafeGetQuestTitle(q.questID), questID=q.questID, mapID=zoneMapID, zone=zoneName, x=q.x, y=q.y})
    end

    CollectTasksForMap(outTable, zoneMapID, zoneName, seen)

    ForEachChildMapRec(zoneMapID, function(childID)
        CollectTasksForMap(outTable, childID, zoneName, seen)
        for _, cq in ipairs(C_QuestLog.GetQuestsOnMap(childID) or {}) do
            if not seen[cq.questID] then
                seen[cq.questID] = true
                AddEntry(outTable, {type="Quest", title=SafeGetQuestTitle(cq.questID), questID=cq.questID, mapID=zoneMapID, zone=zoneName, x=cq.x, y=cq.y})
            end
        end
    end)

    -- Area POIs (available / other)
    for _, poiID in ipairs(C_AreaPoiInfo.GetAreaPOIForMap and (C_AreaPoiInfo.GetAreaPOIForMap(zoneMapID) or {}) or {}) do
        local info = C_AreaPoiInfo.GetAreaPOIInfo and C_AreaPoiInfo.GetAreaPOIInfo(zoneMapID, poiID)
        if info then
            local atlas = info.atlasName and string.lower(info.atlasName) or nil
            local texkit = info.textureKit and string.lower(info.textureKit) or nil
            local isQuestLike = (C_AreaPoiInfo.IsAreaPOIQuest and C_AreaPoiInfo.IsAreaPOIQuest(poiID)) or false
            local isAvailableQuest = (info.isQuestStart == true) or (info.shouldGlow == true) or (atlas and atlas:find("questavailable")) or (texkit and texkit:find("quest")) or isQuestLike
            local pos = C_AreaPoiInfo.GetAreaPOIPosition and C_AreaPoiInfo.GetAreaPOIPosition(zoneMapID, poiID)
            local px, py = pos and pos.x or nil, pos and pos.y or nil
            if isAvailableQuest then
                AddEntry(outTable, {type="AvailableQuest", title=(info.name and info.name ~= "" and info.name) or (info.description) or ("POI "..poiID), poiID=poiID, mapID=zoneMapID, zone=zoneName, x=px, y=py})
            elseif isQuestLike or info.name or info.description then
                AddEntry(outTable, {type="AreaPOI", title=(info.name and info.name ~= "" and info.name) or (info.description) or ("POI "..poiID), poiID=poiID, mapID=zoneMapID, zone=zoneName, x=px, y=py})
            end
        end
    end

    -- Hubs
    if C_AreaPoiInfo.GetQuestHubsForMap then
        local hubIDs = C_AreaPoiInfo.GetQuestHubsForMap(zoneMapID)
        if type(hubIDs) == "table" then
            for _, hubID in ipairs(hubIDs) do
                local hubInfo = C_AreaPoiInfo.GetAreaPOIInfo and C_AreaPoiInfo.GetAreaPOIInfo(zoneMapID, hubID)
                local pos = C_AreaPoiInfo.GetAreaPOIPosition and C_AreaPoiInfo.GetAreaPOIPosition(zoneMapID, hubID)
                AddEntry(outTable, {type="QuestHub", title=(hubInfo and hubInfo.name) or ("Quest Hub "..tostring(hubID)), mapID=zoneMapID, zone=zoneName, x=pos and pos.x or nil, y=pos and pos.y or nil, poiID=hubID})
            end
        end
    end

    -- Campaigns/QuestLines (filtered)
    local function PushCampaignQuests()
        if not C_CampaignInfo then return end
        local campaigns
        if C_CampaignInfo.GetCampaignsForMap then campaigns = C_CampaignInfo.GetCampaignsForMap(zoneMapID)
        elseif C_CampaignInfo.GetCampaigns then campaigns = C_CampaignInfo.GetCampaigns() end
        campaigns = campaigns or {}
        for _, c in ipairs(campaigns) do
            local campaignID = c.campaignID or c
            if campaignID and C_CampaignInfo.GetChapterIDs and C_CampaignInfo.GetQuestIDsForCampaignChapter then
                for _, chapID in ipairs(C_CampaignInfo.GetChapterIDs(campaignID) or {}) do
                    for _, qid in ipairs(C_CampaignInfo.GetQuestIDsForCampaignChapter(chapID) or {}) do
                        if not seen[qid] and CampaignQuestIsAllowed(qid) then
                            seen[qid] = true
                            AddEntry(outTable, {type="CampaignQuest", title=SafeGetQuestTitle(qid), questID=qid, mapID=zoneMapID, zone=zoneName})
                        end
                    end
                end
            end
        end
    end
    local function PushQuestLineQuests()
        if not C_QuestLine or not C_QuestLine.GetAvailableQuestLines then return end
        for _, line in ipairs(C_QuestLine.GetAvailableQuestLines(zoneMapID) or {}) do
            if line and line.questLineID and C_QuestLine.GetQuestLineQuests then
                for _, qid in ipairs(C_QuestLine.GetQuestLineQuests(line.questLineID) or {}) do
                    if not seen[qid] and CampaignQuestIsAllowed(qid) then
                        seen[qid] = true
                        AddEntry(outTable, {type="CampaignQuest", title=SafeGetQuestTitle(qid), questID=qid, mapID=zoneMapID, zone=zoneName})
                    end
                end
            end
        end
    end
    PushCampaignQuests(); PushQuestLineQuests()

    if C_QuestLog.SetMapForQuestPOIs and prevPOI then C_QuestLog.SetMapForQuestPOIs(prevPOI) end
end

-- ===== Grouping =====
local function BuildHubGroupingForList(list)
    local hubs, ungrouped = {}, {}
    for _, e in ipairs(list) do e._grouped = nil end

    for _, e in ipairs(list) do
        if e.type == "QuestHub" then
            local hx, hy = e.x, e.y
            if (not hx or not hy) and e.poiID and C_AreaPoiInfo.GetAreaPOIPosition then
                local pos = C_AreaPoiInfo.GetAreaPOIPosition(e.mapID, e.poiID)
                if pos then hx, hy = pos.x, pos.y end
            end
            e.x, e.y = hx, hy
            e.children = {}
            table.insert(hubs, e)
        end
    end

    local function dist2(x1,y1,x2,y2) local dx,dy=(x1-x2),(y1-y2) return dx*dx+dy*dy end

    for _, q in ipairs(list) do
        if (q.type == "Quest" or q.type == "WorldQuest" or q.type == "CampaignQuest" or q.type == "AvailableQuest" or q.type == "TaskQuest") then
            local attached = false
            if q.x and q.y then
                local bestHub, bestD
                for _, h in ipairs(hubs) do
                    if h.x and h.y then
                        local d = dist2(q.x, q.y, h.x, h.y)
                        if not bestD or d < bestD then bestD, bestHub = d, h end
                    end
                end
                if bestHub and bestD and bestD <= (HUB_RANGE*HUB_RANGE) then
                    table.insert(bestHub.children, q); q._grouped = true; attached = true
                end
            end
            if not attached then table.insert(ungrouped, q) end
        end
    end

    -- ensure non-empty hubs by attaching same-map ungrouped
    for _, h in ipairs(hubs) do
        if #h.children == 0 then
            local still = {}
            for _, q in ipairs(ungrouped) do
                if q.mapID == h.mapID then table.insert(h.children, q); q._grouped = true else table.insert(still, q) end
            end
            ungrouped = still
        end
    end

    table.sort(hubs, function(a,b) return (a.title or "") < (b.title or "") end)
    for _, h in ipairs(hubs) do table.sort(h.children, function(a,b) return (a.title or "") < (b.title or "") end) end
    table.sort(ungrouped, function(a,b) return (a.title or "") < (b.title or "") end)

    return hubs, ungrouped
end

local function SortEntries()
    table.sort(entries, function(a,b)
        if a.type == b.type then return (a.title or "") < (b.title or "") end
        return a.type < b.type
    end)
end

local function SortedNeighborIDs()
    local ids = {}
    for id in pairs(neighborZones) do ids[#ids+1]=id end
    table.sort(ids, function(a,b)
        local an = (neighborZones[a] and neighborZones[a].name) or tostring(a)
        local bn = (neighborZones[b] and neighborZones[b].name) or tostring(b)
        return an < bn
    end)
    return ids
end

-- ===== Collection orchestrators =====
local function CollectData()
    ResetAll()
    currentMapID, currentZoneName = GetPlayerMap()
    if not currentMapID then return end

    -- Current zone
    CollectZoneEntries(currentMapID, currentZoneName, entries)

    -- neighbors from parent
    local info = C_Map.GetMapInfo(currentMapID)
    local parentID = info and info.parentMapID
    if parentID then
        local children
        if Enum and Enum.UIMapType and Enum.UIMapType.Zone then
            children = C_Map.GetMapChildrenInfo(parentID, Enum.UIMapType.Zone) or {}
        else
            children = C_Map.GetMapChildrenInfo(parentID) or {}
        end
        for _, child in ipairs(children) do
            if child.mapID ~= currentMapID then
                neighborZones[child.mapID] = neighborZones[child.mapID] or { name = child.name or ("Map "..child.mapID), entries = {} }
            end
        end
    end

    for zoneID, z in pairs(neighborZones) do
        local zInfo = C_Map.GetMapInfo(zoneID)
        local zName = (zInfo and zInfo.name) or z.name or ("Map "..tostring(zoneID))
        z.name = zName
        CollectZoneEntries(zoneID, zName, z.entries)
    end
end

local function BuildTrees()
    wipe(hubsForRender)
    local h,u = BuildHubGroupingForList(entries)
    for _, hub in ipairs(h or {}) do hubsForRender[#hubsForRender+1] = hub end
    for _, z in pairs(neighborZones) do
        local hh,uu = BuildHubGroupingForList(z.entries)
        z.hubsTree, z.ungrouped = hh, uu
    end
end

-- ===== Pin Scan Integration =====
local PIN_TEMPLATES = {
    QuestBlob = "QuestBlobPinTemplate",
    QuestHub  = "QuestHubPinTemplate",
    QuestOffer= "QuestOfferPinTemplate",
}

local function ClearPinCacheForMap(mapID)
    for k in pairs(pinCache.QuestBlob) do pinCache.QuestBlob[k]=nil end
    for k in pairs(pinCache.QuestHub)  do pinCache.QuestHub[k]=nil end
    for k in pairs(pinCache.QuestOffer)do pinCache.QuestOffer[k]=nil end
end

local function ScanPinsOnWorldMap()
    if not WorldMapFrame or not WorldMapFrame.pinPools then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    ClearPinCacheForMap(mapID)

    local function add(cache, rec)
        cache[#cache+1] = rec
    end

    for key, template in pairs(PIN_TEMPLATES) do
        local pool = WorldMapFrame.pinPools[template]
        if pool and pool.EnumerateActive then
            for pin in pool:EnumerateActive() do
                local name = (pin.GetName and pin:GetName()) or ""
                local x = pin.x or pin.normalizedX or 0
                local y = pin.y or pin.normalizedY or 0
                local questID = pin.questID
                local atlas = pin.atlas or (pin.Texture and pin.Texture.GetTexture and pin.Texture:GetTexture()) or nil
                add(pinCache[key], {mapID=mapID, questID=questID, x=x, y=y, atlas=atlas, name=name})
            end
        end
    end
end

-- Hook when world map is shown
WorldMapFrame:HookScript("OnShow", function()
    C_Timer.After(0, ScanPinsOnWorldMap)
end)

-- ===== Tooltip helpers =====
local function ReleaseTooltip()
    if QTip and tooltip then QTip:Release(tooltip); tooltip=nil
    elseif tooltip then tooltip:Hide(); tooltip=nil end
end

local function AcquireTooltip(anchor)
    if QTip then
        tooltip = QTip:Acquire("QuestZoneBrokerTooltip", 3, "LEFT","LEFT","RIGHT")
        tooltip:ClearAllPoints()
        if anchor and anchor.GetCenter then tooltip:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4) else tooltip:SetPoint("CENTER", UIParent, "CENTER") end
        tooltip:SetAutoHideDelay(0.1, anchor or UIParent)
        return tooltip
    else
        tooltip = CreateFrame("GameTooltip", "QuestZoneBrokerGameTooltip", UIParent, "GameTooltipTemplate")
        tooltip:SetOwner(anchor or UIParent, "ANCHOR_BOTTOM")
        return tooltip
    end
end

-- ===== Hub Enhancement Functions =====
-- Diese Funktionen erweitern die Hub-Anzeige mit mehr Informationen

local function GetHubTypeSummary(hub)
    -- Zähle alle Kinder-Quest-Typen und returne formatierte Summary
    local typeCounts = {}
    
    for _, child in ipairs(hub.children or {}) do
        local qType = child.type or "Unknown"
        typeCounts[qType] = (typeCounts[qType] or 0) + 1
    end
    
    -- Priorisierte Reihenfolge für schöne Anzeige
    local parts = {}
    local priorityOrder = {"AvailableQuest", "Quest", "WorldQuest", "CampaignQuest", "TaskQuest", "AreaPOI"}
    
    for _, ptype in ipairs(priorityOrder) do
        if typeCounts[ptype] and typeCounts[ptype] > 0 then
            -- Kurznamen für bessere Lesbarkeit
            local shortName = ptype
            if ptype == "AvailableQuest" then shortName = "Available"
            elseif ptype == "WorldQuest" then shortName = "WorldQ"
            elseif ptype == "CampaignQuest" then shortName = "Campaign"
            elseif ptype == "TaskQuest" then shortName = "Task"
            elseif ptype == "AreaPOI" then shortName = "POI" end
            
            table.insert(parts, string.format("%d %s", typeCounts[ptype], shortName))
        end
    end
    
    -- Sonstige Types (falls welche übrig)
    for ttype, count in pairs(typeCounts) do
        local found = false
        for _, ptype in ipairs(priorityOrder) do
            if ttype == ptype then found = true break end
        end
        if not found then
            table.insert(parts, string.format("%d %s", count, ttype))
        end
    end
    
    return table.concat(parts, ", ")
end

local function GetHubDistance(hub)
    -- Berechne Entfernung vom Spieler zum Hub
    if not hub.x or not hub.y then return nil end
    
    local playerMapID = C_Map.GetBestMapForUnit("player")
    if not playerMapID or playerMapID ~= hub.mapID then return nil end
    
    local playerPos = C_Map.GetPlayerMapPosition(playerMapID, "player")
    if not playerPos then return nil end
    
    local playerX, playerY = playerPos:GetXY()
    if not playerX or not playerY then return nil end
    
    -- Berechne Distanz (genormalisierte Coords sind 0-1, Map ist typisch 200-250 Yards per 0.01)
    local dx = (playerX - hub.x) * 100 * 3  -- Grobe Konvertierung zu Yards
    local dy = (playerY - hub.y) * 100 * 3
    local distYards = math.sqrt(dx*dx + dy*dy)
    
    -- Formatiere schön
    if distYards < 100 then
        return string.format("%.0fm", distYards)
    elseif distYards < 1000 then
        return string.format("%.0fm", distYards)
    else
        return string.format("%.1fkm", distYards / 1000)
    end
end

local function GetHubColorByDistance(distance)
    -- Farb-Codierung basierend auf Entfernung
    if not distance then return "" end
    
    -- Parse distance (z.B. "150m")
    local numStr = distance:match("([0-9%.]+)")
    if not numStr then return "" end
    local num = tonumber(numStr)
    if not num then return "" end
    
    -- Klassifizierung
    if num < 100 then
        return "|cff1eff00"  -- Grün (nah)
    elseif num < 300 then
        return "|cffffcc00"  -- Gelb (mittel)
    elseif num < 600 then
        return "|cffff8000"  -- Orange (fern)
    else
        return "|cffff0000"  -- Rot (sehr fern)
    end
end

local function GetHubColorByQuestAvailability(hub)
    -- Farb-Codierung basierend auf Quest-Typen im Hub
    -- Grün wenn viele Available Quests, Orange wenn gemischt, Rot wenn nur schwer
    
    local availableCount = 0
    local questCount = 0
    
    for _, child in ipairs(hub.children or {}) do
        if child.type == "AvailableQuest" then
            availableCount = availableCount + 1
        elseif child.type == "Quest" or child.type == "WorldQuest" then
            questCount = questCount + 1
        end
    end
    
    local total = #(hub.children or {})
    if total == 0 then return "" end
    
    local availableRatio = availableCount / total
    
    if availableRatio > 0.5 then
        return "|cff1eff00"  -- Grün (viele Available)
    elseif availableRatio > 0.25 then
        return "|cffffcc00"  -- Gelb (gemischt)
    else
        return "|cff808080"  -- Grau (eher schwierig)
    end
end

-- ===== Tooltip rendering (with pin cache sections) =====
local function RenderCurrentZone()
    if not tooltip then return end
    if QTip then
        tooltip:AddHeader("Quests & Hubs in:", currentZoneName or "?")
        tooltip:AddLine(" ")
        if #hubsForRender > 0 then
            tooltip:AddLine("Typ","Titel","Infos")
            tooltip:AddSeparator(1,1,1,1)
            for _, hub in ipairs(hubsForRender) do
                -- ENHANCEMENT 1: Quest-Typ-Verteilung statt nur Zahl
                local typeSummary = GetHubTypeSummary(hub)
                
                -- ENHANCEMENT 2: Entfernung zum Spieler (optional)
                local hubDistance = GetHubDistance(hub)
                local distStr = hubDistance and ("  " .. hubDistance) or ""
                
                -- ENHANCEMENT 3: Farb-Codierung basierend auf Quest-Verfügbarkeit
                local hubColor = GetHubColorByQuestAvailability(hub)
                if hubColor == "" then hubColor = "|cffaaaaaa" end
                
                -- Kombiniere alles zu schönem Format
                local hubTitle = string.format("%s%s %s(%s)|r", 
                    hubColor, 
                    hub.title or "Quest Hub", 
                    distStr,
                    typeSummary)
                
                local hubInfoCol = (hub.mapID or "?") .. "  " .. (hub.zone or "?")
                local hubLine = tooltip:AddLine("QuestHub", hubTitle, hubInfoCol)
                
                tooltip:SetLineScript(hubLine, "OnMouseDown", function(_,_,button)
                    if IsShiftKeyDown() and button=="LeftButton" then for _,child in ipairs(hub.children) do AddTomTomWaypoint(child) end; AddTomTomWaypoint(hub) else AddTomTomWaypoint(hub) end
                end)
                
                for _, child in ipairs(hub.children) do
                    local mapCol = (child.mapID or "?") .. "  " .. (child.zone or "?")
                    local label = (child.type=="AvailableQuest" and " |cffffd700(Annehmbar)|r") or (child.type=="CampaignQuest" and " |cff66ccff(Kampagne)|r") or (child.type=="TaskQuest" and " |cffc0c0c0(Task)|r") or ""
                    local childTitle = string.format("   • %s%s", child.title or "?", label)
                    local cl = tooltip:AddLine(" ", childTitle, mapCol)
                    tooltip:SetLineScript(cl, "OnMouseDown", function(_,_,button)
                        if IsShiftKeyDown() and button=="LeftButton" then AddAllWaypoints(entries) else AddTomTomWaypoint(child) end
                    end)
                end
            end
        end
        -- Pin cache sections
        local function section(title, list)
            if list and #list > 0 then
                tooltip:AddLine(" ")
                tooltip:AddHeader(title)
                tooltip:AddLine("Typ","Info","Koords")
                tooltip:AddSeparator(1,1,1,1)
                for _, p in ipairs(list) do
                    -- Ermittle den Quest-Titel für bessere Anzeige
                    local titleText = (p.questID and SafeGetQuestTitle and SafeGetQuestTitle(p.questID)) or (p.atlas or p.name or "-")
                    
                    -- Formatiere Info-String basierend auf Pin-Typ
                    local info
                    if title == "QuestOffer" and p.questID then
                        -- Schöne Formatierung für QuestOffer: "Quest Title" (questID)
                        info = string.format("\"%s\" (%s)", titleText, tostring(p.questID))
                    else
                        -- Standard-Formatierung für andere Typen
                        info = (p.questID and ("questID="..p.questID)) or titleText
                    end
                    
                    local coords = (p.x and p.y) and (string.format("%.1f/%.1f", p.x*100, p.y*100)) or "-"
                    local line = tooltip:AddLine(title, info, coords)
                    tooltip:SetLineScript(line, "OnMouseDown", function(_,_,button)
                        if p.questID then AddTomTomWaypoint({type=title, title=info, questID=p.questID, mapID=p.mapID, x=p.x, y=p.y}) end
                    end)
                end
            end
        end
        section("QuestBlob", pinCache.QuestBlob)
        section("QuestHub",  pinCache.QuestHub)
        section("QuestOffer",pinCache.QuestOffer)

        -- Ungrouped
        local ungrouped = {}
        for _, e in ipairs(entries) do if (e.type=="Quest" or e.type=="WorldQuest" or e.type=="CampaignQuest" or e.type=="AvailableQuest" or e.type=="TaskQuest") and not e._grouped then ungrouped[#ungrouped+1]=e end end
        if #ungrouped > 0 then
            table.sort(ungrouped, function(a,b) return (a.title or "") < (b.title or "") end)
            tooltip:AddLine(" ")
            tooltip:AddHeader("Weitere Quests in dieser Zone")
            tooltip:AddLine("Typ","Titel","MapID / Zone")
            tooltip:AddSeparator(1,1,1,1)
            for _, e in ipairs(ungrouped) do
                local mapCol = (e.mapID or "?") .. "  " .. (e.zone or "?")
                local label = (e.type=="AvailableQuest" and " |cffffd700(Annehmbar)|r") or (e.type=="CampaignQuest" and " |cff66ccff(Kampagne)|r") or (e.type=="TaskQuest" and " |cffc0c0c0(Task)|r") or ""
                local title = string.format("%s%s", e.title or "?", label)
                local line = tooltip:AddLine(e.type, title, mapCol)
                tooltip:SetLineScript(line, "OnMouseDown", function(_,_,button)
                    if IsShiftKeyDown() and button=="LeftButton" then AddAllWaypoints(entries) else AddTomTomWaypoint(e) end
                end)
            end
        end
    else
        tooltip:AddLine("Quests & Hubs in: "..(currentZoneName or "?"))
    end
end

local function RenderNeighbors()
    if not tooltip then return end
    local ids = SortedNeighborIDs()
    if #ids == 0 then return end
    if QTip then
        tooltip:AddLine(" ")
        tooltip:AddHeader("Andere Zonen dieses Kontinents")
        for _, zid in ipairs(ids) do
            local z = neighborZones[zid]
            tooltip:AddLine(" ")
            local zoneHeader = tooltip:AddLine("Zone", z.name or ("Map "..zid), tostring(zid))
            tooltip:SetLineScript(zoneHeader, "OnMouseDown", function(_,_,button) if IsShiftKeyDown() and button=="LeftButton" then AddAllWaypoints(z.entries) end end)
            if z.hubsTree and #z.hubsTree > 0 then
                tooltip:AddLine("Typ","Titel","Infos")
                tooltip:AddSeparator(1,1,1,1)
                for _, hub in ipairs(z.hubsTree) do
                    -- ENHANCEMENT 1: Quest-Typ-Verteilung
                    local typeSummary = GetHubTypeSummary(hub)
                    
                    -- ENHANCEMENT 2: Entfernung
                    local hubDistance = GetHubDistance(hub)
                    local distStr = hubDistance and ("  " .. hubDistance) or ""
                    
                    -- ENHANCEMENT 3: Farb-Codierung
                    local hubColor = GetHubColorByQuestAvailability(hub)
                    if hubColor == "" then hubColor = "|cffaaaaaa" end
                    
                    local hubTitle = string.format("%s%s %s(%s)|r", 
                        hubColor,
                        hub.title or "Quest Hub", 
                        distStr,
                        typeSummary)
                    
                    local hubMapCol = (hub.mapID or "?") .. "  " .. (hub.zone or "?")
                    local hubLine = tooltip:AddLine("QuestHub", hubTitle, hubMapCol)
                    tooltip:SetLineScript(hubLine, "OnMouseDown", function(_,_,button)
                        if IsShiftKeyDown() and button=="LeftButton" then for _,child in ipairs(hub.children) do AddTomTomWaypoint(child) end; AddTomTomWaypoint(hub) else AddTomTomWaypoint(hub) end
                    end)
                    for _, child in ipairs(hub.children) do
                        local mapCol = (child.mapID or "?") .. "  " .. (child.zone or "?")
                        local label = (child.type=="AvailableQuest" and " |cffffd700(Annehmbar)|r") or (child.type=="CampaignQuest" and " |cff66ccff(Kampagne)|r") or (child.type=="TaskQuest" and " |cffc0c0c0(Task)|r") or ""
                        local childTitle = string.format("   • %s%s", child.title or "?", label)
                        local cl = tooltip:AddLine(" ", childTitle, mapCol)
                        tooltip:SetLineScript(cl, "OnMouseDown", function(_,_,button)
                            if IsShiftKeyDown() and button=="LeftButton" then AddAllWaypoints(z.entries) else AddTomTomWaypoint(child) end
                        end)
                    end
                end
            end
        end
        tooltip:AddLine(" ")
        tooltip:AddLine("|cffaaaaaaTipp: Shift+Links-Klick setzt Wegpunkte gesammelt (Zone/Hub/Alle).")
    else
        tooltip:AddLine("(Installiere LibQTip-1.0 für klickbare, eingerückte Einträge)", 0.7,0.7,0.7)
    end
end

local function ShowTooltip(anchor)
    ReleaseTooltip()
    CollectData(); SortEntries(); BuildTrees()
    AcquireTooltip(anchor)
    RenderCurrentZone()
    RenderNeighbors()
    if QTip and tooltip then tooltip:Show() else tooltip:Show() end
end

-- ===== Broker Handlers =====
if broker then
    function broker:OnEnter() ShowTooltip(self) end
    function broker:OnLeave() ReleaseTooltip() end
    function broker:OnClick(button)
        if button == "LeftButton" then
            if IsShiftKeyDown() then AddAllWaypoints(entries) else CollectData(); SortEntries(); BuildTrees(); DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[QuestZoneBroker]|r Daten aktualisiert.") end
        end
    end
end

-- ===== Events =====
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("QUEST_LOG_UPDATE")

local function UpdateText()
    local mapID, zone = GetPlayerMap()
    local count = 0
    for _, e in ipairs(entries) do if (e.type=="Quest" or e.type=="WorldQuest" or e.type=="CampaignQuest" or e.type=="AvailableQuest" or e.type=="TaskQuest") then count = count + 1 end end
    if broker then broker.text = (zone or "Zone") .. ": " .. tostring(count) end
end

f:SetScript("OnEvent", function()
    CollectData(); SortEntries(); BuildTrees(); UpdateText()
    if tooltip and ((QTip and tooltip:IsShown()) or (tooltip.IsShown and tooltip:IsShown())) then
        ShowTooltip(broker)
    end
end)

C_Timer.After(2, function() CollectData(); SortEntries(); BuildTrees(); UpdateText() end)
