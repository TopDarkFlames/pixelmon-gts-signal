-- Vincule este arquivo ao evento "Chat" do AdvancedMacros.
-- Ele registra somente mensagens do GTS Global e nao executa nenhuma acao.

local OUTPUT_FILE = "gts_chat_extras_saida.txt"
local HEARTBEAT_FILE = "gts_chat_evento_ultimo.txt"
local PREFIX = "[GTS-CHAT-EXTRAS] "

local function serialize(value, depth, seen)
    depth = depth or 0
    seen = seen or {}

    if depth > 16 then
        return "<max-depth>"
    end

    local valueType = type(value)
    if valueType == "nil" then
        return "nil"
    elseif valueType == "string" then
        return string.format("%q", value)
    elseif valueType == "number" or valueType == "boolean" then
        return tostring(value)
    elseif valueType ~= "table" then
        return "<" .. valueType .. ":" .. tostring(value) .. ">"
    end

    if seen[value] then
        return "<cycle>"
    end
    seen[value] = true

    local entries = {}
    for key, child in pairs(value) do
        entries[#entries + 1] = {
            key = key,
            sortKey = tostring(key),
            value = child,
        }
    end
    table.sort(entries, function(left, right)
        return left.sortKey < right.sortKey
    end)

    local parts = {}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = "[" .. serialize(entry.key, depth + 1, seen) .. "]="
            .. serialize(entry.value, depth + 1, seen)
    end

    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

local function appendOutput(line)
    local ok, err = pcall(function()
        local file, openError = io.open(OUTPUT_FILE, "a")
        if not file then
            error(openError or "io.open falhou")
        end
        file:write(line)
        file:write("\n")
        file:close()
    end)

    return ok, err
end

local args = {...}
local formatted = tostring(args[3] or "")
local unformatted = tostring(args[4] or "")
local allArgs = serialize(args)
local searchable = string.lower(formatted .. " " .. unformatted .. " " .. allArgs)

-- Sobrescreve este arquivo em qualquer disparo para provar que o evento chegou,
-- mesmo quando esta versao do mod usa argumentos diferentes dos documentados.
pcall(function()
    local heartbeat = io.open(HEARTBEAT_FILE, "w")
    if heartbeat then
        heartbeat:write(allArgs)
        heartbeat:write("\n")
        heartbeat:close()
    end
end)

if not string.find(searchable, "gts global", 1, true)
    and not string.find(searchable, "global gts", 1, true) then
    return
end

local timestamp = "unknown-time"
pcall(function()
    timestamp = os.date("%Y-%m-%d %H:%M:%S")
end)

local report = PREFIX
    .. "time=" .. timestamp
    .. " formatted=" .. serialize(args[3])
    .. " unformatted=" .. serialize(args[4])
    .. " extras=" .. serialize(args[5])
    .. " allArgs=" .. allArgs

print(report)
local saved, saveError = appendOutput(report)

if saved then
    log("&a[GTS Extras] Anuncio capturado. Tooltip salvo para analise.")
else
    print(PREFIX .. "ERRO ao salvar: " .. tostring(saveError))
    log("&e[GTS Extras] Anuncio capturado apenas no console do Prism.")
end
