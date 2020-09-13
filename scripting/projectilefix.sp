#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <dhooks>
#include <sdktools>

#define EFL_CHECK_UNTOUCH (1<<24)


Handle g_hPhysicsSimulate;
Handle g_hFireProjectile;
Handle g_hCallPhysicsSimulate;
Handle g_hPhysicsCheckForEntityUntouch;
bool   g_bAllowSimulate;
Address g_pGlobalVarsTickCount;
Address g_pGlobalVarsCurtime;
bool g_bDebugRefire;

bool g_bLatencyFix[MAXPLAYERS + 1];
bool g_bSimFix[MAXPLAYERS + 1];
float g_flPingOffset[MAXPLAYERS + 1];

int g_iCurrentTick;
ArrayList g_clientRockets[MAXPLAYERS+1];
int g_offsCollisionGroup;
int g_iEntityFlagsOffset;

int g_iPlayerCommandCount[MAXPLAYERS + 1];
int g_iNextPrimaryAttackOverride[MAXPLAYERS + 1];
bool g_bOverrideFireDelay[MAXPLAYERS + 1];
//int g_iPlayerActiveWeaponIdx[MAXPLAYERS + 1];

enum struct RocketData {
    bool bGhost;
    bool bSpawned;
    int iOwner;
    int iNumTicksSimulated;
}

RocketData g_aRocketData[2048];


public Plugin myinfo =
{
    name = "projectilefix",
    author = "jayess",
    description = "fixes for rockets and (eventually, hopefully) stickybombs in tf2",
    version = "0.0",
    url = "https://github.com/jsza/projectilefix"
}

public void OnGameFrame() {
    g_iCurrentTick = GetGameTickCount();
}


public void OnPluginStart() {
    g_offsCollisionGroup = FindSendPropInfo("CBaseEntity", "m_CollisionGroup");
    g_iEntityFlagsOffset = FindDataMapInfo(0, "m_iEFlags");

    GameData data = LoadGameConfigFile("projectilefix.games");
    if (!data)
        SetFailState("Missing gamedata!");

    int offset;
    offset = data.GetOffset("CBaseEntity::PhysicsSimulate");
    g_hPhysicsSimulate = DHookCreate(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, PrePhysicsSimulate);

    offset = data.GetOffset("CTFRocketLauncher::FireProjectile");
    g_hFireProjectile = DHookCreate(offset, HookType_Entity, ReturnType_CBaseEntity, ThisPointer_CBaseEntity, FireProjectilePost);
    DHookAddParam(g_hFireProjectile, HookParamType_CBaseEntity);

    StartPrepSDKCall(SDKCall_Entity);
    PrepSDKCall_SetFromConf(data, SDKConf_Virtual, "CBaseEntity::PhysicsSimulate");
    g_hCallPhysicsSimulate = EndPrepSDKCall();

    //StartPrepSDKCall(SDKCall_Entity);
    //PrepSDKCall_SetFromConf(data, SDKConf_Signature, "CBaseEntity::PhysicsCheckForEntityUntouch");
    //g_hPhysicsCheckForEntityUntouch = EndPrepSDKCall();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client)) {
            OnClientPutInServer(client);
        }
    }

    StartPrepSDKCall(SDKCall_Static);
    if(!PrepSDKCall_SetFromConf(data, SDKConf_Signature, "CreateInterface"))
    {
        SetFailState("Failed to get CreateInterface");
        CloseHandle(data);
    }

    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Pointer, VDECODE_FLAG_ALLOWNULL);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);

    Handle call = EndPrepSDKCall();
    Address pPlayerInfoManager;
    pPlayerInfoManager = SDKCall(call, "PlayerInfoManager002", 0);
    CloseHandle(call);

    StartPrepSDKCall(SDKCall_Raw);
    if(!PrepSDKCall_SetFromConf(data, SDKConf_Virtual, "CPlayerInfoManager::GetGlobalVars")) {
        SetFailState("Failed to get GetGlobalVars");
        CloseHandle(data);
    }

    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    call = EndPrepSDKCall();
    Address pGlobalVars;
    pGlobalVars = SDKCall(call, pPlayerInfoManager);
    g_pGlobalVarsTickCount = pGlobalVars + view_as<Address>(24);
    g_pGlobalVarsCurtime = pGlobalVars + view_as<Address>(12);

    RegConsoleCmd("sm_rocketsim", cmdToggleRocketSim, "Enable/disable simulation fix.");
    RegConsoleCmd("sm_rocketping", cmdToggleLatencyFix, "Enable/disable latency fix.");
    RegConsoleCmd("sm_rocketpingoffset", cmdRocketPingOffset, "Add offset to rocket ping fix.");
}

public Action cmdToggleLatencyFix(int client, int args)
{
    g_bLatencyFix[client] = !g_bLatencyFix[client];
    PrintToChat(client, "[Rocket latency fix] Now %s.", g_bLatencyFix[client] ? "enabled" : "disabled");
}

public Action cmdToggleRocketSim(int client, int args)
{
    g_bSimFix[client] = !g_bSimFix[client];
    PrintToChat(client, "[Rocket sim fix] Now %s.", g_bSimFix[client] ? "enabled" : "disabled");
}

public Action cmdRocketPingOffset(int client, int args)
{
    if (args < 1) {
        return;
    }
    char arg[65];
    GetCmdArg(1, arg, sizeof(arg));
    float offset = StringToFloat(arg);
    g_flPingOffset[client] = 1.0 / offset;
    PrintToChat(client, "[Rocket latency fix] offset set to %f.", offset);
}

public void OnClientPutInServer(int client) {
    g_clientRockets[client] = new ArrayList();
    SDKHook(client, SDKHook_PreThink, PrePlayerThink);
    SDKHook(client, SDKHook_PostThinkPost, PostPlayerThink);
    g_bLatencyFix[client] = false;
    g_bSimFix[client] = false;
    g_flPingOffset[client] = 0.0;
    g_iPlayerCommandCount[client] = 0;
    g_iNextPrimaryAttackOverride[client] = 0;
    g_bOverrideFireDelay[client] = false;
}

public void DelayGhost(int entity) {
    if (IsValidEntity(entity)) {
        SpawnGhost(entity);
    }
}

// with player-bound rocket simulation, rockets appear jittery to the client
// when rocket simulation doesn't occur on a given server frame
//
// cloning the rocket and hiding the original provides an indicator of the real
// path without affecting the physics of it
//
// we also use the ghost for the latency fix
void SpawnGhost(int ref) {
    int entity = EntRefToEntIndex(ref);
    if (entity ==  INVALID_ENT_REFERENCE) {
        return;
    }
    int owner = g_aRocketData[entity].iOwner;

    float origin[3], angles[3], velocity[3], adjustOrigin[3], newOrigin[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
    GetEntPropVector(entity, Prop_Data, "m_angAbsRotation", angles);
    GetEntPropVector(entity, Prop_Data, "m_vecAbsVelocity", velocity);

    if (g_bLatencyFix[owner]) {
        // CHECK: not sure if this matches how far the client actually is
        // behind the server; can we maybe use CBasePlayer::m_nTickBase
        // somehow?
        float latency = GetClientAvgLatency(owner, NetFlow_Outgoing);
        latency -= g_flPingOffset[owner];
        adjustOrigin[0] = velocity[0];
        adjustOrigin[1] = velocity[1];
        adjustOrigin[2] = velocity[2];
        ScaleVector(adjustOrigin, latency);
        AddVectors(origin, adjustOrigin, adjustOrigin);

        // trace ahead to avoid spawning the rocket behind any brushes
        float vMins[3], vMaxs[3];
        GetEntPropVector(entity, Prop_Send, "m_vecMins", vMins);
        GetEntPropVector(entity, Prop_Send, "m_vecMaxs", vMaxs);
        Handle trace;
        trace = TR_TraceHullFilterEx(origin, adjustOrigin, vMins, vMaxs, MASK_PLAYERSOLID_BRUSHONLY, TraceRayDontHitSelf, owner);
        if (TR_DidHit(trace)) {
            TR_GetEndPosition(newOrigin, trace);
            PrintToServer("did hit, %f %f %f", newOrigin[0], newOrigin[1], newOrigin[2]);
            CloseHandle(trace);
        }
        else {
            newOrigin[0] = adjustOrigin[0];
            newOrigin[1] = adjustOrigin[1];
            newOrigin[2] = adjustOrigin[2];
            CloseHandle(trace);
        }
    }
    else {
        newOrigin[0] = origin[0];
        newOrigin[1] = origin[1];
        newOrigin[2] = origin[2];
    }

    int ghost = CreateEntityByName("tf_projectile_rocket");
    g_aRocketData[ghost].bGhost = true;
    SetEntData(ghost, g_offsCollisionGroup, GetEntData(entity, g_offsCollisionGroup, 4), 4, true);
    TeleportEntity(ghost, newOrigin, angles, velocity);
    SetEntProp(ghost, Prop_Send, "m_iTeamNum", GetEntProp(entity, Prop_Send, "m_iTeamNum"));
    SetEntPropEnt(ghost, Prop_Send, "m_hOwnerEntity", owner);
    // without this hook, the ghost instantly explodes the original rocket for
    // some reason
    SDKHook(ghost, SDKHook_ShouldCollide, GhostShouldCollide);
    DispatchSpawn(ghost);
}

int lastFiredRocket;

public void ProjectileSpawned(int entity) {
    // SDKHook_Spawn is apparently called twice; store'n'ignore
    if (g_aRocketData[entity].bSpawned) {
        return;
    }
    g_aRocketData[entity].bSpawned = true;
    int owner = GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity");
    // ignore world-owned rockets
    if (1 <= owner <= MaxClients) {
        g_aRocketData[entity].iOwner = owner;
        float origin[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);

        // don't spawn copies of the ghost rocket; this is not an infinite
        // recursion plugin
        if (!g_aRocketData[entity].bGhost) {
            g_bDebugRefire = true;
            float angles[3];
            GetEntPropVector(entity, Prop_Data, "m_angAbsRotation", angles);
            //PrintToServer("%f %f %f", angles[0], angles[1], angles[2]);
            DHookEntity(g_hPhysicsSimulate, false, entity);
            // spawn the ghost next frame where velocity etc. are set
            //
            // also lets us spawn the ghost with the real rocket's position if
            // we simulate it more than once this frame
            RequestFrame(SpawnGhost, EntIndexToEntRef(entity));
            if (g_bLatencyFix[owner]) {
                SDKHook(entity, SDKHook_SetTransmit, Hook_HideFromOwner);
            }
            else {
                SDKHook(entity, SDKHook_SetTransmit, Hook_HideFromAll);
            }
            g_clientRockets[owner].Push(entity);
            //PrintToServer("[%d] tick %d | %d | rocket spawned [%f %f %f]", entity, g_iCurrentTick, GetGameTickCount(), origin[0], origin[1], origin[2]);
        }
        else {
            // tracking simulated ticks only
            DHookEntity(g_hPhysicsSimulate, false, entity);
            if (g_bLatencyFix[owner]) {
                SDKHook(entity, SDKHook_SetTransmit, Hook_ShowOnlyToOwner);
            }
            //PrintToServer("[%d] tick %d | %d | ghost spawned [%f %f %f]", entity, g_iCurrentTick, GetGameTickCount(), origin[0], origin[1], origin[2]);
        }
    }
}

public Action Hook_HideFromAll(int entity, int client) {
    return Plugin_Handled;
}


public Action Hook_HideFromOwner(int entity, int client) {
    if (client == g_aRocketData[entity].iOwner) {
        return Plugin_Handled;
    }
    else {
        return Plugin_Continue;
    }
}

public Action Hook_ShowOnlyToOwner(int entity, int client) {
    if (client != g_aRocketData[entity].iOwner) {
        return Plugin_Handled;
    }
    else {
        return Plugin_Continue;
    }
}

public bool GhostShouldCollide(int entity, int collisiongroup, int contentsmask, bool result) {
    //PrintToServer("ShouldCollide %d", entity);
    char classname[128];
    GetEdictClassname(entity, classname, sizeof(classname));
    //GetEntPropString(entity, Prop_Data, "m_iName", targetname, sizeof(targetname));
    if (StrEqual(classname, "tf_projectile_rocket")) {
        result = false;
        return false;
    }
    else {
        PrintToServer("%s %d", classname, entity);
        result = true;
        return true;
    }
}

public MRESReturn FireProjectilePost(int entity, Handle hReturn, Handle hParams) {
    int owner = GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity");
    // 0.8 seconds rounded up to nearest tick
    // TODO: find a better way to get the original refire delay
    g_iNextPrimaryAttackOverride[owner] = g_iPlayerCommandCount[owner] + 54;
    g_bOverrideFireDelay[owner] = true;
    PrintToServer("%d", g_iPlayerCommandCount[owner] - lastFiredRocket);
    lastFiredRocket = g_iPlayerCommandCount[owner];
    return MRES_Ignored;
}

public void OnEntityCreated(int entity, const char[] classname) {
    if (StrEqual(classname, "tf_projectile_rocket")) {
        g_aRocketData[entity].bSpawned = false;
        g_aRocketData[entity].bGhost = false;
        g_aRocketData[entity].iOwner = -1;
        g_aRocketData[entity].iNumTicksSimulated = 0;
        SDKHook(entity, SDKHook_Spawn, ProjectileSpawned);
    }
    else if (StrEqual(classname, "tf_weapon_rocketlauncher")) {
        DHookEntity(g_hFireProjectile, true, entity);
    }
}

public void OnEntityDestroyed(int entity) {
    //RocketData rocketData = g_aRocketData[entity];
    if (entity <= MaxClients || entity > 2048)
        return;

    if (g_aRocketData[entity].bSpawned) {
        g_aRocketData[entity].bSpawned = false;
        int rocketTick = g_aRocketData[entity].iNumTicksSimulated;
        char targetname[128];
        GetEntPropString(entity, Prop_Data, "m_iName", targetname, sizeof(targetname));
        float origin[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", origin);
        if (g_aRocketData[entity].bGhost) {
            //PrintToServer("[%d] tick %d | %d | ghost exploded after %f seconds [%f %f %f]", entity, g_iCurrentTick, GetGameTickCount(), rocketTick * GetTickInterval(), origin[0], origin[1], origin[2]);
        }
        else {
            //PrintToServer("[%d] tick %d | %d | rocket exploded after %f seconds [%f %f %f]", entity, g_iCurrentTick, GetGameTickCount(), rocketTick * GetTickInterval(), origin[0], origin[1], origin[2]);
            //PrintToServer("%d / %d", g_iPlayerTickBase[GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity")], GetGameTickCount());
        }
        int owner = GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity");
        if (1 <= owner <= MaxClients) {
            ArrayList rockets = g_clientRockets[owner];
            int idx = rockets.FindValue(entity);
            if (idx != -1) {
                rockets.Erase(idx);
            }
        }
    }
    else {
        return;
    }
}


public MRESReturn PrePhysicsSimulate(int entity, Handle hReturn, Handle hParams) {
    char targetname[128];
    GetEntPropString(entity, Prop_Data, "m_iName", targetname, sizeof(targetname));
    if (g_aRocketData[entity].bGhost) {
        g_aRocketData[entity].iNumTicksSimulated++;
        return MRES_Ignored;
    }
    else if (!g_bSimFix[g_aRocketData[entity].iOwner]) {
        g_aRocketData[entity].iNumTicksSimulated++;
        return MRES_Ignored;
    }
    if (!g_bAllowSimulate) {
        return MRES_Supercede;
    }
    else {
        g_aRocketData[entity].iNumTicksSimulated++;
        return MRES_Ignored;
    }
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon) {
    if (IsFakeClient(client)) return;
    int weaponIdx = GetPlayerWeaponSlot(client, 0);
    if (g_bOverrideFireDelay[client]) {
        int nextPrimaryAttack = g_iNextPrimaryAttackOverride[client];
        if (g_iPlayerCommandCount[client] < nextPrimaryAttack) {
            buttons &= ~IN_ATTACK;
        }
        else {
            // let the player fire immediately
            SetEntPropFloat(weaponIdx, Prop_Send, "m_flNextPrimaryAttack", 0.0);
            g_bOverrideFireDelay[client] = false;
        }
    }
}

public void PrePlayerThink(int client) {
    if (IsFakeClient(client)) return;

    ArrayList rockets = g_clientRockets[client].Clone();
    for (int i = 0; i < rockets.Length; i++) {
        int entity = rockets.Get(i);
        if (IsValidEntity(entity) && g_bSimFix[client]) {
            int currentTick = GetGameTickCount();
            float currentCurtime = GetGameTime();
            int orig_m_nSimulationTick = GetEntProp(entity, Prop_Data, "m_nSimulationTick");
            // allows us to force the entity to simulate multiple times per tick
            // see https://github.com/ValveSoftware/source-sdk-2013/blob/master/mp/src/game/shared/physics_main_shared.cpp#L1793
            SetEntProp(entity, Prop_Data, "m_nSimulationTick", -1);

            // without this, the rocket seems to get the timebase of the
            // player, which causes some weirdness
            //
            /// set globalvars->tickcount to the current real tickcount
            /// set globalvars->curtime to the current real curtime
            SetGlobalTickCount(g_iCurrentTick);
            SetGlobalCurtime(g_iCurrentTick * GetTickInterval());

            // debugging
            float before[3];
            float after[3];
            GetEntPropVector(entity, Prop_Send, "m_vecOrigin", before);

            // allow our PrePhysicsSimulate hook to continue
            g_bAllowSimulate = true;
            SDKCall(g_hCallPhysicsSimulate, entity);
            g_bAllowSimulate = false;

            // return to previous values
            SetGlobalTickCount(currentTick);
            SetGlobalCurtime(currentCurtime);

            // TODO: is this necessary?
            SetEntProp(entity, Prop_Data, "m_nSimulationTick", orig_m_nSimulationTick);

            // debugging
            GetEntPropVector(entity, Prop_Send, "m_vecOrigin", after);
            if (before[0] == after[0] ||
                before[1] == after[1] ||
                before[2] == after[2])
                PrintToServer("[%d] tick %d | didn't move!", entity, GetGameTickCount());
            //if (GetEntData(entity, g_iEntityFlagsOffset) & EFL_CHECK_UNTOUCH) {
            //    SDKCall(g_hPhysicsCheckForEntityUntouch, entity);
            //}
        }

    }
    delete rockets;
}

public void PostPlayerThink(int client) {
    g_iPlayerCommandCount[client]++;
}

void SetGlobalTickCount(int tickcount) {
    StoreToAddress(g_pGlobalVarsTickCount, tickcount, NumberType_Int32);
}

void SetGlobalCurtime(float curtime) {
    StoreToAddress(g_pGlobalVarsCurtime, view_as<int>(curtime), NumberType_Int32);
}

public bool TraceRayDontHitSelf(int entity, int mask, any data)
{
    // Don't return players or player projectiles
    int entity_owner;
    entity_owner = GetEntPropEnt(entity, Prop_Data, "m_hOwnerEntity");

    if (entity != data && !(0 < entity <= MaxClients) && !(0 < entity_owner <= MaxClients))
    {
        return true;
    }
    return false;
}
