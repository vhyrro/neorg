-- TODO: better colors
require("neorg.modules.base")

local module = neorg.modules.create("core.execute")
local ts = require("nvim-treesitter.ts_utils")

module.setup = function()
    return { success = true, requires = { "core.neorgcmd", "core.integrations.treesitter" } }
end

module.load = function()
    module.required["core.neorgcmd"].add_commands_from_table({
        execute = {
            args = 1,
            subcommands = {
                view = { args=0, name="execute.view" },
                -- bruh2 = { args=0, name="execute.bruh2" },
            }
        }
    })
end

module.config.public = {
    lang_cmds = {
        python = 'python3',
        lua = 'lua',
        javascript = 'node',
    },
}
module.config.private = {}

module.private = {
    buf = vim.api.nvim_get_current_buf(),
    ns = vim.api.nvim_create_namespace("execute"),
    code_block = {},
    interrupted = false,
    jobid = 0,
    temp_filename = '',


    create_dir_if_doesnt_exist = function()
        if vim.fn.isdirectory(module.public.tmpdir) == 0 then
            vim.fn.mkdir(module.public.tmpdir, "p")
        end
    end,

    virtual = {
        init = function()
            table.insert(module.public.output, {{"", 'Keyword'}})
            table.insert(module.public.output, {{"Result:", 'Keyword'}})

            local id = vim.api.nvim_buf_set_extmark(
                module.private.buf,
                module.private.ns,
                module.private.code_block['end'].row,
                module.private.code_block['end'].column,
                { virt_lines = module.public.output }
            )

            vim.api.nvim_create_autocmd('CursorMoved', {
                once = true,
                callback = function()
                    vim.api.nvim_buf_del_extmark(module.private.buf, module.private.ns, id)
                    module.private.interrupted = true
                    module.public.output = {}
                    vim.fn.delete(module.private.temp_filename)
                end
            })
            return id
        end,

        update = function(id)
            vim.api.nvim_buf_set_extmark(
                module.private.buf,
                module.private.ns,
                module.private.code_block['end'].row,
                0,
                { id=id, virt_lines = module.public.output }
            )
        end
    },

    spawn = function(command)
        module.private.interrupted = false
        local id = module.private.virtual.init()

        module.private.jobid = vim.fn.jobstart(command, {
            stdout_buffered = false,
            -- TODO: check exit code conditions and colors
            on_stdout = function(_, data)
                if module.private.interrupted then
                    vim.fn.jobstop(module.private.jobid)
                    return
                end

                for _, line in ipairs(data) do
                    if line ~= "" then
                        table.insert(module.public.output, {{line, 'Function'}})
                        module.private.virtual.update(id)
                    end
                end
            end,

            on_stderr = function(_, data)
                if module.private.interrupted then
                    vim.fn.jobstop(module.private.jobid)
                    return
                end

                for _, line in ipairs(data) do
                    if line ~= "" then
                        table.insert(module.public.output, {{line, 'Error'}})
                        module.private.virtual.update(id)
                    end
                end
            end

        })
    end
}

module.public = {
    tmpdir = "/tmp/neorg-execute/",
    output = {},

    view = function()
        local node = ts.get_node_at_cursor(0, true)
        local p = module.required["core.integrations.treesitter"].find_parent(node, "^ranged_tag$")

        -- TODO: Add checks here
        local code_block = module.required["core.integrations.treesitter"].get_tag_info(p, true)
        if not code_block then
            vim.pretty_print("Not inside a code block!")
            return
        end

        if code_block.name == "code" then
            module.private.code_block = code_block
            local ft = code_block.parameters[1]

            module.private.create_dir_if_doesnt_exist()
            module.private.temp_filename = module.public.tmpdir
                .. code_block.start.row .. "_"
                .. code_block['end'].row
                .. "." .. ft

            local file = io.open(module.private.temp_filename, "w")
            if file == nil then return end
            file:write(table.concat(code_block.content, '\n'))
            file:close()

            local command = module.config.public.lang_cmds[ft]
            command = {command, module.private.temp_filename}

            module.private.spawn(command)
        end

        -- {attributes, content, ["end"], name, parameters, ["start"]}
    end,
    -- bruh2 = function() end
}

module.on_event = function(event)
    if event.split_type[2] == "execute.view" then
        vim.schedule(module.public.view)
    end
end

module.events.subscribed = {
    ["core.neorgcmd"] = {
        ["execute.view"] = true,
        -- ["execute.bruh2"] = true
    }
}

return module
