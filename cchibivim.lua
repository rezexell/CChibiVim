-- chibivim 1.0. CraftOS / CC:Tweaked
-- Normal + Insert + Visual + Command modes
-- hybrid line numbers, jk -> Normal modek

local width, height = term.getSize()

local BLACK, WHITE, GRAY, LIGHT_GRAY = "f", "0", "7", "8"

local TAB_WIDTH = 4
local MAX_HISTORY = 100

local SYNTAX = {
    keyword = "e", comment = "7", string = "d", number = "a",
    operator = "9", func = "1", bracket = "8", special = "4",
    text = WHITE,
}

local completion = { items = {}, startX = 1, prefix = "", selected = 1, version = -1, scroll = 1 }
local ctrlDown = false

local editor = {
    buffer = { "" },
    cursor = { x = 1, y = 1, wantCol = 1 },
    viewport = { x = 0, y = 0 },

    mode = "normal",
    filename = "[No Name]",
    dirty = false,
    running = true,

    history = {},
    insertSnapshotTaken = false,
    insertShouldStepBack = false,
    lastInsertChar = "",

    savedContent = "",
    bufferVersion = 0,
    lastFind = nil,
    commandLine = "",
    message = "",
    register = { text = "", type = "character", lines = nil },
    visual = nil,
    search = {
        query = "",
        direction = 1,
        matches = {},
        current = 0,
        version = 0,
        bufferVersion = -1,
    },
}

local parser = {
    state = "idle",
    pending = nil,
    count = 0,
    operatorCount = 1,
    object = nil,
    motionPrefix = nil,
    findDirection = 1,
}

-- Short aliases keep the motion and editing code readable.
local function lineLength(y)
    return #(editor.buffer[y] or "")
end

local function maxCursorX()
    local length = lineLength(editor.cursor.y)
    if editor.mode == "insert" then return length + 1 end
    return math.max(1, length)
end

local function clampCursor()
    editor.cursor.y = math.max(1, math.min(editor.cursor.y, #editor.buffer))
    editor.cursor.x = math.max(1, math.min(editor.cursor.x, maxCursorX()))
    editor.cursor.wantCol = math.max(1, editor.cursor.wantCol)
end

local function setCursor(x, y)
    editor.cursor.x = x
    editor.cursor.y = y
    clampCursor()
    editor.cursor.wantCol = editor.cursor.x
end

local function copyBuffer()
    local copy = {}
    for i = 1, #editor.buffer do copy[i] = editor.buffer[i] end
    return copy
end

local function currentContent()
    return table.concat(editor.buffer, "\n")
end

local function updateDirty()
    editor.dirty = currentContent() ~= editor.savedContent
end

local function markBufferChanged()
    editor.bufferVersion = editor.bufferVersion + 1
    updateDirty()
end

-- Full snapshots remain appropriate for this editor's current size.
local function snapshot()
    editor.history[#editor.history + 1] = {
        buffer = copyBuffer(),
        x = editor.cursor.x,
        y = editor.cursor.y,
        wantCol = editor.cursor.wantCol,
    }

    if #editor.history > MAX_HISTORY then
        table.remove(editor.history, 1)
    end

end

local function undo()
    local state = table.remove(editor.history)
    if not state then return end

    editor.buffer = state.buffer
    editor.cursor.x = state.x
    editor.cursor.y = state.y
    editor.cursor.wantCol = state.wantCol
    markBufferChanged()
    clampCursor()
end

local function beginInsertChange()
    if not editor.insertSnapshotTaken then
        snapshot()
        editor.insertSnapshotTaken = true
    end
end

-- ===== Buffer editing helpers =====
local function insertText(text)
    beginInsertChange()
    local x, y = editor.cursor.x, editor.cursor.y
    local line = editor.buffer[y]
    editor.buffer[y] = line:sub(1, x - 1) .. text .. line:sub(x)
    markBufferChanged()
    editor.cursor.x = x + #text
    editor.cursor.wantCol = editor.cursor.x
    editor.insertShouldStepBack = true
end

local function deleteLineRange(y, count)
    local last = math.min(#editor.buffer, y + count - 1)
    for _ = y, last do table.remove(editor.buffer, y) end
    if #editor.buffer == 0 then editor.buffer[1] = "" end
    markBufferChanged()
    setCursor(editor.cursor.x, math.min(y, #editor.buffer))
end

local function deleteBeforeCursor(count)
    local x, y = editor.cursor.x, editor.cursor.y
    if x <= 1 then return false end
    count = math.max(1, math.min(count or 1, x - 1))
    beginInsertChange()
    local line = editor.buffer[y]
    editor.buffer[y] = line:sub(1, x - count - 1) .. line:sub(x)
    markBufferChanged()
    editor.cursor.x = x - count
    editor.cursor.wantCol = editor.cursor.x
    editor.insertShouldStepBack = false
    return true
end

local function insertBackspace()
    local x, y = editor.cursor.x, editor.cursor.y

    if x > 1 then
        local line = editor.buffer[y]
        local prefix = line:sub(1, x - 1)
        local whitespace = prefix:match("(%s+)$")
        if whitespace then
            -- Backspace removes one indentation unit (four spaces) at a time.
            deleteBeforeCursor(math.min(TAB_WIDTH, #whitespace))
        else
            deleteBeforeCursor(1)
        end
    elseif y > 1 then
        beginInsertChange()
        local previous = editor.buffer[y - 1]
        editor.buffer[y - 1] = previous .. editor.buffer[y]
        table.remove(editor.buffer, y)
        markBufferChanged()
        editor.cursor.y = y - 1
        editor.cursor.x = #previous + 1
        editor.cursor.wantCol = editor.cursor.x
        editor.insertShouldStepBack = false
    end
end

local function insertEnter()
    beginInsertChange()
    local x, y = editor.cursor.x, editor.cursor.y
    local line = editor.buffer[y]
    editor.buffer[y] = line:sub(1, x - 1)
    table.insert(editor.buffer, y + 1, line:sub(x))
    markBufferChanged()
    editor.cursor.y = y + 1
    editor.cursor.x = 1
    editor.cursor.wantCol = 1
    editor.insertShouldStepBack = false
end

local function insertTab()
    insertText(string.rep(" ", TAB_WIDTH))
end

-- ===== Modes =====
local function enterInsert()
    editor.mode = "insert"
    editor.insertSnapshotTaken = false
    editor.insertShouldStepBack = false
    editor.lastInsertChar = ""
end

local function exitInsert()
    editor.mode = "normal"
    editor.lastInsertChar = ""

    if editor.insertShouldStepBack and editor.cursor.x > 1 then
        editor.cursor.x = editor.cursor.x - 1
    end

    clampCursor()
    editor.cursor.wantCol = editor.cursor.x
end

-- ===== Basic motions =====
local function moveLeft()
    editor.cursor.x = math.max(1, editor.cursor.x - 1)
    editor.cursor.wantCol = editor.cursor.x
end

local function moveRight()
    editor.cursor.x = math.min(maxCursorX(), editor.cursor.x + 1)
    editor.cursor.wantCol = editor.cursor.x
end

local function moveVertical(delta)
    local oldY = editor.cursor.y
    local targetY = math.max(1, math.min(#editor.buffer, oldY + delta))
    if targetY == oldY then return end

    editor.cursor.y = targetY
    local targetMaxX = maxCursorX()
    editor.cursor.x = math.max(1, math.min(editor.cursor.wantCol, targetMaxX))
end

local function moveLineStart()
    editor.cursor.x = 1
    editor.cursor.wantCol = 1
end

local function moveFirstNonBlank()
    local line = editor.buffer[editor.cursor.y] or ""
    local first = line:find("%S") or 1
    editor.cursor.x = first
    editor.cursor.wantCol = first
end

local function moveLineEnd()
    editor.cursor.x = maxCursorX()
    editor.cursor.wantCol = editor.cursor.x
end

local function moveToLine(y)
    editor.cursor.y = math.max(1, math.min(#editor.buffer, y))
    local targetMaxX = maxCursorX()
    editor.cursor.x = math.max(1, math.min(editor.cursor.wantCol, targetMaxX))
    -- Preserve preferred column even when this line is shorter.
end


-- ===== Word motions =====
-- Small-word motions: keyword chars, punctuation groups and whitespace.
-- WORD motions: any non-whitespace run. Newlines always separate groups.
local function charClass(ch, bigWord)
    if not ch or ch:match("^%s$") then return "space" end
    if bigWord then return "word" end
    if ch:match("^[%w_]$") then return "word" end
    return "punctuation"
end

local function currentChar(x, y)
    local line = editor.buffer[y]
    if not line or x < 1 or x > #line then return nil end
    return line:sub(x, x)
end

local function stepForward()
    local x, y = editor.cursor.x, editor.cursor.y
    if x < lineLength(y) then
        editor.cursor.x = x + 1
    elseif y < #editor.buffer then
        editor.cursor.y = y + 1
        editor.cursor.x = 1
    else
        return false
    end
    return true
end

local function stepBackward()
    local x, y = editor.cursor.x, editor.cursor.y
    if x > 1 then
        editor.cursor.x = x - 1
    elseif y > 1 then
        editor.cursor.y = y - 1
        editor.cursor.x = math.max(1, lineLength(editor.cursor.y))
    else
        return false
    end
    return true
end

local function moveWordForward(bigWord)
    local x, y = editor.cursor.x, editor.cursor.y
    local class = charClass(currentChar(x, y), bigWord)

    -- Leave the current group. Crossing a line is always a word boundary,
    -- even when both lines contain only keyword characters.
    if class ~= "space" then
        while true do
            local oldY = editor.cursor.y
            if not stepForward() then return end
            if editor.cursor.y ~= oldY then break end
            if charClass(currentChar(editor.cursor.x, editor.cursor.y), bigWord) ~= class then break end
        end
    end

    -- Skip whitespace, including empty lines, to the next group.
    while charClass(currentChar(editor.cursor.x, editor.cursor.y), bigWord) == "space" do
        if not stepForward() then return end
    end
end

local function moveWordEnd(bigWord)
    local class = charClass(currentChar(editor.cursor.x, editor.cursor.y), bigWord)

    -- If another character of the current group is immediately to the right,
    -- this motion ends the current group. Otherwise it seeks the next group.
    if class ~= "space" and editor.cursor.x < lineLength(editor.cursor.y)
        and charClass(currentChar(editor.cursor.x + 1, editor.cursor.y), bigWord) == class then
        while editor.cursor.x < lineLength(editor.cursor.y)
            and charClass(currentChar(editor.cursor.x + 1, editor.cursor.y), bigWord) == class do
            stepForward()
        end
        return
    end

    while stepForward() do
        class = charClass(currentChar(editor.cursor.x, editor.cursor.y), bigWord)
        if class ~= "space" then break end
    end
    if class == "space" then return end

    while editor.cursor.x < lineLength(editor.cursor.y)
        and charClass(currentChar(editor.cursor.x + 1, editor.cursor.y), bigWord) == class do
        stepForward()
    end
end

local function moveWordBackward(bigWord)
    if not stepBackward() then return end

    while charClass(currentChar(editor.cursor.x, editor.cursor.y), bigWord) == "space" do
        if not stepBackward() then return end
    end

    local class = charClass(currentChar(editor.cursor.x, editor.cursor.y), bigWord)
    while true do
        local oldX, oldY = editor.cursor.x, editor.cursor.y
        if not stepBackward() then return end
        if editor.cursor.y ~= oldY
            or charClass(currentChar(editor.cursor.x, editor.cursor.y), bigWord) ~= class then
            editor.cursor.x, editor.cursor.y = oldX, oldY
            return
        end
    end
end

-- ===== Empty-line motions =====
local function isBlankLine(y)
    return (editor.buffer[y] or ""):match("^%s*$") ~= nil
end

local function moveToNextBlankLine()
    for y = editor.cursor.y + 1, #editor.buffer do
        if isBlankLine(y) then setCursor(1, y); return end
    end
end

local function moveToPreviousBlankLine()
    for y = editor.cursor.y - 1, 1, -1 do
        if isBlankLine(y) then setCursor(1, y); return end
    end
end

-- ===== Normal-mode editing commands =====
local setCharacterRegister, setLineRegister
local positionToOffset
local function deleteCharacters(count)
    local y, x = editor.cursor.y, editor.cursor.x
    local line = editor.buffer[y]
    local amount = math.min(count, #line - x + 1)
    if amount <= 0 then return end

    setCharacterRegister(positionToOffset(x, y), positionToOffset(x + amount - 1, y))
    snapshot()
    editor.buffer[y] = line:sub(1, x - 1) .. line:sub(x + amount)
    markBufferChanged()
    clampCursor()
    editor.cursor.wantCol = editor.cursor.x
end

local function deleteLines(count)
    setLineRegister(editor.cursor.y, math.min(#editor.buffer, editor.cursor.y + math.max(1, count or 1) - 1))
    snapshot()
    deleteLineRange(editor.cursor.y, count)
    editor.cursor.x = 1
    editor.cursor.wantCol = 1
end

local function deleteToEndOfLine()
    local y, x = editor.cursor.y, editor.cursor.x
    local line = editor.buffer[y]
    if x > #line then return false end

    setCharacterRegister(positionToOffset(x, y), positionToOffset(#line, y))
    snapshot()
    editor.buffer[y] = line:sub(1, x - 1)
    markBufferChanged()
    clampCursor()
    editor.cursor.wantCol = editor.cursor.x
    return true
end

local function changeToEndOfLine()
    local x, y = editor.cursor.x, editor.cursor.y
    local changed = deleteToEndOfLine()

    enterInsert()
    editor.cursor.x, editor.cursor.y = x, y
    clampCursor()
    editor.cursor.wantCol = editor.cursor.x
    editor.insertSnapshotTaken = changed
end

local function changeLines(count)
    local y = editor.cursor.y
    local line = editor.buffer[y]
    local indent = line:match("^%s*") or ""
    local last = math.min(#editor.buffer, y + count - 1)
    setLineRegister(y, last)
    snapshot()

    for _ = y, last do table.remove(editor.buffer, y) end
    table.insert(editor.buffer, y, indent)
    markBufferChanged()

    editor.cursor.x, editor.cursor.y = #indent + 1, y
    editor.cursor.wantCol = editor.cursor.x
    enterInsert()
    editor.insertSnapshotTaken = true
end

-- ===== Word text objects (iw / aw / iW / aW) =====
local function nextPosition(x, y)
    if x < lineLength(y) then return x + 1, y end
    if y < #editor.buffer then return 1, y + 1 end
    return nil, nil
end

local function previousPosition(x, y)
    if x > 1 then return x - 1, y end
    if y > 1 then
        local previousLength = lineLength(y - 1)
        if previousLength > 0 then return previousLength, y - 1 end
        return 1, y - 1
    end
    return nil, nil
end

local function isWhitespaceAt(x, y)
    local ch = currentChar(x, y)
    return ch ~= nil and ch:match("^%s$") ~= nil
end

local function findWordObject(bigWord, around)
    local x, y = editor.cursor.x, editor.cursor.y
    local class = charClass(currentChar(x, y), bigWord)
    if not class then return nil end

    local sx, sy, ex, ey = x, y, x, y
    while true do
        local nx, ny = previousPosition(sx, sy)
        if not nx or ny ~= sy or charClass(currentChar(nx, ny), bigWord) ~= class then break end
        sx, sy = nx, ny
    end
    while true do
        local nx, ny = nextPosition(ex, ey)
        if not nx or ny ~= ey or charClass(currentChar(nx, ny), bigWord) ~= class then break end
        ex, ey = nx, ny
    end

    if class == "space" then
        return sx, sy, ex, ey
    end

    if around then
        local nx, ny = nextPosition(ex, ey)
        local tookTrailingWhitespace = false
        while nx and isWhitespaceAt(nx, ny) do
            ex, ey = nx, ny
            tookTrailingWhitespace = true
            nx, ny = nextPosition(ex, ey)
        end
        -- Vim-style aw: prefer whitespace after the object; at end of a
        -- line/document, include preceding whitespace instead.
        if not tookTrailingWhitespace then
            local px, py = previousPosition(sx, sy)
            while px and isWhitespaceAt(px, py) do
                sx, sy = px, py
                px, py = previousPosition(sx, sy)
            end
        end
    end

    return sx, sy, ex, ey
end

positionToOffset = function(x, y)
    local offset = x
    for row = 1, y - 1 do offset = offset + #editor.buffer[row] + 1 end
    return offset
end

local function replaceRange(first, last, replacement)
    local original = currentContent()
    first = math.max(1, math.min(first, #original + 1))
    last = math.max(first - 1, math.min(last, #original))
    snapshot()

    local updated = original:sub(1, first - 1)
        .. (replacement or "")
        .. original:sub(last + 1)
    local lines = {}
    for line in (updated .. "\n"):gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    if #lines == 0 then lines = { "" } end
    editor.buffer = lines
    markBufferChanged()

    local remaining = first
    for y = 1, #editor.buffer do
        local length = #editor.buffer[y]
        if remaining <= length + 1 then
            return math.min(remaining, length + 1), y
        end
        remaining = remaining - length - 1
    end
    local y = #editor.buffer
    return #editor.buffer[y] + 1, y
end

local function deleteRange(first, last)
    -- Every explicit characterwise delete/change updates the unnamed register.
    setCharacterRegister(first, last)
    return replaceRange(first, last, "")
end

-- ===== Shared range/register engine =====
local offsetToPosition -- forward declaration for pasteRegister
setCharacterRegister = function(first, last)
    local content = currentContent()
    first = math.max(1, math.min(first, #content + 1))
    last = math.max(first - 1, math.min(last, #content))
    editor.register = {
        text = last >= first and content:sub(first, last) or "",
        type = "character",
        lines = nil,
    }
end

setLineRegister = function(firstLine, lastLine)
    firstLine = math.max(1, math.min(firstLine, #editor.buffer))
    lastLine = math.max(firstLine, math.min(lastLine, #editor.buffer))
    local lines = {}
    for y = firstLine, lastLine do
        lines[#lines + 1] = editor.buffer[y]
    end
    editor.register = {
        text = table.concat(lines, "\n"),
        type = "line",
        lines = lines,
    }
end

local function pasteRegister(before, count)
    local register = editor.register
    count = math.max(1, count or 1)
    if not register or (register.type == "character" and register.text == "") then
        editor.message = '"Nothing to paste"'
        return false
    end

    if register.type == "line" then
        local source = register.lines or {}
        if #source == 0 then return false end
        local insertAt = editor.cursor.y + (before and 0 or 1)
        local copies = {}
        for _ = 1, count do
            for _, line in ipairs(source) do
                copies[#copies + 1] = line
            end
        end

        snapshot()
        for i = #copies, 1, -1 do
            table.insert(editor.buffer, insertAt, copies[i])
        end
        markBufferChanged()
        setCursor(1, before and insertAt or (insertAt + #copies - 1))
        editor.message = ""
        return true
    end

    local insertionOffset = positionToOffset(editor.cursor.x, editor.cursor.y)
    local payload = string.rep(register.text, count)
    local newX, newY = replaceRange(insertionOffset, insertionOffset - 1, payload)
    -- Put the cursor on the final inserted character, not after it.
    local finalOffset = insertionOffset + #payload - 1
    local cursorX, cursorY = offsetToPosition(finalOffset)
    if #payload == 0 then cursorX, cursorY = newX, newY end
    setCursor(cursorX, cursorY)
    editor.message = ""
    return true
end

local function findDelimitedObject(delimiter, around)
    local line = editor.buffer[editor.cursor.y] or ""
    local cursor = editor.cursor.x
    local pairs = {}

    if delimiter == "\"" or delimiter == "'" then
        local open = nil
        local i = 1
        while i <= #line do
            local ch = line:sub(i, i)
            if ch == delimiter then
                local escaped = i > 1 and line:sub(i - 1, i - 1) == "\\"
                if not escaped then
                    if open then
                        pairs[#pairs + 1] = { open, i }
                        open = nil
                    else
                        open = i
                    end
                end
            end
            i = i + 1
        end
    else
        local closeFor = { ["("] = ")", ["["] = "]", ["{"] = "}" }
        local openFor = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
        local stack = {}
        for i = 1, #line do
            local ch = line:sub(i, i)
            if ch == delimiter then
                stack[#stack + 1] = i
            elseif ch == closeFor[delimiter] then
                local opening = table.remove(stack)
                if opening then pairs[#pairs + 1] = { opening, i } end
            end
        end
    end

    -- Search strictly forward from the cursor: select the first matching pair
    -- whose opening delimiter is at or after the cursor position. This allows
    -- text objects to target later pairs without requiring the cursor to be
    -- inside them (e.g. cursor in an identifier, then ci( or di[).
    local best
    for _, pair in ipairs(pairs) do
        if pair[1] >= cursor and (not best or pair[1] < best[1]) then
            best = pair
        end
    end
    if not best then return nil end

    local left, right = best[1], best[2]
    local first, last = around and left or left + 1, around and right or right - 1
    if last < first then last = first - 1 end
    return first, editor.cursor.y, last, editor.cursor.y
end

local function applyDelimitedOperator(operator, delimiter, around)
    local sx, sy, ex, ey = findDelimitedObject(delimiter, around)
    if not sx then editor.message = "No enclosing " .. delimiter .. " pair"; return end
    local first = positionToOffset(sx, sy)
    local last = positionToOffset(ex, ey)
    if operator == "y" then
        setCharacterRegister(first, last)
        setCursor(sx, sy)
        editor.message = "Yanked " .. #editor.register.text .. " characters"
        return
    end
    local newX, newY = deleteRange(first, last)
    setCursor(newX, newY)
    if operator == "c" then
        enterInsert()
        editor.insertSnapshotTaken = true
    end
end

local function applyWordOperator(operator, bigWord, around)
    local sx, sy, ex, ey = findWordObject(bigWord, around)
    if not sx then return end

    local first = positionToOffset(sx, sy)
    local last = positionToOffset(ex, ey)
    if operator == "y" then
        setCharacterRegister(first, last)
        setCursor(sx, sy)
        editor.message = "Yanked " .. (#editor.register.text) .. " characters"
        return
    end

    deleteRange(first, last)
    setCursor(sx, sy)

    if operator == "c" then
        enterInsert()
        editor.insertSnapshotTaken = true
    end
end

local function currentLineIndent()
    local line = editor.buffer[editor.cursor.y] or ""
    return line:match("^[ \t]*") or ""
end

local function openLineBelow()
    local indent = currentLineIndent()
    snapshot()
    table.insert(editor.buffer, editor.cursor.y + 1, indent)
    markBufferChanged()
    editor.cursor.y = editor.cursor.y + 1
    editor.cursor.x = #indent + 1
    editor.cursor.wantCol = editor.cursor.x
    enterInsert()
    -- The opening operation and subsequent typing belong to one undo step.
    editor.insertSnapshotTaken = true
end

local function openLineAbove()
    local indent = currentLineIndent()
    snapshot()
    table.insert(editor.buffer, editor.cursor.y, indent)
    markBufferChanged()
    editor.cursor.x = #indent + 1
    editor.cursor.wantCol = editor.cursor.x
    enterInsert()
    -- The opening operation and subsequent typing belong to one undo step.
    editor.insertSnapshotTaken = true
end

-- ===== Line joining (J joins the next line, K joins the previous line) =====
local function joinPair(upper, lower)
    local left = (editor.buffer[upper] or ""):gsub("%s+$", "")
    local right = (editor.buffer[lower] or ""):gsub("^%s+", "")
    local separator = (left ~= "" and right ~= "") and " " or ""
    editor.buffer[upper] = left .. separator .. right
    table.remove(editor.buffer, lower)
    return #left + (separator ~= "" and 1 or 0)
end

local function joinWithNext(count)
    count = math.max(1, count or 1)
    if editor.cursor.y >= #editor.buffer then
        editor.message = "E999: No line below"
        return false
    end
    snapshot()
    local joinColumn = editor.cursor.x
    local joined = 0
    for _ = 1, count do
        if editor.cursor.y >= #editor.buffer then break end
        joinColumn = joinPair(editor.cursor.y, editor.cursor.y + 1)
        joined = joined + 1
    end
    if joined == 0 then return false end
    markBufferChanged()
    editor.cursor.x = math.max(1, math.min(joinColumn, #editor.buffer[editor.cursor.y]))
    editor.cursor.wantCol = editor.cursor.x
    clampCursor()
    return true
end

local function joinWithPrevious(count)
    count = math.max(1, count or 1)
    if editor.cursor.y <= 1 then
        editor.message = "E999: No line above"
        return false
    end
    snapshot()
    local joined = 0
    local joinColumn = 1
    for _ = 1, count do
        if editor.cursor.y <= 1 then break end
        joinColumn = joinPair(editor.cursor.y - 1, editor.cursor.y)
        editor.cursor.y = editor.cursor.y - 1
        joined = joined + 1
    end
    if joined == 0 then return false end
    markBufferChanged()
    editor.cursor.x = math.max(1, math.min(joinColumn, #editor.buffer[editor.cursor.y]))
    editor.cursor.wantCol = editor.cursor.x
    clampCursor()
    return true
end

local refreshSearchMatches

-- ===== Search subsystem =====
-- Search is deliberately kept independent of input handling and rendering.
local function findAllMatches(query)
    local matches = {}
    if not query or query == "" then return matches end

    for y, line in ipairs(editor.buffer) do
        local startAt = 1
        while startAt <= #line do
            local x = line:find(query, startAt, true)
            if not x then break end
            matches[#matches + 1] = { x = x, y = y, length = #query }
            startAt = x + 1
        end
    end
    return matches
end

refreshSearchMatches = function()
    editor.search.matches = findAllMatches(editor.search.query)
    editor.search.current = 0
    editor.search.version = editor.search.version + 1
    editor.search.bufferVersion = editor.bufferVersion
end

local function clearSearchHighlight()
    editor.search.query = ""
    editor.search.matches = {}
    editor.search.current = 0
    editor.search.version = editor.search.version + 1
    editor.message = "Search highlight cleared"
end

local function jumpToSearchMatch(index)
    local matches = editor.search.matches
    if #matches == 0 then
        editor.search.current = 0
        editor.message = "Pattern not found: " .. editor.search.query
        editor.search.version = editor.search.version + 1
        return false
    end

    index = ((index - 1) % #matches) + 1
    editor.search.current = index
    local match = matches[index]
    setCursor(match.x, match.y)
    editor.message = string.format("Match %d/%d", index, #matches)
    editor.search.version = editor.search.version + 1
    return true
end

local function findSearchStart(direction)
    local matches = editor.search.matches
    if #matches == 0 then return false end
    local cursorOffset = positionToOffset(editor.cursor.x, editor.cursor.y)
    if direction >= 0 then
        for i, match in ipairs(matches) do
            if positionToOffset(match.x, match.y) > cursorOffset then
                return jumpToSearchMatch(i)
            end
        end
        return jumpToSearchMatch(1)
    end
    for i = #matches, 1, -1 do
        local match = matches[i]
        if positionToOffset(match.x, match.y) < cursorOffset then
            return jumpToSearchMatch(i)
        end
    end
    return jumpToSearchMatch(#matches)
end

local function repeatSearch(reverse)
    if editor.search.query == "" then return end
    if editor.search.bufferVersion ~= editor.bufferVersion then
        refreshSearchMatches()
    end
    local direction = editor.search.direction
    if reverse then direction = -direction end
    if editor.search.current == 0 then
        findSearchStart(direction)
    else
        local step = direction >= 0 and 1 or -1
        jumpToSearchMatch(editor.search.current + step)
    end
end

local function beginSearch(direction)
    editor.mode = "search"
    editor.searchInput = ""
    editor.searchDirection = direction
    editor.message = ""
end

local function finishSearch()
    local query = editor.searchInput or ""
    editor.mode = "normal"
    editor.searchInput = nil
    if query == "" then return end

    editor.search.query = query
    editor.search.direction = editor.searchDirection or 1
    refreshSearchMatches()
    findSearchStart(editor.search.direction)
end

-- ===== Indentation shifting (Vim-style << and >>) =====
-- Shift width is four spaces, matching Insert-mode Tab.
local function shiftLines(direction, count)
    count = math.max(1, count or 1)
    local first = editor.cursor.y
    local last = math.min(#editor.buffer, first + count - 1)
    local replacements = {}
    local cursorDelta = 0

    for y = first, last do
        local line = editor.buffer[y] or ""
        local updated = line
        if direction > 0 then
            updated = string.rep(" ", TAB_WIDTH) .. line
        else
            local leadingSpaces = #(line:match("^( *)") or "")
            if leadingSpaces > 0 then
                updated = line:sub(math.min(TAB_WIDTH, leadingSpaces) + 1)
            elseif line:sub(1, 1) == "\t" then
                updated = line:sub(2)
            end
        end

        if updated ~= line then
            replacements[y] = updated
            if y == editor.cursor.y then
                cursorDelta = #updated - #line
            end
        end
    end

    if next(replacements) == nil then return false end

    snapshot()
    for y, updated in pairs(replacements) do
        editor.buffer[y] = updated
    end
    markBufferChanged()
    editor.cursor.x = math.max(1, editor.cursor.x + cursorDelta)
    editor.cursor.wantCol = editor.cursor.x
    clampCursor()
    editor.message = direction > 0 and "Indented" or "Outdented"
    return true
end

-- ===== Command execution =====
local saveFile -- assigned in the file-I/O section below
local function repeatMotion(motion, count)
    for _ = 1, count do motion() end
end

local function executeMotion(command, count)
    if command == "h" then repeatMotion(moveLeft, count)
    elseif command == "j" then moveVertical(count)
    elseif command == "k" then moveVertical(-count)
    elseif command == "l" then repeatMotion(moveRight, count)
    elseif command == "w" then repeatMotion(function() moveWordForward(false) end, count)
    elseif command == "W" then repeatMotion(function() moveWordForward(true) end, count)
    elseif command == "e" then repeatMotion(function() moveWordEnd(false) end, count)
    elseif command == "E" then repeatMotion(function() moveWordEnd(true) end, count)
    elseif command == "b" then repeatMotion(function() moveWordBackward(false) end, count)
    elseif command == "B" then repeatMotion(function() moveWordBackward(true) end, count)
    elseif command == "{" then repeatMotion(moveToPreviousBlankLine, count)
    elseif command == "}" then repeatMotion(moveToNextBlankLine, count)
    elseif command == "0" then moveLineStart()
    elseif command == "^" then moveFirstNonBlank()
    elseif command == "$" then moveLineEnd()
    elseif command == "G" then moveToLine(count or #editor.buffer)
    elseif command == "gg" then moveToLine(count or 1)
    end

    clampCursor()
    if command ~= "j" and command ~= "k" and command ~= "gg" and command ~= "G" then
        editor.cursor.wantCol = editor.cursor.x
    end
end

-- ===== Operator + motion (d{motion} / c{motion}) =====
offsetToPosition = function(offset)
    local remaining = math.max(1, offset)
    for y = 1, #editor.buffer do
        local length = #editor.buffer[y]
        if remaining <= length + 1 then
            return math.min(remaining, length + 1), y
        end
        remaining = remaining - length - 1 -- account for the newline
    end
    local y = #editor.buffer
    return #editor.buffer[y] + 1, y
end

-- ===== Visual selection engine =====
local function beginVisual(kind)
    editor.visual = { anchorX = editor.cursor.x, anchorY = editor.cursor.y, kind = kind }
    editor.mode = kind == "line" and "visual_line" or "visual"
    editor.message = ""
end

local function endVisual()
    editor.visual = nil
    editor.mode = "normal"
    parser.state = "idle"
    parser.motionPrefix = nil
    parser.object = nil
    parser.count = 0
end

local function visualBounds()
    local v = editor.visual
    if not v then return nil end
    if v.kind == "line" then
        return math.min(v.anchorY, editor.cursor.y), math.max(v.anchorY, editor.cursor.y)
    end
    local a = positionToOffset(v.anchorX, v.anchorY)
    local b = positionToOffset(editor.cursor.x, editor.cursor.y)
    return math.min(a, b), math.max(a, b)
end

local function deleteVisualSelection(operator)
    local v = editor.visual
    if not v then return false end
    local first, last = visualBounds()
    local x, y
    if v.kind == "line" then
        setLineRegister(first, last)
        snapshot()
        deleteLineRange(first, last - first + 1)
        x, y = 1, math.min(first, #editor.buffer)
    else
        setCharacterRegister(first, last)
        x, y = offsetToPosition(first)
        local nx, ny = deleteRange(first, last)
        x, y = nx, ny
    end
    editor.cursor.x, editor.cursor.y = x, y
    editor.cursor.wantCol = x
    endVisual()
    if operator == "c" then
        enterInsert()
        editor.insertSnapshotTaken = true
    else
        clampCursor()
    end
    return true
end

local function yankVisualSelection()
    local v = editor.visual
    if not v then return false end
    local first, last = visualBounds()

    if v.kind == "line" then
        setLineRegister(first, last)
        editor.message = string.format("Yanked %d lines", last - first + 1)
    else
        setCharacterRegister(first, last)
        editor.message = string.format("Yanked %d characters", #editor.register.text)
    end
    endVisual()
    return true
end

local function handleVisualChar(ch)
    if parser.state == "replace_pending" then
        parser.state = "idle"
        local first, last = visualBounds()
        if editor.visual and editor.visual.kind == "line" then
            first = positionToOffset(1, first)
            last = positionToOffset(#editor.buffer[last] + 1, last) - 1
        end
        if first and last and last >= first and #ch == 1 then
            local startX, startY = offsetToPosition(first)
            replaceRange(first, last, ch)
            setCursor(startX, startY)
        end
        endVisual()
        return
    end

    if parser.object then
        local object = parser.object
        parser.object = nil
        parser.state = "idle"
        local sx, sy, ex, ey
        if ch == "w" or ch == "W" then
            sx, sy, ex, ey = findWordObject(ch == "W", object == "a")
        elseif ch == '\"' or ch == "'" or ch == "(" or ch == ")" or ch == "[" or ch == "]" or ch == "{" or ch == "}" then
            local delimiter = (ch == ")" and "(" or ch == "]" and "[" or ch == "}" and "{" or ch)
            sx, sy, ex, ey = findDelimitedObject(delimiter, object == "a")
        end
        if sx then
            editor.visual.kind = "character"
            editor.mode = "visual"
            editor.visual.anchorX, editor.visual.anchorY = sx, sy
            setCursor(ex, ey)
        end
        parser.count = 0
        return
    end

    if ch:match("^%d$") and (parser.count > 0 or ch ~= "0") then
        parser.count = parser.count * 10 + tonumber(ch)
        return
    end

    local hasExplicitCount = parser.count > 0
    local count = hasExplicitCount and parser.count or 1
    parser.count = 0

    if parser.motionPrefix == "g" then
        parser.motionPrefix = nil
        if ch == "g" then executeMotion("gg", hasExplicitCount and count or nil) end
        return
    end
    if ch == "g" then parser.motionPrefix = "g"; return end

    if ch == "z" then
        endVisual()
    elseif ch == "i" or ch == "a" then
        parser.object = ch
        parser.state = "object_pending"
    elseif ch == "v" then
        if editor.visual.kind == "character" then
            endVisual()
        else
            editor.visual.kind = "character"
            editor.mode = "visual"
        end
    elseif ch == "V" then
        if editor.visual.kind == "line" then
            endVisual()
        else
            editor.visual.kind = "line"
            editor.mode = "visual_line"
        end
    elseif ch == "y" then yankVisualSelection()
    elseif ch == "r" then parser.state = "replace_pending"
    elseif ch == "d" or ch == "x" then deleteVisualSelection("d")
    elseif ch == "c" then deleteVisualSelection("c")
    elseif ch == "p" or ch == "P" then
        local saved = { text = editor.register.text, type = editor.register.type, lines = nil }
        if editor.register.lines then
            saved.lines = {}
            for i, line in ipairs(editor.register.lines) do saved.lines[i] = line end
        end
        if saved.type == "character" and saved.text == "" or saved.type == "line" and (not saved.lines or #saved.lines == 0) then
            editor.message = '"Nothing to paste"'
        elseif deleteVisualSelection("d") then
            editor.register = saved
            pasteRegister(ch == "P", 1)
        end
    elseif ch == "o" then
        local v = editor.visual
        local x, y = v.anchorX, v.anchorY
        v.anchorX, v.anchorY = editor.cursor.x, editor.cursor.y
        setCursor(x, y)
    elseif ch == "h" or ch == "j" or ch == "k" or ch == "l"
        or ch == "w" or ch == "W" or ch == "e" or ch == "E"
        or ch == "b" or ch == "B" or ch == "0" or ch == "^"
        or ch == "$" or ch == "{" or ch == "}" or ch == "G" then
        local motionCount = count
        if ch == "G" and not hasExplicitCount then motionCount = nil end
        executeMotion(ch, motionCount)
    else
        parser.motionPrefix = nil
    end
end

local function isLinewiseMotion(motion)
    return motion == "j" or motion == "k" or motion == "gg"
        or motion == "G" or motion == "{" or motion == "}"
end

local function isInclusiveMotion(motion)
    return motion == "e" or motion == "E" or motion == "$"
end

local function applyOperatorMotion(operator, motion, count)
    local motionCount = math.max(1, count or 1)

    if operator == "c" and (motion == "w" or motion == "W")
        and charClass(currentChar(editor.cursor.x, editor.cursor.y), motion == "W") ~= "space" then
        motion = motion == "W" and "E" or "e"
    end

    local startX, startY = editor.cursor.x, editor.cursor.y

    -- Vertical and paragraph/whole-buffer motions operate on complete lines.
    if isLinewiseMotion(motion) then
        if motion == "G" and count == nil then
            executeMotion(motion, nil)
        else
            executeMotion(motion, motionCount)
        end
        local first = math.min(startY, editor.cursor.y)
        local last = math.max(startY, editor.cursor.y)
        local amount = last - first + 1
        editor.cursor.y = first
        editor.cursor.x = 1
        editor.cursor.wantCol = 1

        if operator == "y" then
            setLineRegister(first, last)
            setCursor(1, first)
            editor.message = "Yanked " .. amount .. (amount == 1 and " line" or " lines")
        elseif operator == "d" then
            deleteLines(amount)
        else
            changeLines(amount)
        end
        return
    end

    local startOffset = positionToOffset(startX, startY)
    executeMotion(motion, count)
    local targetOffset = positionToOffset(editor.cursor.x, editor.cursor.y)

    local inclusive = isInclusiveMotion(motion)
    local documentLength = #table.concat(editor.buffer, "\n")
    if (motion == "w" or motion == "W") and targetOffset == documentLength
        and targetOffset > startOffset then
        inclusive = true
    end

    if targetOffset == startOffset then
        if inclusive then
        else
            editor.cursor.x, editor.cursor.y = startX, startY
            return
        end
    end

    local first, last
    if targetOffset == startOffset then
        first, last = startOffset, startOffset
    elseif targetOffset > startOffset then
        first = startOffset
        last = targetOffset - (inclusive and 0 or 1)
    else
        first = targetOffset
        last = startOffset - 1
    end

    if last < first then
        editor.cursor.x, editor.cursor.y = startX, startY
        return
    end

    if operator == "y" then
        setCharacterRegister(first, last)
        setCursor(startX, startY)
        editor.message = "Yanked " .. (#editor.register.text) .. " characters"
        return
    end

    local newX, newY = deleteRange(first, last)
    editor.cursor.x, editor.cursor.y = newX, newY
    editor.cursor.wantCol = newX

    if operator == "c" then
        enterInsert()
        editor.cursor.x, editor.cursor.y = newX, newY
        clampCursor()
        editor.cursor.wantCol = editor.cursor.x
        editor.insertSnapshotTaken = true
    else
        clampCursor()
        editor.cursor.wantCol = editor.cursor.x
    end
end

local function executeNormalCommand(command, count)
    if command == "v" then beginVisual("character")
    elseif command == "V" then beginVisual("line")
    elseif command == "i" then enterInsert()
    elseif command == "I" then moveFirstNonBlank(); enterInsert()
    elseif command == "a" then
        if lineLength(editor.cursor.y) > 0 then
            editor.cursor.x = math.min(lineLength(editor.cursor.y) + 1, editor.cursor.x + 1)
        end
        enterInsert()
    elseif command == "A" then
        editor.cursor.x = lineLength(editor.cursor.y) + 1
        editor.cursor.wantCol = editor.cursor.x
        enterInsert()
    elseif command == "o" then openLineBelow()
    elseif command == "O" then openLineAbove()
    elseif command == "J" then joinWithNext(count)
    elseif command == "K" then joinWithPrevious(count)
    elseif command == "X" then
        if saveFile(editor.filename) then editor.running = false end
    elseif command == "/" then beginSearch(1)
    elseif command == "?" then beginSearch(-1)
    elseif command == "n" then repeatSearch(false)
    elseif command == "N" then repeatSearch(true)
    elseif command == "z" then clearSearchHighlight()
    elseif command == "x" then deleteCharacters(count)
    elseif command == "p" then pasteRegister(false, count)
    elseif command == "P" then pasteRegister(true, count)
    elseif command == "D" then deleteToEndOfLine()
    elseif command == "C" then changeToEndOfLine()
    elseif command == "u" then undo()
    elseif command == "d" or command == "c" then parser.pending = command
    else executeMotion(command, count) end
end

local function resetCommandParser()
    parser.state = "idle"
    parser.pending = nil
    parser.operatorCount = 1
    parser.object = nil
    parser.motionPrefix = nil
    parser.count = 0
end

local function findChar(ch, direction, count)
    if not ch or #ch ~= 1 then return false end
    local line = editor.buffer[editor.cursor.y] or ""
    local found = 0
    count = math.max(1, count or 1)

    if direction >= 0 then
        for i = editor.cursor.x + 1, #line do
            if line:sub(i, i) == ch then
                found = found + 1
                if found == count then setCursor(i, editor.cursor.y); return true end
            end
        end
    else
        for i = editor.cursor.x - 1, 1, -1 do
            if line:sub(i, i) == ch then
                found = found + 1
                if found == count then setCursor(i, editor.cursor.y); return true end
            end
        end
    end
    return false
end

local function handleNormalChar(ch)
    if editor.mode == "visual" or editor.mode == "visual_line" then
        handleVisualChar(ch)
        return
    end

    if ch == ":" and parser.state == "idle" and not parser.pending then
        editor.mode = "command"
        editor.commandLine = ""
        editor.message = ""
        resetCommandParser()
        return
    end

    if parser.state == "replace_pending" then
        local count = math.max(1, parser.count or 1)
        parser.state = "idle"
        parser.count = 0
        if #ch == 1 and ch ~= "\n" and ch ~= "\t" then
            local y, x = editor.cursor.y, editor.cursor.x
            local line = editor.buffer[y] or ""
            local amount = math.min(count, math.max(0, #line - x + 1))
            if amount > 0 then
                snapshot()
                editor.buffer[y] = line:sub(1, x - 1) .. string.rep(ch, amount) .. line:sub(x + amount)
                markBufferChanged()
                setCursor(x, y)
                editor.message = ""
            end
        end
        resetCommandParser()
        return
    end

    if parser.state == "find_pending" then
        if findChar(ch, parser.findDirection, parser.count > 0 and parser.count or 1) then
            editor.lastFind = { char = ch, direction = parser.findDirection }
        end
        resetCommandParser()
        return
    end

    if not parser.pending and (ch == "f" or ch == "F") then
        parser.state = "find_pending"
        parser.findDirection = ch == "f" and 1 or -1
        return
    end

    -- Operator-pending state: d/c/y followed by a text object or motion.
    if parser.pending == "d" or parser.pending == "c" or parser.pending == "y" then
        local operator = parser.pending
        local operatorCount = parser.operatorCount or 1

        if parser.motionPrefix == "g" then
            if ch == "g" then
                local motionCount = parser.count > 0 and parser.count or 1
                applyOperatorMotion(operator, "gg", operatorCount * motionCount)
            end
            resetCommandParser()
            return
        end

        if ch:match("^%d$") and (parser.count > 0 or ch ~= "0") then
            parser.count = parser.count * 10 + tonumber(ch)
            return
        end

        local explicitMotionCount = parser.count > 0 and parser.count or nil
        local motionCount = explicitMotionCount or 1
        if parser.object then
            local object = parser.object
            if ch == "w" or ch == "W" then
                applyWordOperator(operator, ch == "W", object == "a")
            elseif ch == '\"' or ch == "'" or ch == "(" or ch == ")" or ch == "[" or ch == "]" or ch == "{" or ch == "}" then
                local delimiter = (ch == ")" and "(" or ch == "]" and "[" or ch == "}" and "{" or ch)
                applyDelimitedOperator(operator, delimiter, object == "a")
            end
            resetCommandParser()
            return
        end

        if ch == "i" or ch == "a" then
            parser.object = ch
            parser.state = "object_pending"
            parser.count = 0
            return
        elseif ch == "g" then
            parser.motionPrefix = "g"
            parser.state = "motion_pending"
            return
        elseif ch == operator then
            local total = operatorCount * motionCount
            if operator == "y" then
                local first = editor.cursor.y
                local last = math.min(#editor.buffer, first + total - 1)
                setLineRegister(first, last)
                editor.message = "Yanked " .. (last - first + 1) .. " lines"
            elseif operator == "d" then deleteLines(total)
            else changeLines(total) end
            resetCommandParser()
            return
        end

        local validMotions = {
            h = true, j = true, k = true, l = true,
            w = true, W = true, e = true, E = true,
            b = true, B = true, ["{"] = true, ["}"] = true,
            ["0"] = true, ["^"] = true, ["$"] = true, G = true,
        }
        if validMotions[ch] then
            local totalCount = operatorCount * motionCount
            if ch == "G" and not explicitMotionCount and operatorCount == 1 then
                totalCount = nil -- bare dG/cG reach the last line
            end
            applyOperatorMotion(operator, ch, totalCount)
        end
        resetCommandParser()
        return
    elseif parser.pending == "<" or parser.pending == ">" then
        local shiftOperator = parser.pending
        if ch:match("^%d$") and (parser.count > 0 or ch ~= "0") then
            parser.count = parser.count * 10 + tonumber(ch)
            return
        end
        if ch == shiftOperator then
            local motionCount = parser.count > 0 and parser.count or 1
            shiftLines(shiftOperator == ">" and 1 or -1,
                (parser.operatorCount or 1) * motionCount)
        end
        resetCommandParser()
        return
    elseif parser.pending == "g" then
        local count = parser.count > 0 and parser.count or nil
        if ch == "g" then
            executeMotion("gg", count)
            resetCommandParser()
            return
        end
        resetCommandParser()
    end

    -- Numeric prefix. A leading zero is the first-column motion.
    if ch:match("^%d$") and (parser.count > 0 or ch ~= "0") then
        parser.count = parser.count * 10 + tonumber(ch)
        return
    end

    local count = parser.count > 0 and parser.count or 1

    if ch == ";" or ch == "," then
        if editor.lastFind then
            local direction = editor.lastFind.direction
            if ch == "," then direction = -direction end
            findChar(editor.lastFind.char, direction, count)
        end
        resetCommandParser()
        return
    end

    if ch == "r" then
        parser.state = "replace_pending"
        parser.pending = nil
        return
    elseif ch == "g" then
        parser.pending = "g"
        parser.state = "motion_pending"
        return
    elseif ch == "d" or ch == "c" or ch == "y" or ch == "<" or ch == ">" then
        parser.pending = ch
        parser.operatorCount = count
        parser.count = 0
        return
    end

    if ch == "G" and parser.count == 0 then
        executeMotion("G", nil)
    else
        executeNormalCommand(ch, count)
    end
    resetCommandParser()
end

local function handleInsertChar(ch)
    if #ch ~= 1 or ch == "\n" or ch == "\t" or ch == "\0" then return end

    if editor.lastInsertChar == "j" and ch == "k" then
        -- Remove the previously inserted j and leave Insert mode.
        local x, y = editor.cursor.x, editor.cursor.y
        if x > 1 then
            beginInsertChange()
            local line = editor.buffer[y]
            editor.buffer[y] = line:sub(1, x - 2) .. line:sub(x)
            editor.cursor.x = x - 1
            editor.cursor.wantCol = editor.cursor.x
        end
        editor.mode = "normal"
        editor.lastInsertChar = ""
        editor.insertShouldStepBack = false
        clampCursor()
        return
    end

    insertText(ch)
    editor.lastInsertChar = ch
end

local loadFile

saveFile = function(path)
    if not path or path == "" or path == "[No Name]" then
        editor.message = "E32: No file name"
        return false
    end

    local ok, err = pcall(function()
        local file = fs.open(path, "w")
        if not file then error("cannot open file for writing") end
        local writeOk, writeErr = pcall(function()
            for _, line in ipairs(editor.buffer) do
                file.writeLine(line)
            end
        end)
        local closeOk, closeErr = pcall(function() file.close() end)
        if not writeOk then error(writeErr) end
        if not closeOk then error(closeErr) end
    end)

    if not ok then
        editor.message = "Write error: " .. tostring(err)
        return false
    end

    editor.filename = path
    editor.savedContent = currentContent()
    updateDirty()
    editor.message = '\"' .. path .. '\" written'
    return true
end

local function executeExCommand(command)
    command = command:match("^%s*(.-)%s*$")
    local name, argument = command:match("^(%S+)%s*(.-)$")
    argument = argument or ""

    if name == "X" then
        if saveFile(editor.filename) then editor.running = false end
    elseif name == "w" then
        local path = argument ~= "" and argument or editor.filename
        saveFile(path)
    elseif name == "q" then
        if argument == "!" then
            editor.running = false
        elseif editor.dirty then
            editor.message = "No write since last change (add ! to override)"
        else
            editor.running = false
        end
    elseif name == "q!" then
        editor.running = false
    elseif name == "x" then
        local path = argument ~= "" and argument or editor.filename
        if path == "[No Name]" or path == "" then
            editor.message = "E32: No file name"
            return
        end
        if saveFile(path) then editor.running = false end
    elseif name == "wq" then
        local path = argument ~= "" and argument or editor.filename
        if path == "[No Name]" or path == "" then
            editor.message = "E32: No file name"
            return
        end
        if saveFile(path) then editor.running = false end
    elseif name == "e" then
        if argument == "" then
            editor.message = "E471: Argument required"
        elseif editor.dirty then
            editor.message = "No write since last change (save or use :e!)"
        else
            local ok = loadFile(argument)
            if ok then editor.message = '"' .. argument .. '" opened' end
        end
    elseif name == "e!" then
        if argument == "" then
            if editor.filename == "[No Name]" then
                editor.message = "E32: No file name"
            else
                local path = editor.filename
                local ok = loadFile(path)
                if ok then editor.message = '"' .. path .. '" reloaded' end
            end
        else
            local ok = loadFile(argument)
            if ok then editor.message = '"' .. argument .. '" opened' end
        end
    elseif command == "" then
        editor.message = ""
    else
        editor.message = "Not an editor command: " .. command
    end
end

local function handleChar(ch)
    if editor.mode == "normal" or editor.mode == "visual" or editor.mode == "visual_line" then
        handleNormalChar(ch)
    elseif editor.mode == "insert" then
        handleInsertChar(ch)
    elseif editor.mode == "command" then
        if #ch == 1 and ch ~= "\n" and ch ~= "\t" then
            editor.commandLine = editor.commandLine .. ch
        end
    elseif editor.mode == "search" then
        if #ch == 1 and ch ~= "\n" and ch ~= "\t" then
            editor.searchInput = (editor.searchInput or "") .. ch
        end
    end
end

local applyCompletion -- forward declaration: handleKey uses this before its definition

local function handleKey(code)
    if code == keys.escape then
        if editor.mode == "insert" then
            exitInsert()
        elseif editor.mode == "command" then
            editor.mode = "normal"
            editor.commandLine = ""
        elseif editor.mode == "search" then
            editor.mode = "normal"
            editor.searchInput = nil
        elseif editor.mode == "visual" or editor.mode == "visual_line" then
            endVisual()
        end
        resetCommandParser()
        return
    end

    if editor.mode == "command" then
        if code == keys.backspace then
            editor.commandLine = editor.commandLine:sub(1, -2)
        elseif code == keys.enter then
            local command = editor.commandLine
            editor.mode = "normal"
            editor.commandLine = ""
            executeExCommand(command)
        end
        return
    elseif editor.mode == "search" then
        if code == keys.backspace then
            editor.searchInput = (editor.searchInput or ""):sub(1, -2)
        elseif code == keys.enter then
            finishSearch()
        end
        return
    end

    if editor.mode ~= "insert" then return end

    if ctrlDown and code == keys.n then
        if #completion.items > 0 then
            completion.selected = (completion.selected % #completion.items) + 1
        end
        return
    elseif ctrlDown and code == keys.p then
        if #completion.items > 0 then
            completion.selected = ((completion.selected - 2) % #completion.items) + 1
        end
        return
    end

    if code == keys.backspace then
        insertBackspace()
        editor.lastInsertChar = ""
    elseif code == keys.tab then
        -- Tab is indentation, never a completion-confirm key.
        insertTab()
        editor.lastInsertChar = ""
    elseif code == keys.enter then
        if #completion.items > 0 and applyCompletion() then
            editor.lastInsertChar = ""
        else
            insertEnter()
            editor.lastInsertChar = ""
        end
    end
end

local renderedRows = {}
local composedRows = {}
local layout = { gutterWidth = 4, textWidth = math.max(1, width - 4) }

local function updateLayout()
    local digits = #tostring(#editor.buffer)
    local gutterWidth = math.max(4, digits + 1)
    local textWidth = math.max(1, width - gutterWidth)

    if layout.gutterWidth ~= gutterWidth or layout.textWidth ~= textWidth then
        layout.gutterWidth, layout.textWidth = gutterWidth, textWidth
        renderedRows = {}
        composedRows = {}
    end
end

local function updateViewport()
    local cursor, viewport = editor.cursor, editor.viewport
    local visibleRows = math.max(1, height - 2)
    local verticalMargin = math.min(2, math.floor((visibleRows - 1) / 2))
    local horizontalMargin = math.min(2, math.floor((layout.textWidth - 1) / 2))

    local topLine = viewport.y + 1
    local bottomLine = viewport.y + visibleRows
    if cursor.y < topLine + verticalMargin then
        viewport.y = cursor.y - 1 - verticalMargin
    elseif cursor.y > bottomLine - verticalMargin then
        viewport.y = cursor.y - visibleRows + verticalMargin
    end

    local leftColumn = viewport.x + 1
    local rightColumn = viewport.x + layout.textWidth
    if cursor.x < leftColumn + horizontalMargin then
        viewport.x = cursor.x - 1 - horizontalMargin
    elseif cursor.x > rightColumn - horizontalMargin then
        viewport.x = cursor.x - layout.textWidth + horizontalMargin
    end

    viewport.x = math.max(0, viewport.x)
    viewport.y = math.max(0, viewport.y)
end

local function displayedLineNumber(line)
    if line == editor.cursor.y then return line end
    return math.abs(line - editor.cursor.y)
end

local function makeRow()
    local chars, fg, bg = {}, {}, {}
    for x = 1, width do
        chars[x], fg[x], bg[x] = " ", WHITE, BLACK
    end
    return chars, fg, bg
end

local function writeRow(chars, fg, bg, x, text, textFg, textBg)
    textFg, textBg = textFg or WHITE, textBg or BLACK
    for i = 1, #text do
        local px = x + i - 1
        if px >= 1 and px <= width then
            chars[px], fg[px], bg[px] = text:sub(i, i), textFg, textBg
        end
    end
end

local function fillRow(chars, fg, bg, x1, x2, textFg, textBg)
    for x = math.max(1, x1), math.min(width, x2) do
        chars[x], fg[x], bg[x] = " ", textFg, textBg
    end
end

local luaKeywords = {
    ["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true, ["elseif"]=true, ["end"]=true,
    ["for"]=true, ["function"]=true, ["if"]=true, ["in"]=true, ["local"]=true, ["nil"]=true,
    ["not"]=true, ["or"]=true, ["repeat"]=true, ["return"]=true, ["then"]=true, ["until"]=true,
    ["while"]=true, ["goto"]=true,
}
local luaBuiltins = {
    assert=true, error=true, ipairs=true, pairs=true, next=true, pcall=true,
    xpcall=true, print=true, select=true, tonumber=true, tostring=true,
    type=true, unpack=true, rawequal=true, rawget=true, rawset=true,
    setmetatable=true, getmetatable=true, require=true, load=true,
    loadfile=true, dofile=true, math=true, string=true, table=true,
    coroutine=true, os=true, io=true, debug=true, term=true, colors=true,
    keys=true, fs=true, shell=true, peripheral=true, redstone=true,
    textutils=true, turtle=true, commands=true, paintutils=true,
}

local function syntaxTokens(line)
    local tokens, i, n = {}, 1, #line
    local function add(a, b, color)
        if a <= b then tokens[#tokens + 1] = { a, b, color } end
    end
    while i <= n do
        local c = line:sub(i, i)
        local two = line:sub(i, i + 1)
        if two == "--" then
            add(i, n, SYNTAX.comment); break
        elseif c == '"' or c == "'" then
            local quote, j = c, i + 1
            while j <= n do
                local ch = line:sub(j, j)
                if ch == "\\" then j = j + 2
                elseif ch == quote then j = j + 1; break
                else j = j + 1 end
            end
            add(i, math.min(n, j - 1), SYNTAX.string); i = j
        elseif c:match("%d") then
            local j = i + 1
            while j <= n and line:sub(j, j):match("[%w%.]") do j = j + 1 end
            add(i, j - 1, SYNTAX.number); i = j
        elseif c:match("[%a_]") then
            local j = i + 1
            while j <= n and line:sub(j, j):match("[%w_]") do j = j + 1 end
            local word = line:sub(i, j - 1)
            local color = luaKeywords[word] and SYNTAX.keyword or SYNTAX.text
            if not luaKeywords[word] then
                local k = j
                while k <= n and line:sub(k, k):match("%s") do k = k + 1 end
                if line:sub(k, k) == "(" or luaBuiltins[word] then color = SYNTAX.func end
            end
            add(i, j - 1, color); i = j
        elseif c:match("[%[%]{}%(%)%,;]") then
            add(i, i, SYNTAX.bracket); i = i + 1
        elseif c:match("[+%-*/%%%^#=<>~:.]") then
            local j = i + 1
            while j <= n and line:sub(j, j):match("[+%-*/%%%^#=<>~:.]") do j = j + 1 end
            add(i, j - 1, SYNTAX.operator); i = j
        elseif c:match("[%z\1-\31\127]") then
            add(i, i, SYNTAX.special); i = i + 1
        else
            i = i + 1
        end
    end
    return tokens
end

local function refreshCompletion()
    local previousSelected = completion.selected
    local previousPrefix = completion.prefix
    completion.items, completion.prefix, completion.startX = {}, "", editor.cursor.x
    completion.selected = previousSelected or 1
    completion.scroll = completion.scroll or 1
    if editor.mode ~= "insert" or type(textutils) ~= "table" or type(textutils.complete) ~= "function" then
        completion.version = editor.bufferVersion
        return
    end
    local line = editor.buffer[editor.cursor.y] or ""
    local before = line:sub(1, editor.cursor.x - 1)
    local startX = before:find("[%a%d_%.:]+$")
    if not startX then completion.version = editor.bufferVersion; return end
    local prefix = before:sub(startX)
    if prefix == "" then completion.version = editor.bufferVersion; return end
    local ok, items = pcall(textutils.complete, prefix, _ENV)
    if ok and type(items) == "table" then
        local unique = {}
        for _, item in ipairs(items) do
            if type(item) == "string" and item ~= prefix and not unique[item] then
                unique[item] = true
                completion.items[#completion.items + 1] = item
            end
        end
    end
    completion.startX, completion.prefix = startX, prefix
    if previousPrefix ~= prefix then completion.selected, completion.scroll = 1, 1 end
    completion.selected = math.max(1, math.min(completion.selected, #completion.items))
    completion.scroll = math.max(1, math.min(completion.scroll, math.max(1, #completion.items)))
    completion.version = editor.bufferVersion
end

applyCompletion = function()
    local selected = tonumber(completion.selected)
    local item = selected and completion.items[selected]
    local y = editor.cursor.y
    local line = editor.buffer[y]
    local startX = tonumber(completion.startX)
    if type(item) ~= "string" or type(line) ~= "string" or not startX
        or startX < 1 or startX > editor.cursor.x or editor.cursor.x > #line + 1 then
        return false
    end

    local prefix = tostring(completion.prefix or line:sub(startX, editor.cursor.x - 1))
    local completed = item
    if prefix ~= "" and item:sub(1, #prefix) ~= prefix then
        completed = prefix .. item
    end

    beginInsertChange()
    local prefixBefore = line:sub(1, startX - 1)
    local suffix = line:sub(editor.cursor.x)
    editor.buffer[y] = prefixBefore .. completed .. suffix
    editor.cursor.x = #prefixBefore + #completed + 1
    editor.cursor.wantCol = editor.cursor.x
    markBufferChanged()
    completion.items = {}
    completion.selected = 1
    completion.scroll = 1
    editor.insertShouldStepBack = true
    return true
end

local function composeRow(screenY)
    local cursorX = layout.gutterWidth + editor.cursor.x - editor.viewport.x
    local cursorY = editor.cursor.y - editor.viewport.y + 1
    local signature

    if screenY == 1 then
        signature = "header|" .. editor.filename .. "|" .. tostring(editor.dirty) .. "|" .. width
    elseif screenY == height then
        signature = "status|" .. editor.mode .. "|" .. editor.cursor.x .. "|" .. editor.cursor.y .. "|" .. editor.commandLine .. "|" .. tostring(editor.searchInput) .. "|" .. editor.message .. "|" .. width
    else
        local bufferY = screenY - 1 + editor.viewport.y
        local line = editor.buffer[bufferY]
        local number = line and displayedLineNumber(bufferY) or "~"
        signature = table.concat({ "buffer", tostring(bufferY), tostring(line), tostring(number),
            tostring(editor.viewport.x), tostring(layout.gutterWidth), tostring(layout.textWidth),
            tostring(editor.mode == "normal" and screenY == cursorY and cursorX),
            tostring(editor.search.version), tostring(editor.mode),
            tostring(editor.visual and editor.visual.anchorX), tostring(editor.visual and editor.visual.anchorY),
            tostring(editor.visual and editor.cursor.x), tostring(editor.visual and editor.cursor.y),
            tostring(editor.visual and editor.visual.kind), tostring(width),
            tostring(#completion.items), tostring(completion.selected), tostring(completion.prefix) }, "|")
    end

    local cached = composedRows[screenY]
    if cached and cached.signature == signature then
        return cached.chars, cached.fg, cached.bg
    end

    local chars, fg, bg = makeRow()

    if screenY == 1 then
        fillRow(chars, fg, bg, 1, width, BLACK, LIGHT_GRAY)
        local title = " " .. editor.filename
        if editor.dirty then title = title .. " [+]" end
        writeRow(chars, fg, bg, 1, title, BLACK, LIGHT_GRAY)
    elseif screenY == height then
        fillRow(chars, fg, bg, 1, width, BLACK, LIGHT_GRAY)
        local status
        if editor.mode == "command" then
            status = ":" .. editor.commandLine
        elseif editor.mode == "search" then
            status = (editor.searchDirection == -1 and "?" or "/") .. (editor.searchInput or "")
        elseif editor.message ~= "" then
            status = " " .. editor.message
        else
            local modeName = editor.mode == "insert" and "INSERT"
                or editor.mode == "visual" and "VISUAL"
                or editor.mode == "visual_line" and "VISUAL LINE" or "NORMAL"
            status = string.format(" %s  %d:%d", modeName, editor.cursor.x, editor.cursor.y)
        end
        writeRow(chars, fg, bg, 1, status, BLACK, LIGHT_GRAY)
    else
        local bufferY = screenY - 1 + editor.viewport.y
        local line = editor.buffer[bufferY]
        if line then
            local number = displayedLineNumber(bufferY)
            local numberText = string.format("%" .. (layout.gutterWidth - 1) .. "d ", number)
            writeRow(chars, fg, bg, 1, numberText, GRAY, BLACK)
            writeRow(chars, fg, bg, layout.gutterWidth + 1,
                line:sub(editor.viewport.x + 1, editor.viewport.x + layout.textWidth), WHITE, BLACK)

            -- Syntax colouring is applied to the visible source characters.
            for _, token in ipairs(syntaxTokens(line)) do
                local first = math.max(token[1], editor.viewport.x + 1)
                local last = math.min(token[2], editor.viewport.x + layout.textWidth)
                for sourceX = first, last do
                    local screenX = layout.gutterWidth + sourceX - editor.viewport.x
                    if screenX >= layout.gutterWidth + 1 and screenX <= width then
                        fg[screenX] = token[3]
                    end
                end
            end

            -- Search matches are a renderer overlay; search logic never paints.
            for index, match in ipairs(editor.search.matches) do
                if match.y == bufferY then
                    local first = math.max(match.x, editor.viewport.x + 1)
                    local last = math.min(match.x + match.length - 1,
                        editor.viewport.x + layout.textWidth)
                    if first <= last then
                        local highlightBg = index == editor.search.current and "b" or "e"
                        local highlightFg = "0"
                        for x = first, last do
                            local screenX = layout.gutterWidth + x - editor.viewport.x
                            if screenX >= 1 and screenX <= width then
                                fg[screenX], bg[screenX] = highlightFg, highlightBg
                            end
                        end
                    end
                end
            end

            -- Visual selection is rendered as an overlay, independent of editing.
            if editor.visual then
                local first, last = visualBounds()
                if editor.visual.kind == "line" then
                    local firstLine, lastLine = first, last
                    if bufferY >= firstLine and bufferY <= lastLine then
                        for sx = layout.gutterWidth + 1, width do
                            fg[sx], bg[sx] = BLACK, LIGHT_GRAY
                        end
                    end
                else
                    local lineStart = positionToOffset(1, bufferY)
                    local lineEnd = lineStart + #line - 1
                    local selectedFirst = math.max(first, lineStart)
                    local selectedLast = math.min(last, lineEnd)
                    if selectedFirst <= selectedLast then
                        for offset = selectedFirst, selectedLast do
                            local column = offset - lineStart + 1
                            local screenX = layout.gutterWidth + column - editor.viewport.x
                            if screenX >= layout.gutterWidth + 1 and screenX <= width then
                                fg[screenX], bg[screenX] = BLACK, LIGHT_GRAY
                            end
                        end
                    end
                end
            end
        else
            writeRow(chars, fg, bg, 1, string.rep(" ", layout.gutterWidth - 1) .. " ", GRAY, BLACK)
            writeRow(chars, fg, bg, layout.gutterWidth + 1, "~", GRAY, BLACK)
        end
    end

    local cursorX = layout.gutterWidth + editor.cursor.x - editor.viewport.x
    local cursorY = editor.cursor.y - editor.viewport.y + 1
    if (editor.mode == "normal" or editor.mode == "visual" or editor.mode == "visual_line") and screenY == cursorY
        and cursorX >= layout.gutterWidth + 1 and cursorX <= width then
        fg[cursorX], bg[cursorX] = bg[cursorX], fg[cursorX]
    end

    if #completion.items > 0 then
        local cursorScreenY = editor.cursor.y - editor.viewport.y + 1
        local visibleCount = math.min(4, #completion.items, math.max(1, height - 2))
        if completion.selected < completion.scroll then completion.scroll = completion.selected end
        if completion.selected >= completion.scroll + visibleCount then
            completion.scroll = completion.selected - visibleCount + 1
        end
        completion.scroll = math.max(1, math.min(completion.scroll, #completion.items - visibleCount + 1))
        local popupTop = cursorScreenY + 1
        if popupTop + visibleCount - 1 > height - 1 then
            popupTop = math.max(2, cursorScreenY - visibleCount)
        end
        local popupWidth = 1
        for i = completion.scroll, completion.scroll + visibleCount - 1 do
            popupWidth = math.max(popupWidth, #(completion.items[i] or ""))
        end
        popupWidth = math.min(popupWidth, math.max(1, width - layout.gutterWidth))
        local popupX = math.max(layout.gutterWidth + 1, math.min(
            layout.gutterWidth + editor.cursor.x - editor.viewport.x,
            width - popupWidth + 1))
        if screenY >= popupTop and screenY < popupTop + visibleCount then
            local index = completion.scroll + screenY - popupTop
            local item = completion.items[index] or ""
            local selectedItem = index == completion.selected
            fillRow(chars, fg, bg, popupX, popupX + popupWidth - 1,
                selectedItem and BLACK or WHITE, selectedItem and LIGHT_GRAY or GRAY)
            writeRow(chars, fg, bg, popupX, item:sub(1, popupWidth),
                selectedItem and BLACK or WHITE, selectedItem and LIGHT_GRAY or GRAY)
        end
    end

    local row = { signature = signature, chars = table.concat(chars),
        fg = table.concat(fg), bg = table.concat(bg) }
    composedRows[screenY] = row
    return row.chars, row.fg, row.bg
end

local function flushRows()
    for y = 1, height do
        local chars, fg, bg = composeRow(y)
        local previous = renderedRows[y]
        if not previous or previous.chars ~= chars or previous.fg ~= fg or previous.bg ~= bg then
            term.setCursorPos(1, y)
            term.blit(chars, fg, bg)
            renderedRows[y] = { chars = chars, fg = fg, bg = bg }
        end
    end
end

local function render()
    if editor.search.query ~= "" and editor.search.bufferVersion ~= editor.bufferVersion then
        refreshSearchMatches()
    end
    updateLayout()
    clampCursor()
    updateViewport()
    refreshCompletion()
    flushRows()

    local screenX = layout.gutterWidth + editor.cursor.x - editor.viewport.x
    local screenY = editor.cursor.y - editor.viewport.y + 1
    local visible = screenY >= 2 and screenY <= height - 1
        and screenX >= layout.gutterWidth + 1 and screenX <= width

    if editor.mode == "insert" and visible then
        term.setCursorPos(screenX, screenY)
        term.setCursorBlink(true)
    elseif editor.mode == "command" then
        term.setCursorPos(math.min(width, #editor.commandLine + 2), height)
        term.setCursorBlink(true)
    elseif editor.mode == "search" then
        term.setCursorPos(math.min(width, #(editor.searchInput or "") + 2), height)
        term.setCursorBlink(true)
    else
        term.setCursorBlink(false)
    end
end

-- ===== File loading =====
loadFile = function(path)
    if not path or path == "" then return false, "empty filename" end

    if not fs.exists(path) then
        editor.filename = path
        editor.buffer = { "" }
        editor.savedContent = ""
        editor.history = {}
        editor.visual = nil
        editor.mode = "normal"
        editor.bufferVersion = editor.bufferVersion + 1
        editor.message = '"' .. path .. '" [New File]'
        setCursor(1, 1)
        updateDirty()
        return true
    end

    local loaded = {}
    local ok, err = pcall(function()
        local file = fs.open(path, "r")
        if not file then error("cannot open file for reading") end
        local readOk, readErr = pcall(function()
            while true do
                local line = file.readLine()
                if line == nil then break end
                loaded[#loaded + 1] = line
            end
        end)
        local closeOk, closeErr = pcall(function() file.close() end)
        if not readOk then error(readErr) end
        if not closeOk then error(closeErr) end
    end)

    if not ok then
        editor.message = "Read error: " .. tostring(err)
        return false, err
    end

    if #loaded == 0 then loaded = { "" } end
    editor.buffer = loaded
    editor.filename = path
    editor.savedContent = currentContent()
    editor.history = {}
    editor.visual = nil
    editor.mode = "normal"
    editor.bufferVersion = editor.bufferVersion + 1
    setCursor(1, 1)
    updateDirty()
    return true
end
-- ===== Startup =====
local args = { ... }
if args[1] then loadFile(args[1]) end

updateLayout()
term.clear()
term.setCursorPos(1, 1)

-- ===== Main loop =====
while editor.running do
    render()
    local event = { os.pullEvent() }

    if event[1] == "char" then
        handleChar(event[2])
    elseif event[1] == "key" then
        if event[2] == keys.leftCtrl or event[2] == keys.rightCtrl then ctrlDown = true end
        handleKey(event[2])
    elseif event[1] == "key_up" then
        if event[2] == keys.leftCtrl or event[2] == keys.rightCtrl then ctrlDown = false end
    elseif event[1] == "terminate" then
        editor.running = false
    elseif event[1] == "term_resize" then
        width, height = term.getSize()
        renderedRows = {}
        composedRows = {}
        updateLayout()
        term.clear()
    end
end

term.setCursorBlink(false)
term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)