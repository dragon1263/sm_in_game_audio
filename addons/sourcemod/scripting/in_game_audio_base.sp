/**
 * vim: set ts=4 :
 * =============================================================================
 * in_game_audio_base
 * Handles http calls to the In Game Audio website to query and play songs to
 * users through the MOTD popup panel.
 *
 * Copyright 2013 CrimsonTautology
 * =============================================================================
 *
 */

#pragma semicolon 1

#include <sourcemod>
#include <routes>
#include <clientprefs>
#include <steamworks>
#include <smjansson>
#include <morecolors>

#define PLUGIN_VERSION "1.8.9"
#define PLUGIN_NAME "In Game Audio Base"

#define DEBUG true

public Plugin:myinfo =
{
    name = PLUGIN_NAME,
    author = "CrimsonTautology",
    description = "Interact with the In Game Audio web api",
    version = PLUGIN_VERSION,
    url = "https://github.com/CrimsonTautology/sm_in_game_audio"
};

#define MAX_COMMUNITYID_LENGTH 18 

new Handle:g_Cvar_IGAApiKey = INVALID_HANDLE;
new Handle:g_Cvar_IGAUrl = INVALID_HANDLE;
new Handle:g_Cvar_IGAEnabled = INVALID_HANDLE;
new Handle:g_Cvar_IGARequestCooldownTime = INVALID_HANDLE;

new Handle:g_Cookie_PallEnabled = INVALID_HANDLE;
new Handle:g_Cookie_Volume = INVALID_HANDLE;

new Handle:g_MenuItems = INVALID_HANDLE;
new g_MenuId;

new bool:g_IsInCooldown[MAXPLAYERS+1] = {false, ...};
new bool:g_IsPallEnabled[MAXPLAYERS+1] = {false, ...};
new g_IsHtmlMotdDisabled[MAXPLAYERS+1] = {-1, ...}; //Trinary logic: -1 = Unknown, 0 = Enabled, 1 = Disabled

new String:g_CurrentPallDescription[64];
new String:g_CurrentPallPath[64];
new g_CurrentPlastSongId = 0;
new String:g_CachedURLArgs[MAXPLAYERS+1][256];

new g_PNextFree[MAXPLAYERS+1] = {0, ...};
new g_PallNextFree = 0;
new g_Volume[MAXPLAYERS+1] = {8, ...};

functag IGA_MenuCallback IGAMenu:public(client);
native IGA_RegisterMenuItem(const String:name[], IGA_MenuCallback:func);
native IGA_UnregisterMenuItem(item);

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
    if (LibraryExists("in_game_audio"))
    {
        strcopy(error, err_max, "InGameAudio already loaded, aborting.");
        return APLRes_Failure;
    }

    RegPluginLibrary("in_game_audio"); 

    CreateNative("ClientHasPallEnabled", _ClientHasPallEnabled);
    CreateNative("ClientHasHtmlMotdDisabled", _ClientHasHtmlMotdDisabled);
    CreateNative("SetPallEnabled", _SetPallEnabled);
    CreateNative("IsInP", _IsInP);
    CreateNative("IsInPall", _IsInPall);
    CreateNative("PlaySong", _PlaySong);
    CreateNative("PlaySongAll", _PlaySongAll);
    CreateNative("StopSong", _StopSong);
    CreateNative("StopSongAll", _StopSongAll);
    CreateNative("RegisterPall", _RegisterPall);
    CreateNative("QuerySong", _QuerySong);
    CreateNative("MapTheme", _MapTheme);
    CreateNative("UserTheme", _UserTheme);
    CreateNative("CreateIGAPopup", _CreateIGAPopup);
    CreateNative("CreateIGARequest", _CreateIGARequest);
    CreateNative("StartCoolDown", _StartCoolDown);
    CreateNative("IsClientInCooldown", _IsClientInCooldown);
    CreateNative("IsIGAEnabled", _IsIGAEnabled);

    CreateNative("IGA_RegisterMenuItem", _RegisterMenuItem);
    CreateNative("IGA_UnregisterMenuItem", _UnregisterMenuItem);

    return APLRes_Success;
}

public OnPluginStart()
{
    LoadTranslations("in_game_audio.phrases");

    CreateConVar("sm_iga_version", PLUGIN_VERSION, PLUGIN_NAME, FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY | FCVAR_DONTRECORD);
    
    g_Cvar_IGAApiKey = CreateConVar("sm_iga_api_key", "", "API Key for your IGA webpage");
    g_Cvar_IGAUrl = CreateConVar("sm_iga_url", "", "URL to your IGA webpage");
    g_Cvar_IGAEnabled = CreateConVar("sm_iga_enabled", "1", "Whether or not pall is enabled");
    g_Cvar_IGARequestCooldownTime = CreateConVar("sm_iga_request_cooldown_time", "2.0", "How long in seconds before a client can send another http request");

    RegConsoleCmd("sm_vol", Command_Vol, "Adjust your play volume");
    RegConsoleCmd("sm_volume", Command_Vol, "Adjust your play volume");
    RegConsoleCmd("sm_nopall", Command_Nopall, "Turn off pall for yourself");
    RegConsoleCmd("sm_yespall", Command_Yespall, "Turn on pall for yourself");
    RegConsoleCmd("sm_iga", Command_IGA, "Bring up the IGA settings and control menu");
    RegConsoleCmd("sm_radio", Command_IGA, "Bring up the IGA settings and control menu");
    RegConsoleCmd("sm_music", Command_IGA, "Bring up the IGA settings and control menu");
    RegConsoleCmd("sm_jukebox", Command_IGA, "Bring up the IGA settings and control menu");
    RegConsoleCmd("sm_plast", Command_Plast, "Replay the last song for yourself");
    RegConsoleCmd("sm_ptoo", Command_Plast, "Replay the last song for yourself");
    RegConsoleCmd("sm_dumpiga", Command_DumpIGA, "[DEBUG] List the IGA settings for all clients on the server");

    g_Cookie_Volume = RegClientCookie("iga_volume_1.4", "Volume to play at [0-10]; 0 muted, 10 loudest", CookieAccess_Private);
    g_Cookie_PallEnabled = RegClientCookie("iga_pall_enabled_1.4", "Whether you want pall enabled or not. If yes, you will hear music when other players call !pall", CookieAccess_Private);

    g_MenuItems = CreateArray();
}

public OnAllPluginsLoaded()
{
    IGA_RegisterMenuItem("Disable/Enable Music Player", PallEnabledMenu);
    IGA_RegisterMenuItem("Stop Current Song (!stop)", StopSongMenu);
    IGA_RegisterMenuItem("Adjust Volume (!volume)", ChangeVolumeMenu);
    IGA_RegisterMenuItem("Help, I Don't Hear Anything!!!", TroubleShootingMenu);
    IGA_RegisterMenuItem("How Do I Upload Music?", HowToUploadMenu);
}

public OnClientConnected(client)
{
    if(IsFakeClient(client))
    {
        return;
    }
    g_IsInCooldown[client] = false;
    g_PNextFree[client] = 0;
    g_Volume[client] = 8;
    g_IsPallEnabled[client] = true;
    g_IsHtmlMotdDisabled[client] = -1;

    //Disable pall by default for quickplayers
    new String:connect_method[5];
    GetClientInfo(client, "cl_connectmethod", connect_method, sizeof(connect_method));
    if( strncmp("quick", connect_method, 5, false) == 0 ||
            strncmp("match", connect_method, 5, false) == 0)
    {
        g_IsPallEnabled[client] = false;
    }

}

public OnClientCookiesCached(client)
{
    new String:buffer[11];

    GetClientCookie(client, g_Cookie_Volume, buffer, sizeof(buffer));
    if (strlen(buffer) > 0){
        g_Volume[client] = StringToInt(buffer);
    }

    GetClientCookie(client, g_Cookie_PallEnabled, buffer, sizeof(buffer));
    if (strlen(buffer) > 0){
        g_IsPallEnabled[client] = bool:StringToInt(buffer);
    }
}

public OnClientPutInServer(client)
{
    if(IsFakeClient(client)) return;

    QueryClientConVar(client, "cl_disablehtmlmotd", OnMOTDQueried);
}

public OnMOTDQueried(QueryCookie:cookie, client, ConVarQueryResult:result, const String:cvarName[], const String:cvarValue[])
{
    if(!IsClientConnected(client)) return;

    if(result == ConVarQuery_Okay) {
        g_IsHtmlMotdDisabled[client] = (bool:StringToInt(cvarValue)) ? 1 : 0;
    } else {
        g_IsHtmlMotdDisabled[client] = -1;
    }

}

public OnMapStart()
{
    g_PallNextFree = 0;
}

public Action:Command_Vol(client, args)
{
    if (client && args != 1)
    {
        ChangeVolumeMenu(client);
        return Plugin_Handled;
    }

    if(client && IsClientAuthorized(client))
    {
        decl String:buffer[11];
        new volume;
        GetCmdArgString(buffer, sizeof(buffer));
        volume = StringToInt(buffer);
        SetClientVolume(client, volume);
    }

    return Plugin_Handled;
}

public Action:Command_Nopall(client, args)
{
    if (client && IsClientAuthorized(client))
    {
        SetPallEnabled(client, false);
    }
    return Plugin_Handled;
}

public Action:Command_Yespall(client, args)
{
    if (client && IsClientAuthorized(client))
    {
        SetPallEnabled(client, true);
    }
    return Plugin_Handled;
}

public Action:Command_IGA(client, args)
{
    if(client && IsClientAuthorized(client))
    {
        ShowIGAMenu(client);
    }

    return Plugin_Handled;
}

public Action:Command_Plast(client, args)
{
    if(IsClientInCooldown(client))
    {
        CReplyToCommand(client, "%t", "user_in_cooldown");
        return Plugin_Handled;
    }

    if(!IsIGAEnabled())
    {
        CReplyToCommand(client, "%t", "not_enabled");
        return Plugin_Handled;
    }

    if(client && IsClientAuthorized(client)){
        QuerySong(client, "", false, false, g_CurrentPlastSongId);
    }

    return Plugin_Handled;
}

//Test command to dump info.  Also useful to help debug a user's issues
public Action:Command_DumpIGA(caller, args)
{
    if(IsInPall())
    {
        PrintToConsole(caller, "pall -> '%s' %s %d", g_CurrentPallDescription, g_CurrentPallPath, g_CurrentPlastSongId);
        PrintToConsole(caller, "");

    }

    PrintToConsole(caller, "IsInCooldown !yespall cl_disablehtmlmotd !vol IsInP user");
    for (new client=1; client <= MaxClients; client++)
    {
        if(!IsClientInGame(client) || IsFakeClient(client))
            continue;

        PrintToConsole(caller, "%12d %8d %18d %4d %5d %L",
                g_IsInCooldown[client],
                g_IsPallEnabled[client],
                g_IsHtmlMotdDisabled[client],
                g_Volume[client],
                IsInP(client),
                client);
    }
    return Plugin_Handled;
}

SteamWorks_SetHTTPRequestGetOrPostParameterInt(&Handle:request, const String:param[], value)
{
    new String:tmp[64];
    IntToString(value, tmp, sizeof(tmp));
    SteamWorks_SetHTTPRequestGetOrPostParameter(request, param, tmp);
}

SetAccessCode(&Handle:request)
{
    decl String:api_key[128];
    GetConVarString(g_Cvar_IGAApiKey, api_key, sizeof(api_key));
    SteamWorks_SetHTTPRequestGetOrPostParameter(request, "access_token", api_key);
}

public _CreateIGARequest(Handle:plugin, args)
{ 
    new len;
    GetNativeStringLength(1, len);
    new String:route[len+1];
    GetNativeString(1, route, len+1);

    return _:CreateIGARequest(route);
}
Handle:CreateIGARequest(const String:route[])
{
    decl String:base_url[256], String:url[512];
    GetConVarString(g_Cvar_IGAUrl, base_url, sizeof(base_url));
    TrimString(base_url);
    new trim_length = strlen(base_url) - 1;

    if(trim_length < 0)
    {
        //IGA Url not set
        return INVALID_HANDLE;
    }

    //check for forward slash after base_url;
    if(base_url[trim_length] == '/')
    {
        strcopy(base_url, trim_length + 1, base_url);
    }

    Format(url, sizeof(url),
            "%s%s", base_url, route);

    new Handle:request = SteamWorks_CreateHTTPRequest(k_EHTTPMethodPOST, url);
    SetAccessCode(request);

    return request;
}

public _CreateIGAPopup(Handle:plugin, args)
{
    new len;
    GetNativeStringLength(2, len);
    new String:route[len+1];
    GetNativeString(2, route, len+1);

    GetNativeStringLength(3, len);
    new String:argstring[len+1];
    GetNativeString(3, argstring, len+1);

    CreateIGAPopup(GetNativeCell(1), route, argstring, bool:GetNativeCell(4), bool:GetNativeCell(5));
}
CreateIGAPopup(client, const String:route[]="", const String:args[]="", bool:popup=true, bool:fullscreen=true)
{
    //Don't display if client is a bot or not assigned a team
    if(!IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }
    decl String:url[256], String:base_url[128];
    GetConVarString(g_Cvar_IGAUrl, base_url, sizeof(base_url));

    TrimString(base_url);
    new trim_length = strlen(base_url) - 1;

    if(base_url[trim_length] == '/')
    {
        strcopy(base_url, trim_length + 1, base_url);
    }

    Format(url, sizeof(url),
            "%s%s/%s", base_url, route, args);

    new Handle:panel = CreateKeyValues("data");
    KvSetString(panel, "title", "In Game Audio");
    KvSetNum(panel, "type", MOTDPANEL_TYPE_URL);
    KvSetString(panel, "msg", url);
    if(popup && fullscreen) {KvSetNum(panel, "customsvr", 1);} //Sets motd to be fullscreen
    KvSetNum(panel, "cmd", 0);

    ShowVGUIPanelEx(client, "info", panel, popup, USERMSG_BLOCKHOOKS|USERMSG_RELIABLE);
    CloseHandle(panel);
}

ShowVGUIPanelEx(client, const String:name[], Handle:panel=INVALID_HANDLE, bool:show=true, user_message_flags=0)
{
    new Handle:msg = StartMessageOne("VGUIMenu", client, user_message_flags);

    if (GetFeatureStatus(FeatureType_Native, "GetUserMessageType") == FeatureStatus_Available && GetUserMessageType() == UM_Protobuf)
    {
        PbSetString(msg, "name", name);
        PbSetBool(msg, "show", true);

        if (panel != INVALID_HANDLE && KvGotoFirstSubKey(panel, false))
        {
            new Handle:subkey;

            do
            {
                decl String:key[128], String:value[128];
                KvGetSectionName(panel, key, sizeof(key));
                KvGetString(panel, NULL_STRING, value, sizeof(value), "");

                subkey = PbAddMessage(msg, "subkeys");
                PbSetString(subkey, "name", key);
                PbSetString(subkey, "str", value);

            } while (KvGotoNextKey(panel, false));
        }
    }
    else //BitBuffer
    {
        BfWriteString(msg, name);
        BfWriteByte(msg, show);

        if (panel == INVALID_HANDLE)
        {
            BfWriteByte(msg, 0);
        }
        else
        {   
            if (!KvGotoFirstSubKey(panel, false))
            {
                BfWriteByte(msg, 0);
            }
            else
            {
                new keys = 0;
                do
                {
                    ++keys;
                } while (KvGotoNextKey(panel, false));

                BfWriteByte(msg, keys);

                if (keys > 0)
                {
                    KvGoBack(panel);
                    KvGotoFirstSubKey(panel, false);
                    do
                    {
                        decl String:key[128], String:value[128];
                        KvGetSectionName(panel, key, sizeof(key));
                        KvGetString(panel, NULL_STRING, value, sizeof(value), "");

                        BfWriteString(msg, key);
                        BfWriteString(msg, value);
                    } while (KvGotoNextKey(panel, false));
                }
            }
        }
    }

    EndMessage();
}

public _StartCoolDown(Handle:plugin, args) { StartCooldown(GetNativeCell(1)); }
StartCooldown(client)
{
    //Ignore the server console
    if (client == 0)
        return;

    g_IsInCooldown[client] = true;
    CreateTimer(GetConVarFloat(g_Cvar_IGARequestCooldownTime), RemoveCooldown, client);
}

public _IsIGAEnabled(Handle:plugin, args) { return _:IsIGAEnabled(); }
bool:IsIGAEnabled()
{
    return GetConVarBool(g_Cvar_IGAEnabled);
}
public _ClientHasPallEnabled(Handle:plugin, args) { return _:ClientHasPallEnabled(GetNativeCell(1)); }
bool:ClientHasPallEnabled(client)
{
    return g_IsPallEnabled[client];
}
public _ClientHasHtmlMotdDisabled(Handle:plugin, args) { return _:ClientHasHtmlMotdDisabled(GetNativeCell(1)); }
bool:ClientHasHtmlMotdDisabled(client)
{
    return g_IsHtmlMotdDisabled[client] == 1;
}

public _SetPallEnabled(Handle:plugin, args) { SetPallEnabled(GetNativeCell(1), GetNativeCell(2)); }
SetPallEnabled(client, bool:val)
{
    if(val)
    {
        SetClientCookie(client, g_Cookie_PallEnabled, "1");
        g_IsPallEnabled[client] = true;
        CReplyToCommand(client, "%t", "enabled_pall");

    }else{
        SetClientCookie(client, g_Cookie_PallEnabled, "0");
        g_IsPallEnabled[client] = false;
        CReplyToCommand(client, "%t", "disabled_pall");
        StopSong(client);
    }
}

SetClientVolume(client, volume)
{
    if (volume >=0 && volume <= 10)
    {
        new String:tmp[11];
        IntToString(volume, tmp, sizeof(tmp));
        SetClientCookie(client, g_Cookie_Volume, tmp);
        g_Volume[client] = volume;
        CReplyToCommand(client, "%t", "volume_set", volume); //TODO remove mention that volume will not change for current song

        //Change volume for client's currently playing song
        new String:hash[32];
        Format(hash, sizeof(hash), "v=%f", (volume / 10.0));
        ReplaySong(client, hash);
    }else{
        CReplyToCommand(client, "%t", "volume_usage", g_Volume[client]);
    }

}

public _IsClientInCooldown(Handle:plugin, args) { return _:IsClientInCooldown(GetNativeCell(1)); }
bool:IsClientInCooldown(client)
{
    if(client == 0)
        return false;
    else
        return g_IsInCooldown[client];
}

public Action:RemoveCooldown(Handle:timer, any:client)
{
    g_IsInCooldown[client] = false;
}

public _IsInPall(Handle:plugin, args) { return _:IsInPall(); }
bool:IsInPall()
{
    return GetTime() < g_PallNextFree;
}

public _IsInP(Handle:plugin, args) { return _:IsInP(GetNativeCell(1)); }
bool:IsInP(client)
{
    return GetTime() < g_PNextFree[client];
}

public _QuerySong(Handle:plugin, args) {
    new len;
    GetNativeStringLength(2, len);
    new String:path[len+1];
    GetNativeString(2, path, len+1);

    QuerySong(GetNativeCell(1), path, GetNativeCell(3), GetNativeCell(4), GetNativeCell(5));
}
QuerySong(client, String:path[], bool:pall, bool:force, song_id)
{
    if (!IsIGAEnabled())
    {
        PrintToConsole(0, "%t", "not_enabled");
        return;
    }

    new Handle:request = CreateIGARequest(QUERY_SONG_ROUTE);
    new player = client > 0 ? GetClientUserId(client) : 0;

    if(request == INVALID_HANDLE)
    {
        CReplyToCommand(client, "%t", "url_invalid");
        return;
    }

    SteamWorks_SetHTTPRequestGetOrPostParameter(request, "path", path);
    SteamWorks_SetHTTPRequestGetOrPostParameterInt(request, "pall", pall);
    SteamWorks_SetHTTPRequestGetOrPostParameterInt(request, "force", force);

    if(song_id >= 0)
    {
        SteamWorks_SetHTTPRequestGetOrPostParameterInt(request, "song_id", song_id);
    }

    decl String:uid[MAX_COMMUNITYID_LENGTH];
    GetClientAuthId(client, AuthIdType:AuthId_SteamID64, uid, sizeof(uid));
    SteamWorks_SetHTTPRequestGetOrPostParameter(request, "uid", uid);

    SteamWorks_SetHTTPCallbacks(request, ReceiveQuerySong);
    SteamWorks_SetHTTPRequestContextValue(request, player);
    SteamWorks_SendHTTPRequest(request);

    StartCooldown(client);
}

//TODO Trim this method down
public ReceiveQuerySong(Handle:request, bool:failure, bool:successful, EHTTPStatusCode:code, any:userid)
{
    new client = GetClientOfUserId(userid);
    if(!successful || code != k_EHTTPStatusCode200OK)
    {
        LogError("[IGA] Error at RecivedQuerySong (HTTP Code %d; success %d)", code, successful);
        CloseHandle(request);
        return;
    }


    new size = 0;
    SteamWorks_GetHTTPResponseBodySize(request, size);
    new String:data[size];
    SteamWorks_GetHTTPResponseBodyData(request, data, size);
    CloseHandle(request);

    new Handle:json = json_load(data);
    new bool:found = json_object_get_bool(json, "found");
    new bool:multiple = json_object_get_bool(json, "multiple");


    if(found)
    {
        //Found a matching song
        new duration = json_object_get_int(json, "duration");
        new bool:pall = json_object_get_bool(json, "pall");
        new bool:force = json_object_get_bool(json, "force");
        new String:song_id[64], String:full_path[64], String:description[64], String:duration_formated[64], String:access_token[128];
        json_object_get_string(json, "song_id", song_id, sizeof(song_id));
        json_object_get_string(json, "full_path", full_path, sizeof(full_path));
        json_object_get_string(json, "description", description, sizeof(description));
        json_object_get_string(json, "duration_formated", duration_formated, sizeof(duration_formated));
        json_object_get_string(json, "access_token", access_token, sizeof(access_token));

        if(pall)
        {
            if(force || !IsInPall())
            {
                g_PNextFree[client]=0;

                CPrintToChatAll("%t", "started_playing_to_all", description);
                CPrintToChatAll("%t", "duration", duration_formated);
                CPrintToChatAll("%t", "to_stop_all");
                CPrintToChatAll("%t", "iga_settings");

                RegisterPall(duration, full_path, description);

                g_CurrentPlastSongId = StringToInt(song_id);

                WriteLog("%N: !pall(%s): %s | %s", client, song_id, full_path, description);
                PlaySongAll(song_id, access_token, force);
            }else{
                new minutes = (g_PallNextFree - GetTime()) / 60;
                new seconds = (g_PallNextFree - GetTime());

                if (minutes > 1)
                    CPrintToChat(client, "%t", "pall_currently_playing", g_CurrentPallPath, g_CurrentPallDescription, minutes, "minutes");
                else
                    CPrintToChat(client, "%t", "pall_currently_playing", g_CurrentPallPath, g_CurrentPallDescription, seconds, "seconds");
            }
        }else if(client > 0){
            decl String:name[64];
            GetClientName(client, name, sizeof(name));

            g_PNextFree[client] = duration + GetTime();

            CPrintToChatAll("%t", "started_playing_to_self", name, description, full_path);
            CPrintToChat(client, "%t", "duration", duration_formated);
            CPrintToChat(client, "%t", "to_stop");
            CPrintToChat(client, "%t", "iga_settings");

            g_CurrentPlastSongId = StringToInt(song_id);

            WriteLog("%N: !p(%s): %s | %s", client, song_id, full_path, description);
            PlaySong(client, song_id, access_token);
        }

    }else if(multiple){
        //A matching song was not found but we found a list of songs that could be what the user wants
        new String:tmp[64], String:description[64];
        new song_id;
        new bool:pall = json_object_get_bool(json, "pall");
        new bool:force = json_object_get_bool(json, "force");
        new Handle:songs = json_object_get(json, "songs");
        new Handle:song;
        new i = 0;

        new Handle:menu = CreateMenu(SongChooserMenuHandler, MENU_ACTIONS_DEFAULT|MenuAction_DrawItem|MenuAction_DisplayItem);

        //for each song in songs build selection menu
        while((song = json_array_get(songs, i)) != INVALID_HANDLE)
        {
            song_id = json_object_get_int(song, "song_id");
            json_object_get_string(song, "description", description, sizeof(description));

            //You can only pass one parameter to the menu so encode everything together
            Format(tmp, sizeof(tmp), "%d;%d;%d", pall, force, song_id);
            AddMenuItem(menu, tmp, description);

            i++;
            CloseHandle(song);
        }
        CloseHandle(songs);

        SetMenuTitle(menu, "Song Search");
        DisplayMenu(menu, client, MENU_TIME_FOREVER);

    }else{
        CPrintToChat(client, "%t", "not_found");
    }

    CloseHandle(json);
}

public _UserTheme(Handle:plugin, args) { UserTheme(GetNativeCell(1)); }
UserTheme(client)
{
    if (!IsIGAEnabled())
    {
        PrintToConsole(0, "%t", "not_enabled");
        return;
    }

    new Handle:request = CreateIGARequest(USER_THEME_ROUTE);

    if(request == INVALID_HANDLE)
    {
        PrintToConsole(0, "%t", "url_invalid");
        return;
    }

    //Find the user's theme
    decl String:uid[MAX_COMMUNITYID_LENGTH];
    GetClientAuthId(client, AuthIdType:AuthId_SteamID64, uid, sizeof(uid));
    SteamWorks_SetHTTPRequestGetOrPostParameter(request, "uid", uid);

    SteamWorks_SetHTTPCallbacks(request, ReceiveTheme);
    SteamWorks_SetHTTPRequestContextValue(request, 0);
    SteamWorks_SendHTTPRequest(request);
}

public _MapTheme(Handle:plugin, args)
{
    new len;
    GetNativeStringLength(2, len);
    new String:map[len+1];
    GetNativeString(2, map, len+1);

    MapTheme(GetNativeCell(1), map);
}
MapTheme(bool:force=true, String:map[] ="")
{
    if (!IsIGAEnabled())
    {
        PrintToConsole(0, "%t", "not_enabled");
        return;
    }

    new Handle:request = CreateIGARequest(MAP_THEME_ROUTE);

    if(request == INVALID_HANDLE)
    {
        PrintToConsole(0, "%t", "url_invalid");
        return;
    }

    SteamWorks_SetHTTPRequestGetOrPostParameterInt(request, "force", force);
    SteamWorks_SetHTTPRequestGetOrPostParameter(request, "map", map);

    SteamWorks_SetHTTPCallbacks(request, ReceiveTheme);
    SteamWorks_SetHTTPRequestContextValue(request, 0);
    SteamWorks_SendHTTPRequest(request);
}

public ReceiveTheme(Handle:request, bool:failure, bool:successful, EHTTPStatusCode:code, any:userid)
{
    if(!successful || code != k_EHTTPStatusCode200OK)
    {
        LogError("[IGA] Error at RecivedTheme (HTTP Code %d; success %d)", code, successful);
        CloseHandle(request);
        return;
    }

    new size = 0;
    SteamWorks_GetHTTPResponseBodySize(request, size);
    new String:data[size];
    SteamWorks_GetHTTPResponseBodyData(request, data, size);
    CloseHandle(request);

    new Handle:json = json_load(data);
    new bool:found = json_object_get_bool(json, "found");

    if(found)
    {
        new bool:force = json_object_get_bool(json, "force");
        new String:song_id[64], String:full_path[64], String:description[64], String:access_token[128];
        new duration = json_object_get_int(json, "duration");
        json_object_get_string(json, "song_id", song_id, sizeof(song_id));
        json_object_get_string(json, "full_path", full_path, sizeof(full_path));
        json_object_get_string(json, "description", description, sizeof(description));
        json_object_get_string(json, "access_token", access_token, sizeof(access_token));


        if(force && !IsInPall())
        {
            RegisterPall(duration, full_path, description);
        }

        if(force || !IsInPall())
        {
            WriteLog("theme(%s): %s | %s", song_id, full_path, description);
            PlaySongAll(song_id, access_token, force);
            CPrintToChatAll("%t", "iga_settings");
        }
    }

    CloseHandle(json);
}

public _PlaySongAll(Handle:plugin, args)
{
    new len;
    GetNativeStringLength(1, len);
    new String:song[len+1];
    GetNativeString(1, song, len+1);

    GetNativeStringLength(2, len);
    new String:access_token[len+1];
    GetNativeString(2, access_token, len+1);

    PlaySongAll(song, access_token, GetNativeCell(3));
}
PlaySongAll(String:song[], String:access_token[], bool:force)
{
    for (new client=1; client <= MaxClients; client++)
    {
        //Ignore players who can't hear this
        if(!IsClientInGame(client) || IsFakeClient(client) || g_Volume[client] < 1)
            continue;

        if(!ClientHasPallEnabled(client))
        {
            //Mention that pall is not enabled
            CPrintToChat(client, "%t", "pall_not_enabled");
            continue;
        }

        if(force || !IsInP(client))
        {
            PlaySong(client, song, access_token);
        }

    }
}

public _PlaySong(Handle:plugin, args)
{
    new len;
    GetNativeStringLength(2, len);
    new String:song[len+1];
    GetNativeString(2, song, len+1);

    GetNativeStringLength(3, len);
    new String:access_token[len+1];
    GetNativeString(3, access_token, len+1);

    PlaySong(GetNativeCell(1), song, access_token);
}
PlaySong(client, String:song_id[], String:access_token[])
{
    //Don't play song if client has a muted volume
    if(g_Volume[client] < 1) return;

    if(ClientHasHtmlMotdDisabled(client))
    {
        //Mention that you should enable html motds
        CPrintToChat(client, "%t", "html_motd_not_enabled");
    }

    decl String:args[256];
    Format(args, sizeof(args),
            "%s/play?access_token=%s&volume=%f", song_id, access_token, (g_Volume[client] / 10.0));
    strcopy(g_CachedURLArgs[client], 256, args); //Cache args in case we need to pass a hash arg

    CreateIGAPopup(client, SONGS_ROUTE, args, false);
}

//Replay the song the client is currently listening to but with a different url hash argument
ReplaySong(client, String:hash[])
{
    //Don't re-play song if client won't hear anything
    if(g_Volume[client] < 1) return;
    if(ClientHasHtmlMotdDisabled(client)) return;

    decl String:args[256];
    Format(args, sizeof(args),
            "%s#%s", g_CachedURLArgs[client], hash);

    CreateIGAPopup(client, SONGS_ROUTE, args, false);
}

public _StopSong(Handle:plugin, args) { StopSong(GetNativeCell(1)); }
StopSong(client)
{
    g_PNextFree[client] = 0;

    new Handle:panel = CreateKeyValues("data");
    KvSetString(panel, "title", "Stop In Game Audio");
    KvSetNum(panel, "type", MOTDPANEL_TYPE_URL);
    //KvSetString(panel, "msg", "javascript:windowClosed()");
    KvSetString(panel, "msg", "about:blank");
    KvSetNum(panel, "cmd", 0);

    ShowVGUIPanelEx(client, "info", panel, false, USERMSG_BLOCKHOOKS|USERMSG_RELIABLE);
    CloseHandle(panel);
}

public _StopSongAll(Handle:plugin, args) { StopSongAll(); }
StopSongAll()
{
    g_PallNextFree = 0;
    for (new client=1; client <= MaxClients; client++)
    {
        if(!IsClientInGame(client) || IsFakeClient(client))
            continue;

        if ( !IsInP(client) ) 
        {
            StopSong(client);
        }
    }
}

public _RegisterPall(Handle:plugin, args)
{
    new len;
    GetNativeStringLength(2, len);
    new String:path[len+1];
    GetNativeString(2, path, len+1);

    GetNativeStringLength(3, len);
    new String:description[len+1];
    GetNativeString(3, description, len+1);

    RegisterPall( GetNativeCell(1), path, description);
}
RegisterPall(duration, String:path[], String:description[])
{
    g_PallNextFree = duration + GetTime();
    strcopy(g_CurrentPallPath, 64, path);
    strcopy(g_CurrentPallDescription, 64, description);
}


//Menu Logic

public _RegisterMenuItem(Handle:plugin, args)
{
    decl String:plugin_name[PLATFORM_MAX_PATH];
    GetPluginFilename(plugin, plugin_name, sizeof(plugin_name));

    new Handle:plugin_forward = CreateForward(ET_Single, Param_Cell, Param_CellByRef);	
    if (!AddToForward(plugin_forward, plugin, GetNativeCell(2)))
        ThrowError("Failed to add forward from %s", plugin_name);

    new len;
    GetNativeStringLength(1, len);
    new String:title[len+1];
    GetNativeString(1, title, len+1);

    new Handle:new_item = CreateArray(15);
    new id = g_MenuId++;

    PushArrayString(new_item, plugin_name);
    PushArrayString(new_item, title);
    PushArrayCell(new_item, id);
    PushArrayCell(new_item, plugin_forward);
    PushArrayCell(g_MenuItems, new_item);

    return id;
}


public _UnregisterMenuItem(Handle:plugin, args)
{
    new Handle:tmp;
    for (new i = 0; i < GetArraySize(g_MenuItems); i++)
    {
        tmp = GetArrayCell(g_MenuItems, i);
        new id = GetArrayCell(tmp, 2);
        if (id == GetNativeCell(1))
        {
            RemoveFromArray(g_MenuItems, i);
            return true;
        }
    }
    return false;
}

ShowIGAMenu(client)
{
    new Handle:menu = CreateMenu(IGAMenuSelected);
    SetMenuTitle(menu,"IGA Menu");

    decl Handle:item, String:tmp[64], String:item_number[4];

    for(new i = 0; i < GetArraySize(g_MenuItems); i++)
    {
        FormatEx(item_number, sizeof(item_number), "%i", i);
        item = GetArrayCell(g_MenuItems, i);
        GetArrayString(item, 1, tmp, sizeof(tmp));

        AddMenuItem(menu, item_number, tmp, ITEMDRAW_DEFAULT);
    }

    DisplayMenu(menu, client, 20);
}


public IGAMenuSelected(Handle:menu, MenuAction:action, param1, param2)
{
    decl String:tmp[32], selected;
    GetMenuItem(menu, param2, tmp, sizeof(tmp));
    selected = StringToInt(tmp);

    switch (action)
    {
        case MenuAction_Select:
            {
                new Handle:item = GetArrayCell(g_MenuItems, selected);
                new Handle:plugin_forward = GetArrayCell(item, 3);
                new bool:result;
                Call_StartForward(plugin_forward);
                Call_PushCell(param1);
                Call_Finish(result);
            }
        case MenuAction_End: CloseHandle(menu);
    }
}

public IGAMenu:ChangeVolumeMenu(client)
{
    new Handle:menu = CreateMenu(ChangeVolumeMenuHandler);
    new volume = g_Volume[client];

    SetMenuTitle(menu, "Set IGA volume (!vol)");

    if(volume == 1)
    {AddMenuItem(menu , "1"  , "*█_________(min)");}
    else
    {AddMenuItem(menu , "1"  , "_█_________(min)");}

    if(volume == 2)
    {AddMenuItem(menu , "2"  , "*██________");}
    else
    {AddMenuItem(menu , "2"  , "_██________");}

    if(volume == 3)
    {AddMenuItem(menu , "3"  , "*███_______");}
    else
    {AddMenuItem(menu , "3"  , "_███_______");}

    if(volume == 4)
    {AddMenuItem(menu , "4"  , "*████______");}
    else
    {AddMenuItem(menu , "4"  , "_████______");}

    if(volume == 5)
    {AddMenuItem(menu , "5"  , "*█████_____");}
    else
    {AddMenuItem(menu , "5"  , "_█████_____");}

    if(volume == 6)
    {AddMenuItem(menu , "6"  , "*██████____");}
    else
    {AddMenuItem(menu , "6"  , "_██████____");}

    if(volume == 7)
    {AddMenuItem(menu , "7"  , "*███████___");}
    else
    {AddMenuItem(menu , "7"  , "_███████___");}

    if(volume == 8)
    {AddMenuItem(menu , "8"  , "*████████__");}
    else
    {AddMenuItem(menu , "8"  , "_████████__");}

    if(volume == 9)
    {AddMenuItem(menu , "9"  , "*█████████_");}
    else
    {AddMenuItem(menu , "9"  , "_█████████_");}

    if(volume == 10)
    {AddMenuItem(menu , "10" , "*██████████(max)");}
    else
    {AddMenuItem(menu , "10" , "_██████████(max)");}


    SetMenuExitButton(menu, false);
    SetMenuPagination(menu, MENU_NO_PAGINATION);

    DisplayMenu(menu, client, 20);
}

public ChangeVolumeMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
    switch (action)
    {
        case MenuAction_Select:
            {
                new String:info[32];
                GetMenuItem(menu, param2, info, sizeof(info));
                new volume = StringToInt(info);
                new client = param1;
                SetClientVolume(client, volume);
            }
        case MenuAction_End: CloseHandle(menu);
    }
}

public IGAMenu:PallEnabledMenu(client)
{
    new Handle:menu = CreateMenu(PallEnabledMenuHandler);

    SetMenuTitle(menu, "Listen To Unrequested Music?");

    if(g_IsPallEnabled[client])
    {
        AddMenuItem(menu , "1" , "*Yes (!yespall)");
        AddMenuItem(menu , "0" , " No  (!nopall)" );
    }else{
        AddMenuItem(menu , "1" , " Yes (!yespall)");
        AddMenuItem(menu , "0" , "*No  (!nopall)" );
    }

    DisplayMenu(menu, client, 20);
}

public PallEnabledMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
    switch (action)
    {
        case MenuAction_Select:
            {
                new String:info[32];
                GetMenuItem(menu, param2, info, sizeof(info));
                new bool:val = bool:StringToInt(info);
                new client = param1;
                SetPallEnabled(client, val);
            }
        case MenuAction_End: CloseHandle(menu);
    }
}

public IGAMenu:StopSongMenu(client) StopSong(client);

public IGAMenu:TroubleShootingMenu(client)
{
    //List some steps that can fix the problem
    if (!ClientHasPallEnabled(client))
    {
        CPrintToChat(client, "%t", "pall_not_enabled");
    }

    if (g_Volume[client] < 1)
    {
        CPrintToChat(client, "%t", "volume_muted");
    }

    if (g_IsHtmlMotdDisabled[client] != 0)
    {
        CPrintToChat(client, "%t", "motd_not_enabled");
    }
}

public IGAMenu:HowToUploadMenu(client)
{
    decl String:base_url[256];
    GetConVarString(g_Cvar_IGAUrl, base_url, sizeof(base_url));
    CPrintToChatAll("%t", "how_to_upload", base_url);
}

public SongChooserMenuHandler(Handle:menu, MenuAction:action, param1, param2)
{
    switch (action)
    {
        case MenuAction_Select:
            {
                new String:data[32];
                GetMenuItem(menu, param2, data, sizeof(data));
                new client = param1;

                decl String:bit[3][64];
                ExplodeString(data, ";", bit, sizeof(bit), sizeof(bit[]));

                new bool:pall = bool:StringToInt(bit[0]);
                new bool:force = bool:StringToInt(bit[1]);
                new song_id = StringToInt(bit[2]);

                QuerySong(client, "", pall, force, song_id);
            }
        case MenuAction_End: CloseHandle(menu);
    }
}

stock WriteLog(const String:format[], any:... )
{
#if defined DEBUG
    if(format[0] != '\0')
    {
        decl String:buf[2048];
        VFormat(buf, sizeof(buf), format, 2 );
        //LogToFileEx("log_iga.txt", "[%.3f] %s", GetGameTime(), buf);
        PrintToServer("[IGA] %s", buf);
    }
#endif
}
