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

local CTL_VERSION = 6

local MAX_CPS = 1000			-- 2000 seems to be safe if NOTHING ELSE is happening. let's call it 1000.
local MSG_OVERHEAD = 40		-- Guesstimate overhead for sending a message; source+dest+chattype+protocolstuff

local BURST = 8000				-- WoW's server buffer seems to be about 32KB. Let's use 25% of it for our lib.

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

ChatThrottleLib.PipeBin = { count=0 }

function ChatThrottleLib.PipeBin:Put(pipe)
	for i=getn(pipe),1,-1 do
		tremove(pipe, i);
	end
	pipe.prev = nil;
	pipe.next = self.list;
	self.list = pipe;
	self.count = self.count+1;
end

function ChatThrottleLib.PipeBin:Get()
	if(self.list) then
		local ret = self.list;
		self.list = ret.next;
		ret.next=nil;
		self.count = self.count - 1;
		return ret;
	end
	return {};
end

function ChatThrottleLib.PipeBin:Tidy()
	if(self.count < 25) then
		return;
	end
		
	if(self.count > 100) then
		n=self.count-90;
	else
		n=10;
	end
	for i=2,n do
		self.list = self.list.next;
	end
	local delme = self.list;
	self.list = self.list.next;
	delme.next = nil;
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

function ChatThrottleLib.MsgBin:Tidy()
	if(getn(self)<50) then
		return;
	end
	if(getn(self)>150) then	 -- "can't happen" but ...
		for n=getn(self),120,-1 do
			tremove(self,n);
		end
	else
		for n=getn(self),getn(self)-20,-1 do
			tremove(self,n);
		end
	end
end


-----------------------------------------------------------------------
-- ChatThrottleLib:Init
-- Initialize queues, set up frame for OnUpdate, etc


function ChatThrottleLib:Init()	
	
	-- Set up queues
	if(not self.Prio) then
		self.Prio = {}
		self.Prio["ALERT"] = { ByName={}, Ring = Ring:New(), avail=0 };
		self.Prio["NORMAL"] = { ByName={}, Ring = Ring:New(), avail=0 };
		self.Prio["BULK"] = { ByName={}, Ring = Ring:New(), avail=0 };
	end
	
	-- v4: total send counters per priority
	for _,Prio in self.Prio do
		Prio.nTotalSent = Prio.nTotalSent or 0;
	end
	
	self.avail = self.avail or 0;							-- v5
	self.nTotalSent = self.nTotalSent or 0;		-- v5

	
	-- Set up a frame to get OnUpdate events
	if(not self.Frame) then
		self.Frame = CreateFrame("Frame");
		self.Frame:Hide();
	end
	self.Frame.Show = self.Frame.Show; -- cache for speed
	self.Frame.Hide = self.Frame.Hide; -- cache for speed
	self.Frame:SetScript("OnUpdate", self.OnUpdate);
	self.OnUpdateDelay=0;
	self.LastAvailUpdate=GetTime();
	
end


-----------------------------------------------------------------------
-- ChatThrottleLib:UpdateAvail
-- Update self.avail with how much bandwidth is currently available

function ChatThrottleLib:UpdateAvail()
	local now = GetTime();
	self.avail = min(BURST, self.avail + (MAX_CPS * (now-self.LastAvailUpdate)));
	self.LastAvailUpdate = now;
	return self.avail;
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
		Prio.nTotalSent = Prio.nTotalSent + msg.nSize;
		self.MsgBin:Put(msg);
	end
end



function ChatThrottleLib:OnUpdate()
	self = ChatThrottleLib;
	
	self.OnUpdateDelay = self.OnUpdateDelay + arg1;
	if(self.OnUpdateDelay < 0.08) then
		return;
	end
	self.OnUpdateDelay = 0;
	
	self:UpdateAvail();

	-- See how many of or priorities have queued messages
	local n=0;
	for prioname,Prio in pairs(self.Prio) do
		if(Prio.Ring.pos or Prio.avail<0) then 
			n=n+1; 
		end
	end
	
	-- Anything queued still?
	if(n<1) then
		-- Nope. Move spillover bandwidth to global availability gauge and clear self.bQueueing
		for prioname,Prio in pairs(self.Prio) do
			self.avail = self.avail + Prio.avail;
			Prio.avail = 0;
		end
		self.bQueueing = false;
		self.Frame:Hide();
		return;
	end
	
	-- There's stuff queued. Hand out available bandwidth to priorities as needed and despool their queues
	local avail= self.avail/n;
	self.avail = 0;
	
	for prioname,Prio in pairs(self.Prio) do
		if(Prio.Ring.pos or Prio.avail<0) then
			Prio.avail = Prio.avail + avail;
			if(Prio.Ring.pos and Prio.avail>Prio.Ring.pos[1].nSize) then
				self:Despool(Prio);
			end
		end
	end

	-- Expire recycled tables if needed	
	self.MsgBin:Tidy();
	self.PipeBin:Tidy();
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
	
	self.bQueueing = true;
end



function ChatThrottleLib:SendChatMessage(prio, prefix,   text, chattype, language, destination)
	if(not (self and prio and prefix and text and self.Prio[prio] ) ) then
		error('Usage: ChatThrottleLib:SendChatMessage("{BULK||NORMAL||ALERT}", "prefix", "text"[, "chattype"[, "language"[, "destination"]]]', 0);
	end
	
	local nSize = strlen(text) + MSG_OVERHEAD;
	
	-- Check if there's room in the global available bandwidth gauge to send directly
	if(not self.bQueueing and nSize < self:UpdateAvail()) then
		self.avail = self.avail - nSize;
		SendChatMessage(text, chattype, language, destination);
		self.Prio[prio].nTotalSent = self.Prio[prio].nTotalSent + nSize;
		return;
	end
	
	-- Message needs to be queued
	msg=self.MsgBin:Get();
	msg.f=SendChatMessage
	msg[1]=text;
	msg[2]=chattype or "SAY";
	msg[3]=language;
	msg[4]=destination;
	msg.n = 4
	msg.nSize = nSize;

	self:Enqueue(prio, prefix.."/"..chattype.."/"..(destination or ""), msg);
end


function ChatThrottleLib:SendAddonMessage(prio,   prefix, text, chattype)
	if(not (self and prio and prefix and text and chattype and self.Prio[prio] ) ) then
		error('Usage: ChatThrottleLib:SendAddonMessage("{BULK||NORMAL||ALERT}", "prefix", "text", "chattype")', 0);
	end
	
	local nSize = strlen(prefix) + 1 + strlen(text) + MSG_OVERHEAD;
	
	-- Check if there's room in the global available bandwidth gauge to send directly
	if(not self.bQueueing and nSize < self:UpdateAvail()) then
		self.avail = self.avail - nSize;
		SendAddonMessage(prefix, text, chattype);
		self.Prio[prio].nTotalSent = self.Prio[prio].nTotalSent + nSize;
		return;
	end
	
	-- Message needs to be queued
	msg=self.MsgBin:Get();
	msg.f=SendAddonMessage;
	msg[1]=prefix;
	msg[2]=text;
	msg[3]=chattype;
	msg.n = 3
	msg.nSize = nSize;
	
	self:Enqueue(prio, prefix.."/"..chattype, msg);
end




-----------------------------------------------------------------------
-- Get the ball rolling!

ChatThrottleLib:Init();

--[[
if(WOWB_VER) then
	local function Bleh()
		print("SAY: "..GetTime().." "..arg1);
	end
	ChatThrottleLib.Frame:SetScript("OnEvent", Bleh);
	ChatThrottleLib.Frame:RegisterEvent("CHAT_MSG_SAY");
end
]]


