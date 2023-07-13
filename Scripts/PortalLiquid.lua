---@class PortalLiquid : ShapeClass
PortalLiquid = class()

local v_green_color = sm.color.new("3ecf00")

function PortalLiquid:server_destroyLiquid()
	if not sm.exists(self.shape) then
		return
	end

	sm.effect.playEffect("Sledgehammer - Destroy", self.shape.worldPosition, sm.vec3.zero(), sm.quat.identity(), sm.vec3.one(), { Material = 10 })
	sm.effect.playEffect("GlowstickProjectile - Bounce", self.shape.worldPosition, sm.vec3.zero(), sm.quat.identity(), sm.vec3.one(), { Color = v_green_color, color = v_green_color })

	self.shape:destroyShape()
end

function PortalLiquid:server_onSledgehammer()
	self:server_destroyLiquid()
end

function PortalLiquid:server_onProjectile()
	self:server_destroyLiquid()
end

function PortalLiquid:client_onCreate()
	self.timer = 0.01
	self.frame = 0
end

function PortalLiquid:client_onUpdate(dt)
	if self.timer > 0.0 then
		self.timer = self.timer - dt
	else
		self.timer = 1 / 30

		self.frame = (self.frame + 1) % 64
		self.interactable:setUvFrameIndex(self.frame)
	end
end