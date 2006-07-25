--
-- ChatThrottleLib by Mikk
--
-- Manages AddOn chat output to keep player from getting kicked off.
--
-- ChatThrottleLib.SendChatMessage/.SendAddonMessage functions that accept 
-- a Priority ("BULK", "NORMAL", "ALERT") as well as prefix for SendChatMessage.
--
-- Priorities get an equal share of available bandwidth when fully loaded.
-- Communication channels are separated on extension+chattype+destination and
-- get round-robinned. (Destination only matters for whispers and channels,
-- obviously)
--
-- Can optionally install hooks for SendChatMessage and SendAdd[Oo]nMessage 
-- to prevent addons not using this library from overflowing the output rate.
-- Note however that this is somewhat controversional.
--
--
-- Fully embeddable library. Just copy this file into your addon directory,
-- add it to the .toc, and it's done.
--
-- Can run as a standalone addon also, but, really, just embed it! :-)
--

local CTL_VERSION = 2

local MAX_CPS = 1000			-- 2000 seems to be safe if NOTHING ELSE is happening. let's call it 1000.
local MSG_OVERHEAD = 40		-- Guesstimate overhead for sending a message; source+dest+chattype+protocolstuff


if(ChatThrottleLib and ChatThrottleLib.version>=CTL_VERSION) then
	-- There's already a newer (or same) version loaded. Buh-bye.
	return;
end



if(not ChatThrottleLib) then
	ChatThrottleLib = {}
end

ChatThrottleLib.version=CTL_VERSION;



-----------------------------------------------------------------------
-- Double-linked ring implementation

local Ring = {}
local RingMeta = { __index=Ring }

function Ring:New()
	local ret = {}
	setmetatable(ret, RingMeta)
	return ret;
end

function Ring:Add(obj)	-- Append at the "far end" of the ring (aka just before the current position)
	if(self.pos) then
		obj.prev = self.pos.prev;
		obj.prev.next = obj;
		obj.next = self.pos;
		obj.next.prev = obj;
	else
		obj.next = obj;
		obj.prev = obj;
		self.pos = obj;
	end
end

function Ring:Remove(obj)
	obj.next.prev = obj.prev;
	obj.prev.next = obj.next;
	if(self.pos == obj) then
		self.pos = obj.next;
		if(self.pos == obj) then
			self.pos = nil;
		end
	end
end



-----------------------------------------------------------------------
-- Recycling bin for pipes (kept in a linked list because that's 
-- how they're worked with in the rotating rings; just reusing members)

ChatThrottleLib.PipeBin = {}

function ChatThrottleLib.PipeBin:Put(pipe)
	for i=getn(pipe),1,-1 do
		tremove(pipe, i);
	end
	pipe.prev = nil;
	pipe.next = self.list;
	self.list = pipe;
end

function ChatThrottleLib.PipeBin:Get()
	if(self.list) then
		local ret = self.list;
		self.list = ret.next;
		ret.next=nil;
		return ret;
	end
	return {};
end




-----------------------------------------------------------------------
-- Recycling bin for messages

ChatThrottleLib.MsgBin = {}

function ChatThrottleLib.MsgBin:Put(msg)
	msg.text = nil;
	tinsert(self, msg);
end

function ChatThrottleLib.MsgBin:Get()
	local ret = tremove(self, getn(self));
	if(ret) then return ret; end
	return {};
end




-----------------------------------------------------------------------
-- ChatThrottleLib:Init
-- Initialize queues, set up frame for OnUpdate, etc


function ChatThrottleLib:Init()	
	
	-- Remember original SendChatMessage in case the addon wants to hook
	if(not self.Orig_SendChatMessage) then
		self.Orig_SendChatMessage = SendChatMessage;
	end
	
	-- ... and SendAddonMessage (SendAddOnMessage too in case Slouken changes his mind and fixes the capitalization)
	if(not self.Orig_SendAddonMessage) then
		self.Orig_SendAddonMessage = SendAddOnMessage or SendAddonMessage;
	end

	-- Set up queues
	if(not self.Prio) then
		self.Prio = {}
		self.Prio["ALERT"] = { ByName={}, Ring = Ring:New(), avail=0 };
		self.Prio["NORMAL"] = { ByName={}, Ring = Ring:New(), avail=0 };
		self.Prio["BULK"] = { ByName={}, Ring = Ring:New(), avail=0 };
	end
	
	-- Set up a frame to get OnUpdate events
	if(not self.Frame) then
		self.Frame = CreateFrame("Frame");
		self.Frame:Hide();
	end
	self.Frame:SetScript("OnUpdate", self.OnUpdate);
	self.OnUpdateDelay=0;
	self.LastDespool=GetTime();
	
end


-----------------------------------------------------------------------
-- ChatThrottleLib:Hook
--
-- Call this if you want ALL system chat output to go via ChatThrottleLib
-- to prevent AddOns not aware of the lib from outputting masses of
-- chat "on the side" and overflowing the output rate limit.
--
-- Note that this is somewhat controversial.
--

function ChatThrottleLib:Hook()
	-- Hook SendChatMessage
	if(not self.bHooked_SendChatMessage) then
		self.bHooked_SendChatMessage = true;
		SendChatMessage = function(a1,a2,a3,a4) return ChatThrottleLib:SendChatMessage("NORMAL", "", a1,a2,a3,a4) end
	end
	
	-- Hook SendAddonMessage (SendAddOnMessage too in case Slouken changes his mind and fixes the capitalization)
	if(not self.bHooked_SendAddonMessage) then
		self.bHooked_SendAddonMessage = true;
		SendAddonMessage = function(a1,a2,a3,a4) return ChatThrottleLib:SendAddonMessage("NORMAL", a1,a2,a3,a4) end
		SendAddOnMessage = SendAddonMessage;
	end
end


-----------------------------------------------------------------------
-- Despooling logic

function ChatThrottleLib:Despool(Prio)
	local ring = Prio.Ring;
	while(ring.pos and Prio.avail>ring.pos[1].nSize) do
		local msg = tremove(Prio.Ring.pos, 1);
		if(not Prio.Ring.pos[1]) then
			local pipe = Prio.Ring.pos;
			Prio.Ring:Remove(pipe);
			Prio.ByName[pipe.name] = nil;
			self.PipeBin:Put(pipe);
		else
			Prio.Ring.pos = Prio.Ring.pos.next;
		end
		Prio.avail = Prio.avail - msg.nSize;
		msg.f(msg[1], msg[2], msg[3], msg[4]);
	end
end



function ChatThrottleLib:OnUpdate()
	self = ChatThrottleLib;
	self.OnUpdateDelay = self.OnUpdateDelay + arg1;
	if(self.OnUpdateDelay < 0.08) then
		return;
	end
	self.OnUpdateDelay = 0;
	
	local now = GetTime();
	local avail = min(MAX_CPS * (now-self.LastDespool), MAX_CPS*0.2);
	self.LastDespool = now;
	
	local n=0;
	for prioname,Prio in pairs(self.Prio) do
		if(Prio.Ring.pos or Prio.avail<0) then n=n+1; end
	end
	
	if(n<1) then
		for prioname,Prio in pairs(self.Prio) do
			Prio.avail = 0;
		end
		self.Frame:Hide();
		return;
	end

	avail=avail/n;
	
	for prioname,Prio in pairs(self.Prio) do
		if(Prio.Ring.pos or Prio.avail<0) then
			Prio.avail = Prio.avail + avail;
			if(Prio.Ring.pos and Prio.avail>Prio.Ring.pos[1].nSize) then
				self:Despool(Prio);
			end
		end
	end
	
end




-----------------------------------------------------------------------
-- Spooling logic


function ChatThrottleLib:Enqueue(prioname, pipename, msg)
	local Prio = self.Prio[prioname];
	local pipe = Prio.ByName[pipename];
	if(not pipe) then
		self.Frame:Show();
		pipe = self.PipeBin:Get();
		pipe.name = pipename;
		Prio.ByName[pipename] = pipe;
		Prio.Ring:Add(pipe);
	end
	
	tinsert(pipe, msg);
end


function ChatThrottleLib:SendChatMessage(prio, prefix,   text, chattype, language, destination)
	assert(self and prio and prefix and text and chattype and (prio=="NORMAL" or prio=="BULK" or prio=="ALERT"),
		'Usage: ChatThrottleLib:SendChatMessage("{BULK|NORMAL|ALERT}", "prefix", "text", "chattype"[, "language"[, "destination"]]');
	
	msg=self.MsgBin:Get();
	msg.f=self.Orig_SendChatMessage
	msg[1]=text;
	msg[2]=chattype;
	msg[3]=language;
	msg[4]=destination;
	table.setn(msg,4);
	msg.nSize = strlen(text) + MSG_OVERHEAD;

	self:Enqueue(prio, prefix.."/"..chattype.."/"..(destination or ""), msg);
end


function ChatThrottleLib:SendAddonMessage(prio,   prefix, text, chattype)
	assert(self and prio and prefix and text and chattype and (prio=="NORMAL" or prio=="BULK" or prio=="ALERT"),
		'Usage: ChatThrottleLib:SendAddonMessage("{BULK|NORMAL|ALERT}", "prefix", "text", "chattype")');
	
	msg=self.MsgBin:Get();
	msg.f=self.Orig_SendAddonMessage;
	msg[1]=prefix;
	msg[2]=text;
	msg[3]=chattype;
	setn(msg,3);
	msg.nSize = strlen(text) + MSG_OVERHEAD;
	
	self:Enqueue(prio, prefix.."/"..chattype, msg);
end




-----------------------------------------------------------------------
-- Get the ball rolling!

ChatThrottleLib:Init();


--[[
if(WOWB_VER) then
	function Bleh()
		print("SAY: "..GetTime().." "..arg1);
	end
	ChatThrottleLib.Frame:SetScript("OnEvent", Bleh);
	ChatThrottleLib.Frame:RegisterEvent("CHAT_MSG_SAY");
end
]]