local shell = require("shell")
local serialization = require("serialization")
local fs = require("filesystem")
local ipm = require("ipm")

local config = ipm.util.load_file("/etc/ipm/config.cfg")

local internet = ipm.internet.get_internet()

if not internet then
    io.stderr:write("No internet card found\n")
    return
end

local args, options = shell.parse(...)

local function printUsage()
    print([[
Improved Package Manager
Usage:
  Package:
    ipm list [-ia] [id-filter] - List all packages, you can pipe it to `less`.
    ipm info <id> - Show information about a package.
    ipm search <filter...> - Search for packages.
    ipm install [--path=<path>] <id> - Install a package.
    ipm which <file> - Show which package contains a file.
    ipm upgrade <id> - Upgrade a package.
    ipm upgrade all - Upgrade all packages.
    ipm remove <id> - Remove a package.
    ipm remove auto - Remove unused packages.
  Source:
    ipm update [name] - Update all sources, or a specific file.
    ipm clear - Clear cache.
    ipm source list - List all sources.
    ipm source info <id> [type] - Show information about a source.
    ipm source files - list source config files.
    ipm source add <name> [template:repos|<packages>] - Add a source config file.
    ipm source edit [name] - Edit a source config file.
    ipm source remove <name> - Remove a source config file.
  Install from others:
    ipm pastebin <id> <filename> - Download a file as package from pastebin.
    ipm register <user>/<repo> [id] - Register a repository. Don't forget `ipm update` after this.
]])
end

if #args == 0 or options.h or options.help then
    printUsage()
    return
end

local templates = {
    repos = {
        {
            type = "repos",
            id = "repos_id",
            name = "repos_name",
            description = "repos list",
            url = "url_to_repos",
            priority = 0,
            enabled = true,
        },
    },
    packages = {
        {
            type = "packages",
            id = "packages_id",
            name = "packages_name",
            description = "packages list",
            url = "url_to_programs",
            priority = 0,
            enabled = true,
        }
    }
}

local function source(args, options)
    if #args == 0 then
        printUsage()
        return
    end
    if args[1] == "list" then
        local repos, packages = ipm.source.source_list()
        io.write("Repository sources:\n\n")
        for _, repo in ipairs(repos) do
            io.write(ipm.format.source(repo))
        end
        io.write("\nPackages sources:\n\n")
        for _, package in ipairs(packages) do
            io.write(ipm.format.source(package))
        end
        return
    end
    if args[1] == "info" then
        local source = ipm.source.source_info(args[2], args[3])
        if source then
            io.write(ipm.format.source(source, true))
        else
            io.stderr:write("Source not found\n")
        end
        return
    end
    if args[1] == "files" then
        local list = ipm.util.each_file(ipm.source.source_base, "%.cfg$", function(file)
            return file:gsub("%.cfg$", "")
        end, nil, true)
        for _, file in pairs(list) do
            io.write("  " .. file .. "\n")
        end
        return
    end
    if args[1] == "add" then
        local file = ipm.source.source_base .. "/" .. args[2] .. ".cfg"
        if not templates[args[3] or "packages"] then
            io.stderr:write("Invalid template: " .. (args[3] or "packages") .. "\n")
            return
        end
        local f = io.open(file, "w")
        if not f then
            io.stderr:write("Failed to open file: " .. file .. "\n")
            return
        end
        f:write(serialization.serialize(templates[args[3] or "packages"], math.huge))
        f:close()
        local edit = loadfile("/bin/edit.lua")
        edit(file)
    end
    if args[1] == "edit" then
        local file = args[2] and ipm.source.source_base .. "/" .. args[2] .. ".cfg" or ipm.source.source_file
        local edit = loadfile("/bin/edit.lua")
        if not edit then
            io.stderr:write("Failed to load edit.lua, please install it first\n")
            return
        end
        edit(file)
        return
    end
    if args[1] == "remove" then
        local file = ipm.source.source_base .. "/" .. args[2] .. ".cfg"
        if not fs.exists(file) then
            io.stderr:write("Source config file not found\n")
            return
        end
        fs.remove(file)
        io.write("Removed " .. file .. "\n")
        return
    end
end

local function pastebin(args, options)
    if #args == 0 then
        printUsage()
        return
    end
    local id = args[1]
    local filename = args[2]

    local path = config.default_install_path

    local repo = ipm.repo.repo("pastebin:")
    local execution = {
        type = "install",
        before = {},
        repo = repo,
        run = {
            {"download", repo, id, path .. "/bin/" .. filename .. ".lua"},
        },
        after = {
            {"register", filename, path, {
                name = filename,
                description = "Downloaded from pastebin",
                source = "pastebin:" .. id,
                auto_installed = false,
                install_files = {path .. "/bin/" .. filename .. ".lua"},
                install_dirs = {},
            }}
        }
    }

    io.write("Install: " .. filename .. "\n")
    ipm.tui.paged(ipm.format.execute_data(execution))
    if ipm.package.has_error(execution) then
        io.stderr:write("Error: execute data has error\n")
        return
    end
    if not options.y and not options.yes then
        io.write("Continue? [y/N]")
        local answer = io.read()
        if answer ~= "y" then
            return
        end
    end
    ipm.package.execute(execution)
end
local function register(args, options)
    if #args == 0 then
        printUsage()
        return
    end
    local user, repo = args[1]:match("^(.+)/(.+)$")
    local id = args[2] or user .. "-" .. repo
    local file = ipm.source.source_base .. "/" .. id .. ".cfg"
    local f = io.open(file, "w")
    if not f then
        io.stderr:write("Failed to open file: " .. file .. "\n")
        return
    end
    f:write(serialization.serialize({
        {
            type = "packages",
            id = id,
            name = user .. "/" .. repo,
            description = "Packages from " .. user .. "/" .. repo,
            url = "https://raw.githubusercontent.com/" .. user .. "/" .. repo .. "/refs/heads/master/programs.cfg",
            priority = 1,
            enabled = true,
            source_repo = "github:" .. user .. "/" .. repo,
        }
    }, math.huge))
    f:close()
    io.write("Written to " .. file .. "\n")

    ipm.source.load_sources(id)
    ipm.source.resolve_sources()
    return
end

if args[1] == "pastebin" then
    table.remove(args, 1)
    pastebin(args, options)
    return
end
if args[1] == "register" then
    table.remove(args, 1)
    register(args, options)
    return
end

if args[1] == "clear" then
    ipm.source.clear_data()
    return
end
if args[1] == "update" then
    if args[2] then
        ipm.source.load_sources(args[2])
        ipm.source.resolve_sources()
        return
    end
    ipm.source.clear_data()
    ipm.source.load_sources()
    ipm.source.resolve_sources()
    return
end
if args[1] == "source" then
    table.remove(args, 1)
    source(args, options)
    return
end

if args[1] == "list" then
    local packages = (options.i or options.installed)
        and ipm.package.package_list_installed()
        or ipm.package.package_list()
    for _, package in ipairs(packages) do
        if package.hidden and not (options.a or options.all) then
            goto continue
        end
        io.write(ipm.format.package(package))
        ::continue::
    end
    return
end
if args[1] == "info" then
    local package, installed = ipm.package.package_info(args[2])
    if package then
        io.write("Package in " .. package.source .. ":\n\n")
        io.write(ipm.format.package(package, true))
    end
    if installed then
        io.write("\nPackage installed:\n\n")
        io.write(ipm.format.package(installed, true, true))
    end
    return
end
if args[1] == "search" then
    table.remove(args, 1)
    local pattern = table.concat(args, " "):lower()
    local replaced_pattern = "\x1b[31m" .. pattern .. "\x1b[0m"
    for _, package in ipairs(ipm.package.package_list()) do
        if package.hidden and not (options.a or options.all) then
            goto continue
        end
        local info = ipm.format.package(package, false):lower()
        local replaced = info:gsub(pattern, replaced_pattern)
        if info ~= replaced then
            io.write(replaced .. "\n")
        end
        ::continue::
    end
    return
end
if args[1] == "install" then
    local path = options.path or config.default_install_path
    table.remove(args, 1)
    for _, id in ipairs(args) do
        local data = ipm.package.prepare_install(id, path, false, options.f or options.force)
        io.write("Install: " .. id .. "\n")
        ipm.tui.paged(ipm.format.execute_data(data))
        if ipm.package.has_error(data) then
            io.stderr:write("Error: execute data has error\n")
            return
        end
        if not options.y and not options.yes then
            io.write("Continue? [y/N]")
            local answer = io.read()
            if answer ~= "y" then
                return
            end
        end
        ipm.package.execute(data)
    end
    return
end
if args[1] == "which" then
    local lua = shell.resolve(args[2], "lua")
    local file = lua or shell.resolve(args[2])
    if not file then
        io.stderr:write("File not found\n")
        return
    end
    local packages = ipm.package.package_list_installed()
    for _, package in ipairs(packages) do
        local result = {}
        for _, dst in pairs(package.install_files) do
            if dst:sub(1, #file) == file then
                table.insert(result, dst)
            end
        end
        for _, dst in pairs(package.install_dirs) do
            if dst:sub(1, #file) == file then
                table.insert(result, dst)
            end
        end
        if #result > 0 then
            io.write(package.id .. ":\n")
            for _, r in ipairs(result) do
                io.write("  " .. r .. "\n")
            end
        end
    end
end
if args[1] == "upgrade" then
    table.remove(args, 1)
    if args[1] == "all" then
        local packages = ipm.package.package_list_installed()
        local ids = {}
        for _, package in ipairs(packages) do
            table.insert(ids, package.id)
        end
        args = ids
        io.write("Will upgrade: " .. table.concat(args, ", ") .. "\n")
        if not options.y and not options.yes then
            io.write("Continue? [y/N]")
            local answer = io.read()
            if answer ~= "y" then
                return
            end
        end
    end
    for _, id in ipairs(args) do
        local data = ipm.package.prepare_upgrade(id)
        io.write("Upgrade: " .. id .. "\n")
        ipm.tui.paged(ipm.format.execute_data(data))
        if ipm.package.has_error(data) then
            io.stderr:write("Error: execute data has error\n")
            return
        end
        if not options.y and not options.yes then
            io.write("Continue? [y/N]")
            local answer = io.read()
            if answer ~= "y" then
                return
            end
        end
        ipm.package.execute(data)
    end
    return
end
if args[1] == "remove" then
    table.remove(args, 1)
    if args[1] == "auto" then
        local packages = ipm.package.package_list_installed()
        local ids = {}
        for _, package in ipairs(packages) do
            if not next(package.used) and package.auto_installed then
                table.insert(ids, package.id)
            end
        end
        args = ids
        io.write("Will remove: " .. table.concat(args, ", ") .. "\n")
        if not options.y and not options.yes then
            io.write("Continue? [y/N]")
            local answer = io.read()
            if answer ~= "y" then
                return
            end
        end
    end
    for _, id in ipairs(args) do
        local data = ipm.package.prepare_remove(id)
        io.write("Remove: " .. id .. "\n")
        ipm.tui.paged(ipm.format.execute_data(data))
        if ipm.package.has_error(data) then
            io.stderr:write("Error: execute data has error\n")
            return
        end
        if not options.y and not options.yes then
            io.write("Continue? [y/N]")
            local answer = io.read()
            if answer ~= "y" then
                return
            end
        end
        ipm.package.execute(data)
    end
    return
end