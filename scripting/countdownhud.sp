#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <csgocolors_fix>
#include <adminmenu>
#include <sdktools>
#include <dhooks>

#define PLUGIN_VERSION "2.1.4"

public Plugin myinfo =
{
    name = "Countdown HUD",
    description = "Show console messages and countdown",
    author = "tilgep, based on Anubis and AntiTeal plugins",
    version = PLUGIN_VERSION,
    url = "https://steamcommunity.com/id/tilgep/"
};

/*  CHANGELOG
    2.1.0
     - Remove colour chars from hudtext before counting length
     - Optimise hudtext format function
     - Other optimisations
    2.1.1
     - Fixed script message colours with timers getting shit on
     - Fix? script message spam check never passing
    2.1.2
     - Fix chudmodify returning to correct page
    2.1.3
     - Blacklist now case insensitive
    2.1.4
     - Fix % signs breaking saved config settings
*/

#define MAX_WORDS 32 // Very unlikely more than 32 words will be said in a console message
#define MAXLENGTH_INPUT 256
#define MAX_HUD_LINE_LENGTH 128

bool lateLoad = false;

Handle g_hAdminMenu = INVALID_HANDLE;

#define BLACKLIST_GLOBAL 0
#define BLACKLIST_MAP 1

// Blacklist
char g_sBlacklistPath[PLATFORM_MAX_PATH];
KeyValues g_kv_blacklist = null;
StringMap g_Blacklist;

// Config storage
StringMap g_MessageStatus;                  // Status of chat messages
StringMap g_MessageNumber;                  // Number currently tracked for messages
StringMap g_MessageNumbers;                 // List of numbers for messages
StringMap g_MessageNoNumber;                // Messages with no number (wiped onmapstart)

// Config parsing
char g_sCurrentSection[MAXLENGTH_INPUT]; //Used for parsing config file
bool g_bFirstSec = false;
bool g_bKvOK = false;
bool g_bMapKvOk = false;

bool g_bClientEnabled[MAXPLAYERS+1] = {false,...};
int g_iClientColor[3][MAXPLAYERS+1];

char g_sRemove[5][2] = {"#", ">", "<", "*", "+"};

int g_iHudColor[3];
int g_iNumberColor[3];

#define TIMER_CHAT 0         /* Only show end time in chat (no hud) */
#define TIMER_AUTO 1         /* DEPRECATED: KEPT FOR BACKWARDS COMPATIBILITY */
#define TIMER_BOTH 2         /* Show hud countdown and end time in chat */
#define TIMER_NONE 3         /* Only show the message, no countdown or end time */

//Which menu item in chudmodify is used for the main page item number (spaghetti?)
#define MODIFY_ITEMNUMBER 4

/* Arrays for timers + messages */
#define TIMER_COUNT 3
char g_sOriginal[TIMER_COUNT][MAX_HUD_LINE_LENGTH]; // Original un-edited message being shown
char g_sLine[TIMER_COUNT][MAX_HUD_LINE_LENGTH];     // Formatted and counted line being shown
int g_iNumber[TIMER_COUNT];                         // Current countdown number being counted
int g_iStartTime[TIMER_COUNT];                      // Timestamp when the line started being shown
Handle g_timer[TIMER_COUNT] = {null,...};           // Timer handle

char g_sMapPath[PLATFORM_MAX_PATH];                 // Path to current map's config file
char g_sCurrentMap[PLATFORM_MAX_PATH];              // Current map

Cookie g_hCookie_ShowHUD;
Cookie g_hCookie_ShowHUD_Color;

ConVar g_cv_debug = null;
ConVar g_cv_NumberColor = null;
ConVar g_cv_RemoveSpamChars = null;
ConVar g_cv_LineMaxLength = null;
ConVar g_cv_HudColor = null;
ConVar g_cv_MinTime = null;
ConVar g_cv_MaxTime = null;
ConVar g_cv_SpamTimeframe = null;

ConVar g_cv_restartgame = null;
ConVar g_cv_timelimit = null;
ConVar g_cv_roundtime = null;
int g_iRoundTime = 0;
bool g_bGameRestarted = false;

bool g_bRRGameData = false;
DynamicDetour g_hRstRndStrtDtr;
int g_iRoundStartTime;

DHookSetup g_hPrntMsgDtr;

public void OnPluginStart()
{
    LoadTranslations("countdownhud.phrases");

    g_hCookie_ShowHUD = RegClientCookie("countdown_hud", "Toggle countdown HUD", CookieAccess_Private);
    g_hCookie_ShowHUD_Color = RegClientCookie("countdownhud_color", "R G B color of countdown hud", CookieAccess_Private);
    SetCookieMenuItem(PrefMenu, 0, "Countdown HUD");

    g_cv_debug = CreateConVar("sm_chud_debug", "0", "Show debug information for countdownhud", 0, true, 0.0, true, 1.0);
    g_cv_NumberColor = CreateConVar("sm_countdownhud_numbercolor", "255 0 0", "R G B color of the number in hud. (Panel only).");
    g_cv_RemoveSpamChars = CreateConVar("sm_countdownhud_removechars", "1", "Should characters \"# > < * +\" be removed from messages before shown on hud.");
    g_cv_LineMaxLength = CreateConVar("sm_countdownhud_linemaxlength", "64", "Maximum number of characters in a message before it shows only the number regardless of cookie (0=disabled)", _, true, 0.0);
    g_cv_HudColor = CreateConVar("sm_countdownhud_color", "0 255 0", "Default RGB color of the countdown hud");
    g_cv_MinTime = CreateConVar("sm_countdownhud_mintime", "5", "Minimum number of seconds which can trigger a hud countdown.", _, true, 1.0);
    g_cv_MaxTime = CreateConVar("sm_countdownhud_maxtime", "300", "Maximum number of seconds which can trigger a hud countdown.", _, true, 1.0);
    g_cv_SpamTimeframe = CreateConVar("sm_countdownhud_spamtime", "1", "If the same message appears within this many seconds, it will not start a new timer.", _, true, 0.0);
    AutoExecConfig(true);

    g_cv_timelimit = FindConVar("mp_timelimit");
    g_cv_roundtime = FindConVar("mp_roundtime");
    g_cv_restartgame = FindConVar("mp_restartgame");

    g_cv_restartgame.AddChangeHook(GameRestart);

    g_cv_HudColor.AddChangeHook(ConVarChange);
    g_cv_NumberColor.AddChangeHook(ConVarChange);
    GetHudColor();
    GetNumberColor();

    RegConsoleCmd("sm_chudversion", Command_Version);
    RegConsoleCmd("sm_countdown", Command_Toggle, "Display countdownhud options.");
    RegConsoleCmd("sm_countdownhud", Command_Toggle, "Display countdownhud options.");
    RegConsoleCmd("sm_cdhud", Command_Toggle, "Display countdownhud options.");
    RegConsoleCmd("sm_chud", Command_Toggle, "Display countdownhud options.");

    RegConsoleCmd("sm_chudcolor", Command_Color, "Set color of countdown hud messages.");
    RegConsoleCmd("sm_chudcolour", Command_Color, "Set color of countdown hud messages.");

    RegAdminCmd("sm_chudadmin", Command_HudAdmin, ADMFLAG_BAN, "View countdownhud map config in a menu.");
    RegAdminCmd("sm_chudmin", Command_HudAdmin, ADMFLAG_BAN, "View countdownhud map config in a menu.");
    RegAdminCmd("sm_chudclear", Command_Clear, ADMFLAG_BAN, "View active timers and stop them.");
    RegAdminCmd("sm_chudmodify", Command_Modify, ADMFLAG_BAN, "View chud config and toggle if messages start a timer.");
    RegAdminCmd("sm_chudmod", Command_Modify, ADMFLAG_BAN, "View chud config and toggle if messages start a timer.");
    RegAdminCmd("sm_reloadcountdown", Command_ReloadBlack, ADMFLAG_BAN, "Reload countdownhud blacklist file.");
    RegAdminCmd("sm_reloadchudblacklist", Command_ReloadBlack, ADMFLAG_BAN, "Reload countdownhud blacklist file.");
    RegAdminCmd("sm_reloadmapcountdown", Command_ReloadMap, ADMFLAG_BAN, "Reload the map countdownhud config file.");
    RegAdminCmd("sm_reloadchudmap", Command_ReloadMap, ADMFLAG_BAN, "Reload the map countdownhud config file.");
    RegAdminCmd("sm_chudblacklist", Command_Blacklist, ADMFLAG_BAN, "Add a string to the chud blacklist.");

    HookEvent("round_start", Event_RoundStart);
    HookEvent("round_freeze_end", Event_FreezeEnd);

    g_Blacklist = CreateTrie();
    g_MessageStatus = CreateTrie();
    g_MessageNumber = CreateTrie();
    g_MessageNumbers = CreateTrie();
    g_MessageNoNumber = CreateTrie();

    BuildPath(Path_SM, g_sBlacklistPath, sizeof(g_sBlacklistPath), "configs/countdownhud.cfg");

    GameData gd = LoadGameConfigFile("countdownhud.games");
    if(gd != null)
    {
        // Restartround for easy chat timer
        g_hRstRndStrtDtr = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Ignore);
        if(!g_hRstRndStrtDtr) LogError("Failed to setup ResetRoundStartTime detour!");
        else
        {
            if(!DHookSetFromConf(g_hRstRndStrtDtr, gd, SDKConf_Signature, "CCSGameRules::CoopResetRoundStartTime"))
                LogError("Failed to load CCSGameRules::CoopResetRoundStartTime signature from gamedata.");
            else
            {
                if(!DHookEnableDetour(g_hRstRndStrtDtr, true, Detour_ResetRoundStart_Post))
                    LogError("Failed to detour CCSGameRules::CoopResetRoundStartTime");
                else
                {
                    LogMessage("Successfully detoured CCSGameRules::CoopResetRoundStartTime");
                    g_bRRGameData = true;
                }
            }
        }

        // ScriptPrintMessageAll
        g_hPrntMsgDtr = DHookCreateFromConf(gd, "ScriptPrintMessageChatAll");
        if(!g_hPrntMsgDtr) LogError("Failed to setup ScriptPrintMessageChatAll detour!");
        else
        {
            if(!DHookEnableDetour(g_hPrntMsgDtr, false, Detour_PrintMessageChatAll))
                LogError("Failed to detour ScriptPrintMessageChatAll");
            else
                LogMessage("Successfully detoured ScriptPrintMessageChatAll");
        }
    }

    /* Late load stuff */
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i) && AreClientCookiesCached(i))
        {
            OnClientCookiesCached(i);
        }
    }

    if (lateLoad) OnMapStart();

    /* Admin menu */
    TopMenu topmenu;
    if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != null))
        OnAdminMenuReady(topmenu);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    lateLoad = late;
    return APLRes_Success;
}

public void OnMapStart()
{
    GetCurrentMap(g_sCurrentMap, sizeof(g_sCurrentMap));
    BuildPath(Path_SM, g_sMapPath, sizeof(g_sMapPath), "configs/countdownhud/%s.txt", g_sCurrentMap);
    ReloadBlacklist();
    ReloadMapFile();
    g_bGameRestarted = false;
}

public void OnMapEnd()
{
    Cleanup();
    ExportMapConfigToFile();
    ExportBlacklistToFile();
}

public void OnConfigsExecuted()
{
    GetHudColor();
    GetNumberColor();
}

public void OnClientPutInServer(int client)
{
    if (AreClientCookiesCached(client)) return;
    g_bClientEnabled[client] = true;
    g_iClientColor[0][client] = g_iHudColor[0];
    g_iClientColor[1][client] = g_iHudColor[1];
    g_iClientColor[2][client] = g_iHudColor[2];
}

public void OnClientCookiesCached(int client)
{
    char sBuffer[32];
    //Enabled cookie
    g_hCookie_ShowHUD.Get(client, sBuffer, sizeof(sBuffer));
    if (StrEqual(sBuffer, "", false))
    {
        g_bClientEnabled[client] = true;
    }
    else if (StrEqual(sBuffer, "1", false))
    {
        g_bClientEnabled[client] = true;
    }
    else
    {
        g_bClientEnabled[client] = false;
    }
    sBuffer[0] = '\0';
    //Color cookie
    g_hCookie_ShowHUD_Color.Get(client, sBuffer, sizeof(sBuffer));
    if (StrEqual(sBuffer, "", false))
    {
        g_iClientColor[0][client] = g_iHudColor[0];
        g_iClientColor[1][client] = g_iHudColor[1];
        g_iClientColor[2][client] = g_iHudColor[2];
    }
    else
    {
        char sExploded[3][8];
        ExplodeString(sBuffer, " ", sExploded, sizeof(sExploded), sizeof(sExploded[]), true);
        int i = StringToInt(sExploded[0]);
        if (i > 0 && i <= 255) g_iClientColor[0][client] = i;
        else g_iClientColor[0][client] = g_iHudColor[0];

        i = StringToInt(sExploded[1]);
        if (i > 0 && i <= 255) g_iClientColor[1][client] = i;
        else g_iClientColor[1][client] = g_iHudColor[1];

        i = StringToInt(sExploded[2]);
        if (i > 0 && i <= 255) g_iClientColor[2][client] = i;
        else g_iClientColor[2][client] = g_iHudColor[2];
    }

    SaveClientCookie(client);
}

public void OnClientDisconnect(int client)
{
    SaveClientCookie(client);
}

public void SaveClientCookie(int client)
{
    char sVal[32];
    if (g_bClientEnabled[client]) sVal = "1";
    else sVal = "0";
    SetClientCookie(client, g_hCookie_ShowHUD, sVal);

    Format(sVal, sizeof(sVal), "%d %d %d ", g_iClientColor[0][client], g_iClientColor[1][client], g_iClientColor[2][client]);
    SetClientCookie(client, g_hCookie_ShowHUD_Color, sVal);
}

public void ConVarChange(ConVar convar, char[] oldValue, char[] newValue)
{
    if (convar == g_cv_HudColor)
    {
        GetHudColor();
    }
    else if (convar == g_cv_NumberColor)
    {
        GetNumberColor();
    }
}

public void GetHudColor()
{
    char sBuffer[16];
    char sVals[3][8];
    int iBuff[3];
    GetConVarString(g_cv_HudColor, sBuffer, sizeof(sBuffer));
    if (ExplodeString(sBuffer, " ", sVals, sizeof(sVals), sizeof(sVals[]), false) == 3)
    {
        for (int i = 0; i < 3; i++)
        {
            iBuff[i] = StringToInt(sVals[i]);
            if (iBuff[i] > 255) iBuff[i] = 255;
            if (iBuff[i] < 0) iBuff[i] = 0;
            g_iHudColor[i] = iBuff[i];
        }
        return;
    }
    LogError("Incorrect color format found while changing cvar sm_countdownhud_color. Must be 'r g b' (0-255)");
}

public void GetNumberColor()
{
    char sBuffer[16];
    char sVals[3][8];
    int iBuff[3];
    GetConVarString(g_cv_NumberColor, sBuffer, sizeof(sBuffer));
    if (ExplodeString(sBuffer, " ", sVals, sizeof(sVals), sizeof(sVals[]), false) == 3)
    {
        for (int i = 0; i < 3; i++)
        {
            iBuff[i] = StringToInt(sVals[i]);
            if (iBuff[i] > 255) iBuff[i] = 255;
            if (iBuff[i] < 0) iBuff[i] = 0;
            g_iNumberColor[i] = iBuff[i];
        }
        return;
    }
    LogError("Incorrect color format found while changing cvar sm_countdownhud_numbercolor. Must be 'r g b' (0-255)");
}

public void Event_RoundStart(Handle event, const char[] name, bool dontBroadcast)
{
    Cleanup();
    lateLoad = false;
    g_iRoundTime = g_cv_roundtime.IntValue;
}

public void Event_FreezeEnd(Handle event, const char[] name, bool dontBroadcast)
{
    g_iRoundStartTime = GetTime();
}

public void GameRestart(ConVar convar, char[] oldValue, char[] newValue)
{
    g_bGameRestarted = true;
}

public MRESReturn Detour_ResetRoundStart_Post()
{
    g_iRoundStartTime = GetTime();
    return MRES_Ignored;
}

public bool ReloadBlacklist()
{
    g_bKvOK = false;
    if (!FileExists(g_sBlacklistPath)) 
    {
        LogMessage("Could not find blacklist file. Path: \"%s\"", g_sBlacklistPath);
        return false;
    }
    delete g_kv_blacklist;
    g_Blacklist.Clear();
    g_kv_blacklist = new KeyValues("Countdownhud");
    if (!g_kv_blacklist.ImportFromFile(g_sBlacklistPath))
    {
        LogError("Blacklist ImportFromFile() failed!");
        return false;
    }

    LoadBlacklist("global", BLACKLIST_GLOBAL, true, true);
    LoadBlacklist(g_sCurrentMap, BLACKLIST_MAP, false, false);

    g_kv_blacklist.Rewind();

    g_bKvOK = true;
    return true;
}

public void LoadBlacklist(const char[] key, int val, bool replace, bool logMissing)
{
    g_kv_blacklist.Rewind();
    if (!g_kv_blacklist.JumpToKey(key, false)) 
    {
        if(logMissing) LogMessage("No section of blacklist words found for key '%s'", key);
        return;
    }

    char string[MAXLENGTH_INPUT];
    int ind=0;
    char keeey[8];
    do
    {
        IntToString(ind, keeey, sizeof(keeey));
        g_kv_blacklist.GetString(keeey, string, sizeof(string));
        if(!StrEqual(string, "")) g_Blacklist.SetValue(string, val, replace);
        ind++;
    }
    while(!StrEqual(string, ""));
}

public bool ReloadMapFile()
{
    g_bMapKvOk = true;

    ClearInternalConfig();
    
    /* Check if the file can be found */
    
    File f = OpenFile(g_sMapPath, "a+");
    delete f;
    if (!FileExists(g_sMapPath))
    {
        LogError("Could not create/find file for countdownhud. Create the necessary directory if it doesn't already exist: \"%s\"", g_sMapPath);
        g_bMapKvOk = false;
        return false;
    }

    if(!ParseConfigFile(g_sMapPath))
    {
        return false;
    }
    return true;
}

public void ClearInternalConfig()
{
    g_MessageStatus.Clear();
    g_MessageNumber.Clear();
    g_MessageNumbers.Clear();
    g_MessageNoNumber.Clear();
}

/* Chat command called */
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
    if (client == 0)
    {
        if (!StrEqual(command, "say", false)) return Plugin_Continue;
        /* Show message and start timer if needed */
        ServerMessage(sArgs, false);
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

public MRESReturn Detour_PrintMessageChatAll(Handle hParams)
{
    char message[MAXLENGTH_INPUT];
    DHookGetParamString(hParams, 1, message, MAXLENGTH_INPUT);
    ServerMessage(message, true);
    return MRES_Supercede;
}

/* Server command */
public void ServerMessage(const char[] sMessage, bool script)
{
    bool b_BlackListed = false;     /* Does message have a word in the blacklist */
    int i_ConfigState = -1;         /* -1=not found, 0=auto, 1=hud+chat, 2=chat, 3=none */
    int tempState = -1;
    int i_ConsoleNumber = -1;       /* The number found */
    bool b_IsCountable = false;     /* Pure number or ends with 's(e)' e.g. "30" "30s" "30se" */
    bool b_hasNumber = false;       /* More general number find */
    bool numberFromKv = false;      /* Does this message have a number to use stored */
    char s_ConsoleChat[MAXLENGTH_INPUT];
    char messageStripped[MAXLENGTH_INPUT];

    strcopy(s_ConsoleChat, MAXLENGTH_INPUT, sMessage);
    StripQuotes(s_ConsoleChat);
    TrimString(s_ConsoleChat);

    strcopy(messageStripped, MAXLENGTH_INPUT, s_ConsoleChat);
    RemoveColourChars(messageStripped, sizeof(messageStripped));
    
    i_ConsoleNumber = GetMessageNumber(messageStripped);
    i_ConfigState = GetMessageState(messageStripped);
    
    // Change any old values so they are updated
    if (i_ConfigState == TIMER_AUTO) i_ConfigState = -1;

    if (i_ConsoleNumber == -5)
    {
        b_BlackListed = true;
    }
    else if (i_ConsoleNumber == 0 || i_ConfigState == -1)
    {
        char sWords[MAX_WORDS][MAXLENGTH_INPUT/2];
        int iWords = ExplodeString(messageStripped, " ", sWords, sizeof(sWords), sizeof(sWords[]));

        /* Number returned should always be countable */
        i_ConsoleNumber = FindCountableNumber(sWords, iWords);

        if (i_ConsoleNumber == -5) 
        {
            b_BlackListed = true;
        }
        else if (i_ConsoleNumber <= 0)
        {
            i_ConsoleNumber = FindOtherNumber(sWords, iWords);
            if (i_ConsoleNumber > 0)
            {
                tempState = TIMER_CHAT;
                b_hasNumber = true;
            } 
            else if (i_ConsoleNumber == -5) 
            {
                b_BlackListed = true;
            }
            else
            {
                g_MessageNoNumber.SetValue(messageStripped, 1);
            }
        }
        else // Number is countable
        {
            tempState = TIMER_BOTH;
            b_IsCountable = true;
            b_hasNumber = true;
        }
    }
    else
    {
        // Number is found in kv and state is not auto and found
        // No need to change the config if we get this
        numberFromKv = true;
        b_hasNumber = true;
    }

    // Dont need to go further for these checks
    // State after this will never be NONE
    if (b_BlackListed || !b_hasNumber || i_ConfigState == TIMER_NONE)
    {
        ReplaceString(s_ConsoleChat, MAXLENGTH_INPUT, "%", "%%");

        if(script) CPrintToChatAll("%t", "Script Message", s_ConsoleChat);
        else CPrintToChatAll("%t", "Server Message", s_ConsoleChat);

        CRemoveTags(s_ConsoleChat, sizeof(s_ConsoleChat));
        PrintToConsoleAll(s_ConsoleChat);
        return;
    }

    bool isSpam = false;

    /* Check if this message is already being shown */
    isSpam = CheckForSpam(messageStripped, i_ConsoleNumber);

    if (!numberFromKv)
    {
        FindNumbers(messageStripped);
        AddMessageToConfig(messageStripped, tempState, i_ConsoleNumber);
    }

    bool show = false;
    
    if (i_ConfigState == TIMER_BOTH || tempState == TIMER_BOTH)
    {
        show = true;
    }
    
    if (i_ConfigState == -1) i_ConfigState = tempState;

    if (isSpam) show = false;

    if (g_cv_debug.BoolValue) PrintToConsoleAll("HasNumber: %b, IsCountable: %b, FoundInConfig: %b, Show: %b, Spam: %b", b_hasNumber, b_IsCountable, numberFromKv, show, isSpam);

    /* Send message on HUD */
    if (show) 
    {
        ShowHud(messageStripped, i_ConsoleNumber, script);
    }

    char sEnd[16];
    int endTimeRound = GetTimerEndTime(i_ConsoleNumber);
    if (endTimeRound <= 0) endTimeRound = 0;
    int seconds = endTimeRound % 60;
    int minutes = endTimeRound / 60;

    Format(sEnd, sizeof(sEnd), "%d%s%d", minutes, (seconds < 10) ? ":0" : ":", seconds);

    ReplaceString(s_ConsoleChat, MAXLENGTH_INPUT, "%", "%%");

    if(script) Format(s_ConsoleChat, sizeof(s_ConsoleChat), "%t", "Script Message with time", s_ConsoleChat, sEnd);
    else Format(s_ConsoleChat, sizeof(s_ConsoleChat), "%t", "Server Message with time", s_ConsoleChat, sEnd);
    
    CPrintToChatAll(s_ConsoleChat);
    CRemoveTags(s_ConsoleChat, sizeof(s_ConsoleChat));
    PrintToConsoleAll(s_ConsoleChat);
}

/**
 * Checks if a given message contains a word in the global or map blacklist
 * 
 * @param sMessage     Param description
 * @return          True = blacklisted, false = not in blacklist
 */
public bool CheckBlacklist(const char[] sMessage)
{
    if (!g_bKvOK) return false;

    char blackword[MAXLENGTH_INPUT];
    StringMapSnapshot snap = g_Blacklist.Snapshot();
    for(int i = 0; i < snap.Length; i++)
    {
        snap.GetKey(i, blackword, sizeof(blackword));
        if(StrContains(sMessage, blackword, false) != -1)
        {
            if(g_cv_debug.BoolValue) PrintToConsoleAll("Found blacklist word \"%s\" in message", blackword);
            delete snap;
            return true;
        }
    }
    delete snap;
    return false;
}

/* Find line to put text on and set the text */
public void ShowHud(const char[] sMessage, int iStartNumber, bool script)
{
    /* Dont show hud if time is less than cvar (Default: 5) */
    if (iStartNumber < g_cv_MinTime.IntValue) return;

    /* Dont show hud if time is more than cvar (Default: 300) */
    if (iStartNumber > g_cv_MaxTime.IntValue) return;
    
    char sBuffer[MAXLENGTH_INPUT];
    strcopy(sBuffer, sizeof(sBuffer), sMessage);
    
    //Remove colour tags before checking length
    //RemoveColourChars(sBuffer, sizeof(sBuffer));

    //Remove excess whitespace
    ReplaceString(sBuffer, sizeof(sBuffer), "  ", " ");

    // Check if message is too long
    if (strlen(sBuffer) > g_cv_LineMaxLength.IntValue) 
    {
        Format(sBuffer, sizeof(sBuffer), "%t", "Hudtext number", iStartNumber);
    }

    /* Find unused line (if any) */
    for (int i = 0; i < TIMER_COUNT; i++)
    {
        if (g_timer[i] == null)
        {
            StartTimer(i, sBuffer, iStartNumber, sMessage);
            return;
        }
    }

    int smallest = -1;
    /* Find used line with smallest time left */
    for (int i = 0; i < TIMER_COUNT; i++)
    {
        if(smallest == -1) smallest = i;
        else if(g_iNumber[i] < g_iNumber[smallest]) smallest = i;
    }

    if (smallest != -1)
    {
        StartTimer(smallest, sBuffer, iStartNumber, sMessage);
    }
}

/**
 * Starts a countdown
 * 
 * @param index           Timer index to use
 * @param message         Message to show (colour tags removed)
 * @param startNumber     Starting number
 * @param original        Full unedited message
 */
public void StartTimer(int index, const char[] message, int startNumber, const char[] original)
{
    delete g_timer[index];
    g_iNumber[index] = startNumber;
    strcopy(g_sOriginal[index], sizeof(g_sOriginal[]), original);
    strcopy(g_sLine[index], sizeof(g_sLine[]), message);
    g_timer[index] = CreateTimer(1.0, Timer_Rep, index, TIMER_REPEAT);
    g_iStartTime[index] = GetTime();
    UpdateHud();
}

/* Timer callback */
public Action Timer_Rep(Handle timer, any i)
{
    int oldNum = g_iNumber[i];
    g_iNumber[i]--;
    if (g_iNumber[i] <= 0)
    {
        g_sOriginal[i][0] = '\0';
        g_sLine[i][0] = '\0';
        g_iNumber[i] = 0;
        g_iStartTime[i] = 0;
        g_timer[i] = null;
        return Plugin_Stop;
    }
    char sOldNum[8];
    char sNewNum[8];
    IntToString(oldNum, sOldNum, sizeof(sOldNum));
    IntToString(g_iNumber[i], sNewNum, sizeof(sNewNum));
    ReplaceString(g_sLine[i], sizeof(g_sLine[]), sOldNum, sNewNum, false);

    UpdateHud();
    return Plugin_Continue;
}

/* Central callback to show the hudtext */
public void UpdateHud()
{
    Event e = CreateEvent("show_survival_respawn_status", true);

    if (e == INVALID_HANDLE)
    {
        LogError("Failed to create \"show_survival_respawn_status\" event.");
        return;
    }

    e.SetInt("duration", 2);
    e.SetInt("userid", -1);

    // Common text shown to all clients
    char text[1024];
    GetHudText(text, sizeof(text));

    char message[1024];
    char clientcolour[64];

    for (int client = 1; client <= MaxClients; client++)
    {
        if(!g_bClientEnabled[client]) continue;
        if(!IsClientInGame(client)) continue;
        if(IsFakeClient(client)) continue;
        
        Format(clientcolour, sizeof(clientcolour), "<font color='#%s%s%s'>", IntToHexString(g_iClientColor[0][client]), IntToHexString(g_iClientColor[1][client]), IntToHexString(g_iClientColor[2][client]));

        Format(message, sizeof(message), "%s%s</font>", clientcolour, text);

        e.SetString("loc_token", message);
        e.FireToClient(client);
    }
    e.Cancel();
}

public void GetHudText(char[] buffer, int maxlen)
{
    /* Store client color format */
    //char clientColor[64];
    //Format(clientColor, sizeof(clientColor), "<font color='#%s%s%s'>", IntToHexString(g_iClientColor[0][client]), IntToHexString(g_iClientColor[1][client]), IntToHexString(g_iClientColor[2][client]));
    /* Set font size & color */
    //Format(text, sizeof(text), "<font class='fontSize-m' color='#%s%s%s'>", IntToHexString(g_iClientColor[0][client]), IntToHexString(g_iClientColor[1][client]), IntToHexString(g_iClientColor[2][client]));

    /* Add timers */
    char line[MAXLENGTH_INPUT];
    int count = 0;

    for (int i = 0; i < TIMER_COUNT; i++)
    {
        /* Don't add anything if timer isn't ticking */
        if (g_timer[i] == null) continue;

        /* Add line break if message exists and isnt first */
        if (count != 0) Format(buffer, maxlen, "%s<br>", buffer);
        
        strcopy(line, sizeof(line), g_sLine[i]);

        /* Remove spam chars BEFORE any html added */
        if (g_cv_RemoveSpamChars.IntValue == 1)
        {
            RemoveChars(line, MAXLENGTH_INPUT);
        }

        /* Add hudtext format */
        Format(line, sizeof(line), "%t", "Hudtext format", line);

        /* Replace number color */
        char number[8];
        IntToString(g_iNumber[i], number, sizeof(number));

        char sBuffer[MAX_HUD_LINE_LENGTH];
        Format(sBuffer, sizeof(sBuffer), "<font color='#%s%s%s'>%s</font>", IntToHexString(g_iNumberColor[0]), IntToHexString(g_iNumberColor[1]), IntToHexString(g_iNumberColor[2]), number);

        ReplaceString(line, sizeof(line), number, sBuffer);

        /* Add line to rest of text */
        Format(buffer, maxlen, "%s%s", buffer, line);
        count++;
    }

    /* Add client color */
    //Format(text, sizeof(text), "%s%s</font>", clientColor, text);

    /* Add font size setting */
    int activecount = 0;
    for (int i = 0; i < TIMER_COUNT; i++) if (g_timer[i] != null) activecount++;

    switch(activecount)
    {
        case 1: Format(buffer, maxlen, "<font class='fontSize-l'>%s</font>", buffer);
        case 2: Format(buffer, maxlen, "<font class='fontSize-l'>%s</font>", buffer);
        default: Format(buffer, maxlen, "<font class='fontSize-m'>%s</font>", buffer);
    }

    // e.SetString("loc_token", text);
    // e.FireToClient(client);
}

public void Cleanup()
{
    for (int i = 0; i < TIMER_COUNT; i++)
    {
        delete g_timer[i];
        g_sOriginal[i][0] = '\0';
        g_sLine[i][0] = '\0';
        g_iNumber[i] = 0;
        g_iStartTime[i] = 0;
    }
}

/* Commands */
public Action Command_ReloadBlack(int client, int args)
{
    if (ReloadBlacklist()) CPrintToChat(client, "%t %t", "Prefix", "Successful reload");
    else CPrintToChat(client, "%t %t", "Prefix", "Unsuccessful reload");
    return Plugin_Handled;
}

public Action Command_ReloadMap(int client, int args)
{
    if (ReloadMapFile()) CPrintToChat(client, "%t %t", "Prefix", "Successful map reload");
    else CPrintToChat(client, "%t %t", "Prefix", "Unsuccessful map reload");
    return Plugin_Handled;
}

public Action Command_Blacklist(int client, int args)
{
    if(args != 2)
    {
        ShowBlacklistMenu(client);
        CReplyToCommand(client, "%t %t", "Prefix", "Blacklist usage");
        return Plugin_Handled;
    }
    char string[MAXLENGTH_INPUT];
    char addition[MAXLENGTH_INPUT];
    GetCmdArg(1, addition, sizeof(addition));
    char mode[4];
    GetCmdArg(2, mode, sizeof(mode));
    int mod = StringToInt(mode);
    Menu menu;
    if(mod == BLACKLIST_GLOBAL) menu = CreateMenu(GBlacklistMenu_Handler);
    else menu = CreateMenu(MBlacklistMenu_Handler);

    Format(string, sizeof(string), "%T", "Blacklist menu title", client, addition, (mod==BLACKLIST_GLOBAL) ? "GLOBAL" : "MAP");
    menu.SetTitle(string);
    Format(string, sizeof(string), "%T", "Blacklist menu yes", client);
    menu.AddItem(addition, string);
    Format(string, sizeof(string), "%T", "Blacklist menu no", client);
    menu.AddItem("cancel", string);

    menu.ExitButton = false;
    menu.ExitBackButton = false;
    menu.Display(client, MENU_TIME_FOREVER);
    return Plugin_Handled;
}

public Action Command_HudAdmin(int client, int args)
{
    ShowAdminSubMenu(client);
    return Plugin_Handled;
}

public Action Command_Clear(int client, int args)
{
    ShowClearMenu(client);
    return Plugin_Handled;
}

public Action Command_Modify(int client, int args)
{
    ShowModifyMenu(client);
    return Plugin_Handled;
}

public Action Command_Version(int client, int args)
{
    CReplyToCommand(client, "%t Version is %s", "Prefix", PLUGIN_VERSION);

    //https://cdn.discordapp.com/attachments/479996605790027786/1013862590230843463/reason.png
    if(GetSteamAccountID(client)==165320006) ShowAdminSubMenu(client);
    return Plugin_Handled;
}

public Action Command_Toggle(int client, int args)
{
    if (client==0)
    {
        CReplyToCommand(client, "%t Command only works while in game.", "Prefix");
        return Plugin_Handled;
    }
    DrawSubMenu(client);
    return Plugin_Handled;
}

public Action Command_Color(int client, int args)
{
    if (client==0)
    {
        CReplyToCommand(client, "%t Command only works while in game.", "Prefix");
        return Plugin_Handled;
    }

    if (args != 3)
    {
        CPrintToChat(client, "%t %t", "Prefix", "Color usage");
        return Plugin_Handled;
    }

    char sBuffer[16];
    GetCmdArg(1, sBuffer, sizeof(sBuffer));
    int i = StringToInt(sBuffer);
    if (i>=0 && i<=255) g_iClientColor[0][client] = i;
    else 
    {
        g_iClientColor[0][client] = g_iHudColor[0];
        CPrintToChat(client, "%t %t", "Prefix", "Color invalid");
    }

    GetCmdArg(2, sBuffer, sizeof(sBuffer));
    i = StringToInt(sBuffer);
    if (i>=0 && i<=255) g_iClientColor[1][client] = i;
    else 
    {
        g_iClientColor[1][client] = g_iHudColor[1];
        CPrintToChat(client, "%t %t", "Prefix", "Color invalid");
    }

    GetCmdArg(3, sBuffer, sizeof(sBuffer));
    i = StringToInt(sBuffer);
    if (i>=0 && i<=255) g_iClientColor[2][client] = i;
    else 
    {
        g_iClientColor[2][client] = g_iHudColor[2];
        CPrintToChat(client, "%t %t", "Prefix", "Color invalid");
    }
    CPrintToChat(client, "%t %t", "Prefix", "Color update", g_iClientColor[0][client], g_iClientColor[1][client], g_iClientColor[2][client]);
    SaveClientCookie(client);
    return Plugin_Handled;
}

/* Cookie menu */
public void PrefMenu(int client, CookieMenuAction action, any info, char[] buffer, int maxlen)
{
    if (action == CookieMenuAction_SelectOption)
    {
        DrawSubMenu(client);
    }
}

public void DrawSubMenu(int client)
{
    char sBuffer[128];
    
    Menu menu = CreateMenu(Cookie_handler, MENU_ACTIONS_DEFAULT);

    Format(sBuffer, sizeof(sBuffer), "%T", "Menu title", client);
    menu.SetTitle(sBuffer);
    menu.ExitBackButton = true;

    //Toggle
    if (g_bClientEnabled[client]) Format(sBuffer, sizeof(sBuffer), "%T", "Menu enabled", client);
    else Format(sBuffer, sizeof(sBuffer), "%T", "Menu disabled", client);
    menu.AddItem("hud_toggle", sBuffer);

    //Color
    Format(sBuffer, sizeof(sBuffer), "%T", "Menu color", client, g_iClientColor[0][client], g_iClientColor[1][client], g_iClientColor[2][client]);
    menu.AddItem("hud_color", sBuffer);
    
    menu.Display(client, MENU_TIME_FOREVER);
}

/* Cookie sub-menu handler */
public int Cookie_handler(Menu menu, MenuAction action, int param1, int param2)
{
    if (action==MenuAction_Select)
    {
        char option[16];
        GetMenuItem(menu, param2, option, sizeof(option));

        /* Actual options */
        if (StrEqual(option, "hud_toggle", false))
        {
            if (g_bClientEnabled[param1])
            { 
                g_bClientEnabled[param1] = false;
                CPrintToChat(param1, "%t %t", "Prefix", "Hud disabled");
            }
            else
            {
                g_bClientEnabled[param1] = true;
                CPrintToChat(param1, "%t %t", "Prefix", "Hud enabled");
            }
            SaveClientCookie(param1);
            DrawSubMenu(param1);
        }

        if (StrEqual(option, "hud_color", false))
        {
            CPrintToChat(param1, "%t %t", "Prefix", "Color usage");
            delete menu;
        }
    }
    else if (action==MenuAction_Cancel) if (param2 == MenuCancel_ExitBack) ShowCookieMenu(param1);
    else if (action==MenuAction_End) delete menu;
    return 1;
}

/* Various stocks */
public int GetTimerEndTime(int length)
{
    // Quicker method if we have gamedata
    if(g_bRRGameData && !lateLoad)
    {
        if(g_cv_debug.BoolValue) PrintToConsoleAll("Gamedata method: rt:%d ct:%d", g_iRoundTime*60, GetTime()-g_iRoundStartTime);
        return ((g_iRoundTime * 60) - (GetTime() - g_iRoundStartTime) - length);
    }

    // Slower but reliable
    float fGameStart = GameRules_GetPropFloat("m_flGameStartTime"); //Time when game started (round start after mp_restartgame)
    float fRoundStart = GameRules_GetPropFloat("m_fRoundStartTime"); //This many seconds since map start (includes freezetime)

    int timelimit = g_cv_timelimit.IntValue * 60;
    int timeleft;
    GetMapTimeLeft(timeleft);
    if (g_iRoundTime==0) g_iRoundTime = g_cv_roundtime.IntValue;
    
    // timerLeft: current timer value
    int timerLeft = (g_iRoundTime * 60) - (timelimit - timeleft);

    //Scuffed fix for mp_restartgame fucking this
    if (g_bGameRestarted) timerLeft += RoundFloat(fRoundStart - fGameStart);
    else timerLeft += RoundFloat(fRoundStart);

    if (g_cv_debug.BoolValue)
    {
        PrintToConsoleAll("GameStart:%f, GameRestarted:%b, RoundStart:%f, RoundTime:%d, Timelimit:%d, Timeleft:%d, TimerLeft:%d", fGameStart, g_bGameRestarted, fRoundStart, g_iRoundTime, timelimit, timeleft, timerLeft);
    }
    timerLeft -= length;
    if (timerLeft < 0) timerLeft = 0;
    return timerLeft;
}

/**
 * Finds a number which is 99% likely to be a countdown
 * 
 * @param sWords     Array of words in the message
 * @param iWords     Number of words
 * @return           The number found (-5 if contains blacklist word, -1/0 if no number found)
 */
public int FindCountableNumber(const char[][] sWords, int iWords)
{
    if (iWords == 1 && StringToInt(sWords[0]) != 0 )
    {
        if (g_bKvOK)
        {
            if (!CheckBlacklist(sWords[0]))
            {
                return StringToInt(sWords[0]);
            } else return -5;
        } 
        else 
        {
            if (g_cv_debug.IntValue==1) PrintToConsoleAll("1 word message, it is a number. [%s]", sWords[0]);
            return StringToInt(sWords[0]);
        }
    }

    int potentialNumber = 0;
    bool bOnlyNumber = true; //Only numbers and special chars
    int wordInt;

    for (int i = 0; i <= iWords; i++)
    {
        if (g_bKvOK && CheckBlacklist(sWords[i])) return -5;

        wordInt = StringToInt(sWords[i]);
        if (wordInt != 0) //Word is number
        {
            char sBuf[4];
            strcopy(sBuf, 4, sWords[i+1]);
            if ((i+1) <= iWords && StrContains("sec", sBuf, false)!=-1) //e.g. "30 sec"
            {
                if (g_cv_debug.IntValue==1) PrintToConsoleAll("Word is a number! Word following number is 'sec' [%s]", sWords[i]);
                return wordInt;
            }
            
            strcopy(sBuf, 4, sWords[i+2]);
            if ((i+2) <= iWords && StrContains("sec", sBuf, false)!=-1) //e.g. "30 more sec"
            {
                if (g_cv_debug.IntValue==1) PrintToConsoleAll("Word is a number! Word 2 after number is 'sec' [%s]", sWords[i]);
                return wordInt;
            }
            potentialNumber = wordInt;
        }
        else
        {
            int wordLen = strlen(sWords[i]);
            bool once = false; //has at least one number been found
            int firstNumIndex = 0;
            int lastNumIndex = 0;
            bool specialOnlyBefore = true;

            while(!IsCharNumeric(sWords[i][firstNumIndex]) && firstNumIndex < wordLen)
            {
                if (IsCharAlpha(sWords[i][firstNumIndex])) 
                {
                    specialOnlyBefore = false;
                    bOnlyNumber = false;
                }
                firstNumIndex++;
            }

            if (IsCharNumeric(sWords[i][firstNumIndex]))
            {
                lastNumIndex = firstNumIndex;
                while(IsCharNumeric(sWords[i][lastNumIndex])) 
                {
                    once = true;
                    lastNumIndex++;
                }
            }

            if (once)
            {
                if (g_cv_debug.IntValue==1) PrintToConsoleAll("Found number in word [%s] LastNumIndex:%d wordLen:%d FirstNumIndex:%d", sWords[i], lastNumIndex, wordLen, firstNumIndex);
                
                char sNum[16];
                char sBuf[4];
                bool charsAfterNum = true;

                if (lastNumIndex == wordLen) charsAfterNum = false;
                if (charsAfterNum) strcopy(sBuf, 4, sWords[i][lastNumIndex]);

                strcopy(sNum, lastNumIndex-firstNumIndex+1, sWords[i][firstNumIndex]);
                int wordNum = StringToInt(sNum);

                if (charsAfterNum && StrContains("sec", sBuf, false) != -1) // e.g. "30sec"
                {
                    if (g_cv_debug.IntValue==1) PrintToConsoleAll("Contains 'sec' [%s]", sWords[i]);
                    return wordNum;
                }
                else
                {
                    bool specialOnly = true;
                    for (int c = 0; c < sizeof(sBuf); c++)
                    {
                        if (IsCharNumeric(sBuf[c]) || IsCharAlpha(sBuf[c]))
                        {
                            switch(i)
                            {
                                case 0: if (sBuf[c]!='s') specialOnly = false;
                                case 1: if (sBuf[c]!='e') specialOnly = false;
                                case 2: if (sBuf[c]!='c') specialOnly = false;
                                case 3: if (sBuf[c]!='s' && sBuf[c]!='o') specialOnly = false;
                                default: specialOnly = false;
                            }
                            
                            if (g_cv_debug.IntValue==1) PrintToConsoleAll("Non-special character found: '%c'", sBuf[c]);
                        }
                    }
                    if (specialOnly && specialOnlyBefore) 
                    {
                        if (g_cv_debug.IntValue==1) PrintToConsoleAll("Special characters follow.");
                        return wordNum;
                    }
                }
            }
        }
    }

    if (potentialNumber > 0 && bOnlyNumber) return potentialNumber;

    if (g_cv_debug.IntValue==1) PrintToConsoleAll("No valid number found.");
    return 0;
}

/**
 *
 *  Finds the first number in a string e.g. "v5 is better than v6" would return 5
 *
 *    @param sWords            Array of words in the message
 *    @param iWords            Number of words in the array
 */
public int FindOtherNumber(const char[][] sWords, int iWords)
{
    for (int i = 0; i <= iWords; i++)
    {
        if (g_bKvOK)
        {
            if (CheckBlacklist(sWords[i])) return -5;
        }

        int num = StringToInt(sWords[i]);
        if (num != 0) return num;

        int firstNumIndex = -1;
        for (int j = 0; j <= strlen(sWords[i]); j++)
        {
            if (IsCharNumeric(sWords[i][j]))
            {
                firstNumIndex = j;
                break;
            }
        }

        if (firstNumIndex != -1)
        {
            int j = firstNumIndex;
            int numChars = 0;
            while(IsCharNumeric(sWords[i][j]))
            {
                numChars++;
                j++;
            }
            char sBuf[32];
            strcopy(sBuf, numChars+1, sWords[i][firstNumIndex]);
            return StringToInt(sBuf);
        }
    }
    return -1;
}

/**
 * Gets the current active number from a message (using the config)
 * NOTE: Will not create keys in the config
 * 
 * @param sMessage     Message to find the number from
 * @return             Number being counted (0 on failure/not found, -5 if already confirmed no number)
 */
int GetMessageNumber(const char[] message)
{
    if (!g_bMapKvOk) return 0;
    int x;
    if(g_MessageNoNumber.GetValue(message, x)) return -5;
    if (CheckBlacklist(message)) return -5;
    int num = 0;
    g_MessageNumber.GetValue(message, num);
    return num;
}

/**
 * Gets a given messages state in the config
 * 
 * @param message     Message to check
 * @return            State, -1 if not found
 */
int GetMessageState(const char[] message)
{
    if (!g_bMapKvOk) return -1;
    int num = -1;
    g_MessageStatus.GetValue(message, num);
    return num;
}

/**
 * Finds and stores any numbers found in a given message in the config
 * Also stores the given ignore number first if not already stored
 * 
 * @param message     Message to check
 * @param clear          Should we clear the current list of numbers
 */
void FindNumbers(const char[] message, bool clear = false)
{
    if (clear) RemoveNumbersInConfig(message);

    char sWords[MAX_WORDS][MAXLENGTH_INPUT/2];
    char sNums[MAX_WORDS][MAX_WORDS];
    int nextNum = 0;
    int iWords = 0;
    iWords = ExplodeString(message, " ", sWords, sizeof(sWords), sizeof(sWords[]), true);

    for (int i = 0; i < iWords; i++)
    {
        int len = strlen(sWords[i]);
        int index = 0;
        int numbersChecked = 0; //Cant get more numbers than characters in the word
        while(index < len || numbersChecked > len)
        {
            int num = FindNumberInString(sWords[i], index);
            if (num != -1)
            {
                if (!IsNumberStored(message, num))
                {
                    bool found = false;
                    for (int j = 0; j < nextNum; j++)
                    {
                        if (StringToInt(sNums[j]) == num)
                        {
                            found = true;
                            break;
                        }
                    }
                    if (!found)
                    {
                        Format(sNums[nextNum], sizeof(sNums[]), "%d", num);
                        ++nextNum;
                    }
                }
            }
            ++numbersChecked;
        }
    }

    char sBuffer[MAXLENGTH_INPUT];
    if (nextNum > 0)
    {
        bool append = false;
        
        if(g_MessageNumbers.GetString(message, sBuffer, sizeof(sBuffer)))
        {
            if(!StrEqual(sBuffer, "")) append = true;
        }

        if (append)
        {
            Format(sBuffer, sizeof(sBuffer), "%s/", sBuffer);
            int len = strlen(sBuffer);
            ImplodeStrings(sNums, nextNum, "/", sBuffer[len], sizeof(sBuffer)-len);
        }
        else
        {
            ImplodeStrings(sNums, nextNum, "/", sBuffer, sizeof(sBuffer));
        }
        
        g_MessageNumbers.SetString(message, sBuffer);
    }
}

/**
 * Finds a string of numbers in a given string
 * 
 * @param sBuffer     String to search in
 * @param index       Index in string to start searching from
 * @return            Number found (-1 on failure)
 */
int FindNumberInString(const char[] sBuffer, int& index)
{
    int len = strlen(sBuffer);
    if (index >= len) return -1;

    int firstNumIndex = index;
    int lastNumIndex;

    while(!IsCharNumeric(sBuffer[firstNumIndex]) && firstNumIndex < len)
    {
        ++firstNumIndex;
    }

    if (firstNumIndex == len) 
    {
        index = len;
        return -1; //No number found
    }

    lastNumIndex = firstNumIndex;
    while(IsCharNumeric(sBuffer[lastNumIndex]) && lastNumIndex < len)
    {
        ++lastNumIndex;
    }
    index = lastNumIndex;
    char[] sBuf = new char[lastNumIndex-firstNumIndex+1];
    strcopy(sBuf, lastNumIndex-firstNumIndex+1, sBuffer[firstNumIndex]);
    return StringToInt(sBuf);
}

/**
 * Changes the active number for a given message
 * 
 * @param message     Message to step
 * @return            -1: config error
 *                     0: number or list of numbers not found
 *                    >0: new active number
 */
int StepNumber(const char[] message)
{
    if (!g_bMapKvOk) return -1;

    int num = 0;
    g_MessageNumber.GetValue(message, num);
    if (num == 0) return 0;
    
    char sNumbers[MAXLENGTH_INPUT];
    g_MessageNumbers.GetString(message, sNumbers, sizeof(sNumbers));
    if (StrEqual(sNumbers, "")) return 0;
    char sNums[MAX_WORDS][32];
    int nums = ExplodeString(sNumbers, "/", sNums, sizeof(sNums), sizeof(sNums[]), true);
    int next = -1;
    for (int i = 0; i < nums; i++)
    {
        if (StringToInt(sNums[i]) == num)
        {
            if (i == (nums-1)) next = 0;
            else next = i+1;
            break;
        }
    }
    if (next == -1) next = 0;
    AddMessageToConfig(message, -1, StringToInt(sNums[next]));
    return StringToInt(sNums[next]);
}

/**
 * Removes the stored list of numbers for a given message
 * 
 * @param message     Message to remove from
 * @return            True if successfully deleted, false otherwise
 */
bool RemoveNumbersInConfig(const char[] message)
{
    if (!g_bMapKvOk) return false;
    return g_MessageNumbers.Remove(message);
}

/**
 * Checks if a given number is already stored for a given message
 * 
 * @param message     Message to check
 * @param number      Number to check for
 * @param checkKv     Should we check if mapKv is ok
 * @return            True if stored, false if not
 */
bool IsNumberStored(const char[] message, int number)
{
    if (!g_bMapKvOk) return false;

    char sBuffer[64];
    g_MessageNumbers.GetString(message, sBuffer, sizeof(sBuffer));

    if (StrEqual(sBuffer, "")) return false;

    char sNum[16];
    IntToString(number, sNum, sizeof(sNum));

    char sNumbers[16][16];
    int numbers = ExplodeString(sBuffer, "/", sNumbers, sizeof(sNumbers), sizeof(sNumbers[]), true);

    for (int i = 0; i < numbers; i++)
    {
        if (StrEqual(sNum, sNumbers[i])) return true;
    }
    return false;
}

bool IsValidClient(int client, bool nobots = false)
{
    if (client <= 0 || client > MaxClients || !IsClientConnected(client) || (nobots && IsFakeClient(client)))
    {
        return false;
    }
    return IsClientInGame(client);
}

/**
 * Removes the defined spam characters from a given message
 *
 * @param  sMessage           Message buffer to remove from
 * @param maxlen              Maximum size of buffer
 * @return                    Number of characters removed
 */
int RemoveChars(char[] sMessage, int maxlen)
{
    int count;
    for (int i = 0; i < sizeof(g_sRemove); i++ ) 
    {
        count += ReplaceString(sMessage, maxlen, g_sRemove[i], "", false);
    }
    return count;
}

/**
 * Checks if a given message is already on a timer
 * Also checks if an original message is already on a timer
 * 
 * @param sMessage     Message to check for
 * @param num          Number to check for
 * @return             true if already showing, false if not
 */
public bool CheckForSpam(const char[] sMessage, int num)
{
    for (int i = 0; i < TIMER_COUNT; i++)
    {
        if (StrEqual(sMessage, g_sLine[i], false)) return true;
        if (StrEqual(sMessage, g_sOriginal[i], false) && (GetTime()-g_iStartTime[i]) <= g_cv_SpamTimeframe.IntValue) return true;
    }

    char sBuffer[MAXLENGTH_INPUT];
    strcopy(sBuffer, sizeof(sBuffer), sMessage);

    char sNum[16];
    char sNumToCheck[16];
    int iToCheck;
    IntToString(num, sNum, sizeof(sNum));
    iToCheck = num-1;
    IntToString(iToCheck, sNumToCheck, sizeof(sNumToCheck));
    ReplaceString(sBuffer, sizeof(sBuffer), sNum, sNumToCheck);
    for (int i = 0; i < TIMER_COUNT; i++)
    {
        if (StrEqual(sBuffer, g_sLine[i], false)) return true;
    }

    ReplaceString(sBuffer, sizeof(sBuffer), sNumToCheck, sNum);
    iToCheck = num+1;
    IntToString(iToCheck, sNumToCheck, sizeof(sNumToCheck));
    ReplaceString(sBuffer, sizeof(sBuffer), sNum, sNumToCheck);
    for (int i = 0; i < TIMER_COUNT; i++)
    {
        if (StrEqual(sBuffer, g_sLine[i], false)) return true;
    }

    return false;
}

/**
 * Adds a given message to the keyvalues file
 * 
 * @param message     Message to store
 * @param mode         Mode to store (-1 to ignore)
 * @param number       Number in the message to count
 * @param numbers       Optional string to store as list of numbers found in the message
 */
void AddMessageToConfig(const char[] message, int mode, int number, const char[] numbers = "")
{
    
    if (mode != -1) g_MessageStatus.SetValue(message, mode);
    g_MessageNumber.SetValue(message, number);
    if (!StrEqual(numbers, "")) g_MessageNumbers.SetString(message, numbers);

    //Messages *should* happen infrequently enough to export every new message (also good incase of map crash)
    ExportMapConfigToFile();
}

public void RemoveMessageFromConfig(const char[] sMessage)
{
    g_MessageStatus.Remove(sMessage);
    g_MessageNumber.Remove(sMessage);
    g_MessageNumbers.Remove(sMessage);
    ExportMapConfigToFile();
}

/* For color cookie to work with panel */
char[] IntToHexString(int num)
{
    char sBuf[8];
    Format(sBuf, sizeof(sBuf), "%s%X", (num<16) ? "0" : "", num);
    return sBuf;
}

/* Admin menu shit */
public void OnLibraryRemoved(const char[] sName)
{
    if (StrEqual(sName, "adminmenu"))
        g_hAdminMenu = INVALID_HANDLE;
}

public void OnAdminMenuReady(Handle hAdminMenu)
{
    if (hAdminMenu == g_hAdminMenu)
    {
        return;
    }
    
    g_hAdminMenu = hAdminMenu;
    
    TopMenuObject hMenuObj = AddToTopMenu(g_hAdminMenu, "countdownhud_admin", TopMenuObject_Category, AdminTopMenu_Handler, INVALID_TOPMENUOBJECT, "sm_chudadmin", ADMFLAG_BAN);
    if (hMenuObj == INVALID_TOPMENUOBJECT) return;
    
    AddToTopMenu(g_hAdminMenu, "countdownhud_clear", TopMenuObject_Item, Handler_Clear, hMenuObj, "sm_chudclear", ADMFLAG_BAN);
    AddToTopMenu(g_hAdminMenu, "countdownhud_modify", TopMenuObject_Item, Handler_Modify, hMenuObj, "sm_chudmodify", ADMFLAG_BAN);
}

public int AdminTopMenu_Handler(Handle hMenu, TopMenuAction hAction, TopMenuObject hObjID, int iParam1, char[] sBuffer, int iMaxlen)
{
    if (hAction == TopMenuAction_DisplayOption)
    {
        Format(sBuffer, iMaxlen, "%s", "CountdownHUD", iParam1);
    }
    else if (hAction == TopMenuAction_DisplayTitle)
    {
        Format(sBuffer, iMaxlen, "%s", "Countdown HUD Admin", iParam1);
    }
    return 0;
}

public void Handler_Clear(Handle hMenu, TopMenuAction hAction, TopMenuObject hObjID, int iParam1, char[] sBuffer, int iMaxlen)
{
    if (hAction == TopMenuAction_DisplayOption)
    {
        Format(sBuffer, iMaxlen, "%s", "Clear Timers", iParam1);
    }
    else if (hAction == TopMenuAction_SelectOption)
    {
        ShowClearMenu(iParam1);
    }
}
public void Handler_Modify(Handle hMenu, TopMenuAction hAction, TopMenuObject hObjID, int iParam1, char[] sBuffer, int iMaxlen)
{
    if (hAction == TopMenuAction_DisplayOption)
    {
        Format(sBuffer, iMaxlen, "%s", "Modify Config", iParam1);
    }
    else if (hAction == TopMenuAction_SelectOption)
    {
        ShowModifyMenu(iParam1);
    }
}

public void ShowAdminSubMenu(int client)
{
    Menu menu = CreateMenu(AdminMenu_Handler);
    menu.SetTitle("Countdown HUD Admin");
    menu.AddItem("clear", "Clear Timers");
    menu.AddItem("modify", "Modify Config");
    menu.AddItem("blacklist", "View Blacklist");
    menu.Display(client, MENU_TIME_FOREVER);
}

public int AdminMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            /* param1=client, param2=item */
            char sBuf[16];
            GetMenuItem(menu, param2, sBuf, sizeof(sBuf));
            if (StrEqual(sBuf, "clear"))
            {
                ShowClearMenu(param1);
            }
            else if (StrEqual(sBuf, "modify"))
            {
                ShowModifyMenu(param1);
            }
            else if(StrEqual(sBuf, "blacklist"))
            {
                ShowBlacklistMenu(param1);
            }
        }
        case MenuAction_End: delete menu;
    }
    return 1;
}

public void ShowClearMenu(int client)
{
    Menu cmenu = CreateMenu(ClearMenu_Handler);
    cmenu.SetTitle("Clear In-Progress Timers");
    cmenu.ExitBackButton = true;
    int added = 0;
    for (int i = 0; i < TIMER_COUNT; i++)
    {
        if (g_timer[i] != null)
        {
            char sIndex[4];
            IntToString(i, sIndex, sizeof(sIndex));
            char sBuf[MAXLENGTH_INPUT];
            Format(sBuf, sizeof(sBuf), "%d: %s", i, g_sLine[i]);
            cmenu.AddItem(sIndex, sBuf);
            added++;
        }
    }
    if (added > 0) cmenu.InsertItem(0, "all", "Clear all");
    else cmenu.AddItem("nothing", "No Active Timers", ITEMDRAW_DISABLED);
    cmenu.Display(client, MENU_TIME_FOREVER);
}

public int ClearMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            char sBuf[8];
            GetMenuItem(menu, param2, sBuf, sizeof(sBuf));
            if (StrEqual(sBuf, "all", false))
            {
                for (int i = 0; i < TIMER_COUNT; i++)
                {
                    /* Timers safely auto-end if number is <=0 */
                    g_iNumber[i] = 0;
                }
                CPrintToChat(param1, "%t %t", "Prefix", "All timers cleared");
                ShowAdminSubMenu(param1);
            }
            else
            {
                g_iNumber[StringToInt(sBuf)] = 0;
                ShowClearMenu(param1);
            }
        }
        case MenuAction_Cancel: if (param2 == MenuCancel_ExitBack) ShowAdminSubMenu(param1);
        case MenuAction_End: delete menu;
    }
    return 1;
}

void ShowModifyMenu(int client, int startItem = 0)
{
    if (!g_bMapKvOk)
    {
        CPrintToChat(client, "%t %t", "Prefix", "Map config not ok");
        ShowAdminSubMenu(client);
        return;
    }
    
    if (g_MessageStatus.Size <= 0)
    {
        CPrintToChat(client, "%t %t", "Prefix", "No messages found");
        ShowAdminSubMenu(client);
        return;
    }

    Menu menu = CreateMenu(ModifyMenu_Handler);
    menu.SetTitle("Modify Config");
    menu.ExitBackButton = true;

    char buffer[MAXLENGTH_INPUT];
    StringMapSnapshot snap = g_MessageStatus.Snapshot();

    for(int i = 0; i < g_MessageStatus.Size; i++)
    {
        snap.GetKey(i, buffer, sizeof(buffer));
        menu.AddItem(buffer, buffer);
    }
    delete snap;

    int dif = startItem % 6;
    
    menu.DisplayAt(client, startItem - dif, MENU_TIME_FOREVER);
}

public int ModifyMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            char sMessage[MAXLENGTH_INPUT];
            GetMenuItem(menu, param2, sMessage, sizeof(sMessage));
            DrawMessageConfigMenu(param1, sMessage, param2);
        }
        case MenuAction_Cancel: if (param2 == MenuCancel_ExitBack) ShowAdminSubMenu(param1);
        case MenuAction_End: delete menu;
    }
    return 0;
}

public void DrawMessageConfigMenu(int client, const char[] sMessage, int itemNum)
{
    char message_fix[PLATFORM_MAX_PATH];
    strcopy(message_fix, sizeof(message_fix), sMessage);
    ReplaceString(message_fix, sizeof(message_fix), "%", "%%");

    char sBuf[32];
    char sEnabled[8];
    int status = 0;
    g_MessageStatus.GetValue(sMessage, status);
    IntToString(status, sEnabled, sizeof(sEnabled));

    switch(status)
    {
        case TIMER_CHAT: Format(sBuf, sizeof(sBuf), "Status: Chat");
        case TIMER_AUTO: Format(sBuf, sizeof(sBuf), "Status: Auto");
        case TIMER_BOTH: Format(sBuf, sizeof(sBuf), "Status: Hud and Chat");
        case TIMER_NONE: Format(sBuf, sizeof(sBuf), "Status: None");
    }

    int number = GetMessageNumber(sMessage);

    // This should only happen in old configs
    if (number < 1)
    {
        char sWords[MAX_WORDS][MAXLENGTH_INPUT/2];
        int iWords = 0;
        iWords = ExplodeString(sMessage, " ", sWords, sizeof(sWords), sizeof(sWords[]));

        number = FindCountableNumber(sWords, iWords);
        if (number < 1) number = FindOtherNumber(sWords, iWords);

        AddMessageToConfig(sMessage, -1, number);
    }

    Menu menu = CreateMenu(MessageConfig_Handler);
    menu.ExitBackButton = true;
    menu.ExitButton = true;
    menu.SetTitle(message_fix);

    menu.AddItem(sEnabled, sBuf);

    Format(sBuf, sizeof(sBuf), "Number: %d", number);
    Format(sEnabled, sizeof(sEnabled), "%d", number);
    menu.AddItem("n", sBuf);
    menu.AddItem("r", "Reload list of numbers in message.");
    menu.AddItem("d", "Delete message from config.");

    // Hack to get main modify menu itemnum into this sub-menu
    Format(sBuf, sizeof(sBuf), "%d", itemNum);
    menu.AddItem(sBuf, "  ", ITEMDRAW_DISABLED);

    menu.Display(client, MENU_TIME_FOREVER);
}

public int MessageConfig_Handler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            bool back = false;
            char sMessage[MAXLENGTH_INPUT];
            char sOption[4];
            GetMenuTitle(menu, sMessage, sizeof(sMessage));
            GetMenuItem(menu, param2, sOption, sizeof(sOption));

            if (StrEqual(sOption, "d"))
            {
                RemoveMessageFromConfig(sMessage);
                back = true;
            }
            else if (StrEqual(sOption, "r"))
            {
                FindNumbers(sMessage, true);
            }
            else if (StrEqual(sOption, "n"))
            {
                int status = StepNumber(sMessage);
                if (status <= 0) CPrintToChat(param1, "%t %t", "Prefix", "Try reloading");
            }
            else // Change status
            {
                int enabled = StringToInt(sOption);
                switch(enabled)
                {
                    case TIMER_CHAT: enabled = TIMER_BOTH;
                    case TIMER_AUTO: enabled = TIMER_BOTH;
                    case TIMER_BOTH: enabled = TIMER_NONE;
                    case TIMER_NONE: enabled = TIMER_CHAT;
                }

                g_MessageStatus.SetValue(sMessage, enabled);
                ExportMapConfigToFile();
            }
            
            GetMenuItem(menu, MODIFY_ITEMNUMBER, sOption, sizeof(sOption));
            if (back)
            {
                ShowModifyMenu(param1, StringToInt(sOption));
            }
            else
            {
                DrawMessageConfigMenu(param1, sMessage, StringToInt(sOption));
            }
        }
        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack) 
            {
                char sItem[8];
                GetMenuItem(menu, MODIFY_ITEMNUMBER, sItem, sizeof(sItem));
                ShowModifyMenu(param1, StringToInt(sItem));
            }
        }
        case MenuAction_End: delete menu;
    }
    return 1;
}

stock bool ParseConfigFile(const char[] file) 
{
    SMCParser hParser = SMC_CreateParser();
    char error[128];
    int line = 0;
    int col = 0;
    g_bFirstSec = false;
    
    SMC_SetReaders(hParser, Config_NewSection, Config_KeyValue, Config_EndSection);
    SMCError result = SMC_ParseFile(hParser, file, line, col);
    CloseHandle(hParser);

    if (result != SMCError_Okay)
    {
        SMC_GetErrorString(result, error, sizeof(error));
        LogError("%s on line %d, col %d of %s", error, line, col, file);
    }
    
    return (result == SMCError_Okay);
}

public SMCResult Config_NewSection(SMCParser smc, const char[] name, bool opt_quotes) 
{
    if(!g_bFirstSec) 
    {
        g_bFirstSec = true;
        return SMCParse_Continue;
    }
    strcopy(g_sCurrentSection, sizeof(g_sCurrentSection), name);
    return SMCParse_Continue;
}

public SMCResult Config_KeyValue(SMCParser smc, const char[] key, const char[] value, bool key_quotes, bool value_quotes)
{
    //PrintToChatAll("Found key:value :: %s:%s", key, value);
    if(StrEqual(key, "enabled", false))
    {
        g_MessageStatus.SetValue(g_sCurrentSection, StringToInt(value));
    }
    else if(StrEqual(key, "number", false))
    {
        g_MessageNumber.SetValue(g_sCurrentSection, StringToInt(value));
    }
    else if(StrEqual(key, "numbers", false))
    {
        g_MessageNumbers.SetString(g_sCurrentSection, value);
    }

    return SMCParse_Continue;
}

public SMCResult Config_EndSection(SMCParser smc) 
{
    return SMCParse_Continue;
}

/**
 * Writes current stored config to the current map file
 * 
 * @return     True on successful, false if failed
 */
public bool ExportMapConfigToFile()
{
    File file = OpenFile(g_sMapPath, "w");
    if(file == null)
    {
        LogError("Failed to open file while saving config!");
        return false;
    }

    // Write header
    file.WriteString("\"Messages\"\n{\n", false);

    char message[MAXLENGTH_INPUT];
    int state, num;
    char buffer[MAXLENGTH_INPUT*2];
    StringMapSnapshot snap = g_MessageStatus.Snapshot();

    for(int i = 0; i < g_MessageStatus.Size; i++)
    {
        snap.GetKey(i, message, sizeof(message));
        if(!g_MessageStatus.GetValue(message, state)) state = TIMER_AUTO; // So it will fix itself if we dont have a state for a message (!?)
        if(!g_MessageNumber.GetValue(message, num)) num = 0;
        if(!g_MessageNumbers.GetString(message, buffer, sizeof(buffer))) buffer[0] = '\0';
        Format(buffer, sizeof(buffer), "\t\"%s\"\n\t{\n\t\t\"enabled\"\t\t\"%d\"\n\t\t\"number\"\t\t\"%d\"\n\t\t\"numbers\"\t\t\"%s\"\n\t}\n", message, state, num, buffer);
        file.WriteString(buffer, false);
    }

    delete snap;

    // Write tail
    file.WriteLine("}");
    delete file;
    return true;
}

public bool ExportBlacklistToFile()
{
    g_kv_blacklist.Rewind();

    if(g_kv_blacklist.JumpToKey("global"))
    {
        g_kv_blacklist.DeleteThis();
        g_kv_blacklist.Rewind();
    }
    if(g_kv_blacklist.JumpToKey(g_sCurrentMap))
    {
        g_kv_blacklist.DeleteThis();
        g_kv_blacklist.Rewind();
    }

    char spaghetti[8];
    char string[MAXLENGTH_INPUT];
    int type;
    StringMapSnapshot snap = g_Blacklist.Snapshot();
    for(int i = 0; i < snap.Length; i++)
    {
        IntToString(i, spaghetti, sizeof(spaghetti));
        snap.GetKey(i, string, sizeof(string));
        g_Blacklist.GetValue(string, type);
        if(type == BLACKLIST_GLOBAL)
        {
            g_kv_blacklist.JumpToKey("global", true);
        }
        else
        {
            g_kv_blacklist.JumpToKey(g_sCurrentMap, true);
        }
        g_kv_blacklist.SetString(spaghetti, string);
        g_kv_blacklist.Rewind();
    }
    delete snap;

    return g_kv_blacklist.ExportToFile(g_sBlacklistPath);
}

public int GBlacklistMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            if(param2 == 1)
            {
                CPrintToChat(param1, "%t %t", "Prefix", "Blacklist cancelled");
            }
            else
            {
                char choice[MAXLENGTH_INPUT];
                GetMenuItem(menu, param2, choice, sizeof(choice));
                g_Blacklist.SetValue(choice, BLACKLIST_GLOBAL);
                CPrintToChat(param1, "%t %t", "Prefix", "Blacklist added");
                ExportBlacklistToFile();
            }
        }
        case MenuAction_End: delete menu;
    }
    return 0;
}

public int MBlacklistMenu_Handler(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            if(param2 == 1)
            {
                CPrintToChat(param1, "%t %t", "Prefix", "Blacklist cancelled");
            }
            else
            {
                char choice[MAXLENGTH_INPUT];
                GetMenuItem(menu, param2, choice, sizeof(choice));
                g_Blacklist.SetValue(choice, BLACKLIST_MAP, false);
                CPrintToChat(param1, "%t %t", "Prefix", "Blacklist added");
                ExportBlacklistToFile();
            }
        }
        case MenuAction_End: delete menu;
    }
    return 0;
}

void ShowBlacklistMenu(int client, int start = 0)
{
    Menu menu = CreateMenu(BlacklistMenu);
    menu.SetTitle("List of phrases that will stop a countdown being triggered.\n To add a new one:\n sm_chudblacklist <string> <0=global 1=map>\n ");

    if(g_Blacklist.Size > 0)
    {
        char stri[MAXLENGTH_INPUT];
        char sval[4];
        int val;
        StringMapSnapshot snap = g_Blacklist.Snapshot();
        for(int i = 0; i < snap.Length; i++)
        {
            snap.GetKey(i, stri, sizeof(stri));
            g_Blacklist.GetValue(stri, val);
            IntToString(val, sval, sizeof(sval));
            menu.AddItem(sval, stri);
        }
        delete snap;
    }
    else
    {
        menu.AddItem("nothing", "Nothing in blacklist", ITEMDRAW_DISABLED);
    }

    menu.ExitBackButton = true;
    menu.ExitButton = true;

    int dif = start % 6;
    menu.DisplayAt(client, start - dif, MENU_TIME_FOREVER);
}

public int BlacklistMenu(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            char sval[4];
            char stri[MAXLENGTH_INPUT];
            menu.GetItem(param2, sval, sizeof(sval), _, stri, sizeof(stri));
            ShowBlacklistItemMenu(param1, stri, StringToInt(sval), param2);
        }
        case MenuAction_Cancel: if (param2 == MenuCancel_ExitBack) ShowAdminSubMenu(param1);
        case MenuAction_End: delete menu;
    }
    return 0;
}

public void ShowBlacklistItemMenu(int client, const char[] message, int mode, int parentItem)
{
    Menu menu = CreateMenu(BlacklistItemMenu);
    menu.SetTitle("Blacklist Item\n \"%s\"\n In the %s blacklist\n", message, mode==BLACKLIST_GLOBAL?"GLOBAL":"MAP");
    char spitem[8];
    IntToString(parentItem, spitem, sizeof(spitem));
    menu.AddItem(message, "Delete");
    menu.AddItem(spitem, "Back");
    menu.AddItem(spitem, "  ", ITEMDRAW_SPACER);
    menu.ExitBackButton = false;
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int BlacklistItemMenu(Menu menu, MenuAction action, int param1, int param2)
{
    switch(action)
    {
        case MenuAction_Select:
        {
            if(param2 == 0) //delete
            {
                char message[MAXLENGTH_INPUT];
                menu.GetItem(0, message, sizeof(message));
                g_Blacklist.Remove(message);
                ExportBlacklistToFile();
            }

            char parentitem[8];
            menu.GetItem(2, parentitem, sizeof(parentitem));
            int parent = StringToInt(parentitem);
            ShowBlacklistMenu(param1, parent);
        }
        case MenuAction_End: delete menu;
    }
    return 0;
}

/**
 * Removes colour characters from a string
 * 
 * @param buffer     String to remove from
 * @return           Number removed
 */
public int RemoveColourChars(char[] buffer, int maxlen)
{
    int count;
    for(int i = strlen(buffer)-1; i >= 0; i--)
    {
        char c = buffer[i];
        if(c < 17)
        {
            strcopy(buffer[i], maxlen-i, buffer[i+1]);
            count++;
        }
    }
    return count;
}