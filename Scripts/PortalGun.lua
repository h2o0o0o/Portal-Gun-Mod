dofile( "$GAME_DATA/Scripts/game/AnimationUtil.lua" )
dofile( "$SURVIVAL_DATA/Scripts/util.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/survival_shapes.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/survival_projectiles.lua" )

---@class PortalGun : ToolClass
---@field aiming boolean
---@field fpAnimations table
---@field tpAnimations table
---@field shootEffect Effect
---@field shootEffectFP Effect
---@field aimFireMode table
---@field normalFireMode table
---@field blendTime integer
---@field aimBlendSpeed integer
---@field portals AreaTrigger[]
---@field portal_effects Effect[]
PortalGun = class()

local renderables = {
	"$GAME_DATA/Character/Char_Tools/Char_spudgun/Base/char_spudgun_base_basic.rend",
	"$GAME_DATA/Character/Char_Tools/Char_spudgun/Barrel/Barrel_basic/char_spudgun_barrel_basic.rend",
	"$GAME_DATA/Character/Char_Tools/Char_spudgun/Sight/Sight_basic/char_spudgun_sight_basic.rend",
	"$GAME_DATA/Character/Char_Tools/Char_spudgun/Stock/Stock_broom/char_spudgun_stock_broom.rend",
	"$GAME_DATA/Character/Char_Tools/Char_spudgun/Tank/Tank_basic/char_spudgun_tank_basic.rend"
}

local renderablesTp = {"$GAME_DATA/Character/Char_Male/Animations/char_male_tp_spudgun.rend", "$GAME_DATA/Character/Char_Tools/Char_spudgun/char_spudgun_tp_animlist.rend"}
local renderablesFp = {"$GAME_DATA/Character/Char_Tools/Char_spudgun/char_spudgun_fp_animlist.rend"}

sm.tool.preloadRenderables( renderables )
sm.tool.preloadRenderables( renderablesTp )
sm.tool.preloadRenderables( renderablesFp )

function PortalGun:client_onCreate()
	self.shootEffect = sm.effect.createEffect( "SpudgunBasic - BasicMuzzel" )
	self.shootEffectFP = sm.effect.createEffect( "SpudgunBasic - FPBasicMuzzel" )

	self.portal_effects = {}
	self.portal_timer = 0
end

function PortalGun:client_onDestroy()
	for k, v in pairs(self.portal_effects) do
		if v and sm.exists(v) then
			if v:isPlaying() then
				v:stopImmediate()
			end

			v:destroy()
		end
	end
end

function PortalGun:server_onCreate()
	self.portals = {}
	self.cooldown_data = {}
end

function PortalGun:server_onDestroy()
	for k, v in pairs(self.portals) do
		if v and sm.exists(v) then
			sm.areaTrigger.destroy(v)
		end
	end
end

function PortalGun.client_onRefresh( self )
	self:loadAnimations()
end

function PortalGun.loadAnimations( self )

	self.tpAnimations = createTpAnimations(
		self.tool,
		{
			shoot = { "spudgun_shoot", { crouch = "spudgun_crouch_shoot" } },
			aim = { "spudgun_aim", { crouch = "spudgun_crouch_aim" } },
			aimShoot = { "spudgun_aim_shoot", { crouch = "spudgun_crouch_aim_shoot" } },
			idle = { "spudgun_idle" },
			pickup = { "spudgun_pickup", { nextAnimation = "idle" } },
			putdown = { "spudgun_putdown" }
		}
	)
	local movementAnimations = {
		idle = "spudgun_idle",
		idleRelaxed = "spudgun_relax",

		sprint = "spudgun_sprint",
		runFwd = "spudgun_run_fwd",
		runBwd = "spudgun_run_bwd",

		jump = "spudgun_jump",
		jumpUp = "spudgun_jump_up",
		jumpDown = "spudgun_jump_down",

		land = "spudgun_jump_land",
		landFwd = "spudgun_jump_land_fwd",
		landBwd = "spudgun_jump_land_bwd",

		crouchIdle = "spudgun_crouch_idle",
		crouchFwd = "spudgun_crouch_fwd",
		crouchBwd = "spudgun_crouch_bwd"
	}

	for name, animation in pairs( movementAnimations ) do
		self.tool:setMovementAnimation( name, animation )
	end

	setTpAnimation( self.tpAnimations, "idle", 5.0 )

	if self.tool:isLocal() then
		self.fpAnimations = createFpAnimations(
			self.tool,
			{
				equip = { "spudgun_pickup", { nextAnimation = "idle" } },
				unequip = { "spudgun_putdown" },

				idle = { "spudgun_idle", { looping = true } },
				shoot = { "spudgun_shoot", { nextAnimation = "idle" } },

				aimInto = { "spudgun_aim_into", { nextAnimation = "aimIdle" } },
				aimExit = { "spudgun_aim_exit", { nextAnimation = "idle", blendNext = 0 } },
				aimIdle = { "spudgun_aim_idle", { looping = true} },
				aimShoot = { "spudgun_aim_shoot", { nextAnimation = "aimIdle"} },

				sprintInto = { "spudgun_sprint_into", { nextAnimation = "sprintIdle",  blendNext = 0.2 } },
				sprintExit = { "spudgun_sprint_exit", { nextAnimation = "idle",  blendNext = 0 } },
				sprintIdle = { "spudgun_sprint_idle", { looping = true } },
			}
		)
	end

	self.normalFireMode = {
		fireCooldown = 0.20,
		spreadCooldown = 0.18,
		spreadIncrement = 2.6,
		spreadMinAngle = .25,
		spreadMaxAngle = 8,
		fireVelocity = 130.0,

		minDispersionStanding = 0.1,
		minDispersionCrouching = 0.04,

		maxMovementDispersion = 0.4,
		jumpDispersionMultiplier = 2
	}

	self.aimFireMode = {
		fireCooldown = 0.20,
		spreadCooldown = 0.18,
		spreadIncrement = 1.3,
		spreadMinAngle = 0,
		spreadMaxAngle = 8,
		fireVelocity =  130.0,

		minDispersionStanding = 0.01,
		minDispersionCrouching = 0.01,

		maxMovementDispersion = 0.4,
		jumpDispersionMultiplier = 2
	}

	self.fireCooldownTimer = 0.0
	self.spreadCooldownTimer = 0.0

	self.movementDispersion = 0.0

	self.sprintCooldownTimer = 0.0
	self.sprintCooldown = 0.3

	self.aimBlendSpeed = 3.0
	self.blendTime = 0.2

	self.jointWeight = 0.0
	self.spineWeight = 0.0
	local cameraWeight, cameraFPWeight = self.tool:getCameraWeights()
	self.aimWeight = math.max( cameraWeight, cameraFPWeight )

end

local _sm_vec3_z = sm.vec3.new(0, 0, 1)
local function get_portal_normal(portal)
	return sm.vec3.getRotation(portal:getWorldRotation() * _sm_vec3_z --[[@as Vec3]], _sm_vec3_z) * _sm_vec3_z
end

local portal_color1 = sm.color.new(0x32a865ff)
local portal_color2 = sm.color.new(0x21c29cff)
local portal_color_vec1 = sm.vec3.new(portal_color1.r, portal_color1.g, portal_color1.b)
local portal_color_vec2 = sm.vec3.new(portal_color2.r, portal_color2.g, portal_color2.b)
function PortalGun.client_onUpdate( self, dt )
	self.portal_timer = self.portal_timer + dt * 3
	for k, v in pairs(self.portal_effects) do
		local light_intensity = math.abs(sm.noise.perlinNoise2d(self.portal_timer, 1, 1337 + k))
		v:setParameter("intensity", (light_intensity * 0.3) + 1)

		local color_lerp = sm.vec3.lerp(portal_color_vec1, portal_color_vec2, light_intensity)
		v:setParameter("color", sm.color.new(color_lerp.x, color_lerp.y, color_lerp.z))
	end

	-- First person animation
	local isSprinting =  self.tool:isSprinting()
	local isCrouching =  self.tool:isCrouching()

	if self.tool:isLocal() then
		if self.equipped then
			if isSprinting and self.fpAnimations.currentAnimation ~= "sprintInto" and self.fpAnimations.currentAnimation ~= "sprintIdle" then
				swapFpAnimation( self.fpAnimations, "sprintExit", "sprintInto", 0.0 )
			elseif not self.tool:isSprinting() and ( self.fpAnimations.currentAnimation == "sprintIdle" or self.fpAnimations.currentAnimation == "sprintInto" ) then
				swapFpAnimation( self.fpAnimations, "sprintInto", "sprintExit", 0.0 )
			end

			if self.aiming and not isAnyOf( self.fpAnimations.currentAnimation, { "aimInto", "aimIdle", "aimShoot" } ) then
				swapFpAnimation( self.fpAnimations, "aimExit", "aimInto", 0.0 )
			end
			if not self.aiming and isAnyOf( self.fpAnimations.currentAnimation, { "aimInto", "aimIdle", "aimShoot" } ) then
				swapFpAnimation( self.fpAnimations, "aimInto", "aimExit", 0.0 )
			end
		end
		updateFpAnimations( self.fpAnimations, self.equipped, dt )
	end

	if not self.equipped then
		if self.wantEquipped then
			self.wantEquipped = false
			self.equipped = true
		end
		return
	end

	local effectPos, rot

	if self.tool:isLocal() then

		local zOffset = 0.6
		if self.tool:isCrouching() then
			zOffset = 0.29
		end

		local dir = sm.localPlayer.getDirection()
		local firePos = self.tool:getFpBonePos( "pejnt_barrel" )

		if not self.aiming then
			effectPos = firePos + dir * 0.2
		else
			effectPos = firePos + dir * 0.45
		end

		rot = sm.vec3.getRotation( sm.vec3.new( 0, 0, 1 ), dir )


		self.shootEffectFP:setPosition( effectPos )
		self.shootEffectFP:setVelocity( self.tool:getMovementVelocity() )
		self.shootEffectFP:setRotation( rot )
	end
	local pos = self.tool:getTpBonePos( "pejnt_barrel" )
	local dir = self.tool:getTpBoneDir( "pejnt_barrel" )

	effectPos = pos + dir * 0.2

	rot = sm.vec3.getRotation( sm.vec3.new( 0, 0, 1 ), dir )


	self.shootEffect:setPosition( effectPos )
	self.shootEffect:setVelocity( self.tool:getMovementVelocity() )
	self.shootEffect:setRotation( rot )

	-- Timers
	self.fireCooldownTimer = math.max( self.fireCooldownTimer - dt, 0.0 )
	self.spreadCooldownTimer = math.max( self.spreadCooldownTimer - dt, 0.0 )
	self.sprintCooldownTimer = math.max( self.sprintCooldownTimer - dt, 0.0 )


	if self.tool:isLocal() then
		local dispersion = 0.0
		local fireMode = self.aiming and self.aimFireMode or self.normalFireMode
		local recoilDispersion = 1.0 - ( math.max( fireMode.minDispersionCrouching, fireMode.minDispersionStanding ) + fireMode.maxMovementDispersion )

		if isCrouching then
			dispersion = fireMode.minDispersionCrouching
		else
			dispersion = fireMode.minDispersionStanding
		end

		if self.tool:getRelativeMoveDirection():length() > 0 then
			dispersion = dispersion + fireMode.maxMovementDispersion * self.tool:getMovementSpeedFraction()
		end

		if not self.tool:isOnGround() then
			dispersion = dispersion * fireMode.jumpDispersionMultiplier
		end

		self.movementDispersion = dispersion

		self.spreadCooldownTimer = clamp( self.spreadCooldownTimer, 0.0, fireMode.spreadCooldown )
		local spreadFactor = fireMode.spreadCooldown > 0.0 and clamp( self.spreadCooldownTimer / fireMode.spreadCooldown, 0.0, 1.0 ) or 0.0

		self.tool:setDispersionFraction( clamp( self.movementDispersion + spreadFactor * recoilDispersion, 0.0, 1.0 ) )

		if self.aiming then
			if self.tool:isInFirstPersonView() then
				self.tool:setCrossHairAlpha( 0.0 )
			else
				self.tool:setCrossHairAlpha( 1.0 )
			end
			self.tool:setInteractionTextSuppressed( true )
		else
			self.tool:setCrossHairAlpha( 1.0 )
			self.tool:setInteractionTextSuppressed( false )
		end
	end

	-- Sprint block
	local blockSprint = self.aiming or self.sprintCooldownTimer > 0.0
	self.tool:setBlockSprint( blockSprint )

	local playerDir = self.tool:getSmoothDirection()
	local angle = math.asin( playerDir:dot( sm.vec3.new( 0, 0, 1 ) ) ) / ( math.pi / 2 )
	local linareAngle = playerDir:dot( sm.vec3.new( 0, 0, 1 ) )

	local linareAngleDown = clamp( -linareAngle, 0.0, 1.0 )

	down = clamp( -angle, 0.0, 1.0 )
	fwd = ( 1.0 - math.abs( angle ) )
	up = clamp( angle, 0.0, 1.0 )

	local crouchWeight = self.tool:isCrouching() and 1.0 or 0.0
	local normalWeight = 1.0 - crouchWeight

	local totalWeight = 0.0
	for name, animation in pairs( self.tpAnimations.animations ) do
		animation.time = animation.time + dt

		if name == self.tpAnimations.currentAnimation then
			animation.weight = math.min( animation.weight + ( self.tpAnimations.blendSpeed * dt ), 1.0 )

			if animation.time >= animation.info.duration - self.blendTime then
				if ( name == "shoot" or name == "aimShoot" ) then
					setTpAnimation( self.tpAnimations, self.aiming and "aim" or "idle", 10.0 )
				elseif name == "pickup" then
					setTpAnimation( self.tpAnimations, self.aiming and "aim" or "idle", 0.001 )
				elseif animation.nextAnimation ~= "" then
					setTpAnimation( self.tpAnimations, animation.nextAnimation, 0.001 )
				end
			end
		else
			animation.weight = math.max( animation.weight - ( self.tpAnimations.blendSpeed * dt ), 0.0 )
		end

		totalWeight = totalWeight + animation.weight
	end

	totalWeight = totalWeight == 0 and 1.0 or totalWeight
	for name, animation in pairs( self.tpAnimations.animations ) do
		local weight = animation.weight / totalWeight
		if name == "idle" then
			self.tool:updateMovementAnimation( animation.time, weight )
		elseif animation.crouch then
			self.tool:updateAnimation( animation.info.name, animation.time, weight * normalWeight )
			self.tool:updateAnimation( animation.crouch.name, animation.time, weight * crouchWeight )
		else
			self.tool:updateAnimation( animation.info.name, animation.time, weight )
		end
	end

	-- Third Person joint lock
	local relativeMoveDirection = self.tool:getRelativeMoveDirection()
	if ( ( ( isAnyOf( self.tpAnimations.currentAnimation, { "aimInto", "aim", "shoot" } ) and ( relativeMoveDirection:length() > 0 or isCrouching) ) or ( self.aiming and ( relativeMoveDirection:length() > 0 or isCrouching) ) ) and not isSprinting ) then
		self.jointWeight = math.min( self.jointWeight + ( 10.0 * dt ), 1.0 )
	else
		self.jointWeight = math.max( self.jointWeight - ( 6.0 * dt ), 0.0 )
	end

	if ( not isSprinting ) then
		self.spineWeight = math.min( self.spineWeight + ( 10.0 * dt ), 1.0 )
	else
		self.spineWeight = math.max( self.spineWeight - ( 10.0 * dt ), 0.0 )
	end

	local finalAngle = ( 0.5 + angle * 0.5 )
	self.tool:updateAnimation( "spudgun_spine_bend", finalAngle, self.spineWeight )

	local totalOffsetZ = lerp( -22.0, -26.0, crouchWeight )
	local totalOffsetY = lerp( 6.0, 12.0, crouchWeight )
	local crouchTotalOffsetX = clamp( ( angle * 60.0 ) -15.0, -60.0, 40.0 )
	local normalTotalOffsetX = clamp( ( angle * 50.0 ), -45.0, 50.0 )
	local totalOffsetX = lerp( normalTotalOffsetX, crouchTotalOffsetX , crouchWeight )

	local finalJointWeight = ( self.jointWeight )


	self.tool:updateJoint( "jnt_hips", sm.vec3.new( totalOffsetX, totalOffsetY, totalOffsetZ ), 0.35 * finalJointWeight * ( normalWeight ) )

	local crouchSpineWeight = ( 0.35 / 3 ) * crouchWeight

	self.tool:updateJoint( "jnt_spine1", sm.vec3.new( totalOffsetX, totalOffsetY, totalOffsetZ ), ( 0.10 + crouchSpineWeight )  * finalJointWeight )
	self.tool:updateJoint( "jnt_spine2", sm.vec3.new( totalOffsetX, totalOffsetY, totalOffsetZ ), ( 0.10 + crouchSpineWeight ) * finalJointWeight )
	self.tool:updateJoint( "jnt_spine3", sm.vec3.new( totalOffsetX, totalOffsetY, totalOffsetZ ), ( 0.45 + crouchSpineWeight ) * finalJointWeight )
	self.tool:updateJoint( "jnt_head", sm.vec3.new( totalOffsetX, totalOffsetY, totalOffsetZ ), 0.3 * finalJointWeight )


	-- Camera update
	local bobbing = 1
	if self.aiming then
		local blend = 1 - math.pow( 1 - 1 / self.aimBlendSpeed, dt * 60 )
		self.aimWeight = sm.util.lerp( self.aimWeight, 1.0, blend )
		bobbing = 0.12
	else
		local blend = 1 - math.pow( 1 - 1 / self.aimBlendSpeed, dt * 60 )
		self.aimWeight = sm.util.lerp( self.aimWeight, 0.0, blend )
		bobbing = 1
	end

	self.tool:updateCamera( 2.8, 30.0, sm.vec3.new( 0.65, 0.0, 0.05 ), self.aimWeight )
	self.tool:updateFpCamera( 30.0, sm.vec3.new( 0.0, 0.0, 0.0 ), self.aimWeight, bobbing )
end

function PortalGun:server_onFixedUpdate()
	for k, v in pairs(self.cooldown_data) do
		self.cooldown_data[k] = v - 1
		if v <= 0 then
			self.cooldown_data[k] = nil
		end
	end
end

function PortalGun.client_onEquip( self, animate )

	if animate then
		sm.audio.play( "PotatoRifle - Equip", self.tool:getPosition() )
	end

	self.wantEquipped = true
	self.aiming = false
	local cameraWeight, cameraFPWeight = self.tool:getCameraWeights()
	self.aimWeight = math.max( cameraWeight, cameraFPWeight )
	self.jointWeight = 0.0

	currentRenderablesTp = {}
	currentRenderablesFp = {}

	for k,v in pairs( renderablesTp ) do currentRenderablesTp[#currentRenderablesTp+1] = v end
	for k,v in pairs( renderablesFp ) do currentRenderablesFp[#currentRenderablesFp+1] = v end
	for k,v in pairs( renderables ) do currentRenderablesTp[#currentRenderablesTp+1] = v end
	for k,v in pairs( renderables ) do currentRenderablesFp[#currentRenderablesFp+1] = v end
	self.tool:setTpRenderables( currentRenderablesTp )

	self:loadAnimations()

	setTpAnimation( self.tpAnimations, "pickup", 0.0001 )

	if self.tool:isLocal() then
		-- Sets PotatoRifle renderable, change this to change the mesh
		self.tool:setFpRenderables( currentRenderablesFp )
		swapFpAnimation( self.fpAnimations, "unequip", "equip", 0.2 )
	end
end

function PortalGun.client_onUnequip( self, animate )

	self.wantEquipped = false
	self.equipped = false
	self.aiming = false
	if sm.exists( self.tool ) then
		if animate then
			sm.audio.play( "PotatoRifle - Unequip", self.tool:getPosition() )
		end
		setTpAnimation( self.tpAnimations, "putdown" )
		if self.tool:isLocal() then
			self.tool:setMovementSlowDown( false )
			self.tool:setBlockSprint( false )
			self.tool:setCrossHairAlpha( 1.0 )
			self.tool:setInteractionTextSuppressed( false )
			if self.fpAnimations.currentAnimation ~= "unequip" then
				swapFpAnimation( self.fpAnimations, "equip", "unequip", 0.2 )
			end
		end
	end
end

function PortalGun.sv_n_onAim( self, aiming )
	self.network:sendToClients( "cl_n_onAim", aiming )
end

function PortalGun.cl_n_onAim( self, aiming )
	if not self.tool:isLocal() and self.tool:isEquipped() then
		self:onAim( aiming )
	end
end

function PortalGun.onAim( self, aiming )
	self.aiming = aiming
	if self.tpAnimations.currentAnimation == "idle" or self.tpAnimations.currentAnimation == "aim" or self.tpAnimations.currentAnimation == "relax" and self.aiming then
		setTpAnimation( self.tpAnimations, self.aiming and "aim" or "idle", 5.0 )
	end
end

function PortalGun.sv_n_onShoot( self, dir )
	self.network:sendToClients( "cl_n_onShoot", dir )
end

function PortalGun.cl_n_onShoot( self, dir )
	if not self.tool:isLocal() and self.tool:isEquipped() then
		self:onShoot( dir )
	end
end

function PortalGun.onShoot( self, dir )
	self.tpAnimations.animations.idle.time = 0
	self.tpAnimations.animations.shoot.time = 0
	self.tpAnimations.animations.aimShoot.time = 0

	setTpAnimation( self.tpAnimations, self.aiming and "aimShoot" or "shoot", 10.0 )

	if self.tool:isInFirstPersonView() then
		self.shootEffectFP:start()
	else
		self.shootEffect:start()
	end

end

--[[function PortalGun:test_shit(data)
	local vel_test = sm.noise.gunSpread(data[5], 50) * data[3]:length()

	local pi_5 = math.pi * 5
	local angular_velocity = sm.vec3.new(math.random(0, pi_5), math.random(0, pi_5), math.random(0, pi_5))
	sm.debris.createDebris(data[1], data[4], data[6], vel_test, angular_velocity, data[7])
end]]

---@param owner AreaTrigger
function PortalGun:server_onTriggerEnter(owner, data)
	local v_other_portal = self.portals[owner:getUserData().idx]
	if not (v_other_portal and sm.exists(v_other_portal)) then
		return
	end

	local v_other_portal_normal = get_portal_normal(v_other_portal)
	for k, v in ipairs(data) do
		if type(v) == "Character" and self.cooldown_data[v.id] == nil then
			self.cooldown_data[v.id] = 2

			v:setWorldPosition(v_other_portal:getWorldPosition() + v_other_portal_normal * (v:getHeight() * 0.5))

			sm.physics.applyImpulse(v, v.velocity * -v.mass, true)
			sm.physics.applyImpulse(v, v_other_portal_normal * v.velocity:length() * v.mass, true)
		--[[else
			if v:isDynamic() then
				for _, shape in ipairs(v:getShapes()) do
					self.network:sendToClients("test_shit", { shape.uuid, shape.mass, shape.velocity, v_other_portal:getWorldPosition(), v_other_portal_normal, shape.worldRotation, shape.color })
					shape:destroyShape()
					if sm.item.isBlock(shape.uuid) then
						print(shape:getBoundingBox())
						local new_block = sm.shape.createBlock(shape.uuid, shape:getBoundingBox() * 4, v_other_portal:getWorldPosition(), shape.worldRotation, true, true)
						sm.physics.applyImpulse(new_block, v_other_portal_normal * shape.velocity:length() * shape.mass, true)
						shape:destroyShape()
					else
						local new_shape = sm.shape.createPart(shape.uuid, v_other_portal:getWorldPosition(), shape.worldRotation, true, true)
						sm.physics.applyImpulse(new_shape, v_other_portal_normal * shape.velocity:length() * shape.mass, true)
						shape:destroyShape()
					end
				end
			end]]
		end
	end

	return true
end

---@param owner AreaTrigger
function PortalGun:server_onTriggerProjectile(owner, hit_pos, hit_time, hit_velocity, proj_name, proj_owner, proj_damage, unknown, unknown2, proj_uuid)
	local v_other_portal = self.portals[owner:getUserData().idx]

	local v_other_portal_normal = get_portal_normal(v_other_portal)
	local v_proj_pos = v_other_portal:getWorldPosition()
	local v_proj_dir = (v_other_portal:getWorldRotation() * owner:getWorldRotation()) * hit_velocity
	print(hit_pos, v_proj_pos + v_other_portal_normal * 0.5, owner.id, sm.game.getCurrentTick())

	if type(proj_owner) == "Shape" then
	else
		sm.projectile.projectileAttack(proj_uuid, proj_damage, v_proj_pos + v_other_portal_normal * 0.5, v_proj_dir, proj_owner)
		--sm.projectile.customProjectileAttack({ portal = true }, proj_uuid, proj_damage, v_proj_pos + v_other_portal_normal * 1.5, v_proj_dir, proj_owner)
	end

	return true
end

function PortalGun:client_onPortalSpawn(data)
	local hit_pos    = data[1] --[[@as Vec3]]
	local hit_normal = data[2] --[[@as Vec3]]
	local portal_idx = data[3] --[[@as integer]]

	local hit_quat = sm.vec3.getRotation(sm.vec3.new(1, 0, 0), hit_normal)

	local v_old_effect = self.portal_effects[portal_idx]
	if v_old_effect and sm.exists(v_old_effect) then
		v_old_effect:stopImmediate()
		v_old_effect:destroy()
	end

	local v_new_effect = sm.effect.createEffect("Portanus")
	v_new_effect:setPosition(hit_pos + hit_normal * 0.08)
	v_new_effect:setRotation(hit_quat)
	v_new_effect:start()

	self.portal_effects[portal_idx] = v_new_effect
end

function PortalGun:server_createPortal(data)
	local hit_pos = data[1]
	local hit_normal = data[2]
	local portal_idx = data[3]

	local hit_quat = sm.vec3.getRotation(hit_normal, sm.vec3.new(0, 0, 1))
	local area_trigger = sm.areaTrigger.createBox(sm.vec3.new(0.8, 0.8, 0.05), hit_pos, hit_quat, sm.areaTrigger.filter.all, { idx = (portal_idx % 2) + 1 })
	area_trigger:bindOnEnter("server_onTriggerEnter")
	area_trigger:bindOnProjectile("server_onTriggerProjectile")

	local v_old_portal = self.portals[portal_idx] --[[@as AreaTrigger]]
	if v_old_portal and sm.exists(v_old_portal) then
		sm.areaTrigger.destroy(v_old_portal)
	end

	self.portals[portal_idx] = area_trigger

	self.network:sendToClients("client_onPortalSpawn", data)
end

function PortalGun:cl_placePortalClient(portal_index)
	local owner = self.tool:getOwner()
	if owner == nil or owner.character == nil then return end

	local hit, result = sm.localPlayer.getRaycast(500)
	if hit then
		self.network:sendToServer("server_createPortal", { result.pointWorld, result.normalWorld, portal_index })
	end
end

function PortalGun:client_onReload()
	print("test")
	return true
end

function PortalGun.cl_onPrimaryUse( self, state )
	if state == sm.tool.interactState.start then
		self:cl_placePortalClient(1)
	end
end

function PortalGun.cl_onSecondaryUse( self, state )
	if state == sm.tool.interactState.start then
		self:cl_placePortalClient(2)
	end
end

function PortalGun.client_onEquippedUpdate( self, primaryState, secondaryState )
	if primaryState ~= self.prevPrimaryState then
		self:cl_onPrimaryUse( primaryState )
		self.prevPrimaryState = primaryState
	end

	if secondaryState ~= self.prevSecondaryState then
		self:cl_onSecondaryUse( secondaryState )
		self.prevSecondaryState = secondaryState
	end

	return true, true
end
