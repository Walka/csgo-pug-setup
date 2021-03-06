#include <cstrike>
#include <sdkhooks>
#include <sdktools>
#include <sourcemod>
#include "include/logdebug.inc"
#include "include/pugsetup.inc"
#include "pugsetup/generic.sp"

#pragma semicolon 1
#pragma newdecls required

bool g_InPracticeMode = false;

#define OPTION_NAME_LENGTH 128 // length of a setting name
#define CVAR_NAME_LENGTH 64 // length of a cvar

// These data structures maintain a list of settings for a toggle-able option:
// the name, the cvar/value for the enabled option, and the cvar/value for the disabled option.
// Note: the first set of values for these data structures is the overall-practice mode cvars,
// which aren't toggle-able or named.
ArrayList g_BinaryOptionIds;
ArrayList g_BinaryOptionNames;
ArrayList g_BinaryOptionEnabled;
ArrayList g_BinaryOptionChangeable;
ArrayList g_BinaryOptionEnabledCvars;
ArrayList g_BinaryOptionEnabledValues;
ArrayList g_BinaryOptionDisabledCvars;
ArrayList g_BinaryOptionDisabledValues;

// Infinite money data
ConVar g_InfiniteMoneyCvar;
bool g_InfiniteMoney = false;

// Grenade trajectory fix data
int g_BeamSprite = -1;
int g_ClientColors[MAXPLAYERS+1][4];
ConVar g_GrenadeTrajectoryClientColorCvar;
bool g_GrenadeTrajectoryClientColor = true;

Handle g_GrenadeTrajectoryCvar = INVALID_HANDLE;
Handle g_GrenadeThicknessCvar = INVALID_HANDLE;
Handle g_GrenadeTimeCvar = INVALID_HANDLE;
Handle g_GrenadeSpecTimeCvar = INVALID_HANDLE;
bool g_GrenadeTrajectory = false;
float g_GrenadeThickness = 0.2;
float g_GrenadeTime = 20.0;
float g_GrenadeSpecTime = 4.0;

// These must match the values used by cl_color.
enum ClientColor {
    ClientColor_Yellow = 0,
    ClientColor_Purple = 1,
    ClientColor_Green = 2,
    ClientColor_Blue = 3,
    ClientColor_Orange = 4,
};

public Plugin myinfo = {
    name = "CS:GO PugSetup: practice mode",
    author = "splewis",
    description = "A relatively simple practice mode that can be launched through the setup menu",
    version = PLUGIN_VERSION,
    url = "https://github.com/splewis/csgo-pug-setup"
};

public void OnPluginStart() {
    InitDebugLog(DEBUG_CVAR, "practice");
    LoadTranslations("pugsetup.phrases");
    g_InPracticeMode = false;
    AddChatAlias(".noclip", "noclip");
    AddChatAlias(".god", "god");
    AddCommandListener(Command_TeamJoin, "jointeam");
    g_InfiniteMoneyCvar = CreateConVar("sm_infinite_money", "0", "Whether clients recieve infinite money");
    HookConVarChange(g_InfiniteMoneyCvar, OnCvarChanged);

    // Init data structures to be read from the config file
    g_BinaryOptionIds = new ArrayList(OPTION_NAME_LENGTH);
    g_BinaryOptionNames = new ArrayList(OPTION_NAME_LENGTH);
    g_BinaryOptionEnabled = new ArrayList();
    g_BinaryOptionChangeable = new ArrayList();
    g_BinaryOptionEnabledCvars = new ArrayList();
    g_BinaryOptionEnabledValues = new ArrayList();
    g_BinaryOptionDisabledCvars = new ArrayList();
    g_BinaryOptionDisabledValues = new ArrayList();
    ReadPracticeSettings();

    // Init grenade settings
    g_GrenadeTrajectoryClientColorCvar = CreateConVar("sm_grenade_trajectory_use_player_color", "1", "Whether to use client colors when drawing grenade trajectories");
    HookConVarChange(g_GrenadeTrajectoryClientColorCvar, OnCvarChanged);

    g_GrenadeTrajectoryCvar = GetCvar("sv_grenade_trajectory");
    g_GrenadeThicknessCvar = GetCvar("sv_grenade_trajectory_thickness");
    g_GrenadeTimeCvar = GetCvar("sv_grenade_trajectory_time");
    g_GrenadeSpecTimeCvar = GetCvar("sv_grenade_trajectory_time_spectator");

    // set default colors to green
    for (int i = 0; i <= MAXPLAYERS; i++) {
        g_ClientColors[0][0] = 0;
        g_ClientColors[0][1] = 255;
        g_ClientColors[0][2] = 0;
        g_ClientColors[0][3] = 255;
    }
}

public Handle GetCvar(const char[] name) {
    Handle cvar = FindConVar(name);
    if (cvar == INVALID_HANDLE) {
        SetFailState("Failed to find cvar: \"%s\"", name);
    }
    HookConVarChange(cvar, OnCvarChanged);
    return cvar;
}

public int OnCvarChanged(Handle cvar, const char[] oldValue, const char[] newValue) {
    if (cvar == g_GrenadeTrajectoryCvar) {
        g_GrenadeTrajectory = !StrEqual(newValue, "0");
    } else if (cvar == g_GrenadeThicknessCvar) {
        g_GrenadeThickness = StringToFloat(newValue);
    } else if (cvar == g_GrenadeTimeCvar) {
        g_GrenadeTime = StringToFloat(newValue);
    } else if (cvar == g_GrenadeSpecTimeCvar) {
        g_GrenadeSpecTime = StringToFloat(newValue);
    } else if (cvar == g_InfiniteMoneyCvar) {
        g_InfiniteMoney = !StrEqual(newValue, "0");
        if (g_InfiniteMoney) {
            CreateTimer(1.0, Timer_GivePlayersMoney, _, TIMER_REPEAT);
        }
    } else if (cvar == g_GrenadeTrajectoryClientColorCvar) {
        g_GrenadeTrajectoryClientColor = !StrEqual(newValue, "0");
    }
}

public void OnMapStart() {
    ReadPracticeSettings();
    g_BeamSprite = PrecacheModel("materials/sprites/laserbeam.vmt");
}

public void OnMapEnd() {
    if (g_InPracticeMode)
        DisablePracticeMode();
}

public void OnClientPutInServer(int client) {
    UpdatePlayerColor(client);
}

public Action Command_TeamJoin(int client, const char[] command, int argc) {
    if (!IsValidClient(client) || argc < 1)
        return Plugin_Handled;

    if (g_InPracticeMode) {
        char arg[4];
        GetCmdArg(1, arg, sizeof(arg));
        int team = StringToInt(arg);
        ChangeClientTeam(client, team);
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

public void ReadPracticeSettings() {
    ClearArray(g_BinaryOptionNames);
    ClearArray(g_BinaryOptionEnabled);
    ClearArray(g_BinaryOptionChangeable);
    ClearNestedArray(g_BinaryOptionEnabledCvars);
    ClearNestedArray(g_BinaryOptionEnabledValues);
    ClearNestedArray(g_BinaryOptionDisabledCvars);
    ClearNestedArray(g_BinaryOptionDisabledValues);

    char filePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, filePath, sizeof(filePath), "configs/pugsetup/practicemode.cfg");

    KeyValues kv = new KeyValues("practice_settings");
    if (!kv.ImportFromFile(filePath)) {
        LogError("Failed to import keyvalue from practice config file \"%s\"", filePath);
        delete kv;
        return;
    }

    // Read in the binary options
    if (kv.JumpToKey("binary_options")) {
        if (kv.GotoFirstSubKey()) {
            // read each option
            do {
                char id[128];
                kv.GetSectionName(id, sizeof(id));

                char name[OPTION_NAME_LENGTH];
                kv.GetString("name", name, sizeof(name));

                char enabledString[64];
                kv.GetString("default", enabledString, sizeof(enabledString), "enabled");
                bool enabled = StrEqual(enabledString, "enabled", false);

                bool changeable = (kv.GetNum("changeable", 1) != 0);

                char cvarName[CVAR_NAME_LENGTH];
                char cvarValue[CVAR_NAME_LENGTH];

                // read the enabled cvar list
                ArrayList enabledCvars = new ArrayList(CVAR_NAME_LENGTH);
                ArrayList enabledValues = new ArrayList(CVAR_NAME_LENGTH);
                if (kv.JumpToKey("enabled")) {
                    if (kv.GotoFirstSubKey(false)) {
                        do {
                            kv.GetSectionName(cvarName, sizeof(cvarName));
                            enabledCvars.PushString(cvarName);
                            kv.GetString(NULL_STRING, cvarValue, sizeof(cvarValue));
                            enabledValues.PushString(cvarValue);
                        } while (kv.GotoNextKey(false));
                        kv.GoBack();
                    }
                    kv.GoBack();
                }

                // read the disabled cvar list
                ArrayList disabledCvars = new ArrayList(CVAR_NAME_LENGTH);
                ArrayList disabledValues = new ArrayList(CVAR_NAME_LENGTH);
                if (kv.JumpToKey("disabled")) {
                    if (kv.GotoFirstSubKey(false)) {
                        do {
                            kv.GetSectionName(cvarName, sizeof(cvarName));
                            disabledCvars.PushString(cvarName);
                            kv.GetString(NULL_STRING, cvarValue, sizeof(cvarValue));
                            disabledValues.PushString(cvarValue);
                        } while (kv.GotoNextKey(false));
                        kv.GoBack();
                    }
                    kv.GoBack();
                }

                g_BinaryOptionIds.PushString(id);
                g_BinaryOptionNames.PushString(name);
                g_BinaryOptionEnabled.Push(enabled);
                g_BinaryOptionChangeable.Push(changeable);
                g_BinaryOptionEnabledCvars.Push(enabledCvars);
                g_BinaryOptionEnabledValues.Push(enabledValues);
                g_BinaryOptionDisabledCvars.Push(disabledCvars);
                g_BinaryOptionDisabledValues.Push(disabledValues);


            } while (kv.GotoNextKey());
        }
    }
    kv.Rewind();

    delete kv;
}

public bool OnSetupMenuOpen(int client, Menu menu, bool displayOnly) {
    int leader = GetLeader();
    if (!IsPlayer(leader)) {
        SetLeader(client);
    }

    int style = ITEMDRAW_DEFAULT;
    if (!HasPermissions(client, Permission_Leader) || displayOnly) {
        style = ITEMDRAW_DISABLED;
    }

    if (g_InPracticeMode) {
        GivePracticeMenu(client, style);
        return false;
    } else {
        AddMenuItem(menu, "launch_practice", "Launch practice mode", style);
        return true;
    }
}

public void OnReadyToStart() {
    if (g_InPracticeMode)
        DisablePracticeMode();
}

public void OnSetupMenuSelect(Menu menu, MenuAction action, int param1, int param2) {
    int client = param1;
    char buffer[64];
    menu.GetItem(param2, buffer, sizeof(buffer));
    if (StrEqual(buffer, "launch_practice")) {
        g_InPracticeMode = !g_InPracticeMode;
        if (g_InPracticeMode) {
            // TODO: I'm not sure if it's possible to force
            // set cheat-protected cvars without this,
            // it'd be nice if it was so this isn't needed.
            SetCvar("sv_cheats", 1);

            for (int i = 0; i < g_BinaryOptionNames.Length; i++) {
                bool enabled = view_as<bool>(g_BinaryOptionEnabled.Get(i));
                ChangeSetting(i, enabled, false);
            }

            ServerCommand("exec sourcemod/pugsetup/practice_start.cfg");
            GivePracticeMenu(client, ITEMDRAW_DEFAULT);
            PugSetupMessageToAll("Practice mode is now enabled");
        } else {
            ServerCommand("exec sourcemod/pugsetup/practice_end.cfg");
        }
    }
}

static void ChangeSetting(int index, bool enabled, bool print=true) {
    ArrayList cvars = (enabled) ? g_BinaryOptionEnabledCvars.Get(index) : g_BinaryOptionDisabledCvars.Get(index);
    ArrayList values = (enabled) ? g_BinaryOptionEnabledValues.Get(index) : g_BinaryOptionDisabledValues.Get(index);

    char cvar[CVAR_NAME_LENGTH];
    char value[CVAR_NAME_LENGTH];

    for (int i = 0; i < cvars.Length; i++) {
        cvars.GetString(i, cvar, sizeof(cvar));
        values.GetString(i, value, sizeof(value));
        ServerCommand("%s %s", cvar, value);
    }

    char id[OPTION_NAME_LENGTH];
    char name[OPTION_NAME_LENGTH];
    g_BinaryOptionIds.GetString(index, id, sizeof(id));
    g_BinaryOptionNames.GetString(index, name, sizeof(name));

    if (print) {
        char enabledString[32];
        GetEnabledString(enabledString, sizeof(enabledString), enabled);

        // don't display empty names
        if (!StrEqual(name, ""))
            PugSetupMessageToAll("%s is now %s", name, enabledString);
    }
}

static void GivePracticeMenu(int client, int style, int pos=-1) {
    Menu menu = new Menu(PracticeMenuHandler);
    SetMenuTitle(menu, "Practice Settings");
    SetMenuExitButton(menu, true);

    AddMenuItem(menu, "end_menu", "Exit practice mode", style);

    for (int i = 0; i < g_BinaryOptionNames.Length; i++) {
        if (!g_BinaryOptionChangeable.Get(i))
            continue;

        char name[OPTION_NAME_LENGTH];
        g_BinaryOptionNames.GetString(i, name, sizeof(name));

        char enabled[32];
        GetEnabledString(enabled, sizeof(enabled), g_BinaryOptionEnabled.Get(i), client);

        char buffer[128];
        Format(buffer, sizeof(buffer), "%s: %s", name, enabled);
        AddMenuItem(menu, name, buffer, style);
    }

    if (pos == -1)
        DisplayMenu(menu, client, MENU_TIME_FOREVER);
    else
        DisplayMenuAtItem(menu, client, pos, MENU_TIME_FOREVER);
}

public int PracticeMenuHandler(Menu menu, MenuAction action, int param1, int param2) {
    if (action == MenuAction_Select) {
        int client = param1;
        char buffer[OPTION_NAME_LENGTH];
        int pos = GetMenuSelectionPosition();
        menu.GetItem(param2, buffer, sizeof(buffer));

        for (int i = 0; i < g_BinaryOptionNames.Length; i++) {
            char name[OPTION_NAME_LENGTH];
            g_BinaryOptionNames.GetString(i, name, sizeof(name));
            if (StrEqual(name, buffer)) {
                bool setting = !g_BinaryOptionEnabled.Get(i);
                g_BinaryOptionEnabled.Set(i, setting);
                ChangeSetting(i, setting);
                GivePracticeMenu(client, ITEMDRAW_DEFAULT, pos);
                return 0;
            }
        }

        if (StrEqual(buffer, "end_menu")) {
            DisablePracticeMode();
            GiveSetupMenu(client);
        }

    } else if (action == MenuAction_End) {
        CloseHandle(menu);
    }

    return 0;
}

public void DisablePracticeMode() {
    for (int i = 0; i < g_BinaryOptionNames.Length; i++) {
        ChangeSetting(i, false, false);
    }

    SetCvar("sv_cheats", 0);
    g_InPracticeMode = false;

    // force turn noclip off for everyone
    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i))
            SetEntityMoveType(i, MOVETYPE_WALK);
    }

    PugSetupMessageToAll("Practice mode is now disabled.");
}

public void SetCvar(const char[] name, int value) {
    Handle cvar = FindConVar(name);
    if (cvar == INVALID_HANDLE) {
        LogError("cvar \"%s\" could not be found", name);
    } else {
        SetConVarInt(cvar, value);
    }
}

public Action Timer_GivePlayersMoney(Handle timer) {
    if (!g_InfiniteMoney) {
        return Plugin_Handled;
    }

    for (int i = 1; i <= MaxClients; i++) {
        if (IsValidClient(i) && !IsFakeClient(i)) {
            SetEntProp(i, Prop_Send, "m_iAccount", 16000);
        }
    }

    return Plugin_Continue;
}

public bool IsGrenadeProjectile(const char[] className) {
    char grenadeTypes[][] = {
        "hegrenade_projectile",
        "smokegrenade_projectile",
        "decoy_projectile",
        "flashbang_projectile",
        "molotov_projectile",
    };

    for (int i = 0; i < sizeof(grenadeTypes); i++) {
        if (StrEqual(className, grenadeTypes[i], false)) {
            return true;
        }
    }

    return false;
}

public int OnEntityCreated(int entity, const char[] className) {
    if (!g_GrenadeTrajectory || !IsValidEntity(entity) || !IsGrenadeProjectile(className))
        return;

    SDKHook(entity, SDKHook_SpawnPost, OnEntitySpawned);
}

public int OnEntitySpawned(int entity) {
    if (!g_GrenadeTrajectory || !IsValidEdict(entity))
        return;

    char className[64];
    GetEdictClassname(entity, className, sizeof(className));

    if (!IsGrenadeProjectile(className))
        return;

    // update client color
    int client = 0; // will use the default color (green)
    if (g_GrenadeTrajectoryClientColor) {
        int owner = GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity");
        if (IsPlayer(owner)) {
            client = owner;
            UpdatePlayerColor(client);
        }
    }

    if (IsValidEntity(entity)) {
        for (int i = 1; i <= MaxClients; i++) {
            if (!IsClientConnected(i) || !IsClientInGame(i))
                continue;

            // Note: the technique using temporary entities is taken from InternetBully's NadeTails plugin
            // which you can find at https://forums.alliedmods.net/showthread.php?t=240668
            float time = (GetClientTeam(i) == CS_TEAM_SPECTATOR) ? g_GrenadeSpecTime : g_GrenadeTime;
            TE_SetupBeamFollow(entity, g_BeamSprite, 0, time, g_GrenadeThickness * 5, g_GrenadeThickness * 5, 1, g_ClientColors[client]);
            TE_SendToClient(i);
        }
    }
}

public void UpdatePlayerColor(int client) {
    QueryClientConVar(client, "cl_color", QueryClientColor, client);
}

public void QueryClientColor(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue) {
    int color = StringToInt(cvarValue);
    LogDebug("Got client=%L cl_color=%d", client, color);
    GetColor(view_as<ClientColor>(color), g_ClientColors[client]);
}

public void GetColor(ClientColor c, int array[4]) {
    int r, g, b;
    switch(c) {
        case ClientColor_Green:  { r = 0;   g = 255; b = 0; }
        case ClientColor_Purple: { r = 128; g = 0;   b = 128; }
        case ClientColor_Blue:   { r = 0;   g = 0;   b = 255; }
        case ClientColor_Orange: { r = 255; g = 128; b = 0; }
        case ClientColor_Yellow: { r = 255; g = 255; b = 0; }
    }
    array[0] = r;
    array[1] = g;
    array[2] = b;
    array[3] = 255;
}
