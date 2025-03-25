local Cache = shared.kernel:GetLocalClass("Cache")

local expecttype = shared.kernel:GetBaseLibrary().expecttype

local CCache = {} do
	
	CCache.__base = { Cache }
	
	function CCache:constructor(constructor, cleaner)
		Cache.constructor(self, constructor)
		
		self._Cleaner = expecttype(cleaner, "function")
	end
	
	function CCache:Store(item)
		Cache.Store(self, item)
		self._Cleaner(item)
	end
	
end

return CCache