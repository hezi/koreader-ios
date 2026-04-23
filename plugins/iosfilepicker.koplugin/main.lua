--[[--
iOS file picker integration.

Lets the user add cloud folders (iCloud Drive, Dropbox, Google Drive, …)
into KOReader's file browser. Each cloud folder is picked once via iOS'
native UIDocumentPickerViewController; we persist a security-scoped
bookmark and resolve it on every launch to keep the folder readable.

Plugin only loads on iOS — detected via the KO_IOS env var the launcher
sets in platform/ios/ios_loader.m.

@module koplugin.iOSFilePicker
--]]--

if os.getenv("KO_IOS") ~= "1" then
    return { disabled = true }
end

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local ffi = require("ffi")
local _ = require("gettext")

ffi.cdef[[
typedef enum {
    KO_PICK_IDLE = 0,
    KO_PICK_PENDING = 1,
    KO_PICK_DONE_OK = 2,
    KO_PICK_DONE_CANCEL = 3,
    KO_PICK_DONE_ERROR = 4,
} ko_pick_state_t;

bool ko_ios_pick_folder_start(void);
ko_pick_state_t ko_ios_pick_folder_poll(char *out_path, size_t path_cap,
                                        char *out_bookmark_b64, size_t bookmark_cap,
                                        char *out_error, size_t error_cap);
bool ko_ios_resolve_bookmark(const char *bookmark_b64,
                             char *out_path, size_t path_cap,
                             char *out_error, size_t error_cap);
]]

-- Symbols are statically linked into the launcher executable, so they
-- live in the main program's symbol table.
local C = ffi.C

local PATH_MAX = 1024
local BOOKMARK_MAX = 16384  -- bookmarks are typically a few hundred bytes
local ERROR_MAX = 512

local IOSFilePicker = WidgetContainer:extend{
    name = "iosfilepicker",
    is_doc_only = false,
}

local function ensure_settings_table()
    local t = G_reader_settings:readSetting("ios_cloud_folders")
    if type(t) ~= "table" then
        t = {}
        G_reader_settings:saveSetting("ios_cloud_folders", t)
    end
    return t
end

-- On launch, re-activate every saved bookmark and refresh the folder
-- shortcut entries to use the freshly-resolved path (provider sandbox
-- containers can be renamed across launches).
function IOSFilePicker:resolveSavedBookmarks()
    local saved = ensure_settings_table()
    local shortcuts = G_reader_settings:readSetting("folder_shortcuts", {})
    local out_path = ffi.new("char[?]", PATH_MAX)
    local out_error = ffi.new("char[?]", ERROR_MAX)
    local refreshed = {}
    for _, entry in ipairs(saved) do
        local ok = C.ko_ios_resolve_bookmark(entry.bookmark, out_path, PATH_MAX, out_error, ERROR_MAX)
        if ok then
            local new_path = ffi.string(out_path)
            if entry.path and entry.path ~= new_path and shortcuts[entry.path] then
                -- Provider container path drifted; move the shortcut.
                shortcuts[entry.path] = nil
            end
            entry.path = new_path
            shortcuts[new_path] = { text = entry.name }
            table.insert(refreshed, entry)
        else
            logger.warn("iosfilepicker: failed to resolve bookmark for", entry.name, "-", ffi.string(out_error))
        end
    end
    G_reader_settings:saveSetting("ios_cloud_folders", refreshed)
    G_reader_settings:saveSetting("folder_shortcuts", shortcuts)
end

function IOSFilePicker:init()
    -- One-shot: rehydrate cloud folders before the file browser renders.
    if not IOSFilePicker._bookmarks_resolved then
        IOSFilePicker._bookmarks_resolved = true
        self:resolveSavedBookmarks()
    end
    self.ui.menu:registerToMainMenu(self)
end

function IOSFilePicker:addToMainMenu(menu_items)
    -- "filemanager_settings" only exists in the FileManager menu tree;
    -- Reader's menu has different sort keys and would crash menusorter.
    -- Cloud folders aren't meaningful inside a doc anyway, so just
    -- skip the registration when we're attached to the reader.
    if not self.ui.file_chooser then return end

    menu_items.ios_add_cloud_folder = {
        text = _("Add cloud folder…"),
        sorting_hint = "filemanager_settings",
        callback = function() self:startPicker() end,
    }
end

-- Polls the C bridge until the picker reports DONE; reschedules itself
-- via UIManager so we never block the runloop. Once we have a result,
-- prompts the user for a display name and persists everything.
function IOSFilePicker:startPicker()
    if not C.ko_ios_pick_folder_start() then
        UIManager:show(InfoMessage:new{ text = _("Picker is already open.") })
        return
    end

    local out_path = ffi.new("char[?]", PATH_MAX)
    local out_bookmark = ffi.new("char[?]", BOOKMARK_MAX)
    local out_error = ffi.new("char[?]", ERROR_MAX)

    local function poll()
        local state = C.ko_ios_pick_folder_poll(out_path, PATH_MAX,
                                                out_bookmark, BOOKMARK_MAX,
                                                out_error, ERROR_MAX)
        if state == C.KO_PICK_PENDING then
            UIManager:scheduleIn(0.25, poll)
            return
        end
        if state == C.KO_PICK_DONE_CANCEL then
            return
        end
        if state == C.KO_PICK_DONE_ERROR then
            UIManager:show(InfoMessage:new{
                text = _("File picker failed: ") .. ffi.string(out_error),
            })
            return
        end
        if state == C.KO_PICK_DONE_OK then
            self:onPicked(ffi.string(out_path), ffi.string(out_bookmark))
            return
        end
    end
    UIManager:scheduleIn(0.25, poll)
end

function IOSFilePicker:onPicked(path, bookmark_b64)
    -- Default name: the folder's basename.
    local default_name = path:match("([^/]+)/?$") or path
    local dialog
    dialog = InputDialog:new{
        title = _("Name for this cloud folder"),
        input = default_name,
        buttons = {{
            {
                text = _("Cancel"),
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    if name == "" then name = default_name end
                    UIManager:close(dialog)
                    self:savePicked(name, path, bookmark_b64)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function IOSFilePicker:savePicked(name, path, bookmark_b64)
    local saved = ensure_settings_table()
    -- De-duplicate by bookmark.
    for i, entry in ipairs(saved) do
        if entry.bookmark == bookmark_b64 then
            table.remove(saved, i)
            break
        end
    end
    table.insert(saved, { name = name, path = path, bookmark = bookmark_b64 })
    G_reader_settings:saveSetting("ios_cloud_folders", saved)

    local shortcuts = G_reader_settings:readSetting("folder_shortcuts", {})
    shortcuts[path] = { text = name }
    G_reader_settings:saveSetting("folder_shortcuts", shortcuts)

    UIManager:show(InfoMessage:new{
        text = string.format(_("Added %s. Open it from File browser → Folder shortcuts."), name),
    })
end

return IOSFilePicker
