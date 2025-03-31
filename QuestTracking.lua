local TourGuide = TourGuide
local L = TourGuide.Locale
local hadquest


TourGuide.TrackEvents = {"UI_INFO_MESSAGE", "CHAT_MSG_LOOT", "CHAT_MSG_SYSTEM", "QUEST_WATCH_UPDATE", "QUEST_LOG_UPDATE", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
	"MINIMAP_ZONE_CHANGED", "ZONE_CHANGED_NEW_AREA", "PLAYER_LEVEL_UP", "ADDON_LOADED", "CRAFT_SHOW", "PLAYER_DEAD", "BAG_UPDATE"}


function TourGuide:ADDON_LOADED(event, addon)
	if addon ~= "Blizzard_TrainerUI" then return end

	self:UnregisterEvent("ADDON_LOADED")

	local f = CreateFrame("Frame", nil, ClassTrainerFrame)
	f:SetScript("OnShow", function() if self:GetObjectiveInfo() == "TRAIN" then self:SetTurnedIn() end end)
end


function TourGuide:PLAYER_LEVEL_UP(event, newlevel)
	local level = tonumber((self:GetObjectiveTag("LV")))
	self:Debug( "PLAYER_LEVEL_UP", newlevel, level)
	if level and newlevel >= level then self:SetTurnedIn() end
end


function TourGuide:ZONE_CHANGED(a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18,a19,a20)
	local zonetext, subzonetext, subzonetag, action, quest = GetZoneText(), GetSubZoneText(), self:GetObjectiveTag("SZ"), self:GetObjectiveInfo()
	if (action == "RUN" or action == "FLY" or action == "HEARTH" or action == "BOAT") and (subzonetext == quest or subzonetext == subzonetag or zonetext == quest or zonetext == subzonetag) then
		self:Debug( string.format("Detected zone change %q - %q", action, quest))
		self:SetTurnedIn()
	end
end
TourGuide.ZONE_CHANGED_INDOORS = TourGuide.ZONE_CHANGED
TourGuide.MINIMAP_ZONE_CHANGED = TourGuide.ZONE_CHANGED
TourGuide.ZONE_CHANGED_NEW_AREA = TourGuide.ZONE_CHANGED


function TourGuide:CHAT_MSG_SYSTEM(msg)
	local action, quest = self:GetObjectiveInfo()

	local _, _, loc = string.find(msg,L["(.*) is now your home."])
	if loc then
		self:Debug( string.format("Detected setting hearth to %q", loc))
		self.db.char.hearth = loc
		return action == "SETHEARTH" and loc == quest and self:SetTurnedIn()
	end

	if action == "ACCEPT" then
		local _, _, text = string.find(msg,L["Quest accepted: (.*)"])
		if text and string.gsub(quest,L.PART_GSUB, "") == text then
			self:Debug( string.format("Detected quest accept %q", quest))
			return self:UpdateStatusFrame()
		end
	end

	if action == "PET" then
		local _, _, text = string.find(msg,L["You have learned a new spell: (.*)."])
		local nextEntry = table.getn(self.db.char.petskills) + 1
		self.db.char.petskills[nextEntry] = text
		if text and quest == text then
			self:Debug( string.format("Detected pet skill train %q", quest))
			return self:SetTurnedIn()
		end
	end
end


function TourGuide:QUEST_WATCH_UPDATE(event)
	if self:GetObjectiveInfo() == "COMPLETE" then self:UpdateStatusFrame() end
end


function TourGuide:QUEST_LOG_UPDATE(event)
	local action = self:GetObjectiveInfo()
	local _, logi, complete = self:GetObjectiveStatus()

	self:Debug( "QUEST_LOG_UPDATE", action, logi, complete)

	if (self.updatedelay and not logi) or action == "ACCEPT" or action == "COMPLETE" and complete then self:UpdateStatusFrame() end

	if action == "KILL" or action == "NOTE" then
		local quest, questtext = self:GetObjectiveTag("Q"), self:GetObjectiveTag("QO")
		if not quest or not questtext then return end

		local qi = self:GetQuestLogIndexByName(quest)
		for i=1,GetNumQuestLeaderBoards(qi) do
			if GetQuestLogLeaderBoard(i, qi) == questtext then self:SetTurnedIn() end
		end
	elseif action == "COMPLETE" then
		local skipNext = self:GetObjectiveTag("S")
		if self.db.char.skipfollowups and skipNext and QuestFrame:IsVisible() then
			CloseQuest()
			TourGuide:Print(L["Automatically skipping the follow-up"])
		end
	end
end


function TourGuide:CHAT_MSG_LOOT(event, msg)
	local action, quest = self:GetObjectiveInfo()
	local lootitem, lootqty = self:GetObjectiveTag("L")
	local _, _, itemid, name = string.find(msg,L["^You .*Hitem:(%d+).*(%[.+%])"])
	self:Debug( event, action, quest, lootitem, lootqty, itemid, name)

	if action == "BUY" and name and name == quest
	or (action == "BUY" or action == "KILL" or action == "NOTE" or action == "LOOT") and lootitem and itemid == lootitem and (self.GetItemCount(lootitem) + 1) >= lootqty then
		return self:SetTurnedIn()
	end
end


function TourGuide:PLAYER_DEAD()
	if self:GetObjectiveInfo() == "DIE" then
		self:Debug( "Player has died")
		self:SetTurnedIn()
	end
end


function TourGuide:UI_INFO_MESSAGE(event, msg)
	if msg == ERR_NEWTAXIPATH and self:GetObjectiveInfo() == "GETFLIGHTPOINT" then
		self:Debug( "Discovered flight point")
		self:SetTurnedIn()
	end
end


function TourGuide:CRAFT_SHOW()
	if not GetCraftName() == "Beast Training" then return end
	for i=1,GetNumCrafts() do
		local name, rank = GetCraftInfo(i)
		self.db.char.petskills[name.. (rank == "" and "" or (" (" .. rank .. ")"))] = true
	end
	if self:GetObjectiveInfo() == "PET" then self:UpdateStatusFrame() end
end


--[[ 
    ITEM DETECTION FUNCTIONS
    These functions handle automatic detection of items 
    for LOOT objectives. Automatically marks LOOT steps complete 
    when required items are in inventory.
--]]

-- Check if a player has the required items for the current LOOT objective
function TourGuide:CheckCurrentStepItems()
	-- Check if this is a LOOT objective
	local action, quest = self:GetObjectiveInfo()
	if action ~= "LOOT" then return false end
	
	-- Check if we have specific loot info from the step's tag
	local lootitem, lootqty = self:GetObjectiveTag("L")
	if lootitem then
		lootqty = tonumber(lootqty) or 1
		local itemCount = self.GetItemCount(lootitem)
		self:Debug("CheckCurrentStepItems", action, quest, "ItemID:", lootitem, "Count:", itemCount, "Required:", lootqty)
		
		-- Return true if we have enough items
		if itemCount >= lootqty then
			self:Debug("LOOT item requirement met (ItemID):", quest)
			return true
		end
	end
	
	-- Fall back to parsing the quest text (for backward compatibility)
	local count, item = string.match(quest, "^(%d+)%s+(.+)$")
	if not count or not item then 
		-- Try matching without count (assumes 1)
		count, item = 1, quest
		-- Still need a basic check if item is likely just text
		if string.find(item, "%s") then 
			return false -- Failed to parse and item contains spaces, likely not a simple item name
		end
	end 
	
	count = tonumber(count) or 1
	
	-- Check if we have enough items
	local itemCount = 0
	for bag = 0, 4 do
		for slot = 1, GetContainerNumSlots(bag) do
			local link = GetContainerItemLink(bag, slot)
			
			-- Use string pattern matching on item links
			if link then
				-- Extract the item name from the link (which appears between [ and ])
				local itemName = string.match(link, "%[(.-)%]")
				if itemName and itemName == item then
					local _, stackCount = GetContainerItemInfo(bag, slot)
					itemCount = itemCount + stackCount
				end
			end
		end
	end
	
	self:Debug("CheckCurrentStepItems", action, quest, "Item:", item, "Count:", itemCount, "Required:", count)
	
	-- Return true if we have enough items
	if itemCount >= count then
		self:Debug("LOOT item requirement met (Parsed Text):", quest)
		return true
	end
	
	return false -- Did not meet parsed text requirement
end

-- Bag update event handler
function TourGuide:BAG_UPDATE(event)
	-- Call the check function, but it won't do anything unless the current step is LOOT
	if self:CheckCurrentStepItems() then
		-- If the check returns true, it means we just got the last item needed
		-- We need to mark the step complete
		self:SetTurnedIn() 
	end
end

local orig = GetQuestReward
GetQuestReward = function(a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18,a19,a20)
	local quest = string.gsub(GetTitleText(), "%[[0-9%+%-]+]%s", "")
	
	TourGuide:Debug( "GetQuestReward", quest)
	TourGuide:CompleteQuest(quest, true)

	return orig(a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18,a19,a20)
end
