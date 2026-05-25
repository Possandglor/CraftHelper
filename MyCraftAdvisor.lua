-- ==========================================
-- 1. ИНИЦИАЛИЗАЦИЯ И ДВИЖОК ДАННЫХ
-- ==========================================
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("TRADE_SKILL_SHOW")

local priceCache = {}
MyDynamicCraftDB = MyDynamicCraftDB or {}
MyDynamicVendorDB = MyDynamicVendorDB or {}

local function SafeGetItemInfo(itemId)
    if not itemId then return nil end
    local name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture = GetItemInfo(itemId)
    if not name then
        if not MCAScanTooltip then CreateFrame("GameTooltip", "MCAScanTooltip", nil, "GameTooltipTemplate") end
        MCAScanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
        MCAScanTooltip:SetHyperlink("item:"..itemId)
        name, link, quality, iLevel, reqLevel, class, subclass, maxStack, equipSlot, texture = GetItemInfo(itemId)
    end
    return name, link, texture
end

local function DynamicScanRecipes()
    local profName = GetTradeSkillLine()
    if not profName or profName == "Unknown" then return end
    
    local idx = 1
    while idx <= GetNumTradeSkills() do
        local name, type, _, isExpanded = GetTradeSkillInfo(idx)
        if type == "header" and not isExpanded then
            ExpandTradeSkillSubClass(idx)
        end
        idx = idx + 1
    end
    
    local scanned = 0
    for i = 1, GetNumTradeSkills() do
        local name, type = GetTradeSkillInfo(i)
        if type ~= "header" and name then
            local link = GetTradeSkillItemLink(i)
            if not link and Skillet and Skillet.GetRecipeResultLink then
                link = Skillet:GetRecipeResultLink(i)
            end
            
            local targetItemId = link and tonumber(string.match(link, "item:(%d+)"))
            if targetItemId then
                local minMade, maxMade = GetTradeSkillNumMade(i)
                local yield = (minMade and maxMade) and ((minMade + maxMade) / 2) or 1
                if yield == 0 then yield = 1 end
                
                MyDynamicCraftDB[targetItemId] = { profession = profName, yield = yield, reagents = {} }
                
                for r = 1, GetTradeSkillNumReagents(i) do
                    local rName, _, rCount = GetTradeSkillReagentInfo(i, r)
                    local rLink = GetTradeSkillReagentItemLink(i, r)
                    local rId = rLink and tonumber(string.match(rLink, "item:(%d+)"))
                    if not rId and rName then
                        local _, fallbackLink = GetItemInfo(rName)
                        if fallbackLink then rId = tonumber(string.match(fallbackLink, "item:(%d+)")) end
                    end
                    if rId and rCount then 
                        MyDynamicCraftDB[targetItemId].reagents[rId] = rCount 
                        SafeGetItemInfo(rId)
                    end
                end
                scanned = scanned + 1
            end
        end
    end
    if scanned > 0 then
        print("|cff00ff00[MCA]:|r База обновлена ["..profName.."]: " .. scanned)
    end
end

local function GetItemBasePrice(itemId)
    if MyDynamicVendorDB[itemId] then return MyDynamicVendorDB[itemId], "Vendor" end
    local ahPrice = 0
    local name = SafeGetItemInfo(itemId)
    if Auctionator and Auctionator.API and Auctionator.API.GetAuctionPriceByItemID then
        ahPrice = Auctionator.API.GetAuctionPriceByItemID(itemId) or 0
    elseif Atr_GetAuctionPrice then
        ahPrice = Atr_GetAuctionPrice(name or "") or 0
    end
    return ahPrice, "AH"
end

local function CalculateMinCost(itemId)
    if priceCache[itemId] then return priceCache[itemId].cost, priceCache[itemId].method end

    local ahPrice, method = GetItemBasePrice(itemId)
    local recipe = MyDynamicCraftDB[itemId]

    if not recipe then
        priceCache[itemId] = { cost = ahPrice, method = method }
        return ahPrice, method
    end

    local totalCraftCost = 0
    for reagentId, count in pairs(recipe.reagents) do
        local rCost = CalculateMinCost(reagentId)
        totalCraftCost = totalCraftCost + (rCost * count)
    end
    local finalCraftCost = totalCraftCost / recipe.yield

    if ahPrice > 0 and ahPrice < finalCraftCost then
        priceCache[itemId] = { cost = ahPrice, method = "AH" }
        return ahPrice, "AH"
    else
        priceCache[itemId] = { cost = finalCraftCost, method = "Craft" }
        return finalCraftCost, "Craft"
    end
end

local function FormatMoney(money)
    if not money or money <= 0 then return "0г" end
    local gold = math.floor(money / 10000)
    local silver = math.floor((money % 10000) / 100)
    local copper = math.floor(money % 100)
    if gold > 0 then return string.format("%dг %dс", gold, silver) end
    if silver > 0 then return string.format("%dс %dм", silver, copper) end
    return string.format("%dм", copper)
end

-- ==========================================
-- 2. ГРАФИЧЕСКИЙ ИНТЕРФЕЙС И КОНТРОЛЛЫ
-- ==========================================
MCA_GUI = CreateFrame("Frame", "MyCraftAdvisorFrame", UIParent)
MCA_GUI:SetSize(820, 600)
MCA_GUI:SetPoint("CENTER", UIParent, "CENTER")
MCA_GUI:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    texturing = true, tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 }
})
MCA_GUI:SetBackdropColor(0.03, 0.03, 0.03, 0.98)
MCA_GUI:SetMovable(true)
MCA_GUI:EnableMouse(true)
MCA_GUI:RegisterForDrag("LeftButton")
MCA_GUI:SetScript("OnDragStart", MCA_GUI.StartMoving)
MCA_GUI:SetScript("OnDragStop", MCA_GUI.StopMovingOrSizing)
MCA_GUI:Hide()

-- КНОПКА ЗАКРЫТИЯ ОКНА
local closeBtn = CreateFrame("Button", nil, MCA_GUI, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", MCA_GUI, "TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function() MCA_GUI:Hide() end)

local headerText = MCA_GUI:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
headerText:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", 20, -18)

local backBtn = CreateFrame("Button", nil, MCA_GUI, "UIPanelButtonTemplate")
backBtn:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", 20, -42)
backBtn:SetSize(80, 22)
backBtn:SetText("← Назад")
backBtn:Hide()

local scrollFrame = CreateFrame("ScrollFrame", "MCAScrollFrame", MCA_GUI, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", 20, -110)
scrollFrame:SetPoint("BOTTOMRIGHT", MCA_GUI, "BOTTOMRIGHT", -30, 20)

local contentFrame = CreateFrame("Frame", nil, scrollFrame)
contentFrame:SetSize(2000, 2000)
scrollFrame:SetScrollChild(contentFrame)

local rowPool, nodePool, linePool, tabPool = {}, {}, {}, {}
local currentViewMode = "none"
local currentSelectedProf = ""

local function ResetUI()
    for _, r in ipairs(rowPool) do r:Hide() end
    for _, n in ipairs(nodePool) do n:Hide() end
    for _, l in ipairs(linePool) do l:Hide() end
end

local function HideTabs()
    for _, t in ipairs(tabPool) do t:Hide() end
end

local function HandleItemInteraction(itemLink)
    if IsShiftKeyDown() then
        local name = GetItemInfo(itemLink) or string.match(itemLink, "%[(.-)%]")
        if Atr_Search_Box and Atr_Search_Box:IsVisible() then
            Atr_Search_Box:SetText(name)
            Atr_Search_Box:HighlightText()
            if Atr_Search_Button then Atr_Search_Button:Click() end
        elseif AuctionatorSearchBox and AuctionatorSearchBox:IsVisible() then
            AuctionatorSearchBox:SetText(name)
        else
            local chat = ChatEdit_GetActiveWindow()
            if chat then chat:Insert(itemLink) end
        end
    else
        local id = tonumber(string.match(itemLink, "item:(%d+)"))
        if id then MCA_GUI:DrawNodeGraph(id, true) end
    end
end

-- ==========================================
-- 3. КОМПОНЕНТЫ СПИСКА И ВКЛАДОК
-- ==========================================
local function GetRow(index)
    if rowPool[index] then return rowPool[index] end
    local r = CreateFrame("Button", nil, contentFrame)
    r:SetSize(740, 26)
    
    r.icon = r:CreateTexture(nil, "BACKGROUND")
    r.icon:SetSize(20, 20)
    r.icon:SetPoint("LEFT", r, "LEFT", 5, 0)
    
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.text:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
    
    r.profit = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.profit:SetPoint("RIGHT", r, "RIGHT", -15, 0)
    
    r:SetScript("OnEnter", function(self)
        if self.itemLink then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.itemLink); GameTooltip:Show() end
    end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    r:SetScript("OnClick", function(self) if self.itemLink then HandleItemInteraction(self.itemLink) end end)
    
    rowPool[index] = r
    return r
end

local function GetTab(index)
    if tabPool[index] then return tabPool[index] end
    local t = CreateFrame("Button", nil, MCA_GUI, "UIPanelButtonTemplate")
    t:SetSize(125, 24)
    tabPool[index] = t
    return t
end

function MCA_GUI:RenderProfessionList(profName)
    ResetUI()
    currentViewMode = "scan_all"
    currentSelectedProf = profName
    backBtn:Hide()
    headerText:SetText("Рецепты по профессиям (Сортировка по чистой прибыли)")

    local list = {}
    for itemId, data in pairs(MyDynamicCraftDB) do
        if data.profession == profName then
            priceCache = {}
            local cost = CalculateMinCost(itemId)
            local ah = GetItemBasePrice(itemId)
            local profit = ah - cost
            table.insert(list, { id = itemId, cost = cost, ah = ah, profit = profit })
        end
    end
    table.sort(list, function(a, b) return a.profit > b.profit end)

    local yOffset = 10
    for i, item in ipairs(list) do
        local row = GetRow(i)
        local name, link, tex = SafeGetItemInfo(item.id)
        link = link or name or ("ID: " .. item.id)
        
        row.itemLink = link
        row.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        
        local pColor = item.profit > 0 and "|cff00ff00+" or "|cffff0000"
        row.text:SetText(link .. " |cff888888(Себест: " .. FormatMoney(item.cost) .. " | АХ: " .. FormatMoney(item.ah) .. ")|r")
        row.profit:SetText("Профит: " .. pColor .. FormatMoney(item.profit) .. "|r")
        
        row:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 5, -yOffset)
        row:Show()
        yOffset = yOffset + 30
    end
    contentFrame:SetSize(740, yOffset + 50)
end

function MCA_GUI:ShowAllProfessions()
    HideTabs()
    local profs = {}
    for _, data in pairs(MyDynamicCraftDB) do
        if data.profession then profs[data.profession] = true end
    end
    
    local sortedProfs = {}
    for p in pairs(profs) do table.insert(sortedProfs, p) end
    table.sort(sortedProfs)
    
    if #sortedProfs == 0 then
        headerText:SetText("База рецептов пуста. Откройте окно профессий для сканирования.")
        ResetUI()
        return
    end

    local xOffset = 20
    for i, prof in ipairs(sortedProfs) do
        local tab = GetTab(i)
        tab:SetText(prof)
        tab:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", xOffset, -72)
        tab:SetScript("OnClick", function() MCA_GUI:RenderProfessionList(prof) end)
        tab:Show()
        xOffset = xOffset + 130
    end
    
    if currentSelectedProf == "" or not profs[currentSelectedProf] then
        currentSelectedProf = sortedProfs[1]
    end
    MCA_GUI:RenderProfessionList(currentSelectedProf)
end

-- ==========================================
-- 4. ГРАФИЧЕСКИЙ ДВИЖОК НОД
-- ==========================================
local function GetNode(index)
    if nodePool[index] then return nodePool[index] end
    local n = CreateFrame("Button", nil, contentFrame)
    n:SetSize(36, 36)
    
    n.icon = n:CreateTexture(nil, "BORDER")
    n.icon:SetAllPoints()
    
    n.bg = n:CreateTexture(nil, "BACKGROUND")
    n.bg:SetSize(42, 42)
    n.bg:SetPoint("CENTER")
    n.bg:SetTexture("Interface\\Buttons\\UI-Quickslot")
    
    n.prices = n:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    n.prices:SetPoint("BOTTOM", n, "TOP", 0, 4)
    n.prices:SetJustifyH("CENTER")
    
    n:SetScript("OnEnter", function(self)
        if self.itemLink then GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetHyperlink(self.itemLink); GameTooltip:Show() end
    end)
    n:SetScript("OnLeave", function() GameTooltip:Hide() end)
    n:SetScript("OnClick", function(self) if self.itemLink then HandleItemInteraction(self.itemLink) end end)
    
    nodePool[index] = n
    return n
end

local function GetLine(index)
    if linePool[index] then return linePool[index] end
    local l = contentFrame:CreateTexture(nil, "BACKGROUND")
    l:SetTexture(0.5, 0.5, 0.5, 0.7)
    linePool[index] = l
    return l
end

local lineIdx = 1
local function DrawStepLine(x1, y1, x2, y2)
    local midX = x1 + (x2 - x1) / 2
    
    -- 1. Первое плечо (горизонтальное)
    local l1 = GetLine(lineIdx); lineIdx = lineIdx + 1
    l1:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", x1, y1)
    l1:SetSize(midX - x1, 2)
    l1:Show()
    
    -- 2. Вертикальная стойка перехода (с учетом инверсии осей в WoW)
    local l2 = GetLine(lineIdx); lineIdx = lineIdx + 1
    local topY = math.max(y1, y2) -- В отрицательных координатах большее число находится выше на экране
    local botY = math.min(y1, y2)
    l2:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", midX, topY)
    l2:SetSize(2, topY - botY)
    l2:Show()
    
    -- 3. Второе плечо (горизонтальное к дочерней ноде)
    local l3 = GetLine(lineIdx); lineIdx = lineIdx + 1
    l3:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", midX, y2)
    l3:SetSize(x2 - midX, 2)
    l3:Show()
end

function MCA_GUI:DrawNodeGraph(rootItemId, fromScan)
    ResetUI()
    HideTabs() -- Скрываем вкладки проф, чтобы освободить место под ноды
    
    if fromScan then currentViewMode = "graph"; backBtn:Show() end
    
    local _, rootLink = SafeGetItemInfo(rootItemId)
    headerText:SetText("Граф связей крафта: " .. (rootLink or ("ID: " .. rootItemId)))
    
    priceCache = {}
    
    -- Рекурсивное построение ПОЛНОГО дерева без обрывов цепочки
    local function BuildNode(itemId, depth)
        local nData = { id = itemId, depth = depth, children = {} }
        local recipe = MyDynamicCraftDB[itemId]
        local cost, method = CalculateMinCost(itemId)
        
        nData.cost = cost
        nData.method = method
        nData.ah = GetItemBasePrice(itemId)
        
        -- Вытаскиваем реагенты всегда, если они известны аддону
        if recipe and recipe.reagents then
            for rId, _ in pairs(recipe.reagents) do
                table.insert(nData.children, BuildNode(rId, depth + 1))
            end
        end
        return nData
    end
    
    local treeRoot = BuildNode(rootItemId, 0)
    
    -- Расчет геометрии дерева (X и Y)
    local currentY = -60 -- Стартовый отступ сверху, чтобы верхние ценники не резались
    local function LayoutY(node)
        if #node.children == 0 then
            node.y = currentY
            currentY = currentY - 85 -- Вертикальный шаг увеличен до 85px для свободного размещения цен
        else
            for _, child in ipairs(node.children) do LayoutY(child) end
            node.y = (node.children[1].y + node.children[#node.children].y) / 2
        end
        node.x = 30 + (node.depth * 185) -- Горизонтальный шаг
    end
    LayoutY(treeRoot)
    
    -- Отрисовка
    local nodeIdx = 1
    lineIdx = 1
    
    local function RenderNode(node, parentNode)
        local uiNode = GetNode(nodeIdx); nodeIdx = nodeIdx + 1
        local name, link, tex = SafeGetItemInfo(node.id)
        
        uiNode.itemLink = link or name or ("ID: " .. node.id)
        uiNode.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        uiNode:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", node.x, node.y)
        uiNode:Show()
        
        -- Подсветка рамки в зависимости от оптимального выбора
        if node.method == "Craft" then uiNode.bg:SetVertexColor(1, 0.6, 0)
        elseif node.method == "Vendor" then uiNode.bg:SetVertexColor(0, 1, 1)
        else uiNode.bg:SetVertexColor(0, 1, 0) end
        
        -- Форматирование ценника над иконкой
        local vPrice = MyDynamicVendorDB[node.id] and FormatMoney(MyDynamicVendorDB[node.id]) or "—"
        local pStr = string.format("|cff00ff00АХ: %s|r\n|cff00ffffВенд: %s|r\n|cffffaa00Крафт: %s|r", 
            node.ah > 0 and FormatMoney(node.ah) or "—", vPrice, FormatMoney(node.cost))
        uiNode.prices:SetText(pStr)
        
        -- Отрисовка линка от родителя
        if parentNode then
            DrawStepLine(parentNode.x + 36, parentNode.y - 18, node.x, node.y - 18)
        end
        
        for _, child in ipairs(node.children) do
            RenderNode(child, node)
        end
    end
    
    RenderNode(treeRoot, nil)
    contentFrame:SetSize(treeRoot.x + 400, math.abs(currentY) + 100)
    MCA_GUI:Show() -- Гарантируем видимость фрейма
end

backBtn:SetScript("OnClick", function()
    if currentViewMode == "graph" then
        ResetUI()
        MCA_GUI:ShowAllProfessions()
    end
end)

local function OnClickAnalyze()
    local targetId
    if Skillet and Skillet.GetSelectedRecipe then
        local recipeId = Skillet:GetSelectedRecipe()
        if recipeId then
            local link = Skillet:GetRecipeResultLink(recipeId)
            if link then targetId = tonumber(string.match(link, "item:(%d+)")) end
        end
    end
    if not targetId and GetTradeSkillSelectionIndex() > 0 then
        local link = GetTradeSkillItemLink(GetTradeSkillSelectionIndex())
        if link then targetId = tonumber(string.match(link, "item:(%d+)")) end
    end
    
    if targetId then
        MCA_GUI:Show()
        MCA_GUI:DrawNodeGraph(targetId, true)
    else
        print("|cffff0000[MCA]: Выберите конкретный рецепт для построения графа.|r")
    end
end

local function InjectAnalyzeButton()
    if Skillet and SkilletFrame then
        if not MyCraftButtonSkillet then
            MyCraftButtonSkillet = CreateFrame("Button", "MyCraftAdvisorSkilletButton", SkilletFrame, "UIPanelButtonTemplate")
            MyCraftButtonSkillet:SetPoint("BOTTOMRIGHT", SkilletFrame, "BOTTOMRIGHT", -220, 42)
            MyCraftButtonSkillet:SetSize(90, 22)
            MyCraftButtonSkillet:SetText("MCA Анализ")
            MyCraftButtonSkillet:SetFrameStrata("HIGH") 
            MyCraftButtonSkillet:SetScript("OnClick", OnClickAnalyze)
        end
    elseif TradeSkillFrame then
        if not MyCraftButton then
            MyCraftButton = CreateFrame("Button", "MyCraftAdvisorButton", TradeSkillFrame, "UIPanelButtonTemplate")
            MyCraftButton:SetPoint("TOPRIGHT", TradeSkillFrame, "TOPRIGHT", -70, -45)
            MyCraftButton:SetSize(100, 22)
            MyCraftButton:SetText("Анализ")
            MyCraftButton:SetScript("OnClick", OnClickAnalyze)
        end
    end
end

-- ==========================================
-- 5. ТУЛТИПЫ И СЛЭШ-КОМАНДЫ
-- ==========================================
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" and ... == "MyCraftAdvisor" then
        print("|cff00ff00[MyCraftAdvisor]:|r Готов к работе. Команда: /mca")
    elseif event == "MERCHANT_SHOW" then
        for i = 1, GetMerchantNumItems() do
            local _, _, price, stack, _, _, ext = GetMerchantItemInfo(i)
            local link = GetMerchantItemLink(i)
            if link and price > 0 and not ext then
                local id = tonumber(string.match(link, "item:(%d+)"))
                if id then MyDynamicVendorDB[id] = price / stack end
            end
        end
    elseif event == "TRADE_SKILL_SHOW" then
        local tFrame = CreateFrame("Frame")
        tFrame:SetScript("OnUpdate", function(self, elapsed)
            self.time = (self.time or 0) + elapsed
            if self.time > 0.3 then DynamicScanRecipes(); InjectAnalyzeButton(); self:SetScript("OnUpdate", nil) end
        end)
    end
end)

GameTooltip:HookScript("OnTooltipSetItem", function(self)
    local _, link = self:GetItem()
    local itemId = link and tonumber(string.match(link, "item:(%d+)"))
    if not itemId then return end
    
    if MyDynamicCraftDB[itemId] then
        priceCache = {}
        local cost = CalculateMinCost(itemId)
        local ah = GetItemBasePrice(itemId)
        self:AddLine(" ")
        self:AddLine("|cff00ff00[MCA] Расчет производства:|r")
        self:AddDoubleLine("|cffaaaaaaСебестоимость:|r", FormatMoney(cost))
        if ah > 0 then
            local diff = ah - cost
            local col = diff > 0 and "|cff00ff00" or "|cffff0000"
            self:AddDoubleLine(col .."Чистый профит:|r", col .. FormatMoney(diff) .. "|r")
        end
    end
end)

SLASH_MYCRAFT1 = "/mca"
SlashCmdList["MYCRAFT"] = function(msg)
    msg = msg:trim()
    if msg == "" or msg == "all" then
        ResetUI()
        MCA_GUI:ShowAllProfessions()
        MCA_GUI:Show()
    else
        local itemId = tonumber(string.match(msg, "item:(%d+)"))
        if not itemId then
            local _, link = GetItemInfo(msg)
            if link then itemId = tonumber(string.match(link, "item:(%d+)")) end
        end
        if itemId then 
            MCA_GUI:DrawNodeGraph(itemId, true)
        else 
            print("[MCA] Команды: /mca (открыть списки проф) или /mca [Линк Предмета]") 
        end
    end
end