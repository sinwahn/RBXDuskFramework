local baseLibrary = require(script.Parent.BaseLibrary)
local kernelSettings = require(script.Parent.KernelSettings)

local buildclass = baseLibrary.buildclass
local errorf = baseLibrary.errorf
local assertf = baseLibrary.assertf
local expecttype = baseLibrary.expecttype
local expectrbxtype = baseLibrary.expectrbxtype

local ENUMS_MODULE_NAME = "Enums"

local IMPLEMENTATION_MODULE_EXTENSION = "impl"

local function createFullName(namePrefix : string, name : string)
	expecttype(namePrefix, "string")
	expecttype(name, "string")

	if namePrefix == "" then
		return name
	end

	return namePrefix .. '.' .. name
end

local Module = {} do
	Module.__index = Module

	function Module.new(module : ModuleScript)
		local self = setmetatable({}, Module)
		self.Name = module.Name
		self._Instance = module
		self._IsInitialized = false
		self._ReturnValue = nil
		return self
	end

	function Module:GetReturnValue()
		if self._IsInitialized then
			return self._ReturnValue
		end
		
		local result = require(self._Instance)
		if type(result) ~= "table" then
			error(`expected 'table' value to be returned, got '{type(result)}'\nfrom module '{self._Instance:GetFullName()}'`)
		end

		self._ReturnValue = result
		self._IsInitialized = true
		return result
	end

end

local ModuleCollector = {} do
	ModuleCollector.__index = ModuleCollector

	function ModuleCollector.new()
		local self = setmetatable({}, ModuleCollector)
		self.CollectedModules = {}
		return self
	end

	function ModuleCollector:Collect(root : Instance)
		error("pure virtual method")
	end

	function ModuleCollector:AddModule(name : string, module)
		local existing = self.CollectedModules[name]
		if existing then
			errorf("cannot register files with the same name '%s':\nregistered: %s,\nnew: %s",
				name,
				existing._Instance:GetFullName(),
				module._Instance:GetFullName()
			)
		end

		self.CollectedModules[name] = module
	end

end

local LibraryCollector = setmetatable({}, ModuleCollector) do
	LibraryCollector.__index = LibraryCollector

	function LibraryCollector.new()
		local self = setmetatable(ModuleCollector.new(), LibraryCollector)
		return self
	end

	function LibraryCollector:Collect(rootFolder : Instance)
		for _, file in next, rootFolder:GetDescendants() do
			if not file:IsA("ModuleScript") then continue end

			self:AddModule(file.Name, Module.new(file))
		end
	end

	function LibraryCollector:GetLibrary(name : string)
		local module = self.CollectedModules[name]
		if not module then
			errorf("'%s' is invalid library name", name)
		end
		return module
	end

end

local ClassModule = setmetatable({}, Module) do
	ClassModule.__index = ClassModule

	function ClassModule.new(module : ModuleScript, fullName : string)
		local self = setmetatable(Module.new(module), ClassModule)
		expecttype(fullName, "string")
		self.FullName = fullName
		return self
	end

	function ClassModule:GetReturnValueAsClass()
		local class = self:GetReturnValue()
		if not class then return end

		if not class.__type then
			buildclass(self.Name, class)
		end

		return class
	end

end

local Package = setmetatable({}, ModuleCollector) do
	Package.__index = Package

	function Package.new(packageManager, folder, name, prefixName)
		local self = setmetatable(ModuleCollector.new(), Package)

		self.Name = name
		self.FullName = createFullName(prefixName, name)
		self.Folder = folder
		self.Enums = nil

		self._PackageManager = packageManager
		self._EnumsModule = nil
		self._ModuleNameToImplementation = {}
		self._Packages = {}

		return self
	end

	function Package:GetClass(name)
		local module = self.CollectedModules[name]
		if not module then
			errorf("'%s' is invalid class name", name)
		end
		return module:GetReturnValueAsClass()
	end

	function Package:GetEnum(name)
		if not self.Enums then
			errorf("Package '%s' does not contain enums", self.Name)
		end

		local enum = self.Enums[name]
		if not enum then
			errorf("'%s' is invalid enum name", name)
		end

		return enum
	end

	local initializeEnums do
		local invalidIndexHandler = {}
		function invalidIndexHandler:__index(name)
			errorf("Enum '%s' has no '%s' member", self.__Name, tostring(name))
		end

		function initializeEnums(enums)
			for enumName, enum in next, enums do
				local toAdd = {}
				for name, value in next, enum do
					toAdd[value] = name
				end
				for value, name in next, toAdd do
					enum[value] = name
				end
				enum.__Name = enumName
				setmetatable(enum, invalidIndexHandler)
				table.freeze(enum)
			end
		end
	end

	function Package:RegisterEnums(enumsModule)
		if self._EnumsModule then
			errorf("Duplicate enums in package '%s', registered: %s, new: %s",
				self.Name,
				self._EnumsModule:GetFullName(),
				enumsModule:GetFullName()
			)
		end

		local enums = expecttype(require(enumsModule), "table")
		initializeEnums(enums)
		self._PackageManager:RegisterEnumModule(self.FullName, enums)

		self.Enums = enums
		self._EnumsModule = enumsModule
	end

	function Package:RegisterClass(child : ModuleScript)
		local fileName = child.Name
		local moduleName, extension = string.match(fileName, "(.+)%.([^%.]+)$")

		if extension == IMPLEMENTATION_MODULE_EXTENSION then
			self._ModuleNameToImplementation[moduleName] = child
		else
			local fullName = createFullName(self.FullName, fileName)
			local module = ClassModule.new(child, fullName)
			self:AddModule(fileName, module)
			self._PackageManager:RegisterClass(fullName, module)
		end
	end

	function Package:FindSubPackage(name)
		return self._Packages[name]
	end

	function Package:RegisterSubPackage(package)
		if self._Packages[package.Name] then
			errorf("Duplicate package '%s' in '%s', at '%s'",
				package.Name,
				self.Name,
				package.Folder:GetFullName()
			)
		end

		self._Packages[package.Name] = package
	end

	function Package:Collect(root)
		for _, child in next, root:GetChildren() do
			if child:IsA("Folder") then
				local package = self._PackageManager:BuildPackage(child, child.Name, self.FullName)
				package:Collect(child)
				self:RegisterSubPackage(package)
				continue
			end

			if child:IsA("ModuleScript") then

				local fileName = child.Name

				if child.Name == ENUMS_MODULE_NAME then
					self:RegisterEnums(child)
				else
					self:RegisterClass(child)
				end

				self:Collect(child)
			end

		end
	end

end

local findSimilarFields do

	local THRESHOLD = 2
	local PRIMARY_RESULTS_SIZE = 5

	local function longestCommonSubstring(a: string, b: string)
		local maxLength = 0
		local endPos = 0
		local commonSubstringMatrix = table.create(#a)

		-- Initialize the matrix
		for i = 0, #a do
			commonSubstringMatrix[i] = {}
		end

		-- Populate the matrix and track the longest common substring
		for i = 1, #a do
			for j = 1, #b do
				if string.sub(a, i, i) == string.sub(b, j, j) then
					commonSubstringMatrix[i][j] = (commonSubstringMatrix[i - 1] and commonSubstringMatrix[i - 1][j - 1] or 0) + 1
					if commonSubstringMatrix[i][j] > maxLength then
						maxLength = commonSubstringMatrix[i][j]
						endPos = i
					end
				else
					commonSubstringMatrix[i][j] = 0
				end
			end
		end

		return string.sub(a, endPos - maxLength + 1, endPos), maxLength
	end

	function findSimilarFields(fullName: string, tableWithFieldsToFind: { [string]: any })
		local candidates = {}

		for className in next, tableWithFieldsToFind do
			local commonSubstring, length = longestCommonSubstring(fullName, className)
			if length > 0 then
				table.insert(candidates, {
					name = className,
					substring = commonSubstring,
					length = length
				})
			end
		end

		table.sort(candidates, function(a, b)
			return a.length > b.length
		end)

		local primary = {}
		local secondary = {}
		for index, candidate in next, candidates do
			if candidate.length >= THRESHOLD then
				if #primary < PRIMARY_RESULTS_SIZE then
					table.insert(primary, candidate.name)
				end
			end
		end

		return primary, secondary
	end

end

local PackageManager = {} do
	PackageManager.__index = PackageManager

	function PackageManager.new(classesFolders, mainScript)
		local self = setmetatable({}, PackageManager)

		self.Packages = {}
		self.Classes = {}
		self.Enums = {}

		local rootFolderPaths = {}
		for i, folder in next, classesFolders do
			expectrbxtype(folder, "Instance")
			rootFolderPaths[i] = folder:GetFullName()
		end

		self.RootFolderPaths = rootFolderPaths

		expectrbxtype(mainScript, "Instance")
		self.MainScriptPath = mainScript:GetFullName()
		self.RootPackage = nil

		return self
	end

	function PackageManager:RegisterClass(fullName : string, module : ClassModule)
		self.Classes[fullName] = module
	end

	function PackageManager:RegisterEnumModule(packageName : string, enumModule)
		for enumName, enum in next, enumModule do
			self.Enums[createFullName(packageName, enumName)] = enum
		end
	end

	-- ".class" aka "relative path" syntax support
	function PackageManager:PathToFullName(path : string, apiCallTraceOffset)
		if string.sub(path, 1, 1) ~= '.' then
			return path
		end

		local package = self:_GetLocalPackage(apiCallTraceOffset + 1)
		if package == self.RootPackage then
			-- cannot have dot as first symbol in root
			return string.sub(path, 2, -1)
		end

		return package.FullName .. path
	end

	function PackageManager:GetClass(path : string, apiCallTraceOffset)
		local fullName = self:PathToFullName(path, apiCallTraceOffset + 1)

		local classModule = self.Classes[fullName]
		if not classModule then
			local suggestions = findSimilarFields(fullName, self.Classes)
			if #suggestions > 0 then
				errorf("'%s' is invalid class module full name. Did you mean one of these?\n%s", 
					fullName, table.concat(suggestions, ",\n"))
			else
				errorf("'%s' is invalid class module full name", fullName)
			end
		end

		return classModule:GetReturnValueAsClass()
	end

	function PackageManager:GetEnum(path : string, apiCallTraceOffset)
		local fullName = self:PathToFullName(path, apiCallTraceOffset + 1)

		local enums = self.Enums[fullName]
		if not enums then
			local suggestions = findSimilarFields(fullName, self.Enums)
			if #suggestions > 0 then
				errorf("'%s' is invalid enums full name. Did you mean one of these?\n%s", 
					fullName, table.concat(suggestions, ",\n"))
			else
				errorf("'%s' is invalid enums full name", fullName)
			end
		end
		return enums
	end

	function PackageManager:BuildPackage(folder, name, prefixName)
		expectrbxtype(folder, "Instance")
		expecttype(name, "string")
		expecttype(prefixName, "string")
		local package = Package.new(self, folder, name, prefixName)
		table.insert(self.Packages, package)
		return package
	end

	function PackageManager:BuildRootPackage(folder)
		local root = self:BuildPackage(folder, "", "")
		self.RootPackage = root
		return root
	end

	function PackageManager:_GetLocalPackage(apiCallTraceOffset)
		local trace = debug.traceback("", 2 + apiCallTraceOffset)

		local lastLine = string.match(trace, "[^\n]+%s*$")
		lastLine = string.gsub(lastLine, "\n", "")

		-- Check if the last name is the main script (root package condition)
		local scriptPath = string.match(lastLine, "(.*):%d+$")
		if scriptPath and scriptPath == self.MainScriptPath then
			return self.RootPackage
		end

		local inClassesScriptPath
		local rootFolderNames = self.RootFolderPaths
		for _, path in next, rootFolderNames do
			if string.sub(scriptPath, 1, #path) == path then
				-- step to the next character; plus skipping '.'
				inClassesScriptPath = string.sub(scriptPath, #path + 2, -1)
				break
			end
		end

		local names = {}
		for substring in string.gmatch(inClassesScriptPath, "[^.]+") do
			table.insert(names, substring)
		end

		-- last line is running class
		table.remove(names)

		local currentPackage = self.RootPackage

		for _, name in next, names do
			local subPackage = currentPackage:FindSubPackage(name)
			if subPackage then
				currentPackage = subPackage
			end
		end

		return currentPackage
	end

end

local Kernel = {} do
	Kernel.__index = Kernel

	function Kernel.new(
		classesFolders : {Instance},
		librariesFolders : {Instance},
		mainScript : ModuleScript
	)
		local self = setmetatable({}, Kernel)

		expectrbxtype(classesFolders, "table")
		expectrbxtype(librariesFolders, "table")
		expectrbxtype(mainScript, "Instance")

		local libraryCollector = LibraryCollector.new()
		local packageManager = PackageManager.new(classesFolders, mainScript)

		self._MainScript = mainScript
		self._Finalized = false
		self._PackageManager = packageManager
		self._LibrariesCollector = libraryCollector

		local _, firstRootPackageContainer = next(classesFolders)
		expectrbxtype(firstRootPackageContainer, "Instance")

		local rootPackage = packageManager:BuildRootPackage(firstRootPackageContainer)

		for _, classFolder in next, classesFolders do
			expectrbxtype(classFolder, "Instance")
			rootPackage:Collect(classFolder)
		end

		for _, libraryFolder in next, librariesFolders do
			expectrbxtype(libraryFolder, "Instance")
			libraryCollector:Collect(libraryFolder)
		end

		return self
	end

	function Kernel:_InvokeMain()
		require(self._MainScript)

		if not self._Finalized then
			warn("classes are not finalized after running 'Main' module\nwrite 'shared.kernel:FinalizeClasses()' after all your imports")
		end
	end

	local expectclasstype = baseLibrary.expectclasstype

	function Kernel:_CheckFinalization(actionName : string)
		if self._Finalized then
			error(`cannot {actionName} after finalization`)
		end
	end

	function Kernel:GetClass(path : string)
		expecttype(path, "string")
		self:_CheckFinalization("import")
		return self._PackageManager:GetClass(path, 1)
	end

	function Kernel:GetLibrary(name : string)
		expecttype(name, "string")
		self:_CheckFinalization("import")
		return self._LibrariesCollector:GetLibrary(name):GetReturnValue()
	end

	function Kernel:GetEnum(path : string)
		expecttype(path, "string")
		self:_CheckFinalization("import")
		return self._PackageManager:GetEnum(path, 1)
	end

	function Kernel:FinalizeClasses()
		self:_CheckFinalization("finalize")

		for packageName, package in next, self._PackageManager.Packages do

			for moduleName, implementationModule in next, package._ModuleNameToImplementation do
				local class = package:GetClass(moduleName)
				baseLibrary.__registerimplementation(class, require(implementationModule))
			end
		end

		self._Finalized = true
		baseLibrary.__finalizeclasses()
	end

	function Kernel:GetBaseLibrary()
		return baseLibrary
	end

end

return Kernel