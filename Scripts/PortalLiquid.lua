---@class PortalLiquid : ShapeClass
PortalLiquid = class()

function PortalLiquid:server_onSledgehammer()
	if not sm.exists(self.shape) then
		return
	end

	sm.effect.playEffect("Sledgehammer - Destroy", self.shape.worldPosition, sm.vec3.zero(), sm.quat.identity(), sm.vec3.one(), { Material = 10 })
	sm.effect.playEffect("GlowstickProjectile - Bounce", self.shape.worldPosition)
	self.shape:destroyShape()
end