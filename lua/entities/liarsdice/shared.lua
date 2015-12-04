
-- Tread softly traveller, ugly code awaits you

--search for *
--Clean up code and comments
if SERVER then
	AddCSLuaFile() 
	
	--Server to Client
	util.AddNetworkString("ldPreGameJoin")
	util.AddNetworkString("ldPlayerInfoUpdate")
	util.AddNetworkString("ldHostGame")
	util.AddNetworkString("ldWinGame")
	--Client to Server
	util.AddNetworkString("ldNewAI") 	-- 
	util.AddNetworkString("ldRemoveAI") --consider merging to form toggleAI
	util.AddNetworkString("ldLeaveGame")
	util.AddNetworkString("ldVoteStart") -- Rename
	--2 way
	util.AddNetworkString("ldMakeBet")
	util.AddNetworkString("ldCallBluff")
	util.AddNetworkString("ldNewGame")
	util.AddNetworkString("ldNewRound")

	
   --CreateConVar( "chess_wagers", 1, FCVAR_ARCHIVE, "Set whether players can wager on their chess games." )

end

ENT.Base 			= "base_gmodentity" --*or base_anim?
ENT.Type 			= "anim"
ENT.PrintName		= "Liar's Dice"
ENT.Author			= "ChrisspyB"
ENT.Contact			= "http://steamcommunity.com/id/chrisspyb"
ENT.Purpose			= "You're a liar and you will spend an eternity aboard this ship!"
ENT.Category		= "Fun + Games"
ENT.Spawnable 		= true
ENT.AdminSpawnable 	= true

local MODELS = { 
	["placeholder"] = Model("models/props_c17/oildrum001.mdl"),
	["chair"] 		= Model("models/nova/chair_plastic01.mdl"),
	["table"] 		= Model("models/props_c17/furnituretable001a.mdl"),
	["camera"]		= Model("models/dav0r/camera.mdl")
}

local MAXPLAYERS 		= 6 -- Things will break if this is greater than 4bit
local MAXDICE 			= 6	-- Things will break if this is greater than 4bit
local MAXTURNTIME		= 15 -- Players who take too long will auto-bid

local STATE_presetup 	= 0
local STATE_pregame 	= 1
local STATE_gamestart	= 2
local STATE_roundstart 	= 3
local STATE_roundinprog	= 4
local STATE_roundend	= 5
local STATE_gameend 	= 6

local DEBUGMODE			= true -- console will print useful game info as it happens



function ENT:SetupDataTables()
	self:NetworkVar( "Int", 0, "GameState" )
	self:NetworkVar( "Int", 1, "CurrentPlayers" )
	
	self:NetworkVar('Entity',0,'TurnPlayer') -- Who's turn is it? 
		
end
function ENT:SpawnFunction( ply, tr, ClassName )

	if ( !tr.Hit ) then return end
	
	local SpawnPos = tr.HitPos + tr.HitNormal*18
	
	local ent = ents.Create( ClassName )
	ent:SetPos( SpawnPos )
	ent:Spawn()
	
	return ent
	
end

function ENT:Initialize()
	if SERVER then
		local pos,ang = self:GetPos(),self:GetAngles()
		self:SetModel( MODELS["placeholder"] )
		self:SetModelScale( 0.125, 0 )
		self:SetMoveType( MOVETYPE_NONE )
		--self:PhysicsInit( SOLID_BBOX )
		self:SetCollisionGroup( COLLISION_GROUP_PLAYER )
		self:DrawShadow( false )
		
		
		local tbl = ents.Create( "prop_physics" )
		tbl:SetModel( MODELS["table"] )
		tbl:Spawn()
		tbl:SetCollisionGroup( COLLISION_GROUP_PLAYER )
		tbl:PhysicsInit( SOLID_BBOX )
		tbl:SetMoveType( MOVETYPE_NONE )
		tbl:SetPos(pos)
		
		tbl:SetHealth(100000) -- preferably indestructable...*
		self.tableEnt = tbl
		
		
		self.camera = ents.Create( "prop_physics" )
		self.camera:SetModel(MODELS["camera"])
		self.camera:SetPos(pos+Vector(0,0,40))
		self.camera:SetAngles(ang+Angle(30,0,0))
		self.camera:Spawn()
		self.camera:SetMoveType(MOVETYPE_NONE)
		self.camera:SetSolid(SOLID_NONE)	
		self.camera:SetParent(tbl)	
		
		self.chairDir = {} --list of unit vectors from pos to chair, useful for camera
		self.chairEnts = {}
		self:AddChairs(1)
		
		self.gameInProg = false;
		self.players = {}
		self.maxDice = 5 -- number of dice allowed in current table
		
		self:SetGameState(STATE_presetup)
		self.playerInfo = {}
		self.lastBet = {}
		self.turnIndex = 1 --whose turn it is. Player 1 always goes first on round 1
		self.canSpotOn = false --Are spot on rules enabled?
		self.canWild = false --Are wild ones enabled?
		self.wildOdds = 0 -- Probability that any round will be a wild round
		self.wildRound = false --Are wild ones enabled?

		-- self.camPlace = {} -- [i][1]["pos"] [i][1]["ang"] i = player j = which placement 
	end
	
end
function ENT:OnRemove()
	if SERVER then
		if IsValid(self.tableEnt ) then self.tableEnt:Remove() end --* ALSO DEFINE A REMOVE FUNCTION SOMEWHERE FOR THE TABLE SO IT REMOVES THE ENTITY
		for i=1,#self.chairEnts do 
			if IsValid(self.chairEnts[i]) then self.chairEnts[i]:Remove() end
		end
		if IsValid(self.camera) then self.camera:Remove() end
		
	end
	if CLIENT then

	end
end
function ENT:OnTakeDamage(dmg)
end
function ENT:Think()
	if CLIENT then return end
end

function IsBluff(t, n, d, s, w)
	--[[
		s=false: Returns true if table of dice t has at least n dice with face d
		s=true: Returns true if table of dice t has exactly n dice with face d
		w=true: 'ones' can take any value (they are wild)
	]]
	local s = s or false
	local w = w or false
	local a = 0
	for i=1,#t do
		for j=1,#t[i] do
			print('check',t[i][j],d)
			if t[i][j]==d or (w and t[i][j]==1) then
				a=a+1
				if  s and a>n then return false end 
			end
		end
	end
	if s and a==n then return true
	elseif a<n and not s then return true end 
	print('generic false',s,a,n)
	return false
end

function SortDice(t)
	local a = {}
	for i=1,6 do
		for j=1, #t do
			if t[j]==i then
				table.insert(a,t[j])
				if #a == #t then return a end
			end
		end
	end
	return a 
end

if SERVER then
	function ENT:SetupGame(p,d,h)
		self.maxDice = d
		self:AddChairs(p)
		self:SetGameState(STATE_pregame)
		self.playerInfo={}
		for i=1, p do
			self.playerInfo[i]={}
			self.playerInfo[i][1]=false	-- isAi
			self.playerInfo[i][2]=NULL	-- player obj
			self.playerInfo[i][3]=d
		end
		self.playerInfo[1][2]=h
		net.Start('ldPreGameJoin')
			net.WriteBool(self.canSpotOn)
			net.WriteBool(self.canWild) --*Needed?
		net.Send(h)
	end
	function ENT:BeginGame()
		--[[
			Indentify player indicies
		]]		
		self.gameInProg=true
		self:SetGameState(STATE_gamestart)
		--
		self:BeginRound()
	end
	function ENT:BeginRound()
		print('Begin round has been called',#self.players)
		--[[
			Generate dice and send to corresponding player
		]]
		--Or make them spectators, this would be ideal actually*
		self.cameraIndex = 1
		timer.Create('CameraTimer',1,0, function()
			if not IsValid(self.camera) then timer.Stop('CameraTimer') return end --* ideally the timer would also destroy it self
			local v = self.chairDir[self.turnIndex]
			local ang = v:Angle()
			if self.cameraIndex < 2 then
				self.camera:SetAngles(ang)
				self.camera:SetPos(self.tableEnt:GetPos()+ang:Up()*30)
			elseif self.cameraIndex < 3 then
				self.camera:SetPos(self.tableEnt:GetPos()+ v*20 + self.tableEnt:GetAngles():Up()*40)
				self.camera:SetAngles(ang+Angle(30,0,0))
			elseif self.cameraIndex < 4 then
				self.camera:SetPos(self.tableEnt:GetPos()+ v*60 + self.tableEnt:GetAngles():Up()*55 + self.tableEnt:GetAngles():Right() *20) 
				self.camera:SetAngles(ang+Angle(30,180,0))
			end			
			
			self.cameraIndex=self.cameraIndex < 3 and self.cameraIndex+1 or 1
		end)
		self.lastBet = {0,0,0}
		if self.chairEnts[self.turnIndex].diceNo<1 then
			self.turnIndex = self:NextPlayerInd(self.turnIndex)
		end
		if self.canWild then
			if math.random(0,1)<= self.wildOdds then
				self.wildRound = true
			else
				self.wildRound = false
			end
		end
		if self.playerInfo[self.turnIndex][1] then
			print('ai timer')
			timer.Simple(2, function() 	
				if not IsValid(self) then return end
				self:NextMoveAI(self.turnIndex)  
			end)
		end
		for i=1, #self.playerInfo do
			if self.chairEnts[i].diceNo<1 then
				if self.playerInfo[i][1] then
					self:RemoveAI(i)
				elseif self.playerInfo[i][2]:IsPlayer() then
		--			self.playerInfo[i][2]:ExitVehicle()
				end
			end
			self.playerInfo[i][3] = self.chairEnts[i].diceNo
			self.playerInfo[i][4] = 0
			self.playerInfo[i][5] = 0
			if self.playerInfo[i][2]:IsPlayer() or self.playerInfo[i][1] then
				self.chairEnts[i]:Fire('lock')
				self:GenDice(self.chairEnts[i])
			else
				self.chairEnts[i].dice={}
				self.chairEnts[i]:Fire('lock')
				self.chairEnts[i]:SetColor(Color(255,0,0))	
			end
			
		end
		
	end
	function ENT:NewBet(i,n,d)
		--[[
		
			Register the new bet and allow the next player/AI to move	
		]]
		local j = self:NextPlayerInd(i)
		if i==j then
			--Either only one player left or something has gone horribly wrong.
			self:EndGame(i)
			return
		end
		self.playerInfo[i][4]=n --*needed?
		self.playerInfo[i][5]=d --*needed?
		self.lastBet[1]=n
		self.lastBet[2]=d
		self.lastBet[3]=i
		print(i,n,d)
		net.Start('ldMakeBet')
			net.WriteInt(i,5)
			net.WriteInt(n,9)
			net.WriteInt(d,4)
		net.Send(self.players)
		
		self.turnIndex=j
		if self.playerInfo[j][1] then
			self:NextMoveAI(j)
		end
	end
	function ENT:BluffCalled(index,spotOnCalled)
		--[[
			For display purposes, dice are sent to each client who will add them up.
			Server will also add up
			Index refers to the player calling the bluff
		]]
		local spotOnCalled = spotOnCalled or false
		local dTable = {}
		
		for i=1,#self.playerInfo do 
			dTable[i]=self.chairEnts[i].dice
		end
		local bluffing = IsBluff(dTable,self.lastBet[1],self.lastBet[2],spotOnCalled,self.wildRound)
		print(bluffing,spotOnCalled)
		net.Start('ldCallBluff')
			net.WriteTable(dTable) -- *Should they get this at the start? --*Should bluff really be calculated both client and serverside?
			net.WriteBool(spotOnCalled)
		net.Send(self.players)
		
		print('bluffing:',bluffing,'spot:',spotOnCalled)
		if bluffing and not spotOnCalled then
			--Guy was caught lying and spot on was not called. Guy loses die
			self.chairEnts[self.lastBet[3]].diceNo=self.chairEnts[self.lastBet[3]].diceNo-1
			self.playerInfo[self.lastBet[3]][3] = self.chairEnts[self.lastBet[3]].diceNo --*would rather not be using two identical vars
			self.turnIndex=self.lastBet[3]
			print(self.lastBet[3]..' loses a die')
			
		elseif bluffing and spotOnCalled then
			--Caught by a spot on. All but the caller lose a die.
			print('SERVER HAS SEEN THE SPOT ON')
			for i=1,#self.playerInfo do
				if i~=index then
					self.chairEnts[i].diceNo = self.chairEnts[i].diceNo - 1--*would rather not be using two identical vars
					self.playerInfo[i][3] = self.chairEnts[i].diceNo
				end
			end
		else
			--Guy was telling the truth. Caller loses die
			self.chairEnts[index].diceNo=self.chairEnts[index].diceNo-1
			self.playerInfo[index][3] = self.chairEnts[index].diceNo --*would rather not be using two identical vars
			self.turnIndex=index
			print(index..' loses a die')
		end
		timer.Simple(#self.playerInfo+7,function()
			if not IsValid(self) then return end
			local k = self:NextPlayerInd(1)
			if k ~= self:NextPlayerInd(k) then
				self:BeginRound()
			else
				self:EndGame(self.turnIndex)
			end
		end)
	end
	function ENT:EndRound()
		--[[
			Count dice, invoke punishments
		]]
		--must recieve player/index which called out
		--and what they called (spot on / bluff)
		
	end
	
	function ENT:EndGame(i)
		--[[
			Unlock chairs, 
		]]	
		print('ENDING GAME')
		self:SetGameState(STATE_gameend)
		self.chairEnts[i]:SetMaterial('models/player/shared/gold_player')
		timer.Simple(5,function() 
			if not IsValid(self) then return end
			self.chairEnts[i]:SetMaterial('') 
			self:ResetGame()
			end)
	end
	
	function ENT:ResetGame()
		--[[
			Restore the ent to spawn conditions
		]]
		self.players={}
		self.gameInProg = false
		for i=2,#self.chairEnts do 
			if IsValid(self.chairEnts[i]) then self.chairEnts[i]:Remove() end
		end
		local ch = self.chairEnts[1]
		self.chairEnts = {}
		self.chairEnts[1] = ch
		self:SetGameState(STATE_presetup)
	end
	function ENT:GenDice(chair)
		--[[
			Generate dice, send to players
		]]
		local t = {}
		for i=1,chair.diceNo do 
			t[i]=math.random(1,6)
		end
		chair.dice=SortDice(t)
			
			if DEBUGMODE then print('dice',chair.index,table.concat(chair.dice,', ')) end
		
		if not IsValid(chair:GetDriver()) then return end
		net.Start('ldNewRound')
			net.WriteBool(self.wildRound)
			net.WriteInt(self.turnIndex,5)
			net.WriteTable(chair.dice)
		net.Send(chair:GetDriver())
	end
	function ENT:AddChairs(n)
		--n: number of chairs after new additions have been made, NOT the number to add
		local pos=self.tableEnt:GetPos()
		local dAngDeg = 360/n
		local dAngRad = math.pi*dAngDeg/180
		local chairDist = 50
		for i=1,n-#self.chairEnts do
			if(n>MAXPLAYERS) then return end
			local chair = ents.Create( "prop_vehicle_prisoner_pod" )
			local v = (Vector(math.cos(dAngRad*i)*1,math.sin(dAngRad*i)*1,0)) -- dir from table to chair
			local angChair=Angle(0,90+dAngDeg*i,0)
			
			chair:SetModel(MODELS['chair'])
			chair:SetPos( v * chairDist + pos + Vector(0,0,-18) )
			chair:SetAngles( angChair )
			chair:Spawn()
			chair:SetMoveType( MOVETYPE_NONE )
			chair:SetCollisionGroup( COLLISION_GROUP_WORLD)
			chair:DrawShadow(false)
			chair:SetParent(self.tableEnt)
			chair.ldEnt = self
			chair.diceNo = self.maxDice
			chair.dice = {}
			chair.index = #self.chairEnts+1
			chair.exitOnUse = false -- can only leave chair by clicking "Quit Game", not by pressing USE.
			table.insert(self.chairEnts,chair)
			table.insert(self.chairDir,v)
			
			self.camera:SetPos(pos + Vector (0,0,30) )
			self.camera:SetAngles(Angle(0,dAngDeg*i,0))
			self.camera:SetParent(self.tableEnt)	

		end	
	end
	
	function ENT:UpdatePlayerInfo(i,b,ply)
		self.playerInfo[i][1]=b
		self.playerInfo[i][2]=ply
		net.Start('ldPlayerInfoUpdate')
			net.WriteInt(i,5)
			net.WriteBool(b)
			net.WriteEntity(ply)	
		net.Send(self.players)
	end
	
	function ENT:KickPlayer(ply)
		--tidy this up
		--[[
			Remove a player from the game
			Might need to do validity checks
			Might need to act differently depending on game state: EG LOCK SEAT IF GAME IN PROG, ETC
		]]
		print(#self.players)
		for i=1,#self.players do
			if self.players[i]==ply then
				table.remove(self.players,i)
				break
			end
		end
		
		if self:GetGameState()==STATE_pregame then
			self:UpdatePlayerInfo(ply.ldChair.index,false,NULL)
		end
		if #self.players <1 then
			--AND NOT WIN STATE: Win state should allow players to leave at will, resetting 5-10s after victory (allows winner to see w/e visuals I do)
			self:ResetGame()
		elseif self.gameInProg then
			ply.ldChair:Fire('lock')
			ply.ldChair:SetColor(Color(255,0,0))
		end
		ply.ldChair = NULL
		ply.ldEnt = NULL
		
		
		if DEBUGMODE then 
			print(ply:Nick()..' has left a Liars Dice Game')
			local str=tostring(#self.players)..' remaining player(s): '
			for i=1,#self.players do
				str = str..self.players[i]:Nick()..', '
			end
			print(str)
		end
		
	end
	function ENT:NewPlayer(ply)
		--[[
			Add a new player to the game
			Validity check done on hook
		]]

		if self.gameInProg then
			--this should not be reachable
			if DEBUGMODE then print(tostring(ply)..' cannot join liars dice: game in progress')end
			return
		end

		if self:GetGameState()==STATE_presetup then
			ply.ldChair = ply:GetVehicle()
			ply.ldEnt = self
			table.insert(self.players,ply)
			net.Start('ldHostGame')
			net.Send(ply)
			
		elseif self:GetGameState()==STATE_pregame then
			ply.ldChair = ply:GetVehicle()
			local i = ply.ldChair.index
			ply.ldEnt = self
			table.insert(self.players,ply)
			self.playerInfo[i][1]=false
			self.playerInfo[i][2]=ply
			net.Start('ldPreGameJoin')
				net.WriteBool(self.canSpotOn)
				net.WriteBool(self.canWild)
				net.WriteTable(self.playerInfo)
				
			net.Send(ply)
			
			self:UpdatePlayerInfo(i,false,ply)

		else return end
		
		
		if self:GetGameState()==STATE_pregame then
			
		end		
		
		if DEBUGMODE then 
			print(ply:Nick()..' has entered a Liars Dice Game')
			local str=tostring(#self.players)..' player(s) playing: '
			for i=1,#self.players do
				str = str..
				self.players[i]:Nick()..', '
			end
			print(str)
		end
		
	end
	function ENT:NextPlayerInd(i)
		--[[
			Identify who moves after i
		]]
		local j=i
		while true do 
			j=j+1
			if j==i then
				break
			elseif j>#self.playerInfo then j=0
			elseif self.playerInfo[j][3]>0 and (self.playerInfo[j][1] or self.playerInfo[j][2]:IsPlayer()) then
				break
			end
		end
		return j
	end
	function ENT:NewAI(i)
		self.playerInfo[i][1]=true
		self.playerInfo[i][2]=NULL
		self:UpdatePlayerInfo(i,true,NULL)
		self.chairEnts[i]:Fire('lock')
		self.chairEnts[i]:SetColor(Color(0,0,255))
	end
	function ENT:RemoveAI(i)
		self.playerInfo[i][1]=false
		self.playerInfo[i][2]=NULL
		self:UpdatePlayerInfo(i,false,NULL)
		if gameInProg then
			self.chairEnts[i]:SetColor(Color(255,0,0))
		else 
			self.chairEnts[i]:Fire('unlock')	
			self.chairEnts[i]:SetColor(Color(255,255,255))
		end
	end
	function ENT:NextMoveAI(i)
		--temp, needs to actually consider bets and be able to call bluff
		--*complete rework needed
		local a = math.random()
		local n=self.lastBet[1] 
		local d=self.lastBet[2]
		if n > 20 then
			self:BluffCalled(i)
			return
		end
		if a<0.5 and d<6 then
			d=d+1
		else
			n=n+1
			if a<0.5 then d=math.random(1,6) end
		end
		if n<1 then n=1 end if d<1 then d=1 end
		timer.Simple(2,function()
			if not IsValid(self) then return end
			-- n=1 d=2
			if self.wildOnes and d==1 then d=2 end
			self:NewBet(i,n,d) 
		end )
	end
	
	hook.Add( "PlayerEnteredVehicle", "LD PlayerSit", function( ply, veh )
		if not (IsValid(ply) and IsValid(veh)) then return end
		if not IsValid(veh.ldEnt) then return end
		veh.ldEnt:NewPlayer(ply)
		timer.Simple(1,function() ply:SetViewEntity(veh.ldEnt.camera) end)
		
		
	end)
	hook.Add( "PlayerLeaveVehicle", "LD PlayerSit", function( ply, veh )
		if not (IsValid(ply) and IsValid(veh)) then return end
		if not IsValid(veh.ldEnt) then return end
		veh.ldEnt:KickPlayer(ply)
		
		timer.Simple(1,function() ply:SetViewEntity(ply) end)
		
	end)
	hook.Add( "PlayerDisconnected", "LD PlayerDisconnect", function(ply)
		if IsValid(ply.ldEnt) then
			ply.ldEnt:KickPlayer(ply)
		end
	end)
	hook.Add( "CanExitVehicle", "LD PreventAccidentalLeave", function( veh, ply )
		if not (IsValid(ply) and IsValid(veh)) then return end
		if not( IsValid(ply.ldEnt) and IsValid(veh.ldEnt) and ply.ldEnt==veh.ldEnt )then return end
		if not veh.exitOnUse then return false end 
	end)
	net.Receive("ldLeaveGame", function(len,ply) 
		ply:ExitVehicle()
	end)
	net.Receive('ldVoteStart', function(len,ply)
		ply.ldEnt:BeginGame()
	end)
	net.Receive('ldNewGame',function(len,ply)
		local p = net.ReadInt(5)
		local d = net.ReadInt(5)
		ply:GetVehicle().diceNo = d
		ply:GetVehicle().ldEnt.canSpotOn = net.ReadBool()
		ply:GetVehicle().ldEnt.canWild = net.ReadBool()
		ply:GetVehicle().ldEnt.wildOdds = net.ReadFloat()
		ply:GetVehicle().ldEnt:SetupGame(p,d,ply)
	end)
	net.Receive('ldNewAI',function(len,ply)
		local i = net.ReadInt(5)
		ply.ldEnt:NewAI(i)
	end)
	net.Receive('ldRemoveAI',function(len,ply)
		local i = net.ReadInt(5)
		ply.ldEnt:RemoveAI(i)
	end)
	net.Receive('ldMakeBet',function(len,ply)
		local n = net.ReadInt(9)
		local d = net.ReadInt(4)
		local i = ply.ldChair.index
		ply.ldEnt:NewBet(i,n,d)
	end)
	net.Receive('ldCallBluff',function(len,ply)
		local b = net.ReadBool()
		ply.ldEnt:BluffCalled(ply.ldChair.index,b)
	end)
	net.Receive("ldNewRound", function(len,ply)
		print('Calling begin round')
		ply.ldEnt:BeginRound()
	end)
	net.Receive('ldWinGame',function(len,ply)
		ply.ldEnt:EndGame(ply.ldChair.index)
	end)
	end
	

if CLIENT then
	surface.CreateFont( "ldDerma20", {
		font = "Roboto",
		size = 20,
		weight = 500,
		blursize = 0,
		scanlines = 0,
		antialias = true,
		underline = false,
		italic = false,
		strikeout = false,
		symbol = false,
		rotary = false,
		shadow = false,
		additive = false,
		outline = false,
	} )
	surface.CreateFont( "ldDerma40", {
		font = "Roboto",
		size = 40,
		weight = 500,
		blursize = 0,
		scanlines = 0,
		antialias = true,
		underline = false,
		italic = false,
		strikeout = false,
		symbol = false,
		rotary = false,
		shadow = false,
		additive = false,
		outline = false,
	} )
	local conStrings = {} -- For displaying player info during pre game
	local playerInfo = {{false,NULL}} --[][1] = isAI; [][2] = Player; [][3] = #dice; [][4] = last bet:n; [][5] = last bet:d; where n=#dice, d=number on dice**Maybe don't record their last bet
	local lastBet = {0,0,0} -- n,d,plyInd
	local turnIndex = 1 -- player index whose turn it is
	local dTable = {} -- Received at end of round
	local playerResultsPanel = {} -- For storing the final results display. Used for adjusting color of winner/loser
	local totalDice = 0
	local counter = 0 --* use curTime instead
	local canSpotOn = false
	local wildOnes = false --* Needed?
	local wildRound = false 
	local activeFrame
	local localIndex
	local localEnt
	function NextPlayerInd(i)
		--[[
			Identify who moves after i
		]]
		local j=i
		while true do 
			j=j+1
			if j>#playerInfo then j=0
			elseif playerInfo[j][3]>0 and (playerInfo[j][1] or playerInfo[j][2]:IsPlayer()) then
				break
			elseif j==i then
				error('Could not find next player')
				break
			end
		end
		return j
	end
	local function DrawDie(x,y,s,n,hl)
		-- nice and all, but this whole thing is called many times every frame. Up the efficiency *
		hl = hl or false
		local col = Color(0,0,0)
		if hl then col = Color(0,200,0) end
		if n>6 or n<1 then return end
		--[[
			Used for drawing dice
			x,y = dice position on parent; n = dice value; s = size;
		]]
		local ds = s/4 --size of dice dots
		local sp = ds*1.25 --spacing between dots
		local r = 4 --corner radius of dots
		if s>80 then
			r=16
		end
		local t = 2 --thickness of outline, keep this even
		draw.RoundedBox(4,x-(s+t)/2,y-(s+t)/2,s+t,s+t, col)
		draw.RoundedBox(4,x-s/2,y-s/2,s,s, Color(255,255,255))
		x=x-ds/2 y=y-ds/2
		if n<7 and n>3 then 
			draw.RoundedBox(r,x-sp,y+sp,ds,ds, col)  			-- 1,1
			draw.RoundedBox(r,x+sp,y-sp,ds,ds, col)  			-- 3,3
			if n==6 then 
				draw.RoundedBox(r,x-sp,y,ds,ds, col) 			-- 1,2
				draw.RoundedBox(r,x+sp,y,ds,ds, col)  			-- 3,2
			end
		end
		if n%2==1 then 
			draw.RoundedBox(r,x,y,ds,ds, col) 					-- 2,2
			
		end
		if n~=1 then 
				draw.RoundedBox(r,x-sp,y-sp,ds,ds, col)  		-- 1,3
				draw.RoundedBox(r,x+sp,y+sp,ds,ds, col)  		-- 3,1
			end
		
		
	end
	local function BrightenCol(color,b)
		local col = Color(color.r,color.g,color.b,color.a)
		local i = col.r + b
		col.r = (i<255) and i or 255
		i = col.g + b
		col.g = (i<255) and i or 255
		i = col.b + b
		col.b = (i<255) and i or 255
		return col
	end
	local function DrawBet(x,y,size,n,d)
		local s=0
		local f=''
		if size<1 then s = 30 f="ldDerma20"
		else s = 100 f="ldDerma40"end
		if n<1 and d <1 then
			draw.SimpleText("N/A",f,x+s,y-10,Color(255,255,255,255))
		else
			DrawDie(x,y,s,d)
			draw.SimpleText("*  "..tostring(n),f,x+s,y-10,Color(255,255,255,255))
		end
	end
	local function DrawPlayerPanel(parent,i)
		local inf = playerInfo[i]
		local ply = inf[2]
		local col = Color(100,100,100)
		local colTurn = Color(200,150,25)
		if  inf[3]>0 and ( ply:IsPlayer() or inf[1] )then col = Color(50,50,175)
		end
		local color1 = col
		local color1B = BrightenCol(col,40)
		local color2 = colTurn
		local color2B = BrightenCol(colTurn,40)
		
		local plyPanel = vgui.Create('DPanel',parent)
		plyPanel:SetSize(ScrW()/4,90)
		plyPanel:SetPos(3*ScrW()/4,90*(i-1))
		if inf[3]>0 and (ply:IsPlayer() or inf[1]) then
			local name = 'Bot Jr.'
			if ply:IsPlayer() then name = ply:Nick() end
			local str = 'Has '..inf[3]..' dice'
			function plyPanel:Paint(w,h)
				-- somewhere, check if it is this guy's turn and color accordingly (either green or time dependent gradient)
				draw.RoundedBox(4,0,0,w,h, Color(0,0,0,255))
				if i==turnIndex then
					draw.RoundedBox(4,1,1,w-2,h-2, colTurn)
					if (timer.TimeLeft('AutoBid')~=nil and timer.TimeLeft('AutoBid')>0) then 
						draw.SimpleText(tostring(math.floor(timer.TimeLeft('AutoBid'))),'default',w-20,20,Color(255,255,0)) 
					end
				else draw.RoundedBox(4,1,1,w-2,h-2, col) end
				draw.SimpleText(name,"DermaLarge",80,10,Color(255,255,255,255))
				draw.SimpleText(str,"ldDerma20",80,40,Color(255,255,255,255))
				draw.SimpleText("Last Bet: ","ldDerma20",80,60,Color(255,255,255,255))
				DrawBet(200,60,0,inf[4],inf[5])
			end
			
			local av = vgui.Create("AvatarImage", plyPanel)
			av:SetPos(8,12)
			av:SetSize(64, 64)
			av:SetPlayer( ply, 64 )
			function av:OnCursorEntered()
				col = color1B
				colTurn = color2B
			end
			function av:OnCursorExited()
				col = color1
				colTurn = color2
			end
			
		else
			function plyPanel:Paint(w,h)
				draw.RoundedBox(4,0,0,w,h, Color(0,0,0,255))
				draw.RoundedBox(4,1,1,w-2,h-2, col)
				draw.SimpleText('Chair Empty!',"DermaLarge",80,10,Color(255,255,255,255))
			end
		
		end
		function plyPanel:OnCursorEntered()
			col = color1B
			colTurn = color2B

		end
		function plyPanel:OnCursorExited()
			col = color1
			colTurn = color2

		end
	
	end
	local function DrawPlayerResult(parent,i)
		local inf = playerInfo[i]
		local ply = playerInfo[i][2]
		local panel = vgui.Create('DPanel',parent)
		local h = math.Round((ScrH()-20)/MAXPLAYERS)
		playerResultsPanel[i]=panel
		panel:SetPos(0,(i-1)*h+2*i)
		panel:SetSize(600, h)
		panel.color = Color(20,30,40,200)
		local count = 0
		for j=1, #dTable[i] do
			if dTable[i][j] == lastBet[2] or (wildRound and dTable[i][j] == 1) then
				count  = count +1
			end
		end
		local str = '+ '..count
		if count>0 then 
			counter = counter + count
			str = str..'     Total:  '..counter
		end
		function panel:Paint(w,h)
			draw.RoundedBox(4,0,0,w,h,panel.color)
			draw.SimpleText(str,'Trebuchet24',100+(MAXDICE+1)*40,h/2 -12,Color(0,255,0))
			for j=1, #dTable[i] do
				if dTable[i][j] == lastBet[2] or (wildRound and dTable[i][j] == 1) then
					DrawDie(100+j*40,h/2,30,dTable[i][j],true)
				else
					DrawDie(100+j*40,h/2,30,dTable[i][j])				
				end
			end
		end
			local av = vgui.Create("AvatarImage", panel)
			av:SetSize(64, 64)
			av:SetPlayer( ply, 64 )
			av:SetPos(20,h/2-32)
		
	end
	local function GenConStrings(i)
		local str
		if playerInfo[i][1] then str = ': AI Player' 
		elseif IsValid(playerInfo[i][2]) then str = ': '..playerInfo[i][2]:Nick()
		else str = ': Empty' end
		conStrings[i]='Chair '..i..str

	end
	local function LeaveButton(parent,x,y)
		local but_leave = vgui.Create("DButton",parent)
		but_leave:SetPos(x,y)
		but_leave:SetSize(80,30)
		but_leave:SetText("Quit Game")
		but_leave:SetTextColor(color_black)
		
		function but_leave.DoClick()
			parent:Close()
			chat.AddText('You have left this Liar\'s Dice game')
			net.Start('ldLeaveGame')
			net.SendToServer()
		end		
	end
	
	local function DrawGameSetup()
		local frame = vgui.Create("DFrame")
		frame:SetSize(200,325)
		frame:Center()
		frame:SetTitle("")
		frame:MakePopup() 
		frame:SetKeyboardInputEnabled(false)
		frame:SetVisible(true)
		frame:SetDeleteOnClose(true) 
		frame:SetBackgroundBlur(false)
		frame:SetDraggable(false)
		frame:ShowCloseButton(true) --SET THIS TO FALSE WHEN FIXED	
		function frame:Paint(w,h)
			draw.RoundedBox(4,0,0,w,h,Color(100,100,100,255))
		end
		local plySlider = vgui.Create( "DNumSlider", frame )
		plySlider:SetPos( 25, 50 )			
		plySlider:SetSize( 150, 50 )		
		plySlider:SetText( "Max Players" )	
		plySlider:SetMin( 2 )				
		plySlider:SetMax( MAXPLAYERS )				
		plySlider:SetDecimals( 0 )
		plySlider:SetValue(3)
		
		local diceSlider = vgui.Create( "DNumSlider", frame )
		diceSlider:SetPos( 25, 100 )		
		diceSlider:SetSize( 150, 50 )		
		diceSlider:SetText( "Starting Dice" )
		diceSlider:SetMin( 1 )				
		diceSlider:SetMax( MAXDICE )				
		diceSlider:SetDecimals( 0 )	
		diceSlider:SetValue(2)		

		local spotBox = vgui.Create('DCheckBox',frame)
		spotBox:SetPos(25,175)
		spotBox:SetValue(true)
		local spotTxt = vgui.Create('DLabel',frame)
		spotTxt:SetPos( 45, 175 )
		spotTxt:SetSize(150,15)
		spotTxt:SetText( "Allow spot-on bid" )
		

		local wildBox = vgui.Create('DCheckBox',frame)
		wildBox:SetPos(25,200)
		wildBox:SetValue(false)
		local wildTxt = vgui.Create('DLabel',frame)
		wildTxt:SetPos( 45, 200 )
		wildTxt:SetSize(150,15)
		wildTxt:SetText( "Enable wild ones" )
		
		-- local wildPan = vgui.Create('DPanel',frame)
		-- wildPan:SetPaintBackground(false)
		-- wildPan:SetDisabled(true)
		local wildSlid = vgui.Create('DNumSlider',frame)
		wildSlid:SetPos( 25, 230 )			
		wildSlid:SetSize( 150, 25 )		
		wildSlid:SetText( "Frequency" )	
		wildSlid:SetMin( 0 )				
		wildSlid:SetMax( 1 )				
		wildSlid:SetDecimals( 2 )
		wildSlid:SetValue(0.2)
		wildSlid:Hide()
		function wildBox:OnChange(b)
			print(b)
			if b then
				wildSlid:Show()
			else
				wildSlid:Hide()
			end
		end
		
		local but_host = vgui.Create("DButton",frame)
		but_host:SetPos(80,275)
		but_host:SetSize(80,30)
		but_host:SetText("Host Game")
		but_host:SetTextColor(color_black)
		but_host.ps = plySlider
		but_host.ds = diceSlider
		
		function but_host.DoClick()
			canSpotOn = spotBox:GetChecked()
			wildOnes = wildBox:GetChecked()
			local p = math.Round(plySlider:GetValue())
			local d = math.Round(diceSlider:GetValue())
			playerInfo={}
			totalDice = p*d
			for i=1, p do
				playerInfo[i]={}
				playerInfo[i][1]=false	-- isAi
				playerInfo[i][2]=NULL	-- player obj
				playerInfo[i][3]=d	-- #dice
			end
			playerInfo[1][2]=LocalPlayer()
			for i=1, p do GenConStrings(i) end 
			local f = wildSlid:GetValue() or 0
			net.Start('ldNewGame')
				net.WriteInt(p,5)
				net.WriteInt(d,5)
				net.WriteBool(canSpotOn)
				net.WriteBool(wildOnes)
				net.WriteFloat(f)
			net.SendToServer()
			
			
			frame:Close()
		end
	end
	local function DrawPreGame()
		--[[
			Drawn while this player is sitting but game has not begun
		]]
		local frame = vgui.Create("DFrame")
		activeFrame = frame
		frame:SetSize(250,300)
		frame:Center()
		frame:SetTitle("")
		frame:MakePopup() 
		frame:SetKeyboardInputEnabled(false)
		frame:SetVisible(true)
		frame:SetDeleteOnClose(true) 
		frame:SetBackgroundBlur(false)
		frame:SetDraggable(false)
		frame:ShowCloseButton(true) --SET THIS TO FALSE WHEN FIXED
		
		function frame:Paint(w,h)
			draw.RoundedBox(4,0,0,w,h,Color(0,0,0,200))
			draw.SimpleText('AI |','default',15,20,Color(255,255,255,255))
			draw.SimpleText('CHAIRS','default',40,20,Color(255,255,255,255))
			
			for i=1, #playerInfo do
				draw.SimpleText(conStrings[i],'default',40,20+20*i,Color(255,255,255,255))
			end
		end
		
		-- local but_leave = vgui.Create("DButton",frame)
		-- but_leave:SetPos(20,260)
		-- but_leave:SetSize(80,30)
		-- but_leave:SetText("Quit Game")
		-- but_leave:SetTextColor(color_black)
		
		-- function but_leave.DoClick()
			-- chat.AddText('You have left this Liar\'s Dice game')
			-- net.Start('ldLeaveGame')
			-- net.SendToServer()
			-- frame:Close()
		-- end
		
		LeaveButton(frame,20,260)
		
		
		if LocalPlayer()~=playerInfo[1][2] then return end 
		local but_bot={}
		for i=1, #playerInfo do 
			but_bot[i] = vgui.Create("DButton",frame)
			but_bot[i]:SetPos(10,20+20*i)
			but_bot[i]:SetSize(25,15)
			but_bot[i]:SetText('ADD')
			but_bot[i]:SetTextColor(Color(255,255,255,255))
			but_bot[i].index=i
			but_bot[i].col=Color(50,100,50,255)
		end
		for k,v in pairs(but_bot) do
			function v:Paint(w,h)
				-- if not playerInfo[v.index][1] and playerInfo[v.index][2]==NULL then 
					draw.RoundedBox(4,0,0,w,h,self.col)
				-- end
			end
			function v:DoClick()
				if playerInfo[v.index][1]==true then
					--Remove AI
					playerInfo[v.index][1]=false
					self.col = Color(50,100,50,255)
					self:SetText('ADD')
					net.Start('ldRemoveAI')
						net.WriteInt(v.index,5)
					net.SendToServer()
					
				elseif not playerInfo[v.index][2]:IsPlayer() then
					--this is where you put the "make AI man" code
					playerInfo[v.index][1]=true
					playerInfo[v.index][2]=NULL
					self.col = Color(100,50,50,255)
					self:SetText('REM')
					net.Start('ldNewAI')
						net.WriteInt(v.index,5)
					net.SendToServer()
				end
				
			end
		end
		local but_start = vgui.Create("DButton",frame)
		but_start:SetPos(120,260)
		but_start:SetSize(80,30)
		but_start:SetText("Force Start")
		but_start:SetTextColor(color_black)
		
		function but_start.DoClick()
			net.Start('ldVoteStart')
			net.SendToServer()
			-- frame:Close() -- won't close it for everyone!
		end
		
	end
	local function DrawRoundStart()
		--[[
			Called when a new round starts
		]]
		
		wildRound=net.ReadBool() or false --MAKE SOME KIND OF NOTIFICATION*
		if wildRound then chat.AddText('WOW THIS IS ONE WILDDDDD ROOOOOOOOOUUUUUNNNNDDDD') end
		turnIndex=net.ReadInt(5)
		lastBet = {0,0,0}
		local myDice = net.ReadTable()
		local frame = vgui.Create("DFrame")
		activeFrame:Close()
		activeFrame = frame
		frame:SetSize(ScrW()-50,ScrH()-50)
		frame:SetPos(25,25)
		frame:SetTitle("")
		frame:MakePopup() 
		frame:SetKeyboardInputEnabled(false)
		frame:SetVisible(true)
		frame:SetDeleteOnClose(true) 
		frame:SetBackgroundBlur(false)
		frame:SetDraggable(false)
		frame:ShowCloseButton(true) --SET THIS TO FALSE WHEN FIXED
		--Calclate some paint vars here instead of every frame:
		local md1 = MAXDICE+1
		local md1sq = md1*md1
		local xD = ScrH()/(2*(md1))+10
		local yD = (md1+1)*ScrH()/(md1sq)
		local sD = ScrH()/md1
		
		function frame:Paint(w,h)
			draw.RoundedBox(4,0,0,w,h, Color(10,10,10,245))
			for i=1,#myDice do
				DrawDie(xD,(i-1)*yD+4*ScrH()/md1sq,sD,myDice[i])
			end	
		end
		
		for i=1, #playerInfo do
			if LocalPlayer()==playerInfo[i][2] then localIndex = i end --*This only needs to be done once a GAME
			playerInfo[i][4]=0
			playerInfo[i][5]=0
			DrawPlayerPanel(frame,i)
		end		
		
		LeaveButton(frame,ScrW()-130,ScrH()-80)
		function frame:OnClose()
			timer.Stop('AutoBid')
		end
			
		local but_bet = vgui.Create("DButton",frame)
		but_bet:SetPos(ScrW()-230,ScrH()-180)
		but_bet:SetSize(80,30)
		but_bet:SetText("Make Bet")
		but_bet:SetTextColor(color_black)
		but_bet.canClick=true
		
		-- local betFrame =  vgui.Create("DFrame")
		timer.Create('AutoBid',MAXTURNTIME,0, function()
			print('Autobid Timer called') -- SOME KIND OF NOTIFICATION*
			if not localIndex==turnIndex then 
				return 
			end
			net.Start('ldMakeBet')
				local n = lastBet[1]
				local d = lastBet[2]
				if lastBet[2]>5 then
					n = n>0 and n+1 or 1
					d = wildRound and 2 or 1 
				else
					n = n>0 and n or 1
					d = (wildRound and d>1 and d+1 ) or (d>0 and d+1 ) or 1
				end
			net.WriteInt(n,9)
			net.WriteInt(d,4)
			net.SendToServer()
			turnIndex=0
			if IsValid(frame) then
				frame:MakePopup() --*?
				frame:SetKeyboardInputEnabled(false)
			end	
			if IsValid(betFrame) then betFrame:Close() end
			
		end)
		function but_bet.DoClick() 
			--TEMP STUFF MATE* Use a panel?
			betFrame =  vgui.Create("DFrame")
			if localIndex==turnIndex and but_bet.canClick then
				but_bet.canClick=false
				frame:SetKeyboardInputEnabled(true)
				local autoClose = false
				function betFrame.OnClose() but_bet.canClick=true end
				function betFrame:Paint(w,h) 
					draw.RoundedBox(4,0,0,w,h, Color(10,100,10,245))
					draw.SimpleText(tostring(self:IsActive()),'default',10,10,Color(255,255,255))
					if (not autoClose) and self:IsActive() then autoClose = true
					elseif autoClose and (not self:IsActive()) then
						self:Close() 
						frame:MakePopup()
						frame:SetKeyboardInputEnabled(false)	
						
					end
				end
				betFrame:SetSize(200,200)
				betFrame:SetPos(ScrW()/2 -100,ScrH()/2 -100)
				betFrame:SetTitle("Temp Betting Menu")
				betFrame:MakePopup()
				betFrame:SetVisible(true)	
				betFrame:SetDeleteOnClose(true) 
				betFrame:SetDraggable(false)
				betFrame:ShowCloseButton(true)
								
				local faceSlider = vgui.Create( "DNumSlider", betFrame )
				faceSlider:SetPos( 25, 25 )
				faceSlider:SetSize( 150, 50 )
				faceSlider:SetText( "Face" )
				if wildRound then faceSlider:SetMin( 2 )
				else faceSlider:SetMin( 1 ) end
				faceSlider:SetMax( 6 )
				faceSlider:SetDecimals( 0 )
				faceSlider:SetValue(lastBet[2]+1)
				
				local numSlider = vgui.Create( "DNumSlider", betFrame )
				numSlider:SetPos( 25, 80 )
				numSlider:SetSize( 150, 50 )
				numSlider:SetText( "Num" )
				numSlider:SetMin( lastBet[1] )
				numSlider:SetMax( 30 )
				numSlider:SetDecimals( 0 )
				numSlider:SetValue(lastBet[1])
				
				if lastBet[2]==6 or lastBet[2]==0 then
					faceSlider:SetValue(1)
					numSlider:SetMin(lastBet[1]+1)
					numSlider:SetValue(lastBet[1]+1)
				end
				
				
				local but_submit = vgui.Create("DButton",betFrame)
				but_submit:SetPos(60,120)
				but_submit:SetSize(80,40)
				but_submit:SetText("Submit")
				but_submit:SetTextColor(color_black)
				
				function but_submit.DoClick()
					local n = math.Round(numSlider:GetValue())
					local d = math.Round(faceSlider:GetValue())
					if n>lastBet[1] or (n==lastBet[1] and d>lastBet[2]) then
						timer.Stop('AutoBid')
						net.Start('ldMakeBet')
							net.WriteInt(n,9)
							net.WriteInt(d,4)
						net.SendToServer()
						turnIndex=0
						
						frame:MakePopup()
						frame:SetKeyboardInputEnabled(false)	
						betFrame:Close()
					else chat.AddText('Invalid Bet'..lastBet[1]..lastBet[2])
					end
				end		
				
				
				
			end
		end		
	
		local but_bluff = vgui.Create("DButton",frame)
		but_bluff:SetPos(ScrW()-230,ScrH()-140)
		but_bluff:SetSize(80,30)
		but_bluff:SetText("Liar!")
		but_bluff:SetTextColor(color_black)
		but_bluff.canClick = true
		function but_bluff:DoClick()
			if self.canClick and localIndex==turnIndex and lastBet[1]>0 then
				timer.Stop('AutoBid')
				net.Start('ldCallBluff')
					net.WriteBool(false) -- Not spot on
					
				net.SendToServer()
				self.canClick = false
			end
		end
		
		if canSpotOn then
			local but_spot = vgui.Create("DButton",frame)
			but_spot:SetPos(ScrW()-320,ScrH()-140)
			but_spot:SetSize(80,30)
			but_spot:SetText("Spot On!")
			but_spot:SetTextColor(color_black)
			but_spot.canClick = true
			function but_spot:DoClick()
				if self.canClick and localIndex==turnIndex and lastBet[1]>0 then
					timer.Stop('AutoBid')
					net.Start('ldCallBluff')
						net.WriteBool(true) -- Declaring spot on
					net.SendToServer()
					self.canClick = false
				end
			end
		end
	end
	local function DrawRoundEnd(spotOnCalled)
		--[[
			Called when a round ends
		]]
		spotOnCalled = spotOnCalled or false
		activeFrame:Close()
		--local myDice = net.ReadTable()
		local frame = vgui.Create("DFrame")
		activeFrame = frame
		frame:SetSize(ScrW(),ScrH())
		frame:SetTitle("")
		frame:MakePopup() 
		frame:SetKeyboardInputEnabled(false)
		frame:SetVisible(true)
		frame:SetDeleteOnClose(true) 
		frame:SetBackgroundBlur(false)
		frame:SetDraggable(false)
		frame:ShowCloseButton(true) --SET THIS TO FALSE WHEN FIXED

		timer.Create('NextRound',#playerInfo+6,1, function()
		end)
		local msg = ''
		function frame:Paint(w,h)
			draw.RoundedBox(4,0,0,w,h, Color(10,10,10,245))
			local time = math.floor(timer.TimeLeft('NextRound'))
			draw.SimpleText(msg,'ldDerma20',w/2,h/2,Color(255,255,255))
			if time>=0 then
				draw.SimpleText(tostring(time),'ldDerma40',w-60,60,Color(255,255,0))
			end
		end
		
		counter = 0 
		playerResultsPanel={}
		for i=1, #playerInfo do
			-- DrawPlayerResult(frame,i)
			timer.Simple(i, function () 
				if not IsValid(frame) then return end
				DrawPlayerResult(frame,i) 
			end)
		end		
		
		timer.Simple(#playerInfo+1, function() 
			if not IsValid(frame) then return end
			local bluffing = IsBluff(dTable, lastBet[1], lastBet[2],spotOnCalled,wildRound)
			
			--CONSIDER MAKING THIS ONE FUNCTION
			if bluffing and not spotOnCalled then
				playerInfo[lastBet[3]][3]=playerInfo[lastBet[3]][3]-1
				playerResultsPanel[lastBet[3]].color=Color(180,0,0,200)
				playerResultsPanel[turnIndex].color=Color(0,180,0,200)
				
				print(lastBet[3]..' loses a die')
				if playerInfo[lastBet[3]][1] then
					msg = 'AI Player '..lastBet[3]..' loses a die'	
				elseif IsValid (playerInfo[lastBet[3]][2]) then
					msg = playerInfo[lastBet[3]][2]:Nick()..' loses a die'	
				end
				
			elseif bluffing and spotOnCalled then
				for i=1,#playerInfo do
					if i~=turnIndex then
						playerInfo[i][3]=playerInfo[i][3]-1
						playerResultsPanel[i].color=Color(180,0,0,200)
					else
						playerResultsPanel[turnIndex].color=Color(0,180,0,200)
					end
				end
			else
				playerInfo[turnIndex][3]=playerInfo[turnIndex][3]-1
				playerResultsPanel[turnIndex].color=Color(180,0,0,200)
				playerResultsPanel[lastBet[3]].color=Color(0,180,0,200)
				
				print(turnIndex..' loses a die')
				if playerInfo[lastBet[3]][1] then
					msg = 'AI Player '..turnIndex..' loses a die'	
				elseif IsValid (playerInfo[turnIndex][2]) then
					msg = playerInfo[turnIndex][2]:Nick()..' loses a die'	
				end
			end
			
			totalDice = totalDice - 1
			
			if playerInfo[localIndex][3]==totalDice then
				--YAY YOU WIN DO WIN STUFF HERE. 
				print('You won...')
				net.Start('ldWinGame')
				net.SendToServer()			
			end
			
			LeaveButton(frame,ScrW()-130,ScrH()-80)

		end)
		
	end
	--PREGAME UPDATE COULD BE USED FOR ALL UPDATES
	net.Receive('ldPlayerInfoUpdate',function()
		local i = net.ReadInt(5)
		playerInfo[i][1] = net.ReadBool()
		playerInfo[i][2] = net.ReadEntity()
		GenConStrings(i) --* do a state check here
	end)
	net.Receive("ldPreGameJoin", function() 
		canSpotOn=net.ReadBool()
		wildOnes=net.ReadBool()
		local t = net.ReadTable()
		if #t>1 then 
			playerInfo = t 
			for i=1,#t do GenConStrings(i) end
		end
		
	
		DrawPreGame()
	end)
	net.Receive("ldNewRound", DrawRoundStart)
	net.Receive('ldHostGame',DrawGameSetup)
	net.Receive('ldMakeBet',function()
		local i = net.ReadInt(5)
		local n = net.ReadInt(9)
		local d = net.ReadInt(4)
		local j = NextPlayerInd(i)
		turnIndex=j
		playerInfo[i][4]=n
		playerInfo[i][5]=d
		lastBet[1]=n
		lastBet[2]=d
		lastBet[3]=i
		
		timer.Start('AutoBid')
	end)
	net.Receive('ldCallBluff',function()
		dTable = net.ReadTable()
		local b = net.ReadBool()
		DrawRoundEnd(b)
	end)
end



