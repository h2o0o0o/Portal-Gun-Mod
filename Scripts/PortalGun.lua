dofile( "$GAME_DATA/Scripts/game/AnimationUtil.lua" )
dofile( "$SURVIVAL_DATA/Scripts/util.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/survival_shapes.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/survival_projectiles.lua" )

---@class PortalData
---@field portal AreaTrigger
---@field localOffset Vec3
---@field localNormal Vec3
---@field owner any

---@class ClosingPortalData
---@field effect Effect
---@field owner any
---@field localOffset Vec3
---@field localNormal Vec3

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
---@field portals PortalData[]
---@field portal_effects Effect[]
---@field client_portals PortalData[]
---@field cl_cached_shapes boolean[]
---@field cl_closing_portals ClosingPortalData[]
PortalGun = class()

local renderables = { "$CONTENT_DATA/Tools/Renderables/portalgun_model.rend" }
local renderablesTp = { "$GAME_DATA/Character/Char_Male/Animations/char_male_tp_connecttool.rend", "$CONTENT_DATA/Tools/Renderables/portalgun_tp_offset.rend" }
local renderablesFp = { "$CONTENT_DATA/Tools/Renderables/portalgun_fp_anim.rend", "$CONTENT_DATA/Tools/Renderables/portalgun_tp_offset.rend" }

sm.tool.preloadRenderables( renderables )
sm.tool.preloadRenderables( renderablesTp )
sm.tool.preloadRenderables( renderablesFp )

function PortalGun:server_requestPortals(data, caller)
	for k, v in pairs(self.portals) do
		if v then
			local v_cur_portal = v.portal
			if v_cur_portal and sm.exists(v_cur_portal) then
				if v.owner then
					self.network:sendToClient(caller, "client_onPortalSpawn", { k, v.localOffset, v.localNormal, v.owner })
				else
					self.network:sendToClient(caller, "client_onPortalSpawn", { k, v.localOffset, v.localNormal })
				end
			end
		end
	end
end

function PortalGun:client_onCreate()
	if not self.tool:isLocal() then
		self.network:sendToServer("server_requestPortals")
	end

	self.shootEffect = sm.effect.createEffect( "SpudgunBasic - BasicMuzzel" )
	self.shootEffectFP = sm.effect.createEffect( "SpudgunBasic - FPBasicMuzzel" )

	self.portal_timer = 0
	self.portal_effects = {
		sm.effect.createEffect("Portanus"),
		sm.effect.createEffect("Portanus")
	}

	self.client_portals = {}
	self.client_enter_timers = {}
	self.cl_cached_shapes = {}
	self.cl_closing_portals = {}
end

function PortalGun:client_onDestroy()
	self:client_removePortals()

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
	self:server_removePortals()
end

function PortalGun.client_onRefresh( self )
	self:loadAnimations()
end

function PortalGun.loadAnimations( self )

	self.tpAnimations = createTpAnimations(
		self.tool,
		{
			shoot = { "spudgun_shoot", { crouch = "spudgun_crouch_shoot" } },
			idle = { "connecttool_idle" },
			pickup = { "connecttool_pickup", { nextAnimation = "idle" } },
			putdown = { "connecttool_putdown" }
		}
	)
	local movementAnimations = {
		idle = "connecttool_idle",
		idleRelaxed = "connecttool_idle_relaxed",

		sprint = "connecttool_sprint",
		runFwd = "connecttool_run_fwd",
		runBwd = "connecttool_run_bwd",

		jump = "connecttool_jump",
		jumpUp = "connecttool_jump_up",
		jumpDown = "connecttool_jump_down",

		land = "connecttool_jump_land",
		landFwd = "connecttool_jump_land_fwd",
		landBwd = "connecttool_jump_land_bwd",

		crouchIdle = "connecttool_crouch_idle",
		crouchFwd = "connecttool_crouch_fwd",
		crouchBwd = "connecttool_crouch_bwd"
	}

	for name, animation in pairs( movementAnimations ) do
		self.tool:setMovementAnimation( name, animation )
	end

	setTpAnimation( self.tpAnimations, "idle", 5.0 )

	if self.tool:isLocal() then
		self.fpAnimations = createFpAnimations(
			self.tool,
			{
				equip = { "connecttool_pickup", { nextAnimation = "idle" } },
				unequip = { "connecttool_putdown" },

				idle = { "PortalGun_idle", { looping = true } },

				sprintInto = { "connecttool_sprint_into", { nextAnimation = "sprintIdle",  blendNext = 0.2 } },
				sprintExit = { "connecttool_sprint_exit", { nextAnimation = "idle",  blendNext = 0 } },
				sprintIdle = { "connecttool_sprint_idle", { looping = true } },
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
---@return Vec3
local function get_portal_normal(portal)
	return portal:getWorldRotation() * _sm_vec3_z --[[@as Vec3]]
end

local function draw_line(start_vec, end_vec, steps)
	for i = 1, steps do
		sm.particle.createParticle("construct_welding", sm.vec3.lerp(start_vec, end_vec, i / steps))
	end
end

---@return Vec3
local function vector_reflect(vec, normal)
	return vec - normal * (2 * normal:dot(vec)) --[[@as Vec3]]
end

local function find_vector_angles(vec)
	local output = {}
	output.pitch = math.asin(vec.z)
	output.yaw = math.atan2(vec.y, vec.x)

	return output
end

local function find_right_vector(vector)
    local yaw = math.atan2(vector.y, vector.x) - math.pi / 2
    return sm.vec3.new(math.cos(yaw), math.sin(yaw), 0)
end

local portal_color1 = sm.color.new(0x32a865ff)
local portal_color2 = sm.color.new(0x21c29cff)
local portal_color_vec1 = sm.vec3.new(portal_color1.r, portal_color1.g, portal_color1.b)
local portal_color_vec2 = sm.vec3.new(portal_color2.r, portal_color2.g, portal_color2.b)
function PortalGun:client_onUpdate( dt )
	--[[local hit, result = sm.physics.raycast(sm.camera.getPosition(), sm.camera.getPosition() + sm.camera.getDirection() * 10, nil, sm.physics.filter.areaTrigger)
	if hit and result.type == "areaTrigger" then
		local v_direction = (sm.camera.getPosition() - result.pointWorld):normalize()

		local v_current_portal = result:getAreaTrigger()
		local v_other_portal_data = self.portals[v_current_portal:getUserData().idx]
		local v_other_portal = v_other_portal_data.portal
		local v_other_portal_pos = v_other_portal:getWorldPosition()
		local v_current_portal_pos = v_current_portal:getWorldPosition()

		local v_other_portal_normal = get_portal_normal(v_other_portal)
		local v_current_portal_normal = get_portal_normal(v_current_portal)

		local v_reflected_dir = vector_reflect(v_direction, v_other_portal_normal)
		--local v_reflected_refl_dir = vector_reflect(v_reflected_dir, v_other_portal_normal)

		--local v_cur_normal_angles = find_vector_angles(v_other_portal:getWorldRotation() * v_current_portal_normal)
		----local v_dir_angles        = find_vector_angles(v_direction)

		--local v_angle_diff = { pitch = v_cur_normal_angles.pitch - v_dir_angles.pitch, yaw = v_cur_normal_angles.yaw - v_dir_angles.yaw }

		local v_proj_dir = v_reflected_dir
		--v_proj_dir = v_proj_dir:rotate(-v_angle_diff.pitch, find_right_vector(v_other_portal_normal))
		--v_proj_dir = v_proj_dir:rotate(-v_angle_diff.yaw, sm.vec3.new(0, 0, 1))
		draw_line(v_other_portal:getWorldPosition(), v_other_portal:getWorldPosition() + v_proj_dir * 5, 3)
	end]]
	for k, v in pairs(self.cl_closing_portals) do
		local v_cur_effect = v.effect
		if v_cur_effect:isPlaying() then
			local v_eff_owner = v.owner --[[@as Shape]]
			if v_eff_owner and sm.exists(v_eff_owner) then
				local v_eff_pos = v_eff_owner:getInterpolatedWorldPosition() + v_eff_owner.velocity * dt

				v_cur_effect:setPosition(v_eff_pos + v_eff_owner.worldRotation * v.localOffset)
				v_cur_effect:setRotation(v_eff_owner.worldRotation * sm.vec3.getRotation(sm.vec3.new(0, 0, 1), v.localNormal))
			else
				v_cur_effect:stopImmediate()
			end
		else
			v_cur_effect:destroy()
			self.cl_closing_portals[k] = nil
		end
	end

	for k, v in pairs(self.client_enter_timers) do
		self.client_enter_timers[k] = v - dt

		if v <= 0.0 then
			self.client_enter_timers[k] = nil
		end
	end

	for k, v in pairs(self.client_portals) do
		if v then
			local cur_portal = v.portal

			if sm.exists(cur_portal) then
				local cur_portal_owner = v.owner --[[@as Shape]]
				if cur_portal_owner then
					if sm.exists(cur_portal_owner) then
						local v_portal_pos = cur_portal_owner:getInterpolatedWorldPosition() + cur_portal_owner.velocity * dt

						cur_portal:setWorldPosition(v_portal_pos + cur_portal_owner.worldRotation * v.localOffset --[[@as Vec3]])
						cur_portal:setWorldRotation(cur_portal_owner.worldRotation * sm.vec3.getRotation(sm.vec3.new(0, 0, 1), v.localNormal))
					else
						sm.areaTrigger.destroy(cur_portal)
						self.client_portals[k] = nil
					end
				end
			end
		end
	end

	self.portal_timer = self.portal_timer + dt * 3
	for k, v in pairs(self.portal_effects) do
		local cur_portal_data = self.client_portals[k]
		if cur_portal_data and (cur_portal_data.portal and sm.exists(cur_portal_data.portal)) then
			local v_portal_owner = cur_portal_data.owner --[[@as Shape]]
			local v_cur_portal = cur_portal_data.portal
			if v_portal_owner and sm.exists(v_portal_owner) then
				local v_portal_pos = v_portal_owner:getInterpolatedWorldPosition() + v_portal_owner.velocity * dt
				v:setPosition(v_portal_pos + v_portal_owner.worldRotation * cur_portal_data.localOffset --[[@as Vec3]])
			else
				v:setPosition(v_cur_portal:getWorldPosition())
			end

			v:setRotation(v_cur_portal:getWorldRotation())

			if not v:isPlaying() then
				v:start()
			end

			local v_timer_value = self.client_enter_timers[k] or 0.0
			local light_intensity = math.abs(sm.noise.perlinNoise2d(self.portal_timer, 1, 1337 + k)) + (v_timer_value * 2)
			v:setParameter("intensity", (light_intensity * 0.3) + 1)

			local color_lerp = sm.vec3.lerp(portal_color_vec1, portal_color_vec2, light_intensity)
			v:setParameter("color", sm.color.new(color_lerp.x, color_lerp.y, color_lerp.z))
		else
			if v:isPlaying() then
				v:stopImmediate()
			end
		end
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
		local firePos = self.tool:getFpBonePos( "jnt_portalgun_shoot" )

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
	local pos = self.tool:getTpBonePos( "jnt_portalgun_shoot" )
	local dir = self.tool:getTpBoneDir( "jnt_portalgun_shoot" )

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

function PortalGun:server_onFixedUpdate(dt)
	for k, v in pairs(self.cooldown_data) do
		self.cooldown_data[k] = v - 1

		if v <= 0 then
			self.cooldown_data[k] = nil
		end
	end

	for k, v in pairs(self.portals) do
		if v then
			local cur_portal = v.portal
			local cur_portal_owner = v.owner
			if sm.exists(cur_portal) and cur_portal_owner then
				if sm.exists(cur_portal_owner) then
					local portal_pos = cur_portal_owner:getInterpolatedWorldPosition() + cur_portal_owner.velocity * dt

					cur_portal:setWorldPosition(portal_pos + cur_portal_owner.worldRotation * v.localOffset --[[@as Vec3]])
					cur_portal:setWorldRotation(cur_portal_owner.worldRotation * sm.vec3.getRotation(sm.vec3.new(0, 0, 1), v.localNormal) --[[@as Quat]])
				else
					sm.areaTrigger.destroy(cur_portal)
					self.portals[k] = nil
				end
			end
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

---@param shape Shape
local function spawn_debri_from_shape(self, shape, portal_normal, portal_pos)
	if self.cl_cached_shapes[shape.id] ~= nil then
		return
	end

	local m_pi_5 = math.pi * 10
	local v_debri_speed = math.max(math.abs(shape.velocity:length()), 5)
	local v_debri_vel = sm.noise.gunSpread(portal_normal, 80) * v_debri_speed --[[@as Vec3]]
	local v_angular_vel = sm.vec3.new(math.random(0, m_pi_5), math.random(0, m_pi_5), math.random(0, m_pi_5))

	sm.debris.createDebris(shape.uuid, portal_pos, shape.worldRotation, v_debri_vel, v_angular_vel, shape.color, math.random(4, 10))
	sm.particle.createParticle("portal_teleport_bullet", portal_pos, sm.vec3.getRotation(sm.vec3.new(0, 0, 1), v_debri_vel))

	self.cl_cached_shapes[shape.id] = true
end

---@param body Body
local function create_safe_body_list(body)
	local v_output = {}

	for k, body in pairs(body:getCreationBodies()) do
		v_output[body.id] = true
	end

	return v_output
end

function PortalGun:client_onTriggerProjectile(owner, hit_pos, hit_time, hit_velocity, proj_name, proj_owner, proj_damage, unknown, unknown2, proj_uuid)
	local v_other_idx = owner:getUserData().idx
	local v_other_portal_data = self.client_portals[v_other_idx]
	if not v_other_portal_data then return end

	local v_other_portal = v_other_portal_data.portal
	if not sm.exists(v_other_portal) then return end

	local v_other_portal_norm = get_portal_normal(v_other_portal)
	local v_other_portal_pos = v_other_portal:getWorldPosition() + v_other_portal_norm * 0.05

	sm.particle.createParticle("portal_teleport_bullet_obj", v_other_portal_pos, sm.vec3.getRotation(sm.vec3.new(0, 0, 1), v_other_portal_norm))

	self.client_enter_timers[v_other_idx] = 0.5

	return not sm.isHost
end

function PortalGun:client_onTriggerStay(owner, data)
	local v_other_idx = owner:getUserData().idx
	local v_other_portal_data = self.client_portals[v_other_idx]
	if not v_other_portal_data then return end

	local v_other_portal = v_other_portal_data.portal
	if not sm.exists(v_other_portal) then
		return
	end

	local v_self_owner = self.client_portals[(v_other_idx % 2) + 1].owner
	if v_self_owner and not sm.exists(v_self_owner) then
		v_self_owner = nil
	end

	local v_other_portal_pos = v_other_portal:getWorldPosition()
	local v_other_portal_norm = get_portal_normal(v_other_portal)

	for k, v in ipairs(data) do
		local v_type_data = type(v)
		if v_type_data == "Body" then
			if v_self_owner then
				local v_owner_safe_list = create_safe_body_list(v_self_owner.body)
				for i, shape_data in ipairs(owner:getShapes()) do
					local v_cur_shape = shape_data.shape --[[@as Shape]]
					if sm.exists(v_cur_shape) and v_owner_safe_list[v_cur_shape.body.id] == nil then
						spawn_debri_from_shape(self, v_cur_shape, v_other_portal_norm, v_other_portal_pos)

						self.client_enter_timers[v_other_idx] = 1.0
					end
				end
			else
				self.client_enter_timers[v_other_idx] = 1.0

				for i, shape_data in ipairs(owner:getShapes()) do
					local v_cur_shape = shape_data.shape --[[@as Shape]]
					if sm.exists(v_cur_shape) then
						spawn_debri_from_shape(self, v_cur_shape, v_other_portal_norm, v_other_portal_pos)
					end
				end
			end
		elseif v_type_data == "Character" then
			self.client_enter_timers[v_other_idx] = 1.0
			sm.particle.createParticle("portal_teleport_bullet", v_other_portal_pos, sm.vec3.getRotation(sm.vec3.new(0, 0, 1), v_other_portal_norm))
			sm.effect.playEffect("Portanus - Teleport", v_other_portal_pos)
		end
	end
end

local _sm_item_isBlock = sm.item.isBlock
local _sm_exists = sm.exists

---@param owner AreaTrigger
function PortalGun:server_onTriggerStay(owner, data)
	local v_other_idx = owner:getUserData().idx
	local v_other_portal_data = self.portals[v_other_idx]
	if not v_other_portal_data then return end

	local v_other_portal = v_other_portal_data.portal
	if not _sm_exists(v_other_portal) then
		return
	end

	local v_self_owner = self.portals[(v_other_idx % 2) + 1].owner
	if not _sm_exists(v_self_owner) then
		v_self_owner = nil
	end

	local v_other_portal_normal = get_portal_normal(v_other_portal)
	for k, v in ipairs(data) do
		local v_type_str = type(v)
		if (v_type_str == "Character" or v_type_str == "Unit") and self.cooldown_data[v.id] == nil then
			self.cooldown_data[v.id] = 2

			v:setWorldPosition(v_other_portal:getWorldPosition() + v_other_portal_normal * (v:getHeight() * 0.5) --[[@as Vec3]])
			local v_vel = v.velocity

			sm.physics.applyImpulse(v --[[@as Character]], v_vel * -v.mass, true)
			sm.physics.applyImpulse(v --[[@as Character]], v_other_portal_normal * v_vel:length() * v.mass --[[@as Vec3]], true)
		elseif v_type_str == "Body" then
			if v_self_owner then
				local v_owner_creation_id = v_self_owner.body:getCreationId()
				for _, v_shape_data in ipairs(owner:getShapes()) do
					local v_shape = v_shape_data.shape --[[@as Shape]]
					if _sm_exists(v_shape) and v_shape.body:getCreationId() ~= v_owner_creation_id then
						if _sm_item_isBlock(v_shape.uuid) then
							local v_blk_pos = v_shape:getClosestBlockLocalPosition(v_shape_data.shapeWorldPosition)
							v_shape:destroyBlock(v_blk_pos, sm.vec3.one())
						else
							v_shape:destroyShape()
						end
					end
				end
			else
				for _, v_shape_data in ipairs(owner:getShapes()) do
					local v_shape = v_shape_data.shape
					if _sm_exists(v_shape) then
						if _sm_item_isBlock(v_shape.uuid) then
							local v_blk_pos = v_shape:getClosestBlockLocalPosition(v_shape_data.shapeWorldPosition)
							v_shape:destroyBlock(v_blk_pos, sm.vec3.one())
						else
							v_shape:destroyShape()
						end
					end
				end
			end
		end
	end
end

---@param owner AreaTrigger
function PortalGun:server_onTriggerProjectile(owner, hit_pos, hit_time, hit_velocity, proj_name, proj_owner, proj_damage, unknown, unknown2, proj_uuid)
	local v_other_portal_data = self.portals[owner:getUserData().idx]
	if not v_other_portal_data then return end

	local v_other_portal = v_other_portal_data.portal
	if not sm.exists(v_other_portal) then return end

	local v_other_portal_normal = get_portal_normal(v_other_portal)
	local v_proj_pos = v_other_portal:getWorldPosition() + v_other_portal_normal * 0.15
	local v_proj_dir = sm.noise.gunSpread(v_other_portal_normal, 20) * (hit_velocity:length() * 0.8)

	--[[local v_other_portal_normal = get_portal_normal(v_other_portal)
	local v_proj_pos = v_other_portal:getWorldPosition() + v_other_portal_normal * 0.15
	local v_proj_rot = owner:getWorldRotation() * v_other_portal:getWorldRotation()
	local v_proj_dir = v_proj_rot * vector_reflect(hit_velocity:normalize(), v_other_portal_normal) * (hit_velocity:length() * 0.95)]]

	local v_new_damage = math.floor(proj_damage * 0.9)
	if v_new_damage > 0 then
		if proj_owner and sm.exists(proj_owner) then
			if type(proj_owner) == "Shape" then
				local v_global_pos = proj_owner:transformPoint(v_proj_pos)
				local v_global_vel = proj_owner:transformDirection(v_proj_dir)
	
				sm.projectile.shapeProjectileAttack(proj_uuid, v_new_damage, v_global_pos, v_global_vel, proj_owner)
			else
				sm.projectile.projectileAttack(proj_uuid, v_new_damage, v_proj_pos, v_proj_dir, proj_owner)
			end
		end
	end

	return true
end

---@param self PortalGun
---@param v PortalData
local function client_spawnClosingPortalEffect(self, v, effect_name)
	local v_owner = v.owner --[[@as Shape]]
	if v_owner and sm.exists(v_owner) then
		local v_closing_effect = sm.effect.createEffect(effect_name)
		v_closing_effect:setPosition(v_owner.worldPosition + v_owner.worldRotation * v.localOffset)
		v_closing_effect:setRotation(v_owner.worldRotation * sm.vec3.getRotation(sm.vec3.new(0, 0, 1), v.localNormal))
		v_closing_effect:start()

		local v_new_idx = #self.cl_closing_portals + 1
		self.cl_closing_portals[v_new_idx] = {
			effect = v_closing_effect,
			owner = v.owner,
			localOffset = v.localOffset,
			localNormal = v.localNormal
		}
	else
		local v_portal = v.portal
		if sm.exists(v_portal) then
			sm.effect.playEffect(effect_name, v_portal:getWorldPosition(), sm.vec3.zero(), v_portal:getWorldRotation())
		end
	end
end

function PortalGun:client_onPortalSpawn(data)
	local portal_idx = data[1]
	local hit_pos = data[2]
	local hit_normal = data[3]
	local portal_owner = data[4]

	if portal_owner and not sm.exists(portal_owner) then
		return
	end

	local area_trigger = nil
	if portal_owner then
		local pos_calc = portal_owner.worldPosition + portal_owner.worldRotation * hit_pos --[[@as Vec3]]
		local quat_calc = portal_owner.worldRotation * sm.vec3.getRotation(sm.vec3.new(0, 0, 1), hit_normal) --[[@as Quat]]
		area_trigger = sm.areaTrigger.createBox(sm.vec3.new(0.8, 0.8, 0.05), pos_calc, quat_calc, sm.areaTrigger.filter.all, { idx = (portal_idx % 2) + 1 })

		local quat_calc2 = portal_owner.worldRotation * sm.vec3.getRotation(sm.vec3.new(0, 0, 1), hit_normal) --[[@as Quat]]
		sm.particle.createParticle("portal_poof", pos_calc, quat_calc2)
	else
		local hit_quat = sm.vec3.getRotation(sm.vec3.new(0, 0, 1), hit_normal)
		area_trigger = sm.areaTrigger.createBox(sm.vec3.new(0.8, 0.8, 0.05), hit_pos + hit_normal * 0.1 --[[@as Vec3]], hit_quat, sm.areaTrigger.filter.all, { idx = (portal_idx % 2) + 1 })

		sm.particle.createParticle("portal_poof", hit_pos, hit_quat)
	end

	local cur_effect = self.portal_effects[portal_idx]
	if sm.exists(cur_effect) and cur_effect:isPlaying() then
		cur_effect:stopImmediate()
		cur_effect:start()
	end

	area_trigger:bindOnStay("client_onTriggerStay")
	area_trigger:bindOnEnter("client_onTriggerStay")
	area_trigger:bindOnProjectile("client_onTriggerProjectile")
	area_trigger:setShapeDetection(true)

	local v_old_portal = self.client_portals[portal_idx]
	if v_old_portal and sm.exists(v_old_portal.portal) then
		client_spawnClosingPortalEffect(self, v_old_portal, "Portanus - CloseNoSound")

		sm.areaTrigger.destroy(v_old_portal.portal)
	end

	if portal_owner then
		self.client_portals[portal_idx] = { portal = area_trigger, localOffset = hit_pos, localNormal = hit_normal, owner = portal_owner }
	else
		self.client_portals[portal_idx] = { portal = area_trigger, localOffset = hit_pos, localNormal = hit_normal }
	end

	self.client_enter_timers[portal_idx] = 1.5
end

function PortalGun:server_createPortal(data)
	local portal_idx = data[1]
	local hit_pos = data[2]
	local hit_normal = data[3]
	local portal_owner = data[4]

	if portal_owner and not sm.exists(portal_owner) then
		return
	end

	local area_trigger = nil
	if portal_owner then
		local pos_calc = portal_owner.worldPosition + portal_owner.worldRotation * hit_pos --[[@as Vec3]]
		local quat_calc = portal_owner.worldRotation * sm.vec3.getRotation(sm.vec3.new(0, 0, 1), hit_normal) --[[@as Quat]]
		area_trigger = sm.areaTrigger.createBox(sm.vec3.new(0.8, 0.8, 0.05), pos_calc, quat_calc, sm.areaTrigger.filter.all, { idx = (portal_idx % 2) + 1 })
	else
		local hit_quat = sm.vec3.getRotation(sm.vec3.new(0, 0, 1), hit_normal)
		area_trigger = sm.areaTrigger.createBox(sm.vec3.new(0.8, 0.8, 0.05), hit_pos + hit_normal * 0.1 --[[@as Vec3]], hit_quat, sm.areaTrigger.filter.all, { idx = (portal_idx % 2) + 1 })
	end

	area_trigger:bindOnProjectile("server_onTriggerProjectile")
	area_trigger:bindOnStay("server_onTriggerStay")
	area_trigger:bindOnEnter("server_onTriggerStay")
	area_trigger:setShapeDetection(true)

	local v_old_portal = self.portals[portal_idx]
	if v_old_portal and sm.exists(v_old_portal.portal) then
		sm.areaTrigger.destroy(v_old_portal.portal)
	end

	if portal_owner then
		self.portals[portal_idx] = { portal = area_trigger, localOffset = hit_pos, localNormal = hit_normal, owner = portal_owner }
	else
		self.portals[portal_idx] = { portal = area_trigger, localOffset = hit_pos, localNormal = hit_normal }
	end

	self.network:sendToClients("client_onPortalSpawn", data)
end

local g_allowed_placement_types =
{
	["body"] = true,
	["terrainSurface"] = true,
	["terrainAsset"] = true
}

function PortalGun:cl_placePortalClient(portal_index)
	local owner = self.tool:getOwner()
	if owner == nil or owner.character == nil then return end

	local hit, result = sm.localPlayer.getRaycast(500)
	if not hit then return end

	local r_type = result.type
	if g_allowed_placement_types[r_type] == nil then
		return
	end

	local v_portal_pos = result.pointWorld
	local v_portal_normal = result.normalWorld
	local v_portal_owner = nil
	if r_type == "body" then
		v_portal_owner = result:getShape()
		if sm.item.isJoint(v_portal_owner.uuid) then
			return
		end

		v_portal_pos    = v_portal_owner:transformPoint(result.pointWorld + result.normalWorld/16)
		v_portal_normal = v_portal_owner:transformDirection(result.normalWorld)
	end

	self.network:sendToServer("server_createPortal", { portal_index, v_portal_pos, v_portal_normal, v_portal_owner })
end

function PortalGun:client_removePortals(spawn_effects)
	for k, v in pairs(self.portal_effects) do
		if v and sm.exists(v) then
			if v:isPlaying() then
				v:stopImmediate()
			end
		end
	end

	for k, v in pairs(self.client_portals) do
		if v then
			local v_portal = v.portal
			if sm.exists(v_portal) then
				if spawn_effects then
					client_spawnClosingPortalEffect(self, v, "Portanus - CloseNoSound")
				end

				sm.areaTrigger.destroy(v_portal)
			end
		end

		self.client_portals[k] = nil
	end
end

function PortalGun:server_removePortals()
	for k, v in pairs(self.portals) do
		if v and sm.exists(v.portal) then
			sm.areaTrigger.destroy(v.portal)
		end

		self.portals[k] = nil
	end
end

function PortalGun:client_portalCleanup()
	if not self.tool:isLocal() then
		self:client_removePortals(true)
	end
end

function PortalGun:server_portalCleanup()
	self.network:sendToClients("client_portalCleanup")
	self:server_removePortals()
end

function PortalGun:client_onReload()
	self.network:sendToServer("server_portalCleanup")
	self:client_removePortals(true)
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
