
-- QuestZoneBroker – loaded via: local ADDON_NAME = ...

-- =====================================================
-- QuestZoneBroker v2.0
--  - Zwei LDB-Broker: Zone (Tooltip 1) + Kontinent (Tooltip 2)
--  - QuestHub-Zuordnung: C_QuestHub API (Dragonflight+),
--    Distanz-basiert (mit GetXY()), Koordinatenlos-Fallback
--  - Pin-Scan: QuestBlobPinTemplate, QuestHubPinTemplate, QuestOfferPinTemplate
--  - Zonen-Dedup, Nachbarzonen-Dedup, Campaign/QuestLine-Filter
--  - Debug: /qzb debug | /qzb xzone | /qzb hubs [Filter]
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
    type  = "data source",
    text  = "Zone Quests",
    icon  = "Interface\\GossipFrame\\ActiveQuestIcon",
    label = "Zone",
})

local broker2 = LDB and LDB:NewDataObject("QuestZoneBroker.Neighbors", {
    type  = "data source",
    text  = "Kontinent",
    icon  = "Interface\\GossipFrame\\AvailableQuestIcon",
    label = "Kontinent",
})

-- ===== State =====
local HUB_RANGE = 0.02 -- grouping distance
local entries = {}           -- current zone entries
local hubsForRender = {}     -- hub tree for current zone
local ungroupedEntries = {}  -- ungrouped quests of current zone (built by BuildTrees)
local neighborZones = {}     -- neighbors data
local currentMapID, currentZoneName
local tooltip   -- Tooltip 1: aktuelle Zone
local tooltip2  -- Tooltip 2: Nachbarzonen

-- pin scan cache
local pinCache = {
    QuestBlob = {},   -- { {mapID, questID, title, x, y, atlas} }
    QuestHub  = {},   -- { {mapID, questID, areaPoiID, title, x, y, atlas} }
    QuestOffer= {},   -- { {mapID, questID, title, x, y, atlas} }
}

-- presence sets for campaign filtering
local questsOnMapSet, taskOnMapSet = {}, {}

-- ===== Utils =====
local function SafeGetQuestTitle(questID)
    if not questID then return "?" end
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
    wipe(neighborZones)
    wipe(questsOnMapSet)
    wipe(taskOnMapSet)
    -- hubsForRender + ungroupedEntries werden in BuildTrees gewipet
    -- pinCache bleibt erhalten (wird nur bei WorldMap-Öffnen neu gescannt)
end

local function GetWaypointForQuest(questID, hintMapID)
    if C_QuestLog.GetNextWaypointForMap then
        local v = C_QuestLog.GetNextWaypointForMap(questID, hintMapID)
        if v then
            local vx, vy
            if v.GetXY then vx, vy = v:GetXY() else vx, vy = v.x, v.y end
            if vx and vy then return hintMapID, vx, vy end
        end
    end
    if C_QuestLog.GetNextWaypoint then
        local v, mapID = C_QuestLog.GetNextWaypoint(questID)
        if v then
            local vx, vy
            if v.GetXY then vx, vy = v:GetXY() else vx, vy = v.x, v.y end
            if vx and vy then return mapID or hintMapID, vx, vy end
        end
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
        if pos then
            if pos.GetXY then mapID, x, y = entry.mapID, pos:GetXY()
            else mapID, x, y = entry.mapID, pos.x, pos.y end
        end
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

local function AddAllWaypoints(list)
    if not TomTom or not TomTom.AddWaypoint then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff6666[QuestZoneBroker]|r TomTom nicht gefunden. Bitte installiere TomTom.")
        return
    end
    local count = 0
    for _, e in ipairs(list or {}) do
        if e.x and e.y then
            AddTomTomWaypoint(e)
            count = count + 1
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage(("|cff33ff99[QuestZoneBroker]|r %d Wegpunkte gesetzt."):format(count))
end

-- ===== Map traversal (child/micro) =====
local function ForEachChildMapRec(parentID, fn)
    if not parentID then return end
    local function addChildren(pid, mapType)
        -- false: nur direkte Kinder, Rekursion erfolgt manuell
        local kids = C_Map.GetMapChildrenInfo and C_Map.GetMapChildrenInfo(pid, mapType, false) or {}
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
    -- Nur erlauben wenn die Quest auf der aktuellen Zonen-Map sichtbar ist.
    -- "Im Log" allein reicht NICHT – Quests aus anderen Zonen sind auch im Log
    -- und würden sonst fälschlich in jede Nachbarzone eingetragen.
    if questsOnMapSet[qid] or taskOnMapSet[qid] then return true end
    return false
end

-- ===== Collection (zone) =====
local function CollectTasksForMap(outTable, zoneMapID, zoneName, seen, parentMapID)
    -- parentMapID: wenn gesetzt, erhalten Einträge diese mapID statt zoneMapID
    -- (wird für Child-Maps genutzt damit mapID mit dem Hub-Koordinatensystem übereinstimmt)
    local effectiveMapID = parentMapID or zoneMapID
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
                AddEntry(outTable, {type="AvailableQuest", title=title or ("Quest "..t.questID), questID=t.questID, mapID=effectiveMapID, zone=zoneName, x=tx, y=ty})
            elseif Enum and Enum.QuestTagType and (t.questTagType == Enum.QuestTagType.WorldQuest) then
                AddEntry(outTable, {type="WorldQuest", title=title or ("World Quest "..t.questID), questID=t.questID, mapID=effectiveMapID, zone=zoneName, x=tx, y=ty})
            else
                AddEntry(outTable, {type="TaskQuest", title=title or ("Task "..t.questID), questID=t.questID, mapID=effectiveMapID, zone=zoneName, x=tx, y=ty})
            end
        end
    end
end

-- ===== Campaign / QuestLine helpers (top-level, keine Closure-Allokation pro Zone) =====
local function PushCampaignQuests(zoneMapID, zoneName, outTable, seen)
    if not C_CampaignInfo or not C_CampaignInfo.GetCampaignsForMap then return end
    -- Kein Fallback auf GetCampaigns() – das liefert globale Kampagnen aller Zonen
    local campaigns = C_CampaignInfo.GetCampaignsForMap(zoneMapID) or {}
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

local function PushQuestLineQuests(zoneMapID, zoneName, outTable, seen)
    if not C_QuestLine or not C_QuestLine.GetAvailableQuestLines then return end
    for _, line in ipairs(C_QuestLine.GetAvailableQuestLines(zoneMapID) or {}) do
        if line and line.questLineID and C_QuestLine.GetQuestLineQuests then
            for _, qid in ipairs(C_QuestLine.GetQuestLineQuests(line.questLineID) or {}) do
                -- GetQuestLineQuests gibt ALLE Quests der Linie zurück, auch aus anderen Zonen.
                -- CampaignQuestIsAllowed prüft ob die Quest auf DIESER Zonen-Map sichtbar ist.
                if not seen[qid] and CampaignQuestIsAllowed(qid) then
                    seen[qid] = true
                    AddEntry(outTable, {type="CampaignQuest", title=SafeGetQuestTitle(qid), questID=qid, mapID=zoneMapID, zone=zoneName})
                end
            end
        end
    end
end


local function CollectZoneEntries(zoneMapID, zoneName, outTable)
    -- prevPOI frisch lesen bevor wir den Zustand ändern
    local prevPOI = C_QuestLog.GetMapForQuestPOIs and C_QuestLog.GetMapForQuestPOIs()
    if C_QuestLog.SetMapForQuestPOIs then C_QuestLog.SetMapForQuestPOIs(zoneMapID) end

    -- Presence-Sets NUR für diese Zone neu aufbauen.
    -- Ohne wipe() würden Quests aus vorher verarbeiteten Zonen CampaignQuestIsAllowed()
    -- fälschlicherweise für diese Zone passieren lassen → Quests in mehreren Zonen.
    wipe(questsOnMapSet)
    wipe(taskOnMapSet)
    MarkOnMapPresence(zoneMapID)

    local seen = {}
    for _, q in ipairs(C_QuestLog.GetQuestsOnMap(zoneMapID) or {}) do
        seen[q.questID] = true
        AddEntry(outTable, {type="Quest", title=SafeGetQuestTitle(q.questID), questID=q.questID, mapID=zoneMapID, zone=zoneName, x=q.x, y=q.y})
    end

    CollectTasksForMap(outTable, zoneMapID, zoneName, seen)

    ForEachChildMapRec(zoneMapID, function(childID)
        -- Tasks und Quests aus Child-Maps erhalten mapID=zoneMapID (Parent),
        -- damit ihre Koordinaten mit dem Hub-Koordinatensystem übereinstimmen.
        CollectTasksForMap(outTable, childID, zoneName, seen, zoneMapID)
        for _, cq in ipairs(C_QuestLog.GetQuestsOnMap(childID) or {}) do
            if not seen[cq.questID] then
                seen[cq.questID] = true
                AddEntry(outTable, {type="Quest", title=SafeGetQuestTitle(cq.questID), questID=cq.questID, mapID=zoneMapID, zone=zoneName, x=cq.x, y=cq.y})
            end
        end
    end)

    -- Area POIs (available / other) – poiID in seen tracken gegen Doppeleinträge
    for _, poiID in ipairs(C_AreaPoiInfo.GetAreaPOIForMap and (C_AreaPoiInfo.GetAreaPOIForMap(zoneMapID) or {}) or {}) do
        if not seen["poi_"..poiID] then
            seen["poi_"..poiID] = true
            local info = C_AreaPoiInfo.GetAreaPOIInfo and C_AreaPoiInfo.GetAreaPOIInfo(zoneMapID, poiID)
            if info then
                local atlas = info.atlasName and string.lower(info.atlasName) or nil
                local texkit = info.textureKit and string.lower(info.textureKit) or nil
                local isQuestLike = (C_AreaPoiInfo.IsAreaPOIQuest and C_AreaPoiInfo.IsAreaPOIQuest(poiID)) or false
                local isAvailableQuest = (info.isQuestStart == true) or (info.shouldGlow == true) or (atlas and atlas:find("questavailable")) or (texkit and texkit:find("quest")) or isQuestLike
                local pos = C_AreaPoiInfo.GetAreaPOIPosition and C_AreaPoiInfo.GetAreaPOIPosition(zoneMapID, poiID)
                local px, py
                if pos then
                    if pos.GetXY then
                        px, py = pos:GetXY()
                    else
                        px, py = pos.x, pos.y  -- Fallback für ältere API-Versionen
                    end
                end
                if isAvailableQuest then
                    AddEntry(outTable, {type="AvailableQuest", title=(info.name and info.name ~= "" and info.name) or (info.description) or ("POI "..poiID), poiID=poiID, mapID=zoneMapID, zone=zoneName, x=px, y=py})
                elseif isQuestLike or info.name or info.description then
                    AddEntry(outTable, {type="AreaPOI", title=(info.name and info.name ~= "" and info.name) or (info.description) or ("POI "..poiID), poiID=poiID, mapID=zoneMapID, zone=zoneName, x=px, y=py})
                end
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
                local hx, hy
                if pos then
                    if pos.GetXY then hx, hy = pos:GetXY() else hx, hy = pos.x, pos.y end
                end
                -- C_QuestHub (Dragonflight+): direkte Quest-Zuordnung vom Hub
                local directQuestIDs = nil
                if C_QuestHub and C_QuestHub.GetQuestHubInfo then
                    local qhInfo = C_QuestHub.GetQuestHubInfo(hubID)
                    if qhInfo and qhInfo.questIDs then
                        directQuestIDs = qhInfo.questIDs
                    end
                end
                AddEntry(outTable, {type="QuestHub", title=(hubInfo and hubInfo.name) or ("Quest Hub "..tostring(hubID)), mapID=zoneMapID, zone=zoneName, x=hx, y=hy, poiID=hubID, directQuestIDs=directQuestIDs})
            end
        end
    end
    -- Campaigns / QuestLines (gefiltert, via top-level Helfer)
    PushCampaignQuests(zoneMapID, zoneName, outTable, seen)
    PushQuestLineQuests(zoneMapID, zoneName, outTable, seen)

    if C_QuestLog.SetMapForQuestPOIs then C_QuestLog.SetMapForQuestPOIs(prevPOI) end  -- restore even if nil
end


-- ===== Grouping helpers =====
local function dist2(x1, y1, x2, y2)
    local dx, dy = x1-x2, y1-y2
    return dx*dx + dy*dy
end
local function BuildHubGroupingForList(list)
    local hubs, ungrouped = {}, {}
    for _, e in ipairs(list) do e._grouped = nil end

    for _, e in ipairs(list) do
        if e.type == "QuestHub" then
            local hx, hy = e.x, e.y
            if (not hx or not hy) and e.poiID and C_AreaPoiInfo.GetAreaPOIPosition then
                local pos = C_AreaPoiInfo.GetAreaPOIPosition(e.mapID, e.poiID)
                if pos then
                    if pos.GetXY then hx, hy = pos:GetXY() else hx, hy = pos.x, pos.y end
                end
            end
            e.x, e.y = hx, hy
            e.children = {}
            table.insert(hubs, e)
        end
    end

    -- Pass 1: directQuestIDs (C_QuestHub API, Dragonflight+) – exakte Zuordnung vom Spiel
    for _, h in ipairs(hubs) do
        if h.directQuestIDs then
            local idSet = {}
            for _, qid in ipairs(h.directQuestIDs) do idSet[qid] = true end
            for _, q in ipairs(list) do
                if q.questID and idSet[q.questID] and not q._grouped then
                    table.insert(h.children, q)
                    q._grouped = true
                end
            end
        end
    end

    -- Pass 2: Distanz-basiert für Einträge mit Koordinaten
    for _, q in ipairs(list) do
        if not q._grouped and (q.type == "Quest" or q.type == "WorldQuest" or q.type == "CampaignQuest" or q.type == "AvailableQuest" or q.type == "TaskQuest" or q.type == "AreaPOI") then
            local attached = false
            if q.x and q.y then
                local bestHub, bestD
                for _, h in ipairs(hubs) do
                    -- mapID-Guard: Koordinaten verschiedener Karten sind nicht vergleichbar
                    if h.x and h.y and h.mapID == q.mapID then
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

    -- Leere Hubs bekommen KEINE Quests per mapID-Fallback zugewiesen.
    -- Ein Hub ohne Kinder innerhalb von HUB_RANGE hat schlicht keine zugehörigen Quests –
    -- ein reiner mapID-Match würde beliebige Quests aus der gesamten Zone falsch zuordnen.
    -- Ausnahme: koordinatenlose Einträge (GetQuestsOnMap/GetAreaPOIPosition lieferte nil)
    -- können nicht per Distanz zugeordnet werden. Wenn auf einer mapID genau ein Hub liegt,
    -- bekommt er alle koordinatenlosen Einträge dieser mapID (sicherer Fallback).
    -- Bei mehreren Hubs ohne Koordinatenunterscheidung → bleibt in Ungrouped.
    local hubsByMap = {}  -- mapID → { anzahl, einziger_hub }
    for _, h in ipairs(hubs) do
        local mid = h.mapID
        if not hubsByMap[mid] then
            hubsByMap[mid] = { count = 0, hub = nil }
        end
        hubsByMap[mid].count = hubsByMap[mid].count + 1
        hubsByMap[mid].hub   = h  -- bei count>1 irrelevant
    end

    local stillUngrouped = {}
    for _, q in ipairs(ungrouped) do
        local entry = hubsByMap[q.mapID]
        if entry and entry.count == 1 and not (q.x and q.y) then
            -- Koordinatenlos + genau ein Hub auf dieser Map → sicher zuordnen
            table.insert(entry.hub.children, q)
            q._grouped = true
        else
            table.insert(stillUngrouped, q)
        end
    end
    ungrouped = stillUngrouped

    table.sort(hubs, function(a,b) return (a.title or "") < (b.title or "") end)
    for _, h in ipairs(hubs) do table.sort(h.children, function(a,b) return (a.title or "") < (b.title or "") end) end
    table.sort(ungrouped, function(a,b) return (a.title or "") < (b.title or "") end)

    return hubs, ungrouped
end

local function SortEntries()
    -- QuestHub-Entries werden via hubsForRender gerendert, nicht direkt → überspringen
    table.sort(entries, function(a, b)
        if a.type == "QuestHub" then return false end
        if b.type == "QuestHub" then return true  end
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

    -- Aktuelle Zone sammeln
    CollectZoneEntries(currentMapID, currentZoneName, entries)

    -- Globale QuestID-Menge aus der aktuellen Zone aufbauen.
    -- Verhindert dass dieselbe Quest in Nachbarzonen nochmals auftaucht
    -- (passiert wenn GetQuestsOnMap() eine Quest für mehrere benachbarte Maps zurückgibt).
    local globalSeenQuestIDs = {}
    for _, e in ipairs(entries) do
        if e.questID then globalSeenQuestIDs[e.questID] = true end
    end

    -- Nachbarzonen aus dem Parent-Map aufbauen.
    -- Dedup nach Name verhindert dass dieselbe Zone mit mehreren MapIDs dreifach erscheint
    -- (WoW-API liefert manchmal mehrere Einträge für denselbe Zone, z.B. Insel von Quel'Danas).
    local info = C_Map.GetMapInfo(currentMapID)
    local parentID = info and info.parentMapID
    if parentID then
        local seenNeighborNames = {}
        local children
        if Enum and Enum.UIMapType and Enum.UIMapType.Zone then
            children = C_Map.GetMapChildrenInfo(parentID, Enum.UIMapType.Zone) or {}
        else
            children = C_Map.GetMapChildrenInfo(parentID) or {}
        end
        for _, child in ipairs(children) do
            local childName = child.name or ("Map "..child.mapID)
            if child.mapID ~= currentMapID and not seenNeighborNames[childName] then
                seenNeighborNames[childName] = true
                neighborZones[child.mapID] = { name = childName, entries = {} }
            end
        end
    end

    -- Nachbarzonen befüllen, bereits gesehene Quests ausschließen
    for zoneID, z in pairs(neighborZones) do
        local zInfo = C_Map.GetMapInfo(zoneID)
        local zName = (zInfo and zInfo.name) or z.name or ("Map "..tostring(zoneID))
        z.name = zName
        CollectZoneEntries(zoneID, zName, z.entries)
        -- Quests die bereits in der aktuellen Zone sind entfernen
        local filtered = {}
        for _, e in ipairs(z.entries) do
            if not (e.questID and globalSeenQuestIDs[e.questID]) then
                filtered[#filtered+1] = e
            end
        end
        z.entries = filtered
    end
end

local function BuildTrees()
    wipe(hubsForRender)
    wipe(ungroupedEntries)
    local h, u = BuildHubGroupingForList(entries)
    for _, hub in ipairs(h or {}) do hubsForRender[#hubsForRender+1] = hub end
    for _, e in ipairs(u or {}) do ungroupedEntries[#ungroupedEntries+1] = e end
    for _, z in pairs(neighborZones) do
        local hh, uu = BuildHubGroupingForList(z.entries)
        z.hubsTree, z.ungrouped = hh, uu
    end
end

-- ===== Pin Scan Integration =====
local PIN_TEMPLATES = {
    QuestBlob = "QuestBlobPinTemplate",
    QuestHub  = "QuestHubPinTemplate",
    QuestOffer= "QuestOfferPinTemplate",
}

local function ClearPinCacheForMap()
    wipe(pinCache.QuestBlob)
    wipe(pinCache.QuestHub)
    wipe(pinCache.QuestOffer)
end

local function ScanPinsOnWorldMap()
    if not WorldMapFrame or not WorldMapFrame.pinPools then return end
    -- Nutze die aktuell angezeigte Karte, nicht die Spielerposition
    local mapID = (WorldMapFrame.GetMapID and WorldMapFrame:GetMapID())
                  or C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    ClearPinCacheForMap()

    for key, template in pairs(PIN_TEMPLATES) do
        local pool = WorldMapFrame.pinPools[template]
        if pool and pool.EnumerateActive then
            for pin in pool:EnumerateActive() do
                local x = pin.x or pin.normalizedX or 0
                local y = pin.y or pin.normalizedY or 0
                local questID = pin.questID
                local atlas = pin.atlas or (pin.Texture and pin.Texture.GetTexture and pin.Texture:GetTexture()) or nil
                local rawPoiID = (key == "QuestHub") and (pin.areaPoiID or pin.questID) or nil
                local areaPoiID = (rawPoiID and rawPoiID > 0) and rawPoiID or nil
                local cachedTitle = questID and SafeGetQuestTitle(questID) or nil
                local rec = {mapID=mapID, questID=questID, areaPoiID=areaPoiID, x=x, y=y, atlas=atlas, title=cachedTitle}
                pinCache[key][#pinCache[key]+1] = rec
            end
        end
    end
end

-- Hook when world map is shown
WorldMapFrame:HookScript("OnShow", function()
    C_Timer.After(0, ScanPinsOnWorldMap)
end)

-- ===== Tooltip helpers =====
local function ReleaseTooltip1()
    if QTip then
        if tooltip  then QTip:Release(tooltip);  tooltip  = nil end
    else
        if tooltip  then tooltip:Hide();  tooltip  = nil end
    end
end

local function ReleaseTooltip2()
    if QTip then
        if tooltip2 then QTip:Release(tooltip2); tooltip2 = nil end
    else
        if tooltip2 then tooltip2:Hide(); tooltip2 = nil end
    end
end

local function AcquireTooltip1(anchor)
    if QTip then
        tooltip = QTip:Acquire("QuestZoneBrokerTooltip", 4, "LEFT","LEFT","RIGHT","LEFT")
        tooltip:ClearAllPoints()
        if anchor and anchor.GetCenter then
            tooltip:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
        else
            tooltip:SetPoint("CENTER", UIParent, "CENTER")
        end
        -- anchor ist der LDB-Display-Frame (hat IsMouseOver).
        -- Als alternateFrame übergeben: Tooltip bleibt offen solange Maus über
        -- Broker-Button ODER Tooltip ist. OnLeave entfernt – AutoHide übernimmt.
        local altFrame = (anchor and anchor.IsMouseOver) and anchor or tooltip
        tooltip:SetAutoHideDelay(0.2, altFrame)
    else
        tooltip = _G["QuestZoneBrokerGameTooltip"]
            or CreateFrame("GameTooltip", "QuestZoneBrokerGameTooltip", UIParent, "GameTooltipTemplate")
        tooltip:SetOwner(anchor or UIParent, "ANCHOR_BOTTOM")
    end
end

local function AcquireTooltip2(anchor)
    if QTip then
        tooltip2 = QTip:Acquire("QuestZoneBrokerTooltip2", 4, "LEFT","LEFT","RIGHT","LEFT")
        tooltip2:ClearAllPoints()
        if anchor and anchor.GetCenter then
            tooltip2:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -4)
        else
            tooltip2:SetPoint("CENTER", UIParent, "CENTER")
        end
        local altFrame = (anchor and anchor.IsMouseOver) and anchor or tooltip2
        tooltip2:SetAutoHideDelay(0.2, altFrame)
    else
        tooltip2 = _G["QuestZoneBrokerGameTooltip2"]
            or CreateFrame("GameTooltip", "QuestZoneBrokerGameTooltip2", UIParent, "GameTooltipTemplate")
        tooltip2:SetOwner(anchor or UIParent, "ANCHOR_BOTTOM")
    end
end

-- ===== Hub-Hilfsfunktionen =====

local function GetHubTypeSummary(hub)
    local typeCounts = {}
    for _, child in ipairs(hub.children or {}) do
        local qType = child.type or "Unknown"
        typeCounts[qType] = (typeCounts[qType] or 0) + 1
    end

    local parts = {}
    local priorityOrder = {"AvailableQuest", "Quest", "WorldQuest", "CampaignQuest", "TaskQuest", "AreaPOI"}
    local shortNames = {AvailableQuest="Available", WorldQuest="WorldQ", CampaignQuest="Campaign", TaskQuest="Task", AreaPOI="POI"}

    for _, ptype in ipairs(priorityOrder) do
        if typeCounts[ptype] and typeCounts[ptype] > 0 then
            parts[#parts+1] = string.format("%d %s", typeCounts[ptype], shortNames[ptype] or ptype)
        end
    end

    local extras = {}
    for ttype, count in pairs(typeCounts) do
        local found = false
        for _, ptype in ipairs(priorityOrder) do
            if ttype == ptype then found = true; break end
        end
        if not found then extras[#extras+1] = string.format("%d %s", count, ttype) end
    end
    table.sort(extras)
    for _, s in ipairs(extras) do parts[#parts+1] = s end

    return table.concat(parts, ", ")
end

-- Gecachte Spielerposition für einen Render-Durchgang (verhindert N API-Calls pro Hub)
local _renderPlayerMapID, _renderPlayerX, _renderPlayerY

local function CachePlayerPosForRender()
    _renderPlayerMapID = C_Map.GetBestMapForUnit("player")
    _renderPlayerX, _renderPlayerY = nil, nil
    if _renderPlayerMapID then
        local pos = C_Map.GetPlayerMapPosition(_renderPlayerMapID, "player")
        if pos then _renderPlayerX, _renderPlayerY = pos:GetXY() end
    end
end

local function ClearPlayerPosCache()
    _renderPlayerMapID, _renderPlayerX, _renderPlayerY = nil, nil, nil
end

local function GetHubDistanceCached(hub)
    if not hub.x or not hub.y then return nil end
    if not _renderPlayerMapID or _renderPlayerMapID ~= hub.mapID then return nil end
    if not _renderPlayerX or not _renderPlayerY then return nil end
    local dx = (_renderPlayerX - hub.x) * 100 * 3
    local dy = (_renderPlayerY - hub.y) * 100 * 3
    local distYards = math.sqrt(dx*dx + dy*dy)
    if distYards < 1000 then
        return string.format("%.0fm", distYards)
    else
        return string.format("%.1fkm", distYards / 1000)
    end
end

local function GetHubColorByQuestAvailability(hub)
    -- Grün: >50% annehmbare Quests | Gelb: 25-50% | Grau: <25% (in Arbeit / unbekannt)
    
    local availableCount = 0

    for _, child in ipairs(hub.children or {}) do
        if child.type == "AvailableQuest" then
            availableCount = availableCount + 1
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

-- Forward-Deklarationen: RefreshIfShown wird vor ShowTooltip1/2 definiert,
-- Lua würde sie sonst als globale nil auflösen.
local ShowTooltip1, ShowTooltip2

local function RefreshIfShown()
    -- Nur den jeweils sichtbaren Tooltip neu aufbauen
    if QTip then
        if tooltip  and tooltip:IsShown()  then ShowTooltip1(broker)  end
        if tooltip2 and tooltip2:IsShown() then ShowTooltip2(broker2) end
    end
end
local function CountQuestsAndPOIs(list)
    local quests, pois = 0, 0
    for _, e in ipairs(list) do
        if e.type=="Quest" or e.type=="WorldQuest" or e.type=="CampaignQuest"
        or e.type=="AvailableQuest" or e.type=="TaskQuest" then
            quests = quests + 1
        elseif e.type=="AreaPOI" then
            pois = pois + 1
        end
    end
    return quests, pois
end

-- ===== Render-Hilfsfunktionen =====
local function CoordsStr(x, y)
    if x and y then return string.format("%.1f / %.1f", x*100, y*100) end
    return "-"
end

local function ZoneCol(mapID, zoneName)
    return string.format("%s · %s", tostring(mapID or "?"), zoneName or "?")
end

local function QuestLabel(qtype)
    if qtype == "AvailableQuest" then return " |cffffd700(Annehmbar)|r"
    elseif qtype == "CampaignQuest"  then return " |cff66ccff(Kampagne)|r"
    elseif qtype == "WorldQuest"     then return " |cff00ccff(Weltenquest)|r"
    elseif qtype == "TaskQuest"      then return " |cffc0c0c0(Task)|r"
    elseif qtype == "AreaPOI"        then return " |cffaaaaaa(POI)|r"
    else return "" end
end

-- Einheitlicher Zeilen-Titel fuer Quest-Kinder: "Titel" (QuestID|PoiID) (Label)
local function ChildTitleStr(entry, indent)
    local prefix = indent or "   \226\128\162 "  -- bullet •
    local idStr
    if entry.questID then
        idStr = string.format(" (%d)", entry.questID)
    elseif entry.poiID then
        idStr = string.format(" [POI %d]", entry.poiID)
    else
        idStr = ""
    end
    return string.format('%s"%s"%s%s', prefix, entry.title or "?", idStr, QuestLabel(entry.type))
end

-- ===== Pin-Cache Sektion (top-level, kein Closure pro Render) =====
local function RenderPinSection(tip, sTitle, list)
    if not list or #list == 0 then return end
    tip:AddLine(" ")
    tip:AddHeader(sTitle, "", "", "")
    tip:AddLine("Typ", "Info", "Koords", "MapID \194\183 Zone")
    tip:AddSeparator(1,1,1,1)
    for _, p in ipairs(list) do
        local titleText = p.title or (p.questID and SafeGetQuestTitle(p.questID)) or (p.atlas or "-")
        local info
        if (sTitle == "QuestOffer" or sTitle == "QuestBlob") and p.questID then
            info = string.format('"%s" (%d)', titleText, p.questID)
        elseif sTitle == "QuestHub" then
            local hubName = nil
            if p.areaPoiID and C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIInfo then
                local hi = C_AreaPoiInfo.GetAreaPOIInfo(p.mapID, p.areaPoiID)
                if hi and hi.name and hi.name ~= "" then hubName = hi.name end
            end
            if hubName then
                info = string.format("%s |cffaaaaaa(%d)|r", hubName, p.areaPoiID)
            else
                info = string.format("|cffaaaaaa[PoiID %d]|r", p.areaPoiID or 0)
            end
        else
            info = (p.questID and string.format("questID=%d", p.questID)) or titleText
        end
        local coords  = CoordsStr(p.x, p.y)
        local pMapInfo = p.mapID and C_Map.GetMapInfo(p.mapID)
        local zoneCol = ZoneCol(p.mapID, pMapInfo and pMapInfo.name)
        local line = tip:AddLine(sTitle, info, coords, zoneCol)
        tip:SetLineScript(line, "OnMouseDown", function(_,_,button)
            local we = {type=sTitle, title=info, questID=p.questID, poiID=p.areaPoiID, mapID=p.mapID, x=p.x, y=p.y}
            if p.questID or p.areaPoiID then AddTomTomWaypoint(we) end
        end)
    end
end
local function RenderCurrentZone()
    if not tooltip then return end
    if not QTip then
        tooltip:AddLine("Quests & Hubs in: "..(currentZoneName or "?"))
        return
    end

    local quests, pois = CountQuestsAndPOIs(entries)
    local countStr
    if pois > 0 then
        countStr = string.format("|cffffffff%dQ|r  |cffaaaaaa%dPOI|r", quests, pois)
    else
        countStr = string.format("|cffffffff%d Quests|r", quests)
    end
    tooltip:AddHeader("Aktuelle Zone:", currentZoneName or "?", countStr, "")
    tooltip:AddLine(" ")

    -- ===== Hub-Baum =====
    if #hubsForRender > 0 then
        tooltip:AddLine("|cffddaa00Hubs|r", "|cffddaa00Titel (Typ-Verteilung)|r", "|cffddaa00Koords|r", "|cffddaa00MapID \194\183 Zone|r")
        tooltip:AddSeparator(1, 0.85, 0.55, 1)
        for _, hub in ipairs(hubsForRender) do
            local typeSummary = GetHubTypeSummary(hub)
            local summaryStr  = typeSummary ~= "" and (" (" .. typeSummary .. ")") or ""
            local hubDistance = GetHubDistanceCached(hub)
            local distStr     = hubDistance and (" \194\183 " .. hubDistance) or ""
            local hubColor    = GetHubColorByQuestAvailability(hub)
            if hubColor == "" then hubColor = "|cffaaaaaa" end

            local hubTitle   = string.format("%s%s%s%s|r", hubColor, hub.title or "Quest Hub", distStr, summaryStr)
            local hubCoords  = CoordsStr(hub.x, hub.y)
            local hubZoneCol = ZoneCol(hub.mapID, hub.zone)
            local hubLine    = tooltip:AddLine("QuestHub", hubTitle, hubCoords, hubZoneCol)
            tooltip:SetLineScript(hubLine, "OnMouseDown", function(_,_,button)
                if IsShiftKeyDown() and button=="LeftButton" then
                    for _, child in ipairs(hub.children) do AddTomTomWaypoint(child) end
                    AddTomTomWaypoint(hub)
                else
                    AddTomTomWaypoint(hub)
                end
            end)
            if #hub.children == 0 then
                tooltip:AddLine(" ", "|cffaaaaaa(keine zugeordneten Einträge)|r", "", "")
            else
                for _, child in ipairs(hub.children) do
                    local cTitle   = ChildTitleStr(child)
                    local cCoords  = CoordsStr(child.x, child.y)
                    local cZone    = ZoneCol(child.mapID, child.zone)
                    local cl = tooltip:AddLine(" ", cTitle, cCoords, cZone)
                    tooltip:SetLineScript(cl, "OnMouseDown", function(_,_,button)
                        if IsShiftKeyDown() and button=="LeftButton" then AddAllWaypoints(entries) else AddTomTomWaypoint(child) end
                    end)
                end
            end
        end
    end

    RenderPinSection(tooltip, "QuestBlob",  pinCache.QuestBlob)
    RenderPinSection(tooltip, "QuestHub",   pinCache.QuestHub)
    RenderPinSection(tooltip, "QuestOffer", pinCache.QuestOffer)

    -- ===== Ungrouped =====
    if #ungroupedEntries > 0 then
        local uq, up = CountQuestsAndPOIs(ungroupedEntries)
        local uHeader
        if up > 0 then
            uHeader = string.format("Weitere Eintraege (%dQ \194\183 %dPOI)", uq, up)
        else
            uHeader = string.format("Weitere Quests (%d)", uq)
        end
        tooltip:AddLine(" ")
        tooltip:AddHeader(uHeader, "", "", "")
        tooltip:AddLine("Typ", "Titel", "Koords", "MapID \194\183 Zone")
        tooltip:AddSeparator(1,1,1,1)
        for _, e in ipairs(ungroupedEntries) do
            local eTitle  = ChildTitleStr(e, "")
            local eCoords = CoordsStr(e.x, e.y)
            local eZone   = ZoneCol(e.mapID, e.zone)
            local line = tooltip:AddLine(e.type, eTitle, eCoords, eZone)
            tooltip:SetLineScript(line, "OnMouseDown", function(_,_,button)
                if IsShiftKeyDown() and button=="LeftButton" then AddAllWaypoints(entries) else AddTomTomWaypoint(e) end
            end)
        end
    end

    tooltip:AddLine(" ")
    tooltip:AddLine("|cffaaaaaaTipp: Shift+Links-Klick setzt Wegpunkte gesammelt.")
end

-- ===== Tooltip 2: Nachbarzonen =====
local function RenderNeighbors()
    if not tooltip2 then return end
    if not QTip then
        tooltip2:AddLine("(LibQTip-1.0 benoetigt)", 0.7, 0.7, 0.7)
        return
    end
    local ids = SortedNeighborIDs()
    tooltip2:AddHeader("Nachbarzonen dieses Kontinents", "", "", "")
    if #ids == 0 then
        tooltip2:AddLine("|cffaaaaaa(keine gefunden)|r")
        return
    end

    for _, zid in ipairs(ids) do
        local z = neighborZones[zid]
        local zq, zp = CountQuestsAndPOIs(z.entries)
        local zCountStr
        if zp > 0 then
            zCountStr = string.format("|cffffffff%dQ|r  |cffaaaaaa%dPOI|r", zq, zp)
        else
            zCountStr = string.format("|cffffffff%d|r", zq)
        end
        tooltip2:AddLine(" ")
        local zoneHeader = tooltip2:AddLine("|cffffcc00Zone|r", z.name or ("Map "..zid), zCountStr, ZoneCol(zid, z.name))
        tooltip2:SetLineScript(zoneHeader, "OnMouseDown", function(_,_,button)
            if IsShiftKeyDown() and button=="LeftButton" then AddAllWaypoints(z.entries) end
        end)

        if z.hubsTree and #z.hubsTree > 0 then
            tooltip2:AddLine("Hubs", "Titel", "Koords", "MapID \194\183 Zone")
            tooltip2:AddSeparator(1, 0.85, 0.55, 1)
            for _, hub in ipairs(z.hubsTree) do
                local typeSummary = GetHubTypeSummary(hub)
                local summaryStr  = typeSummary ~= "" and (" (" .. typeSummary .. ")") or ""
                local hubDistance = GetHubDistanceCached(hub)
                local distStr     = hubDistance and (" \194\183 " .. hubDistance) or ""
                local hubColor    = GetHubColorByQuestAvailability(hub)
                if hubColor == "" then hubColor = "|cffaaaaaa" end
                local hubTitle   = string.format("%s%s%s%s|r", hubColor, hub.title or "Quest Hub", distStr, summaryStr)
                local hubCoords  = CoordsStr(hub.x, hub.y)
                local hubZoneCol = ZoneCol(hub.mapID, hub.zone)
                local hubLine = tooltip2:AddLine("QuestHub", hubTitle, hubCoords, hubZoneCol)
                tooltip2:SetLineScript(hubLine, "OnMouseDown", function(_,_,button)
                    if IsShiftKeyDown() and button=="LeftButton" then
                        for _, child in ipairs(hub.children) do AddTomTomWaypoint(child) end
                        AddTomTomWaypoint(hub)
                    else
                        AddTomTomWaypoint(hub)
                    end
                end)
                if #hub.children == 0 then
                    tooltip2:AddLine(" ", "|cffaaaaaa(keine zugeordneten Einträge)|r", "", "")
                else
                    for _, child in ipairs(hub.children) do
                        local cTitle  = ChildTitleStr(child)
                        local cCoords = CoordsStr(child.x, child.y)
                        local cZone   = ZoneCol(child.mapID, child.zone)
                        local cl = tooltip2:AddLine(" ", cTitle, cCoords, cZone)
                        tooltip2:SetLineScript(cl, "OnMouseDown", function(_,_,button)
                            if IsShiftKeyDown() and button=="LeftButton" then AddAllWaypoints(z.entries) else AddTomTomWaypoint(child) end
                        end)
                    end
                end
            end
        end

        -- Ungrouped dieser Nachbarzone
        if z.ungrouped and #z.ungrouped > 0 then
            tooltip2:AddLine(" ")
            for _, e in ipairs(z.ungrouped) do
                local eTitle  = ChildTitleStr(e, "  ")
                local eCoords = CoordsStr(e.x, e.y)
                local eZone   = ZoneCol(e.mapID, e.zone)
                local el = tooltip2:AddLine(e.type, eTitle, eCoords, eZone)
                tooltip2:SetLineScript(el, "OnMouseDown", function(_,_,button)
                    if IsShiftKeyDown() and button=="LeftButton" then AddAllWaypoints(z.entries) else AddTomTomWaypoint(e) end
                end)
            end
        end
    end

    tooltip2:AddLine(" ")
    tooltip2:AddLine("|cffaaaaaaTipp: Shift+Links-Klick setzt Wegpunkte gesammelt.")
end


-- Gemeinsame Datensammlung – wird von beiden Show-Funktionen genutzt
local function EnsureDataCurrent()
    CollectData(); SortEntries(); BuildTrees()
end

ShowTooltip1 = function(anchor)
    ReleaseTooltip1()
    EnsureDataCurrent()
    CachePlayerPosForRender()
    AcquireTooltip1(anchor)
    RenderCurrentZone()
    if tooltip then tooltip:Show() end
    ClearPlayerPosCache()
end

ShowTooltip2 = function(anchor)
    ReleaseTooltip2()
    EnsureDataCurrent()
    CachePlayerPosForRender()
    AcquireTooltip2(anchor)
    RenderNeighbors()
    if tooltip2 then tooltip2:Show() end
    ClearPlayerPosCache()
end

local function UpdateText()
    local _, zone = GetPlayerMap()
    -- Broker 1: aktuelle Zone
    local quests, pois = CountQuestsAndPOIs(entries)
    if broker then
        if pois > 0 then
            broker.text = string.format("%s: %dQ · %dPOI", zone or "Zone", quests, pois)
        else
            broker.text = string.format("%s: %d", zone or "Zone", quests)
        end
    end
    -- Broker 2: Nachbarzonen-Übersicht
    if broker2 then
        local zoneCount = 0
        local totalQ, totalP = 0, 0
        for _, z in pairs(neighborZones) do
            zoneCount = zoneCount + 1
            local zq, zp = CountQuestsAndPOIs(z.entries)
            totalQ = totalQ + zq
            totalP = totalP + zp
        end
        if zoneCount == 0 then
            broker2.text = "Kontinent: –"
        elseif totalP > 0 then
            broker2.text = string.format("Kontinent: %dZ · %dQ · %dPOI", zoneCount, totalQ, totalP)
        else
            broker2.text = string.format("Kontinent: %dZ · %dQ", zoneCount, totalQ)
        end
    end
end

-- ===== Broker Handlers =====
if broker then
    function broker:OnEnter() ShowTooltip1(self) end
    function broker:OnLeave() end  -- AutoHideDelay übernimmt das Schließen
    function broker:OnClick(button)
        if button == "LeftButton" then
            if IsShiftKeyDown() then
                AddAllWaypoints(entries)
            else
                EnsureDataCurrent(); UpdateText()
                DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[QuestZoneBroker]|r Daten aktualisiert.")
                if tooltip and QTip and tooltip:IsShown() then ShowTooltip1(broker) end
            end
        end
    end
end

if broker2 then
    function broker2:OnEnter() ShowTooltip2(self) end
    function broker2:OnLeave() end  -- AutoHideDelay übernimmt das Schließen
    function broker2:OnClick(button)
        if button == "LeftButton" then
            if IsShiftKeyDown() then
                -- Alle Wegpunkte aller Nachbarzonen
                for _, z in pairs(neighborZones) do AddAllWaypoints(z.entries) end
            else
                EnsureDataCurrent(); UpdateText()
                DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[QuestZoneBroker]|r Daten aktualisiert.")
                if tooltip2 and QTip and tooltip2:IsShown() then ShowTooltip2(broker2) end
            end
        end
    end
end

-- ===== Events =====
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("QUEST_LOG_UPDATE")

local pendingUpdate = false
local function ScheduleUpdate()
    if pendingUpdate then return end
    pendingUpdate = true
    C_Timer.After(1.5, function()
        pendingUpdate = false
        EnsureDataCurrent(); UpdateText()
        RefreshIfShown()
    end)
end

local function OnEventImmediate()
    EnsureDataCurrent(); UpdateText()
    RefreshIfShown()
end

f:SetScript("OnEvent", function(_, event)
    if event == "QUEST_LOG_UPDATE" then
        ScheduleUpdate()   -- debounced: max. 1× alle 1,5 Sek.
    else
        OnEventImmediate() -- PLAYER_ENTERING_WORLD / ZONE_CHANGED sofort
    end
end)

C_Timer.After(2, function() EnsureDataCurrent(); UpdateText() end)

-- ===== Debug-Slash-Command =====
-- /qzb debug  → listet alle Einträge pro Zone mit QuestID in den Chat
-- /qzb xzone  → zeigt Quests die in mehreren Zonen vorkommen
SLASH_QUESTZONEBROKER1 = "/qzb"
SlashCmdList["QUESTZONEBROKER"] = function(msg)
    local cmd = msg and msg:lower():match("^(%S+)") or ""

    if cmd == "debug" then
        local function dumpList(label, list)
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffddaa00[QZB]|r %s (%d Einträge):", label, #list))
            for _, e in ipairs(list) do
                local idStr
                if e.questID then
                    idStr = "qid=" .. tostring(e.questID)
                elseif e.poiID then
                    idStr = "poiID=" .. tostring(e.poiID)
                else
                    idStr = "–"
                end
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "  |cffaaaaaa%s|r %s [%s] mapID=%s %s",
                    e.type or "?",
                    e.title or "?",
                    e.zone or "?",
                    tostring(e.mapID or "?"),
                    idStr
                ))
            end
        end
        EnsureDataCurrent()
        dumpList("Aktuelle Zone: "..(currentZoneName or "?"), entries)
        for zid, z in pairs(neighborZones) do
            dumpList("Nachbar: "..(z.name or tostring(zid)), z.entries or {})
        end

    elseif cmd == "xzone" then
        -- Zeige Quests die in mehr als einer Zone auftauchen
        EnsureDataCurrent()
        local seen = {}  -- questID → {zone1, zone2, ...}
        local function scan(list)
            for _, e in ipairs(list) do
                if e.questID then
                    seen[e.questID] = seen[e.questID] or {}
                    table.insert(seen[e.questID], e.zone or "?")
                end
            end
        end
        scan(entries)
        for _, z in pairs(neighborZones) do scan(z.entries or {}) end
        local found = false
        for qid, zones in pairs(seen) do
            if #zones > 1 then
                found = true
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cffff6666[QZB Duplikat]|r qid=%d \"%s\" in: %s",
                    qid, SafeGetQuestTitle(qid), table.concat(zones, ", ")
                ))
            end
        end
        if not found then
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[QZB]|r Keine zonenübergreifenden Duplikate gefunden.")
        end

    elseif cmd == "hubs" then
        -- Zeigt für jeden Hub seine Position und alle Einträge mit Distanz + ob sie zugeordnet werden.
        -- Syntax: /qzb hubs [Zonenname-Fragment]
        local filter = msg and msg:match("^%S+%s+(.+)$")
        EnsureDataCurrent()

        local function analyzeList(label, list)
            local hubs, hubCountByMap = {}, {}
            for _, e in ipairs(list) do
                if e.type == "QuestHub" then
                    local hx, hy = e.x, e.y
                    if (not hx or not hy) and e.poiID and C_AreaPoiInfo and C_AreaPoiInfo.GetAreaPOIPosition then
                        local pos = C_AreaPoiInfo.GetAreaPOIPosition(e.mapID, e.poiID)
                        if pos then
                            if pos.GetXY then hx, hy = pos:GetXY() else hx, hy = pos.x, pos.y end
                        end
                    end
                    table.insert(hubs, {title=e.title, mapID=e.mapID, poiID=e.poiID, x=hx, y=hy})
                    hubCountByMap[e.mapID] = (hubCountByMap[e.mapID] or 0) + 1
                end
            end
            if #hubs == 0 then return end
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffddaa00[QZB Hubs]|r %s", label))

            for _, hub in ipairs(hubs) do
                local hubsOnMap = hubCountByMap[hub.mapID] or 0
                if hub.x and hub.y then
                    DEFAULT_CHAT_FRAME:AddMessage(string.format(
                        "  |cffffcc00HUB|r \"%s\" poiID=%s mapID=%s @ %.4f/%.4f  (max dist2=%.6f)",
                        hub.title or "?", tostring(hub.poiID or "?"), tostring(hub.mapID or "?"),
                        hub.x*100, hub.y*100, HUB_RANGE*HUB_RANGE))
                else
                    local fbInfo = hubsOnMap == 1
                        and "|cff1eff00Fallback aktiv: koordinatenlose Eintrage werden zugeordnet|r"
                        or  string.format("|cffff6666Fallback INAKTIV: %d Hubs auf mapID=%s|r", hubsOnMap, tostring(hub.mapID))
                    DEFAULT_CHAT_FRAME:AddMessage(string.format(
                        "  |cffff6666HUB|r \"%s\" poiID=%s mapID=%s KEINE KOORDS  %s",
                        hub.title or "?", tostring(hub.poiID or "?"), tostring(hub.mapID or "?"), fbInfo))
                end

                for _, e in ipairs(list) do
                    if e.type ~= "QuestHub" then
                        local sameMap = (e.mapID == hub.mapID)
                        if e.x and e.y and hub.x and hub.y and sameMap then
                            local dx, dy = e.x-hub.x, e.y-hub.y
                            local d2 = dx*dx + dy*dy
                            local ok = d2 <= (HUB_RANGE*HUB_RANGE)
                            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                                "    %s%s|r \"%s\" @ %.4f/%.4f dist2=%.6f %s",
                                ok and "|cff1eff00" or "|cffff6666", e.type, e.title or "?",
                                e.x*100, e.y*100, d2, ok and "ZUGEORDNET" or "zu weit"))
                        elseif sameMap and not (e.x and e.y) then
                            local fa = (hubsOnMap == 1)
                            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                                "    %s%s|r \"%s\" keine Koords  %s",
                                fa and "|cff1eff00" or "|cffaaaaaa", e.type, e.title or "?",
                                fa and "FALLBACK-ZUORDNUNG" or "mehrere Hubs, bleibt ungrouped"))
                        elseif not sameMap then
                            DEFAULT_CHAT_FRAME:AddMessage(string.format(
                                "    |cffaaaaaa%s|r \"%s\" mapID=%s~=hub.mapID=%s (andere Map)",
                                e.type, e.title or "?", tostring(e.mapID), tostring(hub.mapID)))
                        end
                    end
                end
            end
        end

        -- Aktuelle Zone + optionaler Filter
        if not filter or currentZoneName:lower():find(filter:lower(), 1, true) then
            analyzeList("Aktuelle Zone: " .. (currentZoneName or "?"), entries)
        end
        for _, z in pairs(neighborZones) do
            if not filter or (z.name or ""):lower():find(filter:lower(), 1, true) then
                analyzeList("Nachbar: " .. (z.name or "?"), z.entries or {})
            end
        end

    else
        DEFAULT_CHAT_FRAME:AddMessage("|cffddaa00[QZB]|r Befehle:")
        DEFAULT_CHAT_FRAME:AddMessage("  /qzb debug   – alle Einträge pro Zone")
        DEFAULT_CHAT_FRAME:AddMessage("  /qzb xzone   – zonenübergreifende Duplikate")
        DEFAULT_CHAT_FRAME:AddMessage("  /qzb hubs [Filter]  – Hub-Koordinaten und Distanzen zu allen Einträgen")
    end
end
