-- ==========================================
-- 1. ИНИЦИАЛИЗАЦИЯ И БАЗЫ ДАННЫХ
-- ==========================================
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("TRADE_SKILL_SHOW")

local priceCache = {}
local craftingSteps = {}

MyDynamicCraftDB = MyDynamicCraftDB or {}
MyDynamicVendorDB = MyDynamicVendorDB or {}

-- Функция безопасного получения данных (запрашивает сервер, если шмотка не прогрузилась)
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

-- Новый бронебойный сканер по ID (не зависит от прогрузки ссылок и свернутых категорий)
local function DynamicScanRecipes()
    local profName = GetTradeSkillLine()
    if not profName or profName == "Unknown" then return end
    
    -- ПРИНУДИТЕЛЬНО раскрываем все категории, иначе GetNumTradeSkills() не увидит скрытые рецепты
    local idx = 1
    while idx <= GetNumTradeSkills() do
        local name, type, _, isExpanded = GetTradeSkillInfo(idx)
        if type == "header" and not isExpanded then
            ExpandTradeSkillSubClass(idx)
        end
        idx = idx + 1
    end
    
    local scanned = 0
    local numRecipes = GetNumTradeSkills()
    
    for i = 1, numRecipes do
        local name, type = GetTradeSkillInfo(i)
        if type ~= "header" and name then
            local link = GetTradeSkillItemLink(i)
            if not link and Skillet and Skillet.GetRecipeResultLink then
                link = Skillet:GetRecipeResultLink(i)
            end
            
            local targetItemId = link and tonumber(string.match(link, "item:(%d+)"))
            
            if not targetItemId and Skillet and Skillet.db and Skillet.db.realm and Skillet.db.realm.recipes then
                for id, data in pairs(Skillet.db.realm.recipes) do
                    if data.name == name then
                        local rLink = Skillet:GetRecipeResultLink(id)
                        if rLink then targetItemId = tonumber(string.match(rLink, "item:(%d+)")) end
                        break
                    end
                end
            end
            
            if targetItemId then
                local minMade, maxMade = GetTradeSkillNumMade(i)
                local yield = (minMade and maxMade) and ((minMade + maxMade) / 2) or 1
                if yield == 0 then yield = 1 end
                
                MyDynamicCraftDB[targetItemId] = {
                    profession = profName,
                    yield = yield,
                    reagents = {}
                }
                
                local numReagents = GetTradeSkillNumReagents(i)
                for r = 1, numReagents do
                    local rName, rTexture, rCount = GetTradeSkillReagentInfo(i, r)
                    local rLink = GetTradeSkillReagentItemLink(i, r)
                    local rId
                    
                    if rLink then
                        rId = tonumber(string.match(rLink, "item:(%d+)"))
                    elseif rName then
                        -- Хак для рецептов с кулдауном (Колдовская ткань), где rLink часто возвращает nil
                        local _, fallbackLink = GetItemInfo(rName)
                        if fallbackLink then
                            rId = tonumber(string.match(fallbackLink, "item:(%d+)"))
                        end
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
        print("|cff00ff00[MyCraftAdvisor]:|r База синхронизирована. Успешно обработано рецептов: " .. scanned)
    end
end

local function OnClickAnalyze()
    if Skillet and Skillet.GetSelectedRecipe then
        local recipeId = Skillet:GetSelectedRecipe()
        if recipeId then
            local link = Skillet:GetRecipeResultLink(recipeId)
            if link then
                local itemId = tonumber(string.match(link, "item:(%d+)"))
                if itemId then MCA_GUI:ShowReport(itemId) return end
            end
        end
    end
    local selectionIndex = GetTradeSkillSelectionIndex()
    if selectionIndex > 0 then
        local link = GetTradeSkillItemLink(selectionIndex)
        if link then
            local itemId = tonumber(string.match(link, "item:(%d+)"))
            if itemId then MCA_GUI:ShowReport(itemId) end
        end
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

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "MyCraftAdvisor" then
            print("|cff00ff00[MyCraftAdvisor]:|r Загружен. Откройте окно профессий.")
        end
    elseif event == "MERCHANT_SHOW" then
        local numItems = GetMerchantNumItems()
        for i = 1, numItems do
            local _, _, price, stackCount, _, _, extendedCost = GetMerchantItemInfo(i)
            local link = GetMerchantItemLink(i)
            if link and price > 0 and not extendedCost then
                local itemId = tonumber(string.match(link, "item:(%d+)"))
                if itemId then MyDynamicVendorDB[itemId] = price / stackCount end
            end
        end
    elseif event == "TRADE_SKILL_SHOW" then
        local tFrame = CreateFrame("Frame")
        tFrame:SetScript("OnUpdate", function(self, elapsed)
            self.time = (self.time or 0) + elapsed
            if self.time > 0.3 then
                DynamicScanRecipes()
                InjectAnalyzeButton()
                self:SetScript("OnUpdate", nil)
            end
        end)
    end
end)

-- ==========================================
-- 2. РАСЧЕТНЫЙ ДВИЖОК
-- ==========================================
local function GetItemBasePrice(itemId)
    if MyDynamicVendorDB[itemId] then return MyDynamicVendorDB[itemId], "Vendor" end
    local ahPrice = 0
    local name = SafeGetItemInfo(itemId)
    
    -- Оптимизация для Auctionator: поиск по ID надежнее, если имя еще не закэшировано
    if Auctionator and Auctionator.API and Auctionator.API.GetAuctionPriceByItemID then
        ahPrice = Auctionator.API.GetAuctionPriceByItemID(itemId) or 0
    elseif Atr_GetAuctionPrice then
        ahPrice = Atr_GetAuctionPrice(name or "") or 0
    end
    return ahPrice, "AH"
end

function CalculateMinCostAdvanced(itemId, depth)
    depth = depth or 0
    if priceCache[itemId] then return priceCache[itemId].cost, priceCache[itemId].method end

    local ahPrice, method = GetItemBasePrice(itemId)
    local recipe = MyDynamicCraftDB[itemId]

    if not recipe then
        table.insert(craftingSteps, { itemId = itemId, depth = depth, cost = ahPrice, method = method, count = 1 })
        priceCache[itemId] = { cost = ahPrice, method = method }
        return ahPrice, method
    end

    -- Вставляем родительский узел. Дерево больше не обрезается!
    local stepIndex = #craftingSteps + 1
    table.insert(craftingSteps, { itemId = itemId, depth = depth, cost = 0, method = "Craft", count = recipe.yield })

    local totalCraftCost = 0
    for reagentId, count in pairs(recipe.reagents) do
        local rCost = CalculateMinCostAdvanced(reagentId, depth + 1)
        totalCraftCost = totalCraftCost + (rCost * count)
    end
    
    local finalCraftCost = totalCraftCost / recipe.yield

    -- Если на аукционе дешевле, используем эту цену для расчетов, 
    -- но сохраняем все дочерние узлы в UI для наглядности.
    if ahPrice > 0 and ahPrice < finalCraftCost then
        craftingSteps[stepIndex].cost = ahPrice
        craftingSteps[stepIndex].method = "AH"
        priceCache[itemId] = { cost = ahPrice, method = "AH" }
        return ahPrice, "AH"
    else
        craftingSteps[stepIndex].cost = finalCraftCost
        craftingSteps[stepIndex].method = "Craft"
        priceCache[itemId] = { cost = finalCraftCost, method = "Craft" }
        return finalCraftCost, "Craft"
    end
end

local function FormatMoney(money)
    if not money or money <= 0 then return "0г" end
    local gold = math.floor(money / 10000)
    local silver = math.floor((money % 10000) / 100)
    local copper = math.floor(money % 100)
    local res = ""
    if gold > 0 then res = res .. gold .. "г " end
    if silver > 0 then res = res .. silver .. "с " end
    if copper > 0 then res = res .. copper .. "м" end
    return res
end

-- ==========================================
-- 3. ИНТЕРФЕЙС
-- ==========================================
MCA_GUI = CreateFrame("Frame", "MyCraftAdvisorFrame", UIParent)
MCA_GUI:SetSize(440, 500)
MCA_GUI:SetPoint("CENTER", UIParent, "CENTER")
MCA_GUI:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    texturing = true, tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 }
})
MCA_GUI:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
MCA_GUI:SetMovable(true)
MCA_GUI:EnableMouse(true)
MCA_GUI:RegisterForDrag("LeftButton")
MCA_GUI:SetScript("OnDragStart", MCA_GUI.StartMoving)
MCA_GUI:SetScript("OnDragStop", MCA_GUI.StopMovingOrSizing)
MCA_GUI:Hide()

local closeBtn = CreateFrame("Button", nil, MCA_GUI, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", MCA_GUI, "TOPRIGHT", -5, -5)

local scanAllBtn = CreateFrame("Button", nil, MCA_GUI, "UIPanelButtonTemplate")
scanAllBtn:SetPoint("TOPRIGHT", MCA_GUI, "TOPRIGHT", -40, -14)
scanAllBtn:SetSize(130, 22)
scanAllBtn:SetText("Сканировать всё")

local scrollFrame = CreateFrame("ScrollFrame", "MCAScrollFrame", MCA_GUI, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", 15, -90)
scrollFrame:SetPoint("BOTTOMRIGHT", MCA_GUI, "BOTTOMRIGHT", -30, 15)

local contentFrame = CreateFrame("Frame", nil, scrollFrame)
contentFrame:SetSize(380, 2500)
scrollFrame:SetScrollChild(contentFrame)

local headerText = MCA_GUI:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
headerText:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", 15, -15)

local summaryText = MCA_GUI:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
summaryText:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", 15, -38)

local warningText = MCA_GUI:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
warningText:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", 15, -65)

local uiRows = {}

local function CreateUIRow(index)
    local row = CreateFrame("Button", nil, contentFrame)
    row:SetSize(370, 22)
    
    local icon = row:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.icon = icon
    
    local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    row.text = text
    
    local price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    price:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.price = price

    row:SetScript("OnEnter", function(self)
        if self.itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    
    row:SetScript("OnClick", function(self)
        if self.itemLink then
            if IsShiftKeyDown() then
                local chatWindow = ChatEdit_GetActiveWindow()
                if chatWindow then chatWindow:Insert(self.itemLink) end
            else
                local itemId = tonumber(string.match(self.itemLink, "item:(%d+)"))
                if itemId and MyDynamicCraftDB[itemId] then MCA_GUI:ShowReport(itemId) end
            end
        end
    end)

    uiRows[index] = row
    return row
end

function MCA_GUI:ShowReport(itemId)
    priceCache = {}
    craftingSteps = {}
    
    local finalCost, bestMethod = CalculateMinCostAdvanced(itemId, 0)
    local ahPrice = GetItemBasePrice(itemId)
    local itemName, itemLink = SafeGetItemInfo(itemId)
    itemLink = itemLink or itemName or ("ID: " .. itemId)

    headerText:SetText("Анализ: " .. itemLink)
    warningText:SetText("|cff00ff00[Дерево крафта]: Клик на строку - развернуть рецепт реагента.|r")

    local profit = ahPrice - finalCost
    local profitStr = profit > 0 and ("|cff00ff00+" .. FormatMoney(profit) .. "|r") or "|cffff0000Нет прибыли|r"
    summaryText:SetText(string.format("Себестоимость: %s | На АХ: %s \nПрофит: %s", FormatMoney(finalCost), FormatMoney(ahPrice), profitStr))

    for _, row in pairs(uiRows) do row:Hide() end
    
    local yOffset = 5
    for i, step in ipairs(craftingSteps) do
        local row = uiRows[i] or CreateUIRow(i)
        local sName, sLink, sIcon = SafeGetItemInfo(step.itemId)
        sLink = sLink or sName or ("ID: " .. step.itemId)
        sIcon = sIcon or "Interface\\Icons\\INV_Misc_QuestionMark"
        
        row.itemLink = sLink
        row.icon:SetTexture(sIcon)
        local indent = step.depth * 15
        row.icon:SetPoint("LEFT", row, "LEFT", indent, 0)
        
        local methodColor = step.method == "Craft" and "|cff00ff00[Крафт]|r" or (step.method == "Vendor" and "|cff00ffff[Вендор]|r" or "|cff0000ff[АХ]|r")
        row.text:SetText(methodColor .. " " .. sLink)
        row.price:SetText(FormatMoney(step.cost))
        
        row:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 10, -yOffset)
        row:Show()
        yOffset = yOffset + 24
    end
    MCA_GUI:Show()
end

function MCA_GUI:ScanAllProfitable()
    headerText:SetText("Топ прибыльных крафтов")
    summaryText:SetText("Сортировка по чистой прибыли с аукциона")
    warningText:SetText("|cff00ff00Клик по строке открывает дерево крафта предмета.|r")
    
    for _, row in pairs(uiRows) do row:Hide() end
    
    local results = {}
    for itemId, _ in pairs(MyDynamicCraftDB) do
        priceCache = {}
        craftingSteps = {}
        local finalCost = CalculateMinCostAdvanced(itemId, 0)
        local ahPrice = GetItemBasePrice(itemId)
        local profit = ahPrice - finalCost
        if ahPrice > 0 then
            table.insert(results, { itemId = itemId, cost = finalCost, ah = ahPrice, profit = profit })
        end
    end
    
    table.sort(results, function(a, b) return a.profit > b.profit end)
    
    local yOffset = 5
    for i, res in ipairs(results) do
        local row = uiRows[i] or CreateUIRow(i)
        local sName, sLink, sIcon = SafeGetItemInfo(res.itemId)
        sLink = sLink or sName or ("ID: " .. res.itemId)
        sIcon = sIcon or "Interface\\Icons\\INV_Misc_QuestionMark"
        
        row.itemLink = sLink
        row.icon:SetTexture(sIcon)
        row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
        
        local profitColor = res.profit > 0 and "|cff00ff00" or "|cffff0000"
        row.text:SetText(sLink .. " (" .. profitColor .. "Профит: " .. FormatMoney(res.profit) .. "|r)")
        row.price:SetText("|cffaaaaaaКрафт:|r " .. FormatMoney(res.cost))
        
        row:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 10, -yOffset)
        row:Show()
        yOffset = yOffset + 24
    end
    MCA_GUI:Show()
end

scanAllBtn:SetScript("OnClick", function() MCA_GUI:ScanAllProfitable() end)

-- ==========================================
-- 4. ИНТЕГРАЦИЯ ПОДСКАЗКИ В ТУЛТИПЫ
-- ==========================================
local function OnTooltipSetItem(self)
    local _, link = self:GetItem()
    if not link then return end
    local itemId = tonumber(string.match(link, "item:(%d+)"))
    if not itemId then return end
    
    if MyDynamicCraftDB[itemId] then
        priceCache = {} 
        craftingSteps = {}
        local finalCost = CalculateMinCostAdvanced(itemId, 0)
        local ahPrice = GetItemBasePrice(itemId)
        
        self:AddLine(" ")
        self:AddLine("|cff00ff00[MCA] Анализ крафта:|r")
        self:AddDoubleLine("|cffaaaaaaСебестоимость:|r", FormatMoney(finalCost))
        
        if ahPrice > 0 then
            local profit = ahPrice - finalCost
            if profit > 0 then
                self:AddDoubleLine("|cff00ff00Выгода (Профит):|r", "|cff00ff00" .. FormatMoney(profit) .. "|r")
            else
                self:AddDoubleLine("|cffff0000Выгода (Профит):|r", "|cffff0000Убыток " .. FormatMoney(math.abs(profit)) .. "|r")
            end
        end
    elseif MyDynamicVendorDB[itemId] then
        self:AddDoubleLine("|cff00ffff[MCA] Цена у вендора:|r", FormatMoney(MyDynamicVendorDB[itemId]))
    end
end
GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)

-- СЛЭШ-КОМАНДА
SLASH_MYCRAFT1 = "/mca"
SlashCmdList["MYCRAFT"] = function(msg)
    msg = msg:trim()
    if msg == "" or msg == "all" then
        MCA_GUI:ScanAllProfitable()
    else
        local itemId = tonumber(string.match(msg, "item:(%d+)"))
        if not itemId then
            local _, link = GetItemInfo(msg)
            if link then itemId = tonumber(string.match(link, "item:(%d+)")) end
        end
        if itemId then MCA_GUI:ShowReport(itemId) else print("[MCA] Используйте /mca или /mca [Предмет]") end
    end
end