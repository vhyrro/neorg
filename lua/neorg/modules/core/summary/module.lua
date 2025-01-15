--[[
    file: Summary
    title: Write notes, not boilerplate.
    description: The summary module creates links and annotations to all files in a given workspace.
    summary: Creates links to all files in any workspace.
    ---
<!-- TODO: GIF -->
The `core.summary` module exposes a single command - `:Neorg generate-workspace-summary`.

When executed with the cursor hovering over a heading, `core.summary` will generate, you guessed it,
a summary of the entire workspace, with links to each respective entry in that workspace.

If arguments are provided then a partial summary is generated containing only categories that
you have provided.
E.g. `:Neorg generate-workspace-summary work todos` would only generate a
summary of the categories `work` and `todos`.

The way the summary is generated relies on the `strategy` configuration option,
which by default consults the document metadata (see also
[`core.esupports.metagen`](@core.esupports.metagen)) or the first heading title
as a fallback to build up a tree of categories, titles and descriptions.
--]]

local neorg = require("neorg.core")
local lib, modules, utils = neorg.lib, neorg.modules, neorg.utils

local module = modules.create("core.summary")

module.setup = function()
    return {
        sucess = true,
        requires = { "core.integrations.treesitter" },
    }
end

module.load = function()
    modules.await("core.neorgcmd", function(neorgcmd)
        neorgcmd.add_commands_from_table({
            ["generate-workspace-summary"] = {
                min_args = 0,
                condition = "norg",
                name = "summary.summarize",
            },
        })
    end)
    local ts = module.required["core.integrations.treesitter"]

    -- declare query on load so that it's parsed once, on first use
    local heading_query

    local get_first_heading_title = function(bufnr)
        local document_root = ts.get_document_root(bufnr)
        if not heading_query then
            -- allow second level headings, just in case
            local heading_query_string = [[
                         [
                             (heading1
                                 title: (paragraph_segment) @next-segment
                             )
                             (heading2
                                 title: (paragraph_segment) @next-segment
                             )
                         ]
                     ]]
            heading_query = utils.ts_parse_query("norg", heading_query_string)
        end
        -- search up to 20 lines (a doc could potentially have metadata without metadata.title)
        local _, heading = heading_query:iter_captures(document_root, bufnr)()
        if not heading then
            return nil
        end
        local start_line, _ = heading:start()
        local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, start_line + 1, false)
        if #lines > 0 then
            local title = lines[1]:gsub("^%s*%*+%s*", "") -- strip out '*' prefix (handle '* title', ' **title', etc)
            if title ~= "" then -- exclude an empty heading like `*` (although the query should have excluded)
                return title
            end
        end
    end

    -- Return true if catagories_path is or is a subcategory of an entry in included_categories
    local is_included_category = function(included_categories, category_path)
        local found_match = false
        for _, included in ipairs(included_categories) do
            local included_path = vim.split(included, ".", { plain = true })
            for i, path in ipairs(included_path) do
                if path == category_path[i] and i == #included_path then
                    found_match = true
                    break
                elseif path ~= category_path[i] then
                    break
                end
            end
        end
        return found_match
    end

    -- Insert a categorized record for the given file into the categories table
    local insert_categorized = function(categories, category_path, norgname, metadata)
        local leaf_categories = categories
        for i, path in ipairs(category_path) do
            local titled_path = lib.title(path)
            if i == #category_path then
                -- There are no more sub catergories so insert the record
                table.insert(leaf_categories[titled_path], {
                    title = tostring(metadata.title),
                    norgname = norgname,
                    description = metadata.description,
                })
                break
            end
            local sub_categories = vim.defaulttable()
            if leaf_categories[titled_path] then
                -- This category already been added so find it's sub_categories table
                for _, item in ipairs(leaf_categories[titled_path]) do
                    if item.sub_categories then
                        leaf_categories = item.sub_categories
                        goto continue
                    end
                end
            end
            -- This is a new sub category
            table.insert(leaf_categories[titled_path], {
                title = titled_path,
                sub_categories = sub_categories,
            })
            leaf_categories = sub_categories
            ::continue::
        end
    end

    module.config.public.strategy = lib.match(module.config.public.strategy)({
        default = function()
            return function(files, ws_root, heading_level, include_categories)
                local categories = vim.defaulttable()

                if vim.tbl_isempty(include_categories) then
                    include_categories = nil
                end

                utils.read_files(files, function(bufnr, filename)
                    local metadata = ts.get_document_metadata(bufnr)

                    if not metadata then
                        metadata = {}
                    end

                    local norgname = filename:match("(.+)%.norg$") -- strip extension for link destinations
                    if not norgname then
                        norgname = filename
                    end
                    norgname = string.sub(norgname, ws_root:len() + 1)

                    -- normalise categories into a list. Could be vim.NIL, a number, a string or a list ...
                    if not metadata.categories or metadata.categories == vim.NIL then
                        metadata.categories = { "Uncategorised" }
                    elseif not vim.tbl_islist(metadata.categories) then ---@diagnostic disable-line
                        metadata.categories = { tostring(metadata.categories) }
                    end

                    if not metadata.title then
                        metadata.title = get_first_heading_title(bufnr)
                        if not metadata.title then
                            metadata.title = vim.fs.basename(norgname)
                        end
                    end

                    if metadata.description == vim.NIL then
                        metadata.description = nil
                    end

                    for _, category in ipairs(metadata.categories) do
                        local category_path = vim.split(category, ".", { plain = true })

                        if include_categories then
                            if is_included_category(include_categories, category_path) then
                                insert_categorized(categories, category_path, norgname, metadata)
                            end
                        else
                            insert_categorized(categories, category_path, norgname, metadata)
                        end
                    end
                end)

                local result = {}
                local starting_prefix = string.rep("*", heading_level)

                local function add_category(category, data, level)
                    local result_temp = {}
                    local sub_cats_temp = {}
                    local new_prefix = starting_prefix .. string.rep("*", level)
                    table.insert(result_temp, new_prefix .. " " .. category)
                    for _, datapoint in ipairs(data) do
                        if datapoint.sub_categories then
                            for sub_category, sub_data in vim.spairs(datapoint.sub_categories) do
                                table.insert(sub_cats_temp, add_category(sub_category, sub_data, level + 1))
                            end
                        else
                            table.insert(
                                result_temp,
                                table.concat({
                                    string.rep(" ", level + 1),
                                    " - {:$",
                                    datapoint.norgname,
                                    ":}[",
                                    lib.title(datapoint.title),
                                    "]",
                                })
                                    .. (
                                        datapoint.description and (table.concat({ " - ", datapoint.description })) or ""
                                    )
                            )
                        end
                    end
                    for _, sub_cat in pairs(sub_cats_temp) do
                        for _, row in pairs(sub_cat) do
                            table.insert(result_temp, row)
                        end
                    end
                    return result_temp
                end
                for category, data in vim.spairs(categories) do
                    local temp = add_category(category, data, 0)
                    for _, row in pairs(temp) do
                        table.insert(result, row)
                    end
                end
                return result
            end
        end,
        headings = function()
            return function() end
        end,
        by_path = function()
            return function(files, ws_root, heading_level, include_categories)
                local categories = vim.defaulttable()

                if vim.tbl_isempty(include_categories) then
                    include_categories = nil
                end

                utils.read_files(files, function(bufnr, filename)
                    local metadata = ts.get_document_metadata(bufnr) or {}

                    local path_tokens = lib.tokenize_path(filename)
                    local category = path_tokens[#path_tokens - 1] or "Uncategorised"

                    local norgname = filename:match("(.+)%.norg$") or filename -- strip extension for link destinations
                    norgname = string.sub(norgname, ws_root:len() + 1)

                    if not metadata.title then
                        metadata.title = get_first_heading_title(bufnr) or vim.fs.basename(norgname)
                    end

                    if metadata.description == vim.NIL then
                        metadata.description = nil
                    end

                    if not include_categories or vim.tbl_contains(include_categories, category:lower()) then
                        table.insert(categories[lib.title(category)], {
                            title = tostring(metadata.title),
                            norgname = norgname,
                            description = metadata.description,
                        })
                    end
                end)
                local result = {}
                local prefix = string.rep("*", heading_level)

                for category, data in vim.spairs(categories) do
                    table.insert(result, prefix .. " " .. category)

                    for _, datapoint in ipairs(data) do
                        table.insert(
                            result,
                            table.concat({
                                string.rep(" ", heading_level),
                                " - {:$",
                                datapoint.norgname,
                                ":}[",
                                lib.title(datapoint.title),
                                "]",
                            })
                                .. (datapoint.description and (table.concat({ " - ", datapoint.description })) or "")
                        )
                    end
                end

                return result
            end
        end,
    }) or module.config.public.strategy
end

module.config.public = {
    -- The strategy to use to generate a summary.
    --
    -- Possible options are:
    -- - "default" - read the metadata to categorize and annotate files. Files
    --   without metadata will use the top level heading as the title. If no headings are present, the filename will be used.
    -- - "by_path" - Similar to "default" but uses the capitalized name of the folder containing a *.norg file as category.
    -- - A custom function with the signature:
    --   `fun(files: PathlibPath[], ws_root: PathlibPath, heading_level: number?, include_categories: string[]?): string[]?`.
    --   Returning a list of lines that make up the summary
    strategy = "default",
}

---@class core.summary
module.public = {
    ---@param buf integer? the buffer to insert the summary to
    ---@param cursor_pos integer[]? a tuple of row, col of the cursor positon (see nvim_win_get_cursor())
    ---@param include_categories string[]? table of strings (ignores case) for categories that you wish to include in the summary.
    -- if excluded then all categories are written into the summary.
    generate_workspace_summary = function(buf, cursor_pos, include_categories)
        local ts = module.required["core.integrations.treesitter"]

        local buffer = buf or 0
        local cursor_position = cursor_pos or vim.api.nvim_win_get_cursor(0)

        local node_at_cursor = ts.get_first_node_on_line(buffer, cursor_position[1] - 1)

        if not node_at_cursor or not node_at_cursor:type():match("^heading%d$") then
            utils.notify(
                "No heading under cursor! Please move your cursor under the heading you'd like to generate the summary under."
            )
            return
        end
        -- heading level of 'node_at_cursor' (summary headings should be one level deeper)
        local level = tonumber(string.sub(node_at_cursor:type(), -1))

        local dirman = modules.get_module("core.dirman")

        if not dirman then
            utils.notify("`core.dirman` is not loaded! It is required to generate summaries")
            return
        end

        local ws_root = dirman.get_current_workspace()[2]
        local generated = module.config.public.strategy(
            dirman.get_norg_files(dirman.get_current_workspace()[1]) or {},
            ws_root,
            level + 1,
            vim.tbl_map(string.lower, include_categories or {})
        )

        if not generated or vim.tbl_isempty(generated) then
            utils.notify(
                "No summary to generate! Either change the `strategy` option or ensure you have some indexable files in your workspace."
            )
            return
        end

        vim.api.nvim_buf_set_lines(buffer, cursor_position[1], cursor_position[1], true, generated)
    end,
}

module.events.subscribed = {
    ["core.neorgcmd"] = {
        ["summary.summarize"] = true,
    },
}

module.on_event = function(event)
    if event.type == "core.neorgcmd.events.summary.summarize" then
	-- Extract any additional arguments past the first
	-- So that :Neorg generate_workspace_summary a b c
	-- Will result in include_categories = {"a", "b", "c"}
	local include_categories = {table.unpack(event.content.data.fargs, 2)}
        module.public.generate_workspace_summary(event.buffer, event.cursor_position, include_categories)
    end
end

return module
