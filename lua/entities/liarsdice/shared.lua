-- Asterisks * signify that something requires attention

if SERVER then
	AddCSLuaFile() 
	
	--Server to Client
	util.AddNetworkString("ldPreGameJoin")
	util.AddNetworkString("ldPlayerInfoUpdate")
	util.AddNetworkString("ldHostGame")
	util.AddNetworkString("ldWinGame")
	--Client to Server
	util.AddNetworkString("ldNewAI") 
	util.AddNetworkString("ldRemoveAI") --consider merging to form toggleAI
	util.AddNetworkString("ldLeaveGame")
	util.AddNetworkString("ldForceStart") -- Rename
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

local AI_type = {
	['easy']	= 1,
	['medium']	= 2,
	['hard']	= 3,
	}

local AI_name = {'Alice', 'Bob', 'Charlie', 'Diana', 'Eric'}
	
local MAXPLAYERS 		= 6 --	Things will break if this is greater than 4bit
local MAXDICE 			= 6	--	Things will break if this is greater than 4bit
local MAXTURNTIME		= 600--	Players who take too long will auto-bid
local CAMERADELAY		= 5 --	Time delay between camera switching
local AIDelay			= 0.5--	Min time bots take to make their turns
local AIDelaySpread		= 0.2--	Max time for a bot is this plus min delay

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
		
		tbl:SetHealth(100000) 			-- *Preferably indestructable
		self.tableEnt = tbl
		

		self.camera = ents.Create( "prop_physics" )
		self.camera:SetModel(MODELS["camera"])
		self.camera:SetPos(pos+Vector(0,0,40))
		self.camera:SetAngles(ang+Angle(30,0,0))
		self.camera:Spawn()
		self.camera:SetMoveType(MOVETYPE_NONE)
		self.camera:SetSolid(SOLID_NONE)	
		self.camera:SetParent(tbl)	
		
		self.chairDir = {} 				-- Table of unit vectors from pos to chair, useful for camera.
		self.chairs = {}				-- Table of chairs. Chairs store some dice information.
		self:AddChairs(1)
		
		self.gameInProg = false
		self.humans 	= {}			-- Table of (non-ai) players in game
		self.totalPlayers=1				-- Number of players (incl. ai) still in the game
		self.maxDice 	= 0 			-- Number of dice allowed in current table
		self.totalDice	= 0				-- Number of dice in play (this round)
		self:SetGameState(STATE_presetup)
		self.playerInfo = {}			-- Table of all important player (ai and human) information
		
		self.lastBet 	= {}			-- {number of die bid, die-face bid} i.e. {n,d}
		self.turnIndex 	= 1 			-- Whose turn it is. Player 1 always goes first on round 1
		self.spotonEnabled 	= false 	-- Are spot on rules enabled?
		self.wildRoundsEnabled 	= false -- Can wild rounds occur?
		self.wildRound 	= false 		-- Is this round a wild round?
		self.wildOdds 	= 0 			-- Probability of a wild round occuring (if enabled)
	end
	
end
function ENT:OnRemove()
	if SERVER then
		if IsValid(self.tableEnt ) then self.tableEnt:Remove() end --* ALSO DEFINE A REMOVE FUNCTION SOMEWHERE FOR THE TABLE SO IT REMOVES THE ENTITY
		for i=1,#self.chairs do 
			if IsValid(self.chairs[i]) then self.chairs[i]:Remove() end
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

function IsBluff(dice, n, d, spoton, wild)
--	Determines if a bet is a bluff
--	
--	dice:	table containing all the dice currently in play
--	n:		number of dice in the bet
--	d:		dice's face (1-6) in the bet
--	spoton:	are we checking for a spot-on?
--				s=false: Returns true if t has at least n dice of face d
--				s=true: Returns true if t has exactly n dice of face d
--	wild:	are wild ones enabled?
	
	local spoton = spoton or false
	local wild = wild or false
	local a = 0
	for i=1,#dice do
		for j=1,#dice[i] do
			if dice[i][j]==d or (wild and dice[i][j]==1) then
				a=a+1
				if  spoton and a>n then return false end 
			end
		end
	end
	if spoton and a==n then return true
	elseif a<n and not spoton then return true end 

	return false
end

function SortDice(dice)
--	Sorts a list of dice such that they are in numberical order (from 1 to 6)
--	Is there a more efficent way? Probably, but this is sufficient.
--	dice:		table of dice.
	local a = {}
	for i=1,6 do
		for j=1, #dice do
			if dice[j]==i then
				table.insert(a,dice[j])
				if #a == #dice then return a end
			end
		end
	end
	return a 
end

function CountDice(dice,face,wild)
--	Counts the number of dice of a particular face.
--	Assumes dice have been sorted by SortDice
	count = 0
	for _,d in ipairs(dice) do
		if d>face then break
		elseif d==face or (wild and d == 1) then count = count + 1 end
	end
	return count
end
function ListCountedDice(dice)
--	Returns list stating how many of each die there is. a[4] = number of dice of face 4
--	Assumes dice have been sorted by SortDice
	a = {0,0,0,0,0,0}
	for _,d in ipairs(dice) do 
		for i=1,6 do
			if d==i then a[i] = a[i] + 1 end
			--elseif d>i then break end
		
		end
	end
	return a
end

if SERVER then
	local function Factorial(n)
	--	Returns the factorial of some number

		local a = 1
		if n<1 then return a
		else
			for i = 1,n do 
				a = a * i 
			end
		end
		return a
	end
	
	local function SpotonOdds(N,n,wild)
	--	Calculates the odds of there being exactly n dice of some face, in a set of N dice.
	--	Wild:	Should wild-ones be included?
		n = n or 0
		wild = wild or false
		if n>N then return 0 end
		local p = wild and 1/3 or 1/6
		return Factorial(N)*math.pow(p,n)*math.pow(1-p,N-n)/(Factorial(n)*Factorial(N-n))
	end

	local function BluffOdds(N,n,wild)
	--	Calculates the odds of there being fewer than n dice of some face, in a set of N dice.
	--	Wild:	Should wild-ones be included?
	
		print(N,n,wild)
		wild = wild or false
		local sum = 0
		if n>N then return 1		
		elseif n < N/2 then
			for i = 0,n-1 do
				sum = sum + SpotonOdds(N,i,wild)
			end
			return sum
		else
			for i = n,N do
				sum = sum + SpotonOdds(N,i,wild)
			end
			return 1 - sum
		end
	end


	function ENT:SetupGame(p,d,ply)
	--	Performs the preliminary setup for a new ld game.
	--	Specifically *
	--	p:		number of players
	--	d:		initial number of dice per player
	--	ply:	the player hosting the game
	
		self.maxDice = d
		self:AddChairs(p)
		self:SetGameState(STATE_pregame)
		self.playerInfo={}
		
		for i=1, p do 
			self.playerInfo[i] = {
			['isAI'] 	= false,
			['ply']		= NULL,
			['#dice']	= d,
			['n']		= 0,
			['d']		= 0}
		end
		
		self.playerInfo[1]['ply']=ply
		net.Start('ldPreGameJoin')
			net.WriteBool(self.spotonEnabled)
			net.WriteBool(self.wildRoundsEnabled)
		net.Send(ply)
	end
	
	function ENT:BeginGame()
	--	Initiates the ld game.
		self.gameInProg=true
		self:SetGameState(STATE_gamestart)
		self.totalDice = self.totalPlayers * self.maxDice
		self:BeginRound()
	end
	function ENT:BeginRound()
	--	Begins a new round: rolls the dice and sends them to players.
	--	*consider grouping camera stuff into its own function
		print('A new round has begun. Number of humans: ',#self.humans)
		print('A new round has begun. Number of players: ',self.totalPlayers)
		self.cameraIndex = 1
		timer.Create('CameraTimer',CAMERADELAY,0, function()
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
		if self.chairs[self.turnIndex].diceNo<1 then
			self.turnIndex = self:NextPlayerInd(self.turnIndex)
		end
		if self.wildRoundsEnabled then
			if math.random(0,1)<= self.wildOdds then
				self.wildRound = true
			else
				self.wildRound = false
			end
		end
		if self.playerInfo[self.turnIndex]['isAI'] then			
			timer.Simple(2, function() 	
				if not IsValid(self) then return end
				self:NextMoveAI(self.turnIndex)  
			end)
		end
		for i=1, #self.playerInfo do
			if self.chairs[i].diceNo<1 and self.playerInfo[i]['isAI'] then
				self:RemoveAI(i)
				-- * currently nothing happens to players, they remain as spectators.
			end
			self.playerInfo[i]['#dice'] = self.chairs[i].diceNo
			self.playerInfo[i]['n'] = 0
			self.playerInfo[i]['d'] = 0
			if self.playerInfo[i]['isAI'] or self.playerInfo[i]['ply']:IsPlayer() then
				self.chairs[i]:Fire('lock')
				self:GenDice(self.chairs[i])
			else
				self.chairs[i].dice={}
				self.chairs[i]:Fire('lock')
				self.chairs[i]:SetColor(Color(255,0,0))	
			end
			
		end
		
	end
	function ENT:NewBet(i,n,d)
	--	Receives the newest bet and allows the next player to move.
	--	i:	Index of player who made the bet
	--	n:	The number of dice in the bet
	--	d:	The face of the bet 
		local j = self:NextPlayerInd(i)
		if i==j then
			--Either only one player left or something has gone horribly wrong.
			self:EndGame(i)
			return
		end
		self.playerInfo[i]['n']=n --*needed?
		self.playerInfo[i]['d']=d --*needed?
		self.lastBet[1]=n
		self.lastBet[2]=d
		self.lastBet[3]=i
		net.Start('ldMakeBet')
			net.WriteInt(i,5)
			net.WriteInt(n,9)
			net.WriteInt(d,4)
		net.Send(self.humans)
		
		self.turnIndex=j
		if self.playerInfo[j]['isAI'] then
			self:NextMoveAI(j)
		end
	end
	function ENT:BluffCalled(index,spoton)
	--	Informs players that a bluff has been called. 
	--	i:		index of player who has called the bluff
	--	spoton:	was spot on called?
	--*marked for cleanup
		local spoton = spoton or false
		local dTable = {}
		
		for i=1,#self.playerInfo do 
			dTable[i]=self.chairs[i].dice
		end
		local bluffing = IsBluff(dTable,self.lastBet[1],self.lastBet[2],spoton,self.wildRound)
		net.Start('ldCallBluff')
			net.WriteTable(dTable) -- *Should they get this at the start? --*Should bluff really be calculated both client and serverside?
			net.WriteBool(spoton)
		net.Send(self.humans)
		
		if bluffing and not spoton then
			--Guy was caught lying and spot on was not called. Guy loses die
			self.chairs[self.lastBet[3]].diceNo=self.chairs[self.lastBet[3]].diceNo-1
			self.totalDice = self.totalDice - 1
			self.playerInfo[self.lastBet[3]]['#dice'] = self.chairs[self.lastBet[3]].diceNo --*would rather not be using two identical vars
			self.turnIndex=self.lastBet[3]
			print(self.lastBet[3]..' loses a die')
			
		elseif bluffing and spoton then
			--Caught by a spot on. All but the caller lose a die.
			for i=1,#self.playerInfo do
				if i~=index and self.chairs[i].diceNo>0 then
					self.chairs[i].diceNo = self.chairs[i].diceNo - 1--*would rather not be using two identical vars
					self.playerInfo[i]['#dice'] = self.chairs[i].diceNo
					self.totalDice = self.totalDice - 1
				end
			end
		else
			--Guy was telling the truth. Caller loses die
			self.chairs[index].diceNo=self.chairs[index].diceNo-1
			self.totalDice = self.totalDice - 1
			self.playerInfo[index]['#dice'] = self.chairs[index].diceNo --*would rather not be using two identical vars
			self.turnIndex=index
			print(index..' loses a die')
		end
		print('total dice: ',self.totalDice)
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
	--	Ends the current game of liar's dice.
	--	i:	player index of winner.
		print('ENDING GAME')
		self:SetGameState(STATE_gameend)
		self.chairs[i]:SetMaterial('models/player/shared/gold_player')
		timer.Simple(5,function() 
			if not IsValid(self) then return end
			self.chairs[i]:SetMaterial('') 
			self:ResetGame()
			end)
	end
	
	function ENT:ResetGame()
	--	Returns the entity to its pregame state
		self.humans={}
		self.totalPlayers = 1
		self.gameInProg = false
		for i=2,#self.chairs do 
			if IsValid(self.chairs[i]) then self.chairs[i]:Remove() end
		end
		local ch = self.chairs[1]
		self.chairs = {}
		self.chairs[1] = ch
		self:SetGameState(STATE_presetup)
	end
	function ENT:GenDice(chair)
	--	Rolls dice and sends to the roller.
	--	chair:	where the roller is sitting...*
		local dice = {}
		for i=1,chair.diceNo do 
			dice[i]=math.random(1,6)
		end
		chair.dice=SortDice(dice)
		chair.faceNo=ListCountedDice(dice)
		print(table.concat(chair.dice))
		if not IsValid(chair:GetDriver()) then return end
		net.Start('ldNewRound')
			net.WriteBool(self.wildRound)
			net.WriteInt(self.turnIndex,5)
			net.WriteTable(chair.dice)
		net.Send(chair:GetDriver())
	end
	function ENT:AddChairs(n)
	--	Adds new chairs to the game.
	--	n:	number of chairs AFTER additions have been made...*
		local pos=self.tableEnt:GetPos()
		local dAngDeg = 360/n
		local dAngRad = math.pi*dAngDeg/180
		local chairDist = 50
		for i=1,n-#self.chairs do
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
			chair.index = #self.chairs+1
			chair.exitOnUse = false -- can only leave chair by clicking "Quit Game", not by pressing USE.
			table.insert(self.chairs,chair)
			table.insert(self.chairDir,v)
			
			self.camera:SetPos(pos + Vector (0,0,30) )
			self.camera:SetAngles(Angle(0,dAngDeg*i,0))
			self.camera:SetParent(self.tableEnt)	

		end	
	end
	
	function ENT:UpdatePlayerInfo(i,isAI,ply,dif)
	--	Updates player info serverside and tells clients to do likewise.
	--	i:		index of player being updated
	--	isAI:	is this player an AI?
	--	ply:	the player being assigned the index
		dif = dif or 1
		self.playerInfo[i]['isAI']=isAI
		self.playerInfo[i]['ply']=ply
		self.playerInfo[i]['dif']=dif
		net.Start('ldPlayerInfoUpdate')
			net.WriteInt(i,5)
			net.WriteBool(isAI)
			net.WriteEntity(ply)
			net.WriteInt(dif,4)
		net.Send(self.humans)
	end
	
	function ENT:KickPlayer(ply)
	--	Removes player from this ld game and updates the other players.
	--	ply:	player to be removed
		--[[
			Remove a player from the game
			Might need to do validity checks
			Might need to act differently depending on game state: EG LOCK SEAT IF GAME IN PROG, ETC
		]]
		
		self.totalPlayers = self.totalPlayers - 1
		
		for i=1,#self.humans do
			if self.humans[i]==ply then
				table.remove(self.humans,i)
				break
			end
		end
		
		if self:GetGameState()==STATE_pregame then
			self:UpdatePlayerInfo(ply.ldChair.index,false,NULL)
		end
		if #self.humans <1 then
			--*AND NOT WIN STATE: Win state should allow players to leave at will, resetting 5-10s after victory (allows winner to see w/e visuals I do)
			self:ResetGame()
		elseif self.gameInProg then
			ply.ldChair:Fire('lock')
			ply.ldChair:SetColor(Color(255,0,0))
		end
		ply.ldChair = NULL
		ply.ldEnt = NULL
		
		print(ply:Nick()..' has left a Liars Dice Game')
		local str=tostring(#self.humans)..' remaining player(s): '
		for i=1,#self.humans do
			str = str..self.humans[i]:Nick()..', '
		end
		print(str)
		
	end
	function ENT:NewPlayer(ply)
	--	Adds a new player to the ld game and informs the other players
	--	ply:	Player to add
		if self.gameInProg then
			--this should not be reachable
			print(tostring(ply)..' cannot join liars dice: game in progress')
			return
		end

		if self:GetGameState()==STATE_presetup then
			-- host has sat down
			ply.ldChair = ply:GetVehicle()
			ply.ldEnt = self
			table.insert(self.humans,ply)
			net.Start('ldHostGame')
			net.Send(ply)
			
		elseif self:GetGameState()==STATE_pregame then
		
			self.totalPlayers = self.totalPlayers + 1
			ply.ldChair = ply:GetVehicle()
			local i = ply.ldChair.index
			ply.ldEnt = self
			table.insert(self.humans,ply)
			self.playerInfo[i]['isAI']=false
			self.playerInfo[i]['ply']=ply
			net.Start('ldPreGameJoin')
				net.WriteBool(self.spotonEnabled)
				net.WriteBool(self.wildRoundsEnabled)
				net.WriteTable(self.playerInfo)
			net.Send(ply)
			
			self:UpdatePlayerInfo(i,false,ply)

		else return end
		
		print(ply:Nick()..' has entered a Liars Dice Game')
		local str=tostring(#self.humans)..' player(s) playing: '
		for i=1,#self.humans do
			str = str..
			self.humans[i]:Nick()..', '
		end
		print(str)
	end
	function ENT:NextPlayerInd(i)
	--	Returns the index of the player whose turn it is after player i.
	--	i:	player index of the last player to bet.
		local j=i
		while true do 
			j=j+1
			if j==i then
				break
			elseif j>#self.playerInfo then j=0
			elseif self.playerInfo[j]['#dice']>0 and (self.playerInfo[j]['isAI'] or self.playerInfo[j]['ply']:IsPlayer()) then
				break
			end
		end
		return j
	end
	function ENT:NewAI(i,dif)
	--	Adds a new AI player to the ld game.
	--	i:	player index to be assigned to the new AI.
		dif = dif or 1
		self.chairs[i]:Fire('lock')
		self.chairs[i]:SetColor(Color(0,0,255))
		self.totalPlayers = self.totalPlayers + 1
		self:UpdatePlayerInfo(i,true,NULL,dif)
	end
	function ENT:RemoveAI(i)
	--	Removes an AI player from the ld game.
	--	i:	player index of the AI to be removed.
		self.totalPlayers = self.totalPlayers - 1
		self:UpdatePlayerInfo(i,false,NULL)
		if gameInProg then
			self.chairs[i]:SetColor(Color(255,0,0))
		else 
			self.chairs[i]:Fire('unlock')	
			self.chairs[i]:SetColor(Color(255,255,255))
		end
	end
	function ENT:NextMoveAI(i)
	--	Calculates an AI's next move.
	--	Eventually, will properly consider bets, etc based on AI's difficulty setting.
	--	i:	player index of AI whose move is being calculated.
		local r = math.random()
		local turndelay = AIDelay+math.Rand(0,AIDelaySpread)

		local n=self.lastBet[1] 
		local d=self.lastBet[2]
		
		if n==0 then -- AI has first move
			local d_new,n_new = 0,0
			for j=1,6 do
				if self.wildRound and j==1 then j=2 end
				if self.chairs[i].faceNo[j] > n_new then
					d_new,n_new = j,self.chairs[i].faceNo[j] -- find most common face. k = face, h = how many.
				end
			end
			timer.Simple(turndelay,function()
				if not IsValid(self) then return end
				self:NewBet(i,n_new,d_new) 
				end)
			return
		end
		
		local dice = self.chairs[i].dice
		local dif = self.playerInfo[i]['dif'] -- AI difficulty
		local faceNo = self.chairs[i].faceNo[d]		
		
		local spotonOdds = self.spotonEnabled and SpotonOdds(self.totalDice,n,self.wildRound) or 0
		local bluffOdds = BluffOdds(self.totalDice-#dice,n - faceNo,self.wildRound)
		
		-- if n > self.totalDice - (#dice-faceNo) then -- bid is trivialy false
			-- print('bid is trivially false',1-bluffOdds)
			-- timer.Simple(turndelay,function() self:BluffCalled(i) end)
			-- return
		-- end
		
		
		print('truth odds',1- bluffOdds)
		print('bluff odds',bluffOdds)
		if bluffOdds > 0.5 then
			timer.Simple(turndelay,function() self:BluffCalled(i) end)
			return
		end
		
		local new_n = 6
		local new_d = 1
		-- if dif < AI_type['medium'] then
			-- if r<0.5 and d<6 then
				-- new_d=d+1
			-- else
				-- new_n=n+1
				-- if r<0.5 then new_d=math.random(1,6) end
			-- end
		-- elseif dif < AI_type['hard'] then
		local d1,n1 = 0,0
		for j=1,6 do
			if self.wildRound and j==1 then j=2 end
			if self.chairs[i].faceNo[j] > n1 then
				d1,n1 = j,self.chairs[i].faceNo[j] -- find most common face. k = face, h = how many.
			end
		end
		--*
		if d1<=d and d<6 then
			local d2,n2 = 0,0	
			for j=d+1,6 do
				if self.chairs[i].faceNo[j] > n2 then
					d2,n2 = j,self.chairs[i].faceNo[j] -- find most common face of k > d. k = face, h = how many.
				end
			end
			-- Find safest bet:
			if n2<=n1+1 then
				new_d,new_n = d1,n1
			else
				new_d,new_n = d2,n2
			end
		else
			new_d,new_n = d1,n1
		end
		-- end
		
		if new_n <= n then 
			new_n = new_d<=d and n+1 or n 

		end
		
		--if about to bet something 'too' improbable, call bluff instead.
		print ('Odds of new bid being a bluff:',BluffOdds(self.totalDice-#dice,new_n - self.chairs[i].faceNo[new_d],self.wildRound))
		if BluffOdds(self.totalDice-#dice,new_n - self.chairs[i].faceNo[new_d],self.wildRound) > 0.7 then
			timer.Simple(turndelay,function() self:BluffCalled(i) end)
			return
		end
		
		timer.Simple(turndelay,function()
			if not IsValid(self) then return end
			if self.wildRound and d==1 then d=2 end
				self:NewBet(i,new_n,new_d) 
			end 
		)
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
	net.Receive('ldForceStart', function(len,ply)
		ply.ldEnt:BeginGame()
	end)
	net.Receive('ldNewGame',function(len,ply)
		local p = net.ReadInt(5)
		local d = net.ReadInt(5)
		ply:GetVehicle().diceNo = d
		ply:GetVehicle().ldEnt.spotonEnabled = net.ReadBool()
		ply:GetVehicle().ldEnt.wildRoundsEnabled = net.ReadBool()
		ply:GetVehicle().ldEnt.wildOdds = net.ReadFloat()
		ply:GetVehicle().ldEnt:SetupGame(p,d,ply)
	end)
	net.Receive('ldNewAI',function(len,ply)
		local i = net.ReadInt(5)
		local d = net.ReadInt(4)
		-- in case player entered seat while AI was being setup:
		if IsValid(ply.ldEnt.chairs[i]:GetDriver()) then return end
		
		ply.ldEnt:NewAI(i,d)
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
		ply.ldEnt:BeginRound()
	end)
	net.Receive('ldWinGame',function(len,ply)
		ply.ldEnt:EndGame(ply.ldChair.index)
	end)
	end
	

if CLIENT then
	surface.CreateFont( "ldDerma20", {
		font		= "Roboto",
		size 		= 20,
		weight 		= 500,
		blursize 	= 0,
		scanlines 	= 0,
		antialias 	= true,
		underline 	= false,
		italic 		= false,
		strikeout 	= false,
		symbol 		= false,
		rotary 		= false,
		shadow 		= false,
		additive 	= false,
		outline 	= false} 
	)
	surface.CreateFont( "ldDerma40", {
		font		= "Roboto",
		size 		= 40,
		weight 		= 500,
		blursize 	= 0,
		scanlines 	= 0,
		antialias 	= true,
		underline 	= false,
		italic 		= false,
		strikeout 	= false,
		symbol 		= false,
		rotary 		= false,
		shadow 		= false,
		additive 	= false,
		outline 	= false}
	)
	
	local conStrings = {} -- For displaying player info during pre game
	local playerInfo = {
			{['isAI'] 	= false,
			['ply']		= NULL,
			['#dice']	= 0,
			['n']		= 0,
			['d']		= 0,
			['name']	= 'Alice'}
		}
	local lastBet = {0,0,0} -- n,d,plyInd
	local turnIndex = 1 -- player index whose turn it is
	local dTable = {} -- Received at end of round
	local playerResultsPanel = {} -- For storing the final results display. Used for adjusting color of winner/loser
	local totalDice = 0
	local dice_counter = 0
	local spotonEnabled = false
	local wildRound = false 
	local activeFrame
	local localIndex
	local localEnt

	local colors = {
		['lose']	= Color(180,0,0,200),
		['win']		= Color(0,180,0,200)}
	
	function NextPlayerInd(i)
	--	Determines which player moves after player i.
		local j=i
		while true do 
			j=j+1
			if j>#playerInfo then j=0
			elseif playerInfo[j]['#dice']>0 and (playerInfo[j]['isAI'] or playerInfo[j]['ply']:IsPlayer()) then
				break
			elseif j==i then
				error('Could not find next player')
				break
			end
		end
		return j
	end
	local function DrawDie(x,y,s,n,hl)
	--	Draws a die.
	--	x:	x-coord of die's centre
	--	y:	y-coord of die's centre
	--	s:	width of die
	--	n:	number of dots to be drawn on die
	--	hl:	is this die being highlighted? (If so draws the dots as green)
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
	--	Returns a brighter form of a given RGB color.
	--	color:	Color to be brightened
	--	b:		Brightness constant to be added to R,G and B.
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
	--	Draws the most recent bet.
	--	x:		x-coord of die centre
	--	y:		y-coord of die centre
	--	size:	measure of how big to draw the die *
	--	n:		number of die in last bet
	--	d:		face of last bet
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
	--	Draws each player's panel, displays their name profile_pic and last bet.
	--	parent:	VGUI object onto which the panel is attached.
	--	i:		index of player whose panel is being drawn.
		local data = playerInfo[i]
		local ply = data['ply']
		local name= data['name']
		local col = Color(100,100,100)
		local colTurn = Color(25,150,25)
		if  data['#dice']>0 and ( ply:IsPlayer() or data['isAI'] )then col = Color(50,50,175) end
		local color1 = col
		local color1B = BrightenCol(col,40)
		local color2 = colTurn
		local color2B = BrightenCol(colTurn,40)
		
		local plyPanel = vgui.Create('DPanel',parent)
		plyPanel:SetSize(ScrW()/4,90)
		plyPanel:SetPos(3*ScrW()/4,90*(i-1))
		if data['#dice']>0 and (ply:IsPlayer() or data['isAI']) then
			local str = 'Has '..data['#dice']..' dice'
			
			function plyPanel:Paint(w,h)
				draw.RoundedBox(4,0,0,w,h, Color(0,0,0,255))
				if i==turnIndex then
					timeleft = timer.TimeLeft('AutoBid') or nil
					if timeleft ~= nil then
						timepassed = MAXTURNTIME - timeleft
						drawcol = Color(
							math.floor(colTurn.r + timepassed*(200-colTurn.r)/MAXTURNTIME),
							math.floor(colTurn.g - colTurn.g*timepassed/MAXTURNTIME),
							math.floor(colTurn.b - colTurn.b*timepassed/MAXTURNTIME)
						)
					else drawcol = colTurn end
					draw.RoundedBox(4,1,1,w-2,h-2, drawcol)
					if (timeleft~=nil and timeleft>0) then 
						draw.SimpleText(tostring(math.floor(timeleft)),'default',w-20,20,Color(255,255,0)) 
					end
				else draw.RoundedBox(4,1,1,w-2,h-2, col) end
				draw.SimpleText(name,"DermaLarge",80,10,Color(255,255,255,255))
				draw.SimpleText(str,"ldDerma20",80,40,Color(255,255,255,255))
				draw.SimpleText("Last Bet: ","ldDerma20",80,60,Color(255,255,255,255))
				DrawBet(200,60,0,data['n'],data['d'])
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
				draw.SimpleText('Empty chair',"DermaLarge",80,10,Color(255,255,255,255))
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
	--	Draws the player panels displayed on the results screen.
	--	parent:	VGUI object onto which the panel is attached.
	--	i:		index of player whose panel is being drawn.
		local ply = playerInfo[i]['ply']
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
			dice_counter = dice_counter + count
			str = str..'     Total:  '..dice_counter
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
	--	Generates strings to be drawn, indicating the state of a particular chair.
	--	i:	chair/player index...*
		local str
		if playerInfo[i]['isAI'] or playerInfo[i]['ply']:IsPlayer() then 
			str = ': '..playerInfo[i]['name']
		else str = ': Empty' 
		end
		conStrings[i]='Chair '..i..str
	end
	local function LeaveButton(parent,x,y)
	--	Draws button which removes player from game, when clicked.
	--	* may want to follow up with an "are you sure?" window, but leave it for now.
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
	--	Draws the game setup display, where host controls the game's settings.
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
		plySlider:SetValue(MAXPLAYERS)
		
		local diceSlider = vgui.Create( "DNumSlider", frame )
		diceSlider:SetPos( 25, 100 )		
		diceSlider:SetSize( 150, 50 )		
		diceSlider:SetText( "Starting Dice" )
		diceSlider:SetMin( 1 )				
		diceSlider:SetMax( MAXDICE )				
		diceSlider:SetDecimals( 0 )	
		diceSlider:SetValue(MAXDICE)		

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
			spotonEnabled = spotBox:GetChecked()
			local wildOnes = wildBox:GetChecked()
			local p = math.Round(plySlider:GetValue())
			local d = math.Round(diceSlider:GetValue())
			playerInfo={}
			totalDice = p*d
			for i=1, p do
				playerInfo[i]={}
				playerInfo[i]['isAI']=false	
				playerInfo[i]['ply']=NULL	
				playerInfo[i]['#dice']=d	
			end
			playerInfo[1]['ply']=LocalPlayer()
			playerInfo[1]['name']=LocalPlayer():Nick()
			
			for i=1, p do GenConStrings(i) end 
			local f = wildSlid:GetValue() or 0
			net.Start('ldNewGame')
				net.WriteInt(p,5)
				net.WriteInt(d,5)
				net.WriteBool(spotonEnabled)
				net.WriteBool(wildOnes)
				net.WriteFloat(f)
			net.SendToServer()
			
			
			frame:Close()
		end
	end
	local function DrawPreGame()
	--	Draws the pregame display, when players can sit and AI can be added/removed.
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

		LeaveButton(frame,20,260)
		
		if LocalPlayer()~=playerInfo[1]['ply'] then return end 
		
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
				draw.RoundedBox(4,0,0,w,h,self.col)
			end
			function v:DoClick()
				if playerInfo[v.index]['isAI'] then
					--Remove AI
					playerInfo[v.index]['isAI']=false
					self.col = Color(50,100,50,255)
					self:SetText('ADD')
					net.Start('ldRemoveAI')
						net.WriteInt(v.index,5)
					net.SendToServer()
					
				elseif not playerInfo[v.index]['ply']:IsPlayer() then
					-- Create new AI
					--
					difFrame =  vgui.Create("DFrame")
					frame:SetKeyboardInputEnabled(true)
					local autoClose = false
					function difFrame:Paint(w,h)
						draw.RoundedBox(4,0,0,w,h, Color(50,50,150,245))
						if (not autoClose) and self:IsActive() then autoClose = true
						elseif autoClose and (not self:IsActive()) then
							self:Close() 
							frame:MakePopup()
							frame:SetKeyboardInputEnabled(false)	
						end
					end
					
					difFrame:SetSize(200,200)
					difFrame:SetPos(ScrW()/2 -100,ScrH()/2 -100)
					difFrame:SetTitle("Choose AI Difficulty")
					difFrame:MakePopup()
					difFrame:SetVisible(true)	
					difFrame:SetDeleteOnClose(true) 
					difFrame:SetDraggable(false)
					difFrame:ShowCloseButton(true)
									
					local difSlider = vgui.Create( "DNumSlider", difFrame )
					difSlider:SetPos( 25, 25 )
					difSlider:SetSize( 150, 50 )
					difSlider:SetText( "Difficulty" )
					difSlider:SetMin( 1 )
					local maxDif = 0
					for k,v in pairs(AI_type) do maxDif = maxDif + 1 end
					difSlider:SetMax( maxDif )
					difSlider:SetDecimals( 0 )
					difSlider:SetValue(2)
					
					local but_submit = vgui.Create("DButton",difFrame)
					but_submit:SetPos(60,120)
					but_submit:SetSize(80,40)
					but_submit:SetText("Submit")
					but_submit:SetTextColor(color_black)
					
					function but_submit.DoClick()
						local dif = math.Round(difSlider:GetValue())
						playerInfo[v.index]['isAI']=true
						playerInfo[v.index]['ply']=NULL
						self.col = Color(100,50,50,255)
						self:SetText('REM')
						net.Start('ldNewAI')
							net.WriteInt(v.index,5)
							net.WriteInt(dif,4)
						net.SendToServer()
						
						frame:MakePopup()
						frame:SetKeyboardInputEnabled(false)	
						difFrame:Close()
					end
					--
				end
				
			end
		end
		local but_start = vgui.Create("DButton",frame)
		but_start:SetPos(120,260)
		but_start:SetSize(80,30)
		but_start:SetText("Force Start")
		but_start:SetTextColor(color_black)
		
		function but_start.DoClick()
			net.Start('ldForceStart')
			net.SendToServer()
			-- frame:Close() -- won't close it for everyone!
		end
		
	end
	local function DrawRoundStart()
	--	Draws the main game display.
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
			if LocalPlayer()==playerInfo[i]['ply'] then localIndex = i end --*This only needs to be done once a GAME
			playerInfo[i]['n']=0
			playerInfo[i]['d']=0
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
			if not localIndex==turnIndex then 
				return 
			end
			print('Times up, autobidding...') -- *SOME KIND OF NOTIFICATION
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
		
		if spotonEnabled then
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
	--	Draws the end of round display, showing the results of the last bluff call.
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
		local msg = 'Counting the dice...'
		function frame:Paint(w,h)
			draw.RoundedBox(4,0,0,w,h, Color(10,10,10,245))
			local time = math.floor(timer.TimeLeft('NextRound'))
			draw.SimpleText(msg,'ldDerma20',w/2,h/2,Color(255,255,255))
			if time>=0 then
				draw.SimpleText(tostring(time),'ldDerma40',w-60,60,Color(255,255,0))
			end
		end
		
		playerResultsPanel={}
		dice_counter = 0 
		for i=1, #playerInfo do
			timer.Simple(i, function () 
				if not IsValid(frame) then return end
				DrawPlayerResult(frame,i) 
			end)
		end		
		
		timer.Simple(#playerInfo+1, function() 
			if not IsValid(frame) then return end
			local bluffing = IsBluff(dTable, lastBet[1], lastBet[2],spotOnCalled,wildRound)
			
			if spotOnCalled and bluffing then
				if bluffing then 
					msg = 'Bid was spot on. Everyone else loses a die'
					for i=1,#playerInfo do
						if i~=turnIndex then
							playerInfo[i]['#dice']=playerInfo[i]['#dice']-1
							playerResultsPanel[i].color=colors['lose']
						else
							playerResultsPanel[turnIndex].color=colors['win']
						end
					end
				end
			else
				local iloser	= (bluffing and not spotOnCalled) and lastBet[3] or turnIndex
				local iwinner	= (bluffing and not spotOnCalled) and turnIndex or lastBet[3]
				playerInfo[iloser]['#dice']=playerInfo[iloser]['#dice']-1
				playerResultsPanel[iwinner].color=colors['win']
				playerResultsPanel[iloser].color=colors['lose']	
				
				msg = playerInfo[iloser]['name']..' loses a die'	
			end
			totalDice = totalDice - 1
			if playerInfo[localIndex]['#dice']==totalDice then
				net.Start('ldWinGame')
				net.SendToServer()			
			end
			
			LeaveButton(frame,ScrW()-130,ScrH()-80)

		end)
		
	end
	--PREGAME UPDATE COULD BE USED FOR ALL UPDATES
	net.Receive('ldPlayerInfoUpdate',function()
		local i 	= net.ReadInt(5)
		local isAI 	= net.ReadBool()
		local ply 	= net.ReadEntity()
		local dif 	= net.ReadInt(4)
		playerInfo[i]['isAI'] 	= isAI
		playerInfo[i]['ply'] 	= ply
		playerInfo[i]['dif'] 	= dif
		playerInfo[i]['name'] 	= isAI and AI_name[dif] or ply:IsPlayer() and ply:Nick() or 'Nameless'
		GenConStrings(i) --* do a state check here
	end)
	net.Receive("ldPreGameJoin", function() 
		spotonEnabled=net.ReadBool()
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
		playerInfo[i]['n']=n
		playerInfo[i]['d']=d
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