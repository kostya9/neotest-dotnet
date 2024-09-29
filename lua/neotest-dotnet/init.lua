local lib = require("neotest.lib")
local logger = require("neotest.logging")
local nio = require("nio")
local FrameworkDiscovery = require("neotest-dotnet.framework-discovery")
local build_spec_utils = require("neotest-dotnet.utils.build-spec-utils")

local DotnetNeotestAdapter = { name = "neotest-dotnet" }
local dap = { adapter_name = "netcoredbg" }
local custom_attribute_args
local dotnet_additional_args
local discovery_root = "project"

-- get omnisharp lsp client

DotnetNeoTestOmnisharp = {}

--- @return nio.lsp.Client?
--- @param bufnr integer
DotnetNeoTestOmnisharp.get_client = function(bufnr)
	local clients = vim.lsp.get_clients({ bufnr = bufnr })
	for _, client in ipairs(clients) do
		if client.name == "omnisharp" then
			return nio.lsp.get_client_by_id(client.id)
		end
	end
	return nil
end


--- @class dotnetneotest.omnisharp.test
--- @field CodeFilePath string
--- @field DisplayName string
--- @field LineNumber integer
--- @field Source string
--- @field FullyQualifiedName string

--- @param client nio.lsp.Client?
--- @param path string
--- @param bufnr integer
--- @return dotnetneotest.omnisharp.test[]
DotnetNeoTestOmnisharp.discover_tests = function(client, path, bufnr)
	if client == nil then
		client = DotnetNeoTestOmnisharp.get_client(bufnr)
	end
	if client == nil then
		logger.debug("dotnet-neotest: no omnisharp client found")
		return {}
	end

	local lsp_request = {
		filename = path,
	}


	vim.defer_fn(function()
		logger.debug("dotnet-neotest: found omnisharp client, discovering tests in path=" .. path)
		vim.notify(path)
	end, 0)
	local err, result = client.request['o#_v2_discovertests'](lsp_request, bufnr)
	if err then
		logger.warn("error getting tests " .. vim.inspect(err))
	else
		logger.debug("got tests " .. vim.inspect(result))
	end

	return result.Tests
end

DotnetNeotestAdapter.root = function(path)
	if discovery_root == "solution" then
		return lib.files.match_root_pattern("*.sln")(path)
	else
		return lib.files.match_root_pattern("*.csproj", "*.fsproj")(path)
	end
end

DotnetNeotestAdapter.is_test_file = function(file_path)
	if vim.endswith(file_path, ".cs") or vim.endswith(file_path, ".fs") then
		local content = lib.files.read(file_path)

		local found_derived_attribute
		local found_standard_test_attribute

		-- Combine all attribute list arrays into one
		local all_attributes = FrameworkDiscovery.all_test_attributes

		for _, test_attribute in ipairs(all_attributes) do
			if string.find(content, "%[" .. test_attribute) then
				found_standard_test_attribute = true
				break
			end
		end

		if custom_attribute_args then
			for _, framework_attrs in pairs(custom_attribute_args) do
				for _, value in ipairs(framework_attrs) do
					if string.find(content, "%[" .. value) then
						found_derived_attribute = true
						break
					end
				end
			end
		end

		return found_standard_test_attribute or found_derived_attribute
	else
		return false
	end
end

DotnetNeotestAdapter.filter_dir = function(name)
	return name ~= "bin" and name ~= "obj"
end

DotnetNeotestAdapter._build_position = function(...)
	local args = { ... }

	logger.debug("neotest-dotnet: Buil Position Args: ")
	logger.debug(args)

	local framework =
	    FrameworkDiscovery.get_test_framework_utils_from_source(args[2], custom_attribute_args) -- args[2] is the content of the file

	logger.debug("neotest-dotnet: Framework: ")
	logger.debug(framework)

	return framework.build_position(...)
end

DotnetNeotestAdapter._position_id = function(...)
	local args = { ... }
	local framework = args[1].framework and require("neotest-dotnet." .. args[1].framework)
	    or require("neotest-dotnet.xunit")
	return framework.position_id(...)
end

----@param name string
----@return integer
local function find_buffer_by_name(name)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		local buf_name = vim.api.nvim_buf_get_name(bufnr)
		if buf_name == name then
			return bufnr
		end
	end
	return 0
end

---@class IntermediateTree
---@field children (IntermediateTree | dotnetneotest.omnisharp.test)[]
---@field name string
---@field path string

---@param path any The path to the file to discover positions in
---@return neotest.Tree
DotnetNeotestAdapter.discover_positions = function(path)
	local bufnr = find_buffer_by_name(path)
	local tests = DotnetNeoTestOmnisharp.discover_tests(nil, path, bufnr)
	-- filter tests to only include tests that are in the file
	tests = vim.tbl_filter(function(test)
		return test.CodeFilePath == path
	end, tests)
	if #tests > 0 then
		vim.defer_fn(function()
			vim.notify("using omnisharp")
		end, 0)
		local result = {}

		-- foreach test in tests
		--- @type IntermediateTree
		local tree = { children = {}, name = "root", path = "" }

		for _, test in ipairs(tests) do
			print("test: " .. vim.inspect(test))
			local fully_qualified_name_parts = vim.split(test.FullyQualifiedName, ".",
				{ plain = true, trimempty = true })
			table.insert(fully_qualified_name_parts, 1, test.CodeFilePath)
			print("fully_qualified_name_parts: " .. vim.inspect(fully_qualified_name_parts))
			local parent = tree
			for i, part in ipairs(fully_qualified_name_parts) do
				local found = false
				for _, child in ipairs(parent.children) do
					if type(child) == "table" and child.name == part then
						parent = child
						found = true
						break
					end
				end
				if not found then
					---@type IntermediateTree
					local new_node = { name = part, children = {}, path = test.CodeFilePath }
					table.insert(parent.children, new_node)
					parent = new_node
				end
			end
			table.insert(parent.children, test)
		end

		---@param subtree IntermediateTree | dotnetneotest.omnisharp.test
		local function build_children(parent, subtree)
			if not subtree.children then
				local test = subtree
				local position = {
					type = "test",
					name = test.DisplayName,
					path = test.CodeFilePath,
					id = parent.path .. "::" .. test.DisplayName,
					running_id = parent.path .. "::" .. test.DisplayName,
					framework = "vstest"
				}
				return { position }
			else
				if #subtree.children == 1 then
					return build_children(parent, subtree.children[1])
				end

				local node = {
					type = "namespace",
					name = subtree.name,
					path = subtree.path,
					id = parent.id .. "::" .. subtree.name,
					range = { 1, 1, 1, 1 },
				}

				local built_children = {}
				table.insert(built_children, node)
				for _, child in ipairs(subtree.children) do
					table.insert(built_children, build_children(node, child))
				end
				return built_children
			end
		end

		logger.debug("neotest-dotnet: omnisharp results tree: " .. vim.inspect(tree))

		local results = {}
		for _, child in ipairs(tree.children) do
			--- @type neotest.Position
			local node = {
				type = "file",
				name = vim.fn.fnamemodify(child.path, ':t'),
				path = child.path,
				id = child.name,
				range = { 1, 1, 1, 1 },
			}
			table.insert(results, node)

			for _, innerchild in ipairs(child.children) do
				local built_child = build_children(node, innerchild)
				table.insert(results, built_child)
			end
		end
		local neotest_tree = require('neotest.types.tree')
		logger.debug("neotest-dotnet: omnisharp results transformed: " .. vim.inspect(results))
		vim.defer_fn(function()
			print("result: " .. vim.json.encode(results))
		end, 0)
		return neotest_tree.from_list(results, function(data)
			if type(data[1]) == "table" then
				return data[1].name
			end

			if type(data) == "table" then
				return data.name
			end

			logger.debug("wtf is dis" .. vim.inspect(data))

			return "unknown"
		end)
	end
	vim.defer_fn(function()
		logger.debug("NOT using omnisharp")
	end, 0)
	if true then
		return {}
	end




	local content = lib.files.read(path)
	local test_framework =
	    FrameworkDiscovery.get_test_framework_utils_from_source(content, custom_attribute_args)
	local framework_queries = test_framework.get_treesitter_queries(custom_attribute_args)

	local query = [[
    ;; --Namespaces
    ;; Matches namespace with a '.' in the name
    (namespace_declaration
        name: (qualified_name) @namespace.name
    ) @namespace.definition

    ;; Matches namespace with a single identifier (no '.')
    (namespace_declaration
        name: (identifier) @namespace.name
    ) @namespace.definition

    ;; Matches file-scoped namespaces (qualified and unqualified respectively)
    (file_scoped_namespace_declaration
        name: (qualified_name) @namespace.name
    ) @namespace.definition

    (file_scoped_namespace_declaration
        name: (identifier) @namespace.name
    ) @namespace.definition
  ]] .. framework_queries

	local tree = lib.treesitter.parse_positions(path, query, {
		nested_namespaces = true,
		nested_tests = true,
		build_position = "require('neotest-dotnet')._build_position",
		position_id = "require('neotest-dotnet')._position_id",
	})

	logger.debug("neotest-dotnet: Original Position Tree: ")
	logger.debug(tree:to_list())

	local modified_tree = test_framework.post_process_tree_list(tree, path)

	logger.debug("neotest-dotnet: Post-processed Position Tree: ")
	logger.debug(modified_tree:to_list())

	return modified_tree
end

---@summary Neotest core interface method: Build specs for running tests
---@param args neotest.RunArgs
---@return nil | neotest.RunSpec | neotest.RunSpec[]
DotnetNeotestAdapter.build_spec = function(args)
	logger.debug("neotest-dotnet: Creating specs from Tree (as list): ")
	logger.debug(args.tree:to_list())

	local additional_args = args.dotnet_additional_args or dotnet_additional_args or nil

	local specs = build_spec_utils.create_specs(args.tree, nil, additional_args)

	logger.debug("neotest-dotnet: Created " .. #specs .. " specs, with contents: ")
	logger.debug(specs)

	if args.strategy == "dap" then
		if #specs > 1 then
			logger.warn(
				"neotest-dotnet: DAP strategy does not support multiple test projects. Please debug test projects or individual tests. Falling back to using default strategy."
			)
			args.strategy = "integrated"
			return specs
		else
			specs[1].dap = dap
			specs[1].strategy = require("neotest-dotnet.strategies.netcoredbg")
		end
	end

	return specs
end

---@async
---@param spec neotest.RunSpec
---@param _ neotest.StrategyResult
---@param tree neotest.Tree
---@return neotest.Result[]
DotnetNeotestAdapter.results = function(spec, _, tree)
	local output_file = spec.context.results_path

	logger.debug("neotest-dotnet: Fetching results from neotest tree (as list): ")
	logger.debug(tree:to_list())

	local test_framework = FrameworkDiscovery.get_test_framework_utils_from_tree(tree)
	local results = test_framework.generate_test_results(output_file, tree, spec.context.id)

	return results
end

setmetatable(DotnetNeotestAdapter, {
	__call = function(_, opts)
		if type(opts.dap) == "table" then
			for k, v in pairs(opts.dap) do
				dap[k] = v
			end
		end
		if type(opts.custom_attributes) == "table" then
			custom_attribute_args = opts.custom_attributes
		end
		if type(opts.dotnet_additional_args) == "table" then
			dotnet_additional_args = opts.dotnet_additional_args
		end
		if type(opts.discovery_root) == "string" then
			discovery_root = opts.discovery_root
		end
		return DotnetNeotestAdapter
	end,
})

return DotnetNeotestAdapter
