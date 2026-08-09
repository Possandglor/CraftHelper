-- ==========================================
-- MyCraftAdvisor v2.0
-- Интеграция с ARL, переключатель Мои/Все, новый дизайн
-- ==========================================

-- ==========================================
-- 1. ИНИЦИАЛИЗАЦИЯ И ДВИЖОК ДАННЫХ
-- ==========================================
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("TRADE_SKILL_SHOW")

local priceCache        = {}
MyDynamicCraftDB        = MyDynamicCraftDB or {}
MyDynamicVendorDB       = MyDynamicVendorDB or {}

-- База всех рецептов из ARL (spell_id -> {item_id, profession, name, skill_level})
local MCA_ARLRecipeDB   = {}
-- Флаг: true = показывать только известные, false = все из ARL
local MCA_FilterKnown   = true

-- ==========================================
-- 1а. ПЕРЕХВАТ БАЗЫ ДАННЫХ ARL
-- ==========================================
local function HookARL()
    if not ARL then return end
    if ARL.__MCA_hooked then return end
    ARL.__MCA_hooked = true

    -- Хукаем AddRecipe, чтобы перехватывать все рецепты при загрузке базы
    hooksecurefunc(ARL, "AddRecipe", function(self, spell_id, skill_level, item_id, quality, profession_spellid)
        if not spell_id then return end
        local profName = GetSpellInfo(profession_spellid) or ""
        local recipeName = GetSpellInfo(spell_id) or ""
        MCA_ARLRecipeDB[spell_id] = {
            item_id     = item_id,
            profession  = profName,
            name        = recipeName,
            skill_level = skill_level or 0,
        }
    end)
end

-- ==========================================
-- 1б. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ==========================================
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
        print("|cff00ccff[MCA]:|r База обновлена [|cffffcc00"..profName.."|r]: " .. scanned .. " рецептов")
    end
end

-- Возвращает цену покупки предмета (вендор или АХ), или nil если данных нет
local function GetItemBasePrice(itemId)
    if MyDynamicVendorDB[itemId] then return MyDynamicVendorDB[itemId], "Vendor" end
    local name = SafeGetItemInfo(itemId)
    local ahPrice = nil
    if Auctionator and Auctionator.API and Auctionator.API.GetAuctionPriceByItemID then
        local p = Auctionator.API.GetAuctionPriceByItemID(itemId)
        if p and p > 0 then ahPrice = p end
    elseif Atr_GetAuctionPrice then
        local p = Atr_GetAuctionPrice(name or "")
        if p and p > 0 then ahPrice = p end
    end
    return ahPrice, "AH"
end

-- Возвращает минимальную стоимость получения предмета.
-- nil = цена неизвестна (нет данных АХ/вендора для одного из реагентов).
local function CalculateMinCost(itemId)
    if priceCache[itemId] then return priceCache[itemId].cost, priceCache[itemId].method end

    local ahPrice, _ = GetItemBasePrice(itemId)
    local recipe = MyDynamicCraftDB[itemId]

    -- Нет рецепта в нашей базе → единственный вариант получить — купить
    if not recipe then
        priceCache[itemId] = { cost = ahPrice, method = "AH" }
        return ahPrice, "AH"
    end

    -- Считаем стоимость крафта; если хоть один реагент без цены — craftCost = nil
    local totalCraftCost = 0
    local craftUnknown   = false
    for reagentId, count in pairs(recipe.reagents) do
        local rCost = CalculateMinCost(reagentId)
        if rCost == nil then
            craftUnknown = true
        else
            totalCraftCost = totalCraftCost + (rCost * count)
        end
    end
    local finalCraftCost = craftUnknown and nil or (totalCraftCost / recipe.yield)

    -- Выбираем минимум из доступных вариантов
    if ahPrice and finalCraftCost then
        if ahPrice <= finalCraftCost then
            priceCache[itemId] = { cost = ahPrice, method = "AH" }
            return ahPrice, "AH"
        else
            priceCache[itemId] = { cost = finalCraftCost, method = "Craft" }
            return finalCraftCost, "Craft"
        end
    elseif ahPrice then
        -- Можем только купить (данных для крафта нет или крафт дороже)
        priceCache[itemId] = { cost = ahPrice, method = "AH" }
        return ahPrice, "AH"
    elseif finalCraftCost then
        -- АХ-цены нет, но можем скрафтить
        priceCache[itemId] = { cost = finalCraftCost, method = "Craft" }
        return finalCraftCost, "Craft"
    else
        -- Нет данных вообще
        priceCache[itemId] = { cost = nil, method = "Unknown" }
        return nil, "Unknown"
    end
end

-- Стоимость КРАФТА конкретного предмета (сумма реагентов по мин. ценам покупки).
-- Используется ТОЛЬКО для отображения в UI верхнего уровня.
-- Для реагентов используем CalculateMinCost (мин. стоимость = купить или крафтить).
local function CalculateCraftCost(itemId)
    local recipe = MyDynamicCraftDB[itemId]
    if not recipe then return nil end
    local total      = 0
    local hasUnknown = false
    for reagentId, count in pairs(recipe.reagents) do
        local rCost = CalculateMinCost(reagentId)
        if rCost == nil then
            hasUnknown = true
        else
            total = total + rCost * count
        end
    end
    if hasUnknown then return nil end
    return total / recipe.yield
end

local function FormatMoney(money)
    if money == nil then return "|cffff8800?|r" end   -- неизвестна
    if money <= 0   then return "|cff888888—|r" end   -- нет/нулевая
    local gold   = math.floor(money / 10000)
    local silver = math.floor((money % 10000) / 100)
    local copper = math.floor(money % 100)
    if gold   > 0 then return string.format("|cffffd700%dг|r |cffc0c0c0%dс|r", gold, silver) end
    if silver > 0 then return string.format("|cffc0c0c0%dс|r |cffb87333%dм|r", silver, copper) end
    return string.format("|cffb87333%dм|r", copper)
end

-- ==========================================
-- 2. ГРАФИЧЕСКИЙ ИНТЕРФЕЙС — ГЛАВНОЕ ОКНО
-- ==========================================

-- Фон главного фрейма
MCA_GUI = CreateFrame("Frame", "MyCraftAdvisorFrame", UIParent)
MCA_GUI:SetSize(860, 620)
MCA_GUI:SetPoint("CENTER", UIParent, "CENTER")
MCA_GUI:SetBackdrop({
    bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    texturing = true, tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 }
})
MCA_GUI:SetBackdropColor(0.05, 0.06, 0.10, 0.97)
MCA_GUI:SetMovable(true)
MCA_GUI:EnableMouse(true)
MCA_GUI:RegisterForDrag("LeftButton")
MCA_GUI:SetScript("OnDragStart", MCA_GUI.StartMoving)
MCA_GUI:SetScript("OnDragStop",  MCA_GUI.StopMovingOrSizing)
MCA_GUI:Hide()

-- Декоративная полоса-заголовок
local titleBar = MCA_GUI:CreateTexture(nil, "BACKGROUND")
titleBar:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", 8, -8)
titleBar:SetPoint("TOPRIGHT", MCA_GUI, "TOPRIGHT", -8, -8)
titleBar:SetHeight(36)
titleBar:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
titleBar:SetVertexColor(0.08, 0.22, 0.45, 1)

-- Иконка-кристалл в заголовке
local titleIcon = MCA_GUI:CreateTexture(nil, "OVERLAY")
titleIcon:SetSize(22, 22)
titleIcon:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", 16, -15)
titleIcon:SetTexture("Interface\\Icons\\INV_Misc_Note_01")

-- Текст заголовка
local headerText = MCA_GUI:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
headerText:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", 44, -18)
headerText:SetTextColor(0.9, 0.85, 1.0)

-- Кнопка закрытия
local closeBtn = CreateFrame("Button", nil, MCA_GUI, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", MCA_GUI, "TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function() MCA_GUI:Hide() end)

-- Кнопка «Назад»
local backBtn = CreateFrame("Button", nil, MCA_GUI, "UIPanelButtonTemplate")
backBtn:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", 20, -50)
backBtn:SetSize(88, 22)
backBtn:SetText("← Назад")
backBtn:Hide()

-- ==========================================
-- 2а. ПЕРЕКЛЮЧАТЕЛЬ «МОИ / ВСЕ ИЗ ARL»
-- ==========================================
-- Переключатель режима: размещаем на второй строке (ниже табов), справа
local filterToggleBtn = CreateFrame("Button", "MCA_FilterToggle", MCA_GUI, "UIPanelButtonTemplate")
filterToggleBtn:SetSize(170, 22)
filterToggleBtn:SetPoint("TOPRIGHT", MCA_GUI, "TOPRIGHT", -44, -82)

-- Поиск по названию рецепта
local searchQuery = ""

local searchBox = CreateFrame("EditBox", "MCA_SearchBox", MCA_GUI, "InputBoxTemplate")
searchBox:SetSize(180, 22)
searchBox:SetPoint("TOPRIGHT", MCA_GUI, "TOPRIGHT", -44, -110)
searchBox:SetAutoFocus(false)
searchBox:SetMaxLetters(64)
searchBox:SetText("")

-- Placeholder-текст (WoW 3.3.5 не имеет SetPlaceholderText)
local searchPlaceholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
searchPlaceholder:SetPoint("LEFT", searchBox, "LEFT", 6, 0)
searchPlaceholder:SetText("Поиск...")
searchPlaceholder:SetTextColor(0.5, 0.5, 0.5)

local function UpdateFilterToggleText()
    if MCA_FilterKnown then
        filterToggleBtn:SetText("[Мои] Только мои рецепты")
    else
        filterToggleBtn:SetText("[Все] Все рецепты (ARL)")
    end
end

local function UpdateSearch()
    searchQuery = searchBox:GetText():lower()
    -- Показываем/скрываем placeholder
    if searchBox:GetText() == "" then
        searchPlaceholder:Show()
    else
        searchPlaceholder:Hide()
    end
    if currentViewMode == "scan_all" then
        MCA_GUI:RenderMyRecipes(currentSelectedProf)
    elseif currentViewMode == "arl_all" then
        MCA_GUI:RenderARLRecipes(currentSelectedProf)
    else
        MCA_GUI:ShowAllProfessions()
    end
end

searchBox:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    UpdateSearch()
end)
searchBox:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    UpdateSearch()
end)
searchBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus(); UpdateSearch(); end)
searchBox:SetScript("OnEditFocusGained", function(self) searchPlaceholder:Hide() end)
searchBox:SetScript("OnEditFocusLost", function(self)
    if self:GetText() == "" then searchPlaceholder:Show() end
end)
UpdateFilterToggleText()

-- Разделительная линия: ниже второй строки кнопок
local divider = MCA_GUI:CreateTexture(nil, "BACKGROUND")
divider:SetPoint("TOPLEFT",  MCA_GUI, "TOPLEFT",  18, -108)
divider:SetPoint("TOPRIGHT", MCA_GUI, "TOPRIGHT", -18, -108)
divider:SetHeight(1)
divider:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
divider:SetVertexColor(0.2, 0.35, 0.6, 0.8)

-- Строка статуса внизу
local statusBar = MCA_GUI:CreateTexture(nil, "BACKGROUND")
statusBar:SetPoint("BOTTOMLEFT",  MCA_GUI, "BOTTOMLEFT",  8,  8)
statusBar:SetPoint("BOTTOMRIGHT", MCA_GUI, "BOTTOMRIGHT", -8, 8)
statusBar:SetHeight(24)
statusBar:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
statusBar:SetVertexColor(0.08, 0.22, 0.45, 0.7)

local statusText = MCA_GUI:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
statusText:SetPoint("BOTTOMLEFT", MCA_GUI, "BOTTOMLEFT", 20, 12)
statusText:SetTextColor(0.6, 0.75, 1.0)

-- Scroll-фрейм: начинается ниже двух рядов кнопок + разделитель
local scrollFrame = CreateFrame("ScrollFrame", "MCAScrollFrame", MCA_GUI, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT",     MCA_GUI, "TOPLEFT",     20, -112)
scrollFrame:SetPoint("BOTTOMRIGHT", MCA_GUI, "BOTTOMRIGHT", -30, 36)

local contentFrame = CreateFrame("Frame", nil, scrollFrame)
contentFrame:SetSize(2000, 2000)
scrollFrame:SetScrollChild(contentFrame)

-- Добавляем невидимый фон для надежного захвата мыши при перетаскивании холста
local contentBg = contentFrame:CreateTexture(nil, "BACKGROUND")
contentBg:SetAllPoints(contentFrame)
contentBg:SetTexture(0, 0, 0, 0.01)

-- Реализация перемещения холста (pan/drag) мышкой
contentFrame:EnableMouse(true)
contentFrame:SetScript("OnMouseDown", function(self, button)
    if button == "LeftButton" then
        self.isDragging = true
        local x, y = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        if scale and scale > 0 then
            self.startX = x / scale
            self.startY = y / scale
            self.startH = scrollFrame:GetHorizontalScroll()
            self.startV = scrollFrame:GetVerticalScroll()
        end
    end
end)
contentFrame:SetScript("OnMouseUp", function(self, button)
    if button == "LeftButton" then
        self.isDragging = false
    end
end)
contentFrame:SetScript("OnUpdate", function(self, elapsed)
    if self.isDragging then
        if not IsMouseButtonDown("LeftButton") then
            self.isDragging = false
            return
        end
        local x, y = GetCursorPosition()
        local scale = self:GetEffectiveScale()
        if scale and scale > 0 then
            local currX = x / scale
            local currY = y / scale
            local diffX = currX - self.startX
            local diffY = currY - self.startY
            
            local newH = self.startH - diffX
            local newV = self.startV + diffY
            
            local maxH = scrollFrame:GetHorizontalScrollRange()
            local maxV = scrollFrame:GetVerticalScrollRange()
            
            if newH < 0 then newH = 0 elseif newH > maxH then newH = maxH end
            if newV < 0 then newV = 0 elseif newV > maxV then newV = maxV end
            
            scrollFrame:SetHorizontalScroll(newH)
            scrollFrame:SetVerticalScroll(newV)
            
            local scrollbar = _G[scrollFrame:GetName() .. "ScrollBar"]
            if scrollbar then
                scrollbar:SetValue(newV)
            end
        end
    end
end)

-- Поддержка прокрутки колесиком мыши (с Shift — по горизонтали)
scrollFrame:EnableMouseWheel(true)
scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    if IsShiftKeyDown() then
        local newH = self:GetHorizontalScroll() - (delta * 40)
        local maxH = self:GetHorizontalScrollRange()
        if newH < 0 then newH = 0 elseif newH > maxH then newH = maxH end
        self:SetHorizontalScroll(newH)
    else
        local scrollbar = _G[self:GetName() .. "ScrollBar"]
        if scrollbar then
            local current = scrollbar:GetValue()
            local min, max = scrollbar:GetMinMaxValues()
            local newV = current - (delta * 40)
            if newV < min then newV = min elseif newV > max then newV = max end
            scrollbar:SetValue(newV)
        end
    end
end)

local rowPool, nodePool, linePool, tabPool = {}, {}, {}, {}
local currentViewMode     = "none"
local currentSelectedProf = ""

local function ResetUI()
    for _, r in ipairs(rowPool)  do r:Hide() end
    for _, n in ipairs(nodePool) do n:Hide() end
    for _, l in ipairs(linePool) do l:Hide() end
    statusText:SetText("")
    if scrollFrame then
        scrollFrame:SetHorizontalScroll(0)
        scrollFrame:SetVerticalScroll(0)
        local scrollbar = _G[scrollFrame:GetName() .. "ScrollBar"]
        if scrollbar then
            scrollbar:SetValue(0)
        end
    end
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
local ROW_HEIGHT = 30
local ROW_WIDTH  = 780

local function GetRow(index)
    if rowPool[index] then return rowPool[index] end

    local r = CreateFrame("Button", nil, contentFrame)
    r:SetSize(ROW_WIDTH, ROW_HEIGHT)

    -- Фоновая текстура строки (чередование)
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()

    -- Иконка предмета
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(22, 22)
    r.icon:SetPoint("LEFT", r, "LEFT", 6, 0)

    -- Рамка иконки
    r.iconBorder = r:CreateTexture(nil, "OVERLAY")
    r.iconBorder:SetSize(24, 24)
    r.iconBorder:SetPoint("CENTER", r.icon, "CENTER")
    r.iconBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    r.iconBorder:SetVertexColor(1, 1, 1, 0.5)

    -- Бейдж «Известен» / «Неизвестен»
    r.badge = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.badge:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.badge:SetWidth(70)
    r.badge:SetJustifyH("LEFT")

    -- Название предмета
    r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.text:SetPoint("LEFT", r.badge, "RIGHT", 4, 0)
    r.text:SetWidth(340)
    r.text:SetJustifyH("LEFT")

    -- Цена крафта
    r.costText = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.costText:SetPoint("RIGHT", r, "RIGHT", -160, 0)
    r.costText:SetWidth(130)
    r.costText:SetJustifyH("RIGHT")

    -- Профит
    r.profit = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.profit:SetPoint("RIGHT", r, "RIGHT", -8, 0)
    r.profit:SetWidth(145)
    r.profit:SetJustifyH("RIGHT")

    r:SetScript("OnEnter", function(self)
        self.bg:SetVertexColor(0.15, 0.3, 0.55, 0.9)
        if self.itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        end
    end)
    r:SetScript("OnLeave", function(self)
        local oddColor = self._odd and 0.06 or 0.04
        self.bg:SetVertexColor(oddColor, oddColor + 0.04, oddColor + 0.08, 0.85)
        GameTooltip:Hide()
    end)
    r:SetScript("OnClick", function(self)
        if self.itemLink then HandleItemInteraction(self.itemLink) end
    end)

    rowPool[index] = r
    return r
end

local function GetTab(index)
    if tabPool[index] then return tabPool[index] end
    local t = CreateFrame("Button", nil, MCA_GUI, "UIPanelButtonTemplate")
    t:SetSize(130, 24)
    tabPool[index] = t
    return t
end

-- ==========================================
-- 3а. РЕНДЕР СПИСКА "МОИ РЕЦЕПТЫ"
-- ==========================================
function MCA_GUI:RenderMyRecipes(profName)
    ResetUI()
    currentViewMode     = "scan_all"
    currentSelectedProf = profName
    backBtn:Hide()
    headerText:SetText("|cff7ec8e3Мои рецепты|r — |cffffcc00" .. profName .. "|r  |cff888888(по прибыли)|r")

    local list = {}
    for itemId, data in pairs(MyDynamicCraftDB) do
        if data.profession == profName then
            local name = SafeGetItemInfo(itemId)
            if searchQuery == "" or (name and name:lower():find(searchQuery, 1, true)) then
                priceCache = {}
                local craftCost = CalculateCraftCost(itemId)
                local ah        = GetItemBasePrice(itemId)
                local profit    = (ah and craftCost) and (ah - craftCost) or nil
                table.insert(list, { id = itemId, craftCost = craftCost, ah = ah, profit = profit })
            end
        end
    end
    -- nil-безопасная сортировка: без цены — в конец
    table.sort(list, function(a, b)
        if a.profit == nil and b.profit == nil then return false end
        if a.profit == nil then return false end
        if b.profit == nil then return true end
        return a.profit > b.profit
    end)

    local yOffset = 4
    for i, item in ipairs(list) do
        local row = GetRow(i)
        local name, link, tex = SafeGetItemInfo(item.id)
        link = link or name or ("ID: " .. item.id)

        row._odd = (i % 2 == 1)
        local r, g, b = row._odd and 0.08 or 0.05, row._odd and 0.12 or 0.08, row._odd and 0.18 or 0.13
        row.bg:SetVertexColor(r, g, b, 0.85)

        row.itemLink = link
        row.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")

        row.badge:SetText("|cff00ff88[+] Знаю|r")

        local bagCount = GetItemCount(item.id)
        local countText = bagCount > 0 and (" |cff00ff00(" .. bagCount .. " в сумке)|r") or ""
        row.text:SetText(link .. countText)
        row.costText:SetText("|cff999999Крафт:|r " .. FormatMoney(item.craftCost))
        if item.profit == nil then
            row.profit:SetText("|cffff8800Нет данных АХ|r")
        else
            local pColor = item.profit > 0 and "|cff00ff88" or "|cffff5555"
            row.profit:SetText("Профит: " .. pColor .. (item.profit > 0 and "+" or "") .. FormatMoney(item.profit) .. "|r")
        end

        row:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 5, -yOffset)
        row:Show()
        yOffset = yOffset + ROW_HEIGHT + 2
    end
    contentFrame:SetSize(ROW_WIDTH + 20, yOffset + 20)
    statusText:SetText("|cff7ec8e3Моих рецептов:|r |cffffcc00" .. #list .. "|r  |cff888888(Shift+клик → поиск на АХ, клик → граф крафта)|r")
end

-- ==========================================
-- 3б. РЕНДЕР СПИСКА "ВСЕ РЕЦЕПТЫ ИЗ ARL"
-- ==========================================
function MCA_GUI:RenderARLRecipes(profName)
    ResetUI()
    currentViewMode     = "arl_all"
    currentSelectedProf = profName
    backBtn:Hide()
    headerText:SetText("|cffff9f44Все рецепты (ARL)|r — |cffffcc00" .. profName .. "|r  |cff888888(по уровню скила)|r")

    -- Собираем рецепты этой профессии из базы ARL
    local list = {}
    local knownCount   = 0
    local unknownCount = 0

    for spell_id, data in pairs(MCA_ARLRecipeDB) do
        if data.profession == profName then
            local isKnown = IsSpellKnown(spell_id)
            local itemId  = data.item_id
            local name = data.name
            if searchQuery == "" or (name and name:lower():find(searchQuery, 1, true)) then
                local craftCost, ah, profit = nil, nil, nil
                if itemId and MyDynamicCraftDB[itemId] then
                    priceCache = {}
                    craftCost = CalculateCraftCost(itemId)
                    ah        = GetItemBasePrice(itemId)
                    profit    = (ah and craftCost) and (ah - craftCost) or nil
                end
                table.insert(list, {
                    spell_id    = spell_id,
                    item_id     = itemId,
                    name        = name,
                    skill_level = data.skill_level,
                    is_known    = isKnown,
                    craftCost   = craftCost,
                    ah          = ah,
                    profit      = profit,
                })
                if isKnown then knownCount = knownCount + 1 else unknownCount = unknownCount + 1 end
            end
        end
    end

    -- Сортируем: известные сначала, потом по уровню
    table.sort(list, function(a, b)
        if a.is_known ~= b.is_known then return a.is_known end
        return a.skill_level < b.skill_level
    end)

    if #list == 0 then
        headerText:SetText("|cffff5555База ARL пуста для профессии «" .. profName .. "».|r Нажмите кнопку Scan в ARL.")
        statusText:SetText("|cffff5555Рецепты ARL не загружены. Откройте профессию и нажмите Scan в ARL.|r")
        return
    end

    local yOffset = 4
    for i, item in ipairs(list) do
        local row = GetRow(i)

        row._odd = (i % 2 == 1)
        local r, g, b
        if item.is_known then
            r, g, b = row._odd and 0.06 or 0.04, row._odd and 0.13 or 0.09, row._odd and 0.10 or 0.07
        else
            r, g, b = row._odd and 0.12 or 0.09, row._odd and 0.07 or 0.05, row._odd and 0.06 or 0.04
        end
        row.bg:SetVertexColor(r, g, b, 0.85)

        -- Иконка
        local tex = nil
        local link = nil
        if item.item_id then
            local name, itemLink, itemTex = SafeGetItemInfo(item.item_id)
            tex  = itemTex
            link = itemLink or name
        end
        if not link then link = item.name or ("Spell: " .. item.spell_id) end

        row.itemLink = link
        row.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")

        -- Бейдж (ASCII-символы, WoW 3.3.5 не поддерживает Unicode bullets)
        if item.is_known then
            row.badge:SetText("|cff00ff88[+] Знаю|r")
        else
            row.badge:SetText("|cffff5555[-] Нет|r")
        end

        -- Название + уровень скила + рюкзак
        local bagCount = item.item_id and GetItemCount(item.item_id) or 0
        local countText = bagCount > 0 and (" |cff00ff00(" .. bagCount .. " в сумке)|r") or ""
        row.text:SetText(link .. " |cff666666[" .. item.skill_level .. "]|r" .. countText)

        -- Себестоимость (если рецепт есть в нашей БД)
        if item.item_id and MyDynamicCraftDB[item.item_id] then
            row.costText:SetText("|cff999999Крафт:|r " .. FormatMoney(item.craftCost))
            if item.profit == nil then
                row.profit:SetText("|cffff8800Нет данных АХ|r")
            else
                local pColor = item.profit > 0 and "|cff00ff88" or "|cffff5555"
                row.profit:SetText("Профит: " .. pColor .. (item.profit > 0 and "+" or "") .. FormatMoney(item.profit) .. "|r")
            end
        else
            row.costText:SetText("|cff444444Нет цен|r")
            row.profit:SetText("|cff444444—|r")
        end

        row:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 5, -yOffset)
        row:Show()
        yOffset = yOffset + ROW_HEIGHT + 2
    end
    contentFrame:SetSize(ROW_WIDTH + 20, yOffset + 20)

    local arlTotal = knownCount + unknownCount
    statusText:SetText(
        "|cff7ec8e3ARL рецептов:|r |cffffcc00" .. arlTotal .. "|r  " ..
        "|cff00ff88Знаю: " .. knownCount .. "|r  " ..
        "|cffff5555Не знаю: " .. unknownCount .. "|r  " ..
        "|cff888888(Shift+клик → АХ, клик → граф крафта)|r"
    )
end

-- ==========================================
-- 3в. ОТОБРАЖЕНИЕ СПИСКА ПРОФЕССИЙ
-- ==========================================
function MCA_GUI:ShowAllProfessions()
    HideTabs()
    filterToggleBtn:Show()

    -- Собираем профессии из MCA-базы и/или ARL-базы (в зависимости от режима)
    local profs = {}
    if MCA_FilterKnown then
        for _, data in pairs(MyDynamicCraftDB) do
            if data.profession then profs[data.profession] = true end
        end
    else
        for _, data in pairs(MCA_ARLRecipeDB) do
            if data.profession and data.profession ~= "" then profs[data.profession] = true end
        end
        -- Добавляем и из нашей базы на случай, если ARL не загружен для этой проф
        for _, data in pairs(MyDynamicCraftDB) do
            if data.profession then profs[data.profession] = true end
        end
    end

    local sortedProfs = {}
    for p in pairs(profs) do table.insert(sortedProfs, p) end
    table.sort(sortedProfs)

    if #sortedProfs == 0 then
        if MCA_FilterKnown then
            headerText:SetText("|cffff5555База рецептов пуста.|r Откройте окно профессий для сканирования.")
        else
            headerText:SetText("|cffff5555База ARL пуста.|r Откройте профессию и нажмите Scan в ARL, или включите «Только мои».")
        end
        ResetUI()
        return
    end

    local xOffset = 20
    local TAB_W = 134
    for i, prof in ipairs(sortedProfs) do
        local tab = GetTab(i)
        tab:SetText(prof)
        -- Строка 1: табы профессий на Y=-50, filterToggle на Y=-82 (отдельно)
        tab:SetPoint("TOPLEFT", MCA_GUI, "TOPLEFT", xOffset, -52)
        tab:SetScript("OnClick", function()
            currentSelectedProf = prof
            if MCA_FilterKnown then
                MCA_GUI:RenderMyRecipes(prof)
            else
                MCA_GUI:RenderARLRecipes(prof)
            end
        end)
        tab:Show()
        xOffset = xOffset + TAB_W + 4
    end

    if currentSelectedProf == "" or not profs[currentSelectedProf] then
        currentSelectedProf = sortedProfs[1]
    end

    if MCA_FilterKnown then
        MCA_GUI:RenderMyRecipes(currentSelectedProf)
    else
        MCA_GUI:RenderARLRecipes(currentSelectedProf)
    end
end

-- Обработчик кнопки переключателя
filterToggleBtn:SetScript("OnClick", function()
    MCA_FilterKnown = not MCA_FilterKnown
    UpdateFilterToggleText()
    MCA_GUI:ShowAllProfessions()
end)

-- ==========================================
-- 4. ГРАФИЧЕСКИЙ ДВИЖОК НОД (граф крафта)
-- ==========================================
local function GetNode(index)
    if nodePool[index] then return nodePool[index] end
    local n = CreateFrame("Button", nil, contentFrame)
    n:SetSize(40, 40)

    n.icon = n:CreateTexture(nil, "BORDER")
    n.icon:SetAllPoints()

    n.bg = n:CreateTexture(nil, "BACKGROUND")
    n.bg:SetSize(48, 48)
    n.bg:SetPoint("CENTER")
    n.bg:SetTexture("Interface\\Buttons\\UI-Quickslot")

    n.prices = n:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    n.prices:SetPoint("BOTTOM", n, "TOP", 0, 4)
    n.prices:SetJustifyH("CENTER")

    n:SetScript("OnEnter", function(self)
        self.bg:SetAlpha(1.0)
        if self.itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        end
    end)
    n:SetScript("OnLeave", function(self)
        self.bg:SetAlpha(0.8)
        GameTooltip:Hide()
    end)
    n:SetScript("OnClick", function(self)
        if self.itemLink then HandleItemInteraction(self.itemLink) end
    end)

    nodePool[index] = n
    return n
end

local function GetLine(index)
    if linePool[index] then return linePool[index] end
    local l = contentFrame:CreateTexture(nil, "BACKGROUND")
    l:SetTexture(0.3, 0.5, 0.8, 0.6)
    linePool[index] = l
    return l
end

local lineIdx = 1
local function DrawStepLine(x1, y1, x2, y2)
    local midX = x1 + (x2 - x1) / 2

    local l1 = GetLine(lineIdx); lineIdx = lineIdx + 1
    l1:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", x1, y1)
    l1:SetSize(midX - x1, 2)
    l1:Show()

    local topY = math.max(y1, y2)
    local botY = math.min(y1, y2)
    local l2 = GetLine(lineIdx); lineIdx = lineIdx + 1
    l2:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", midX, topY)
    l2:SetSize(2, topY - botY)
    l2:Show()

    local l3 = GetLine(lineIdx); lineIdx = lineIdx + 1
    l3:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", midX, y2)
    l3:SetSize(x2 - midX, 2)
    l3:Show()
end

function MCA_GUI:DrawNodeGraph(rootItemId, fromScan)
    ResetUI()
    HideTabs()
    filterToggleBtn:Hide()

    if fromScan then currentViewMode = "graph"; backBtn:Show() end

    local _, rootLink = SafeGetItemInfo(rootItemId)
    headerText:SetText("|cff7ec8e3Граф крафта:|r " .. (rootLink or ("ID: " .. rootItemId)))

    priceCache = {}

    local function BuildNode(itemId, depth)
        local nData = { id = itemId, depth = depth, children = {} }
        local recipe = MyDynamicCraftDB[itemId]
        local cost, method = CalculateMinCost(itemId)

        nData.cost   = cost
        nData.method = method
        nData.ah     = GetItemBasePrice(itemId)
        nData.craft  = CalculateCraftCost(itemId)

        if recipe and recipe.reagents then
            for rId, _ in pairs(recipe.reagents) do
                table.insert(nData.children, BuildNode(rId, depth + 1))
            end
        end
        return nData
    end

    local treeRoot = BuildNode(rootItemId, 0)

    local currentY = -60
    local maxX = 0
    local function LayoutY(node)
        if #node.children == 0 then
            node.y = currentY
            currentY = currentY - 105 -- увеличен шаг для 4 строк текста
        else
            for _, child in ipairs(node.children) do LayoutY(child) end
            node.y = (node.children[1].y + node.children[#node.children].y) / 2
        end
        node.x = 30 + (node.depth * 195)
        if node.x > maxX then maxX = node.x end
    end
    LayoutY(treeRoot)

    local nodeIdx = 1
    lineIdx = 1

    local function RenderNode(node, parentNode)
        local uiNode = GetNode(nodeIdx); nodeIdx = nodeIdx + 1
        local name, link, tex = SafeGetItemInfo(node.id)

        uiNode.itemLink = link or name or ("ID: " .. node.id)
        uiNode.icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
        uiNode:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", node.x, node.y)
        uiNode.bg:SetAlpha(0.8)
        uiNode:Show()

        -- Цвет рамки по оптимальному выбору
        if node.method == "Craft" then
            uiNode.bg:SetVertexColor(1.0, 0.65, 0.1)
        elseif node.method == "Vendor" then
            uiNode.bg:SetVertexColor(0.1, 0.9, 1.0)
        else
            uiNode.bg:SetVertexColor(0.1, 1.0, 0.4)
        end

        local vPrice = MyDynamicVendorDB[node.id] and FormatMoney(MyDynamicVendorDB[node.id]) or "—"
        local ahStr  = node.ah and FormatMoney(node.ah) or "—"
        local crStr  = node.craft and FormatMoney(node.craft) or "—"
        local bagCount = GetItemCount(node.id)
        local countText = bagCount > 0 and ("\n|cff00ff00В сумке: " .. bagCount .. "|r") or ""
        local pStr = string.format(
            "|cff00dd66АХ: %s|r\n|cff00ddffВенд: %s|r\n|cffffaa00Крафт: %s|r\n|cffffffffМин: %s|r%s",
            ahStr, vPrice, crStr, FormatMoney(node.cost), countText
        )
        uiNode.prices:SetText(pStr)

        if parentNode then
            DrawStepLine(parentNode.x + 40, parentNode.y - 20, node.x, node.y - 20)
        end

        for _, child in ipairs(node.children) do
            RenderNode(child, node)
        end
    end

    RenderNode(treeRoot, nil)
    local canvasWidth = math.max(maxX + 250, 800)
    local canvasHeight = math.max(math.abs(currentY) + 100, 480)
    contentFrame:SetSize(canvasWidth, canvasHeight)
    statusText:SetText(
        "|cffff9f44Граф крафта.|r  " ..
        "|cff00dd66■|r Крафт  |cff00ddff■|r Вендор  |cff00ff88■|r АХ  " ..
        "|cff888888Зажмите ЛКМ для перемещения · Shift+Колесо для гор. прокрутки|r"
    )
    MCA_GUI:Show()
end

backBtn:SetScript("OnClick", function()
    if currentViewMode == "graph" then
        ResetUI()
        MCA_GUI:ShowAllProfessions()
    end
end)

-- ==========================================
-- 5. КНОПКА «АНАЛИЗ» В ИНТЕРФЕЙСЕ ПРОФЕССИЙ
-- ==========================================
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
        print("|cffff5555[MCA]: Выберите конкретный рецепт для построения графа.|r")
    end
end

local function InjectAnalyzeButton()
    if Skillet and SkilletFrame then
        if not MyCraftButtonSkillet then
            MyCraftButtonSkillet = CreateFrame("Button", "MyCraftAdvisorSkilletButton", SkilletFrame, "UIPanelButtonTemplate")
            MyCraftButtonSkillet:SetPoint("BOTTOMRIGHT", SkilletFrame, "BOTTOMRIGHT", -220, 42)
            MyCraftButtonSkillet:SetSize(95, 22)
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
-- 6. ТУЛТИПЫ, СОБЫТИЯ, SLASH-КОМАНДЫ
-- ==========================================
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addon = ...
        if addon == "MyCraftAdvisor" then
            print("|cff00ccff[MyCraftAdvisor]:|r v2.0 загружен. Команда: |cffffcc00/mca|r")
            -- Пробуем хукнуть ARL сразу
            HookARL()
        elseif addon == "AckisRecipeList" then
            HookARL()
            print("|cff00ccff[MCA]:|r ARL обнаружен — интеграция базы рецептов активна.")
        end

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
            if self.time > 0.3 then
                DynamicScanRecipes()
                InjectAnalyzeButton()
                self:SetScript("OnUpdate", nil)
            end
        end)
    end
end)

-- Тултип: добавляем инфо о крафте
GameTooltip:HookScript("OnTooltipSetItem", function(self)
    local _, link = self:GetItem()
    local itemId = link and tonumber(string.match(link, "item:(%d+)"))
    if not itemId then return end

    if MyDynamicCraftDB[itemId] then
        priceCache = {}
        -- Используем craftCost (реальная стоимость материалов), не CalculateMinCost
        local craftCost = CalculateCraftCost(itemId)
        local ah        = GetItemBasePrice(itemId)
        self:AddLine(" ")
        self:AddLine("|cff00ccff[MCA] Расчёт крафта:|r")
        self:AddDoubleLine("|cffaaaaaaСтоимость крафта:|r", FormatMoney(craftCost))
        if ah then
            self:AddDoubleLine("|cffaaaaaaЦена на АХ:|r", FormatMoney(ah))
            if craftCost then
                local diff = ah - craftCost
                local col  = diff > 0 and "|cff00ff88" or "|cffff5555"
                self:AddDoubleLine(col .. "Профит (продать):|r", col .. FormatMoney(diff) .. "|r")
            end
        else
            self:AddDoubleLine("|cff888888Цена АХ:|r", "|cff888888нет данных|r")
        end
        self:Show()
    end
end)

SLASH_MYCRAFT1 = "/mca"
SlashCmdList["MYCRAFT"] = function(msg)
    msg = msg:trim()
    if msg == "" or msg == "all" then
        ResetUI()
        MCA_GUI:ShowAllProfessions()
        MCA_GUI:Show()
    elseif msg == "arl" then
        MCA_FilterKnown = false
        UpdateFilterToggleText()
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
            print("|cff00ccff[MCA]:|r Команды: |cffffcc00/mca|r (мои рецепты) · |cffffcc00/mca arl|r (все из ARL) · |cffffcc00/mca [Линк]|r (граф крафта)")
        end
    end
end