-- Diagnostico passivo para descobrir onde o servidor armazena a textura/TXT.
-- Abra o /gts manualmente e execute este macro sem fechar o inventario.

local OUTPUT_FILE = "gts_txt_diagnostico_saida.txt"
local PREFIX = "[GTS-TXT-DIAG] "

local output = {}

local function emit(message)
    local line = PREFIX .. tostring(message)
    output[#output + 1] = line
    print(line)
end

local function serialize(value, depth, seen)
    depth = depth or 0
    seen = seen or {}

    if depth > 14 then
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

local function containsAny(haystack, needles)
    local normalized = string.lower(haystack or "")
    for _, needle in ipairs(needles) do
        if string.find(normalized, needle, 1, true) then
            return true
        end
    end
    return false
end

local function writeOutput()
    local ok, result = pcall(function()
        local file, err = io.open(OUTPUT_FILE, "w")
        if not file then
            error(err or "io.open falhou")
        end
        file:write(table.concat(output, "\n"))
        file:write("\n")
        file:close()
        return true
    end)

    if ok and result then
        return true, OUTPUT_FILE
    end
    return false, tostring(result)
end

local function waitForContainer()
    log("&e[GTS TXT] Abra o /gts nos proximos 20 segundos.")

    for _ = 1, 80 do
        local okInventory, inventory = pcall(openInventory)
        if okInventory and inventory then
            local okSlots, totalSlots = pcall(function()
                return inventory.getTotalSlots()
            end)

            -- O inventario normal possui 46 slots. Um bau/menu do GTS possui mais.
            if okSlots and type(totalSlots) == "number" and totalSlots > 46 then
                return inventory, totalSlots
            end
        end
        sleep(250)
    end

    return nil, nil
end

local inventory, totalSlots = waitForContainer()
if not inventory then
    log("&c[GTS TXT] Tempo esgotado. Execute novamente e abra o /gts.")
    emit("ERRO nenhum container com mais de 46 slots foi aberto")
    writeOutput()
    return
end

emit("BEGIN totalSlots=" .. tostring(totalSlots))

local nonEmpty = 0
local detailed = 0
local keywords = {
    "texture",
    "textura",
    "txt",
    "sprite",
    "species",
    "pokemon",
    "pixelmon",
}

-- Alguns builds usam slots iniciando em 0 e outros documentam a faixa a partir de 1.
-- O pcall torna a leitura das duas bordas inofensiva.
for slot = 0, totalSlots do
    local okItem, item = pcall(function()
        return inventory.getSlot(slot)
    end)

    if okItem and type(item) == "table" and item.id then
        local amount = tonumber(item.amount) or 0
        local id = tostring(item.id or "")
        local name = tostring(item.name or "")

        if amount > 0 and id ~= "minecraft:air" then
            nonEmpty = nonEmpty + 1
            local nbt = serialize(item.nbt)
            emit(string.format(
                "SLOT slot=%d id=%q name=%q amount=%s dmg=%s nbtBytes=%d",
                slot,
                id,
                name,
                tostring(item.amount),
                tostring(item.dmg),
                string.len(nbt)
            ))

            local searchable = id .. " " .. name .. " " .. nbt
            if containsAny(searchable, keywords) then
                detailed = detailed + 1
                emit(string.format("DETAIL slot=%d nbt=%s", slot, nbt))
            end
        end
    end
end

emit(string.format("END nonEmpty=%d detailed=%d", nonEmpty, detailed))

local wroteFile, writeResult = writeOutput()
if wroteFile then
    log(string.format(
        "&a[GTS TXT] Diagnostico concluido: %d itens, %d candidatos. Resultado salvo.",
        nonEmpty,
        detailed
    ))
else
    emit("AVISO arquivo nao salvo: " .. tostring(writeResult))
    log("&e[GTS TXT] Diagnostico no console do Prism; o arquivo nao pode ser salvo.")
end
